--[[ ===========================================================================
  ConLogsRelay.lua — embed ConLogs gear/talent data into WoWCombatLog.txt via the
  SPELL_CAST_FAILED relay (a.k.a. CLEU hijack / "LegacyPlayers-style").

  How it works: while logging + in an instance + in combat, the head chunk string is
  written into the SPELL_FAILED_* global error strings. The next failed cast makes the
  client write that string as the SPELL_CAST_FAILED `failedType` field into
  WoWCombatLog.txt. The server reassembles the chunks from the uploaded log.

  Spike-confirmed on the Project Epoch client (2026-06-03): the sentinel lands at CLEU
  arg index 12, and the failedType field carries ~1023 chars (~950 usable after the
  chunk header). No UnitPosition / LibDeflate on this client, so payloads are the
  addon's existing `^`-delimited wire string, base64'd (no compression yet).

  DEFAULT ON — runs for every user, so any /combatlog automatically embeds the data.
  Disable per-user with `/conlogs relay off` (sets ConLogsDB.config.relayEnabled=false).
  NOTE: overwriting the fail-reason globals taints the secure environment; the taint/
  UIErrors suppression below keeps that invisible, but harden before a public release.
  Commands: /conlogs relay on | off | status | test
=========================================================================== ]]--

local PREFIX_FAMILY = "[[CL_"   -- landed-evidence family prefix (all our chunk kinds share it)
local CI_PREFIX     = "[[CL_CI_v1_"
local TS_PREFIX     = "[[CL_TS_v1_"   -- telemetry snapshot (positions)
local TELEMETRY_INTERVAL = 2.0        -- seconds between position snapshots
local CHUNK_BODY    = 850       -- base64 chars per chunk (field cap ~1023, header ~46)
local QUEUE_MAX     = 400       -- ring cap
local CHUNK_TTL     = 600       -- seconds a chunk waits before TTL-evict
local CI_REENQUEUE_S = 120      -- don't re-enqueue group CI more often than this
local FAILEDTYPE_ARG = 12       -- spike-confirmed CLEU arg index of failedType on PE

-- Broad SPELL_FAILED_* set (proven, most-observed first). The more we cover, the more
-- failed casts carry a chunk; landed-evidence gating handles the uncovered/C-side ones.
local FAIL_GLOBALS = {
    "SPELL_FAILED_NOT_READY", "SPELL_FAILED_ITEM_NOT_READY", "SPELL_FAILED_INTERRUPTED",
    "SPELL_FAILED_INTERRUPTED_COMBAT", "SPELL_FAILED_OUT_OF_RANGE", "SPELL_FAILED_LINE_OF_SIGHT",
    "SPELL_FAILED_INVALID_TARGET", "SPELL_FAILED_BAD_TARGETS", "SPELL_FAILED_NO_TARGETS",
    "SPELL_FAILED_BAD_IMPLICIT_TARGETS", "SPELL_FAILED_TARGETS_DEAD", "SPELL_FAILED_CASTER_DEAD",
    "SPELL_FAILED_UNIT_NOT_INFRONT", "SPELL_FAILED_NOT_INFRONT", "SPELL_FAILED_NOT_BEHIND",
    "SPELL_FAILED_TOO_CLOSE", "SPELL_FAILED_AFFECTING_COMBAT", "SPELL_FAILED_SPELL_IN_PROGRESS",
    "SPELL_FAILED_ALREADY_AT_FULL_HEALTH", "SPELL_FAILED_ALREADY_AT_FULL_POWER",
    "SPELL_FAILED_CASTER_AURASTATE", "SPELL_FAILED_STUNNED", "SPELL_FAILED_CHARMED",
    "SPELL_FAILED_CONFUSED", "SPELL_FAILED_FLEEING", "SPELL_FAILED_PACIFIED",
    "SPELL_FAILED_SILENCED", "SPELL_FAILED_IMMUNE", "SPELL_FAILED_NO_COMBO_POINTS",
    "SPELL_FAILED_MOVING", "SPELL_FAILED_NOT_HERE", "SPELL_FAILED_ONLY_STEALTHED",
    "SPELL_FAILED_LOW_CASTLEVEL", "SPELL_FAILED_MOREPOWERFULSPELLACTIVE",
    "SPELL_FAILED_TOO_MANY_OF_ITEM", "SPELL_FAILED_CANT_CAST_ON_TAPPED",
}

--==========================================================================--
-- base64 (standard) — keeps the chunk free of commas/quotes/spaces so the
-- combat-log field stays a single clean unquoted token.
--==========================================================================--
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64encode(data)
    return ((data:gsub('.', function(c)
        local b = ''
        local byte = string.byte(c)
        for i = 8, 1, -1 do b = b .. ((byte % (2 ^ i) - byte % (2 ^ (i - 1)) > 0) and '1' or '0') end
        return b
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if #x < 6 then return '' end
        local c = 0
        for i = 1, 6 do c = c + ((x:sub(i, i) == '1') and (2 ^ (6 - i)) or 0) end
        return B64:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

--==========================================================================--
-- session id (per login) — time-based; chunks are disambiguated by guid too,
-- and the server groups by (session, guid).
--==========================================================================--
local session = string.format("%x", (time() or 0) % 0xffffffff)

--==========================================================================--
-- chunk queue (FIFO with TTL + ring cap)
--==========================================================================--
local queue = {}            -- array of { chunk = str, exp = unixSec }
local function enqueue(chunk)
    queue[#queue + 1] = { chunk = chunk, exp = (time() or 0) + CHUNK_TTL }
    if #queue > QUEUE_MAX then table.remove(queue, 1) end
end

--==========================================================================--
-- SPELL_FAILED_* hijack
--==========================================================================--
local origins = {}     -- [globalName] = original value (captured once)
local active  = false
local pending = nil    -- the chunk currently sitting in the globals

local function applyChunk(s)
    for _, g in ipairs(FAIL_GLOBALS) do
        if origins[g] == nil then origins[g] = _G[g] end
        _G[g] = s
    end
end

local function restoreGlobals()
    for g, v in pairs(origins) do _G[g] = v end
    origins = {}
    pending = nil
end

-- Suppress the red on-screen error text + the taint error spam for our chunks.
local function installSuppress()
    if UIErrorsFrame and not UIErrorsFrame.__clHooked then
        local orig = UIErrorsFrame.AddMessage
        UIErrorsFrame.AddMessage = function(self, m, ...)
            if type(m) == "string" and m:find(PREFIX_FAMILY, 1, true) then return end
            return orig(self, m, ...)
        end
        UIErrorsFrame.__clHooked = true
    end
    if not _G.__clTaintHooked then
        _G.__clTaintHooked = true
        local inner = geterrorhandler()
        seterrorhandler(function(err)
            if type(err) == "string" and err:find("ConLogs", 1, true) and err:find("tainted", 1, true) then return end
            if inner then return inner(err) end
        end)
    end
end

--==========================================================================--
-- scope: when may the relay be active?
--==========================================================================--
local testForce = false   -- set by /conlogs relay test for out-of-instance testing
local function relayEnabled()
    -- DEFAULT ON: the relay runs for every user (so any /combatlog automatically
    -- carries gear/talents/positions). Only an explicit `/conlogs relay off`
    -- (relayEnabled == false) disables it; nil/true both mean on.
    if ConLogsDB and ConLogsDB.config and ConLogsDB.config.relayEnabled == false then return false end
    return true
end
local function shouldBeActive()
    if not (relayEnabled() or testForce) then return false end
    if not (LoggingCombat and LoggingCombat()) then return false end
    if testForce then return true end
    local _, instType = IsInInstance()
    if instType ~= "raid" and instType ~= "party" and instType ~= "pvp" then return false end
    return UnitAffectingCombat("player") and true or false
end

local function reevaluate()
    local want = shouldBeActive()
    if want and not active then
        installSuppress()
        active = true
    elseif not want and active then
        active = false
        restoreGlobals()
    end
end

--==========================================================================--
-- CI producer — read each grouped player's stored wire string from ConLogsDB,
-- base64 + chunk it, enqueue. (rawPayload is kept fresh by the addon's scans.)
--==========================================================================--
local function freshestRaw(p)
    if not (p and p.sets) then return nil end
    local best, bestTime
    for _, set in pairs(p.sets) do
        if set.rawPayload and (not bestTime or (set.scanTime or 0) > bestTime) then
            best, bestTime = set.rawPayload, (set.scanTime or 0)
        end
    end
    return best
end

local function groupGUIDs()
    local out, seen = {}, {}
    local function add(u)
        if UnitExists(u) then local g = UnitGUID(u); if g and not seen[g] then seen[g] = true; out[#out + 1] = g end end
    end
    add("player")
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then for i = 1, raidN do add("raid" .. i) end
    else for i = 1, (GetNumPartyMembers() or 0) do add("party" .. i) end end
    return out
end

local function enqueueCI(guid, raw)
    local b64 = b64encode(raw)
    local short = tostring(guid):gsub("^0x", "")
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        enqueue(string.format("%s%s_%s_%d/%d]]%s", CI_PREFIX, session, short, i, total, piece))
    end
    return total
end

local lastCIAt = 0
local function enqueueGroupCI(force)
    local now = time() or 0
    if not force and (now - lastCIAt) < CI_REENQUEUE_S then return 0 end
    lastCIAt = now
    ConLogsDB = ConLogsDB or {}
    local players = (ConLogsDB.players) or {}
    local n = 0
    for _, guid in ipairs(groupGUIDs()) do
        local raw = freshestRaw(players[guid])
        if raw then n = n + enqueueCI(guid, raw) end
    end
    return n
end

--==========================================================================--
-- position telemetry (TS) producer — periodic raid position snapshots
-- Payload: TS|<getTimeMs>|<unixSec>|<guid>:<x>,<y>|<guid>:<x>,<y>|...
-- (no UnitPosition on PE → normalized GetPlayerMapPosition map_x/map_y only)
--==========================================================================--
local function round4(n)
    if type(n) ~= "number" then return 0 end
    return math.floor(n * 10000 + 0.5) / 10000
end

-- GetPlayerMapPosition only returns non-zero when the world map is set to the
-- player's current zone; do the dance only if needed, never while the map is open.
local function withCurrentZoneMap(fn)
    if type(GetPlayerMapPosition) == "function" then
        local px, py = GetPlayerMapPosition("player")
        if px and py and (px ~= 0 or py ~= 0) then return fn() end
    end
    local canAdjust = type(SetMapToCurrentZone) == "function"
        and not (_G.WorldMapFrame and WorldMapFrame:IsShown())
    if not canAdjust then return fn() end
    local oldC = type(GetCurrentMapContinent) == "function" and GetCurrentMapContinent() or nil
    local oldZ = type(GetCurrentMapZone) == "function" and GetCurrentMapZone() or nil
    pcall(SetMapToCurrentZone)
    local function pack(...) return { n = select('#', ...), ... } end
    local r = pack(fn())
    if oldC and oldC > 0 and type(SetMapZoom) == "function" then pcall(SetMapZoom, oldC, oldZ or 0) end
    return unpack(r, 1, r.n)
end

local snapId = 0
local function captureSnapshot()
    local units = {}
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then for i = 1, raidN do units[#units + 1] = "raid" .. i end
    else units[#units + 1] = "player"; for i = 1, (GetNumPartyMembers() or 0) do units[#units + 1] = "party" .. i end end
    local parts = {}
    local mapFile, level = "", 0
    withCurrentZoneMap(function()
        -- map identity so the server knows which WorldMap background these 0-1
        -- coords belong to (Naxx etc. normalize per wing/level).
        if type(GetMapInfo) == "function" then mapFile = GetMapInfo() or "" end
        if type(GetCurrentMapDungeonLevel) == "function" then level = GetCurrentMapDungeonLevel() or 0 end
        for _, u in ipairs(units) do
            if UnitExists(u) then
                local x, y = GetPlayerMapPosition(u)
                if x and y and (x ~= 0 or y ~= 0) then
                    local g = (UnitGUID(u) or ""):gsub("^0x", "")
                    parts[#parts + 1] = string.format("%s:%s,%s", g, round4(x), round4(y))
                end
            end
        end
    end)
    if #parts == 0 then return nil end
    -- TS|<getTimeMs>|<unixSec>|<mapFile>|<dungeonLevel>|<guid>:<x>,<y>|...
    return string.format("TS|%d|%d|%s|%d|%s", math.floor((GetTime() or 0) * 1000), time() or 0, tostring(mapFile), level, table.concat(parts, "|"))
end

local function enqueueTS()
    local payload = captureSnapshot()
    if not payload then return end
    snapId = snapId + 1
    local b64 = b64encode(payload)
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        enqueue(string.format("%s%s_%d_%d/%d]]%s", TS_PREFIX, session, snapId, i, total, piece))
    end
end

--==========================================================================--
-- driver: on each of the player's SPELL_CAST_FAILED events
--==========================================================================--
local function onFailed(...)
    -- Landed-evidence: if the failedType the engine just read starts with our family
    -- prefix, the previously-applied chunk made it into the log → drop it.
    local ft = select(FAILEDTYPE_ARG, ...)
    if pending and type(ft) == "string" and ft:sub(1, #PREFIX_FAMILY) == PREFIX_FAMILY then
        table.remove(queue, 1)
        pending = nil
    end
    -- TTL-evict stale heads.
    local now = time() or 0
    while queue[1] and queue[1].exp <= now do table.remove(queue, 1); pending = nil end
    if not queue[1] then
        if next(origins) then restoreGlobals() end  -- drained: revert so the last chunk can't re-land
        return
    end
    -- (Re-)apply the current head so the next failed cast carries it.
    applyChunk(queue[1].chunk)
    pending = queue[1].chunk
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not active then return end
        if select(2, ...) ~= "SPELL_CAST_FAILED" then return end
        if select(3, ...) ~= UnitGUID("player") then return end
        onFailed(...)
    elseif event == "PLAYER_REGEN_DISABLED" then
        reevaluate()
        if active then enqueueGroupCI(false) end
    elseif event == "PLAYER_REGEN_ENABLED" or event == "ZONE_CHANGED_NEW_AREA"
        or event == "PLAYER_ENTERING_WORLD" then
        reevaluate()
    elseif event == "PLAYER_LOGOUT" then
        if active then restoreGlobals() end
    end
end)
-- Position snapshot ticker: every TELEMETRY_INTERVAL while active, enqueue a TS chunk.
local tsAccum = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    if not active then return end
    tsAccum = tsAccum + (elapsed or 0)
    if tsAccum < TELEMETRY_INTERVAL then return end
    tsAccum = 0
    enqueueTS()
end)
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")

--==========================================================================--
-- slash: /conlogs relay <on|off|status|test>
--==========================================================================--
local function out(s) print("|cff66ccff[ConLogs relay]|r " .. tostring(s)) end

local function cmdRelay(sub)
    sub = (sub or ""):lower()
    ConLogsDB = ConLogsDB or {}; ConLogsDB.config = ConLogsDB.config or {}
    if sub == "on" then
        ConLogsDB.config.relayEnabled = true
        out("enabled. Active while logging (/combatlog) + in an instance + in combat.")
        reevaluate()
    elseif sub == "off" then
        ConLogsDB.config.relayEnabled = false
        testForce = false
        active = false
        restoreGlobals()
        out("disabled + globals restored.")
    elseif sub == "test" then
        testForce = true
        installSuppress()
        active = true
        local n = enqueueGroupCI(true)
        out(("test mode ON — queued %d gear chunk(s); positions now stream every %ds while active."):format(n, TELEMETRY_INTERVAL))
        out("Make sure /combatlog is on, then fail casts (abilities on cooldown). Search the log for [[CL_CI_ (gear) and [[CL_TS_ (positions). /conlogs relay off to stop.")
    elseif sub == "status" then
        local _, instType = IsInInstance()
        out(("enabled=%s active=%s queued=%d logging=%s instance=%s testForce=%s"):format(
            tostring(relayEnabled()), tostring(active), #queue,
            tostring(LoggingCombat and LoggingCombat() or false), tostring(instType), tostring(testForce)))
    else
        out("usage: /conlogs relay on | off | test | status")
    end
end

local origHandler = SlashCmdList["CONLOGS"]
SlashCmdList["CONLOGS"] = function(msg)
    msg = msg or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    if (cmd or ""):lower() == "relay" then
        cmdRelay(arg)
        return
    end
    if origHandler then origHandler(msg) end
end
