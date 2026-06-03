--[[ ===========================================================================
  ConLogsSpike.lua — DEBUG / THROWAWAY Phase-2 feasibility probe.

  NOT FOR RELEASE. Temporary diagnostic living inside ConLogs (one addon) only
  so we can test in the real environment. Delete this file + its .toc line + the
  ConLogsSpikeDB SavedVariable once the relay-vs-SavedVariables decision is made.

  Measures, in ONE in-game session, the three inputs needed to build the relay on
  the Project Epoch client (PE is NOT Ascension — nothing is assumed):
    1. POSITIONS — do GetPlayerMapPosition / UnitPosition return real coords for the
       player AND other raid members (especially inside an instance)?
    2. RELAY LANDS? + ARG INDEX — does overwriting SPELL_FAILED_* globals put a
       sentinel into the SPELL_CAST_FAILED combat-log event, and at which CLEU arg?
    3. MAX PAYLOAD — how many chars survive the combat-log writer intact (sets our
       chunk size for gear/talents/positions)?

  Commands (hidden sub-commands of the existing /epogarmory slash):
    /epogarmory spike pos        — probe positions for your whole group, print + store
    /epogarmory spike relay      — relay landing test (then fail a cast)
    /epogarmory spike size       — max-payload test (then fail a cast)
    /epogarmory spike relaystop  — stop the active test, restore globals
    /epogarmory spike dump       — print stored results
  Results persist to ConLogsSpikeDB (saved inside SavedVariables/ConLogs.lua).
=========================================================================== ]]--

local function out(s)  print("|cff66ccff[Spike]|r " .. tostring(s)) end
local function good(s) print("|cff66ccff[Spike]|r |cff55ff55" .. tostring(s) .. "|r") end
local function bad(s)  print("|cff66ccff[Spike]|r |cffff5555" .. tostring(s) .. "|r") end

local function round4(n)
    if type(n) ~= "number" then return n end
    return math.floor(n * 10000 + 0.5) / 10000
end

--==========================================================================--
-- POSITION PROBE
--==========================================================================--

-- 3.3.5's GetPlayerMapPosition only returns non-zero when the world map is set to
-- the player's current zone. Probe first; only do the SetMapToCurrentZone dance if
-- needed, and never while the world map is open (would yank the user's UI around).
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
    if oldC and oldC > 0 and type(SetMapZoom) == "function" then
        pcall(SetMapZoom, oldC, oldZ or 0)
    end
    return unpack(r, 1, r.n)
end

local function readPos(unit)
    if not UnitExists(unit) then return nil end
    local res = {}
    if type(GetPlayerMapPosition) == "function" then
        local ok, x, y = pcall(GetPlayerMapPosition, unit)
        if ok and x and y then res.map_x, res.map_y = round4(x), round4(y) end
    end
    -- UnitPosition may not exist on this client. Record RAW return values without
    -- assuming retail's y,x,z,instance order, so we can work out PE's order.
    if type(UnitPosition) == "function" then
        local ok, a, b, c, d = pcall(UnitPosition, unit)
        if ok then res.up = { round4(a), round4(b), round4(c), d } end
    end
    return res
end

local function probePositions()
    local units = {}
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do units[#units + 1] = "raid" .. i end
    else
        units[#units + 1] = "player"
        for i = 1, (GetNumPartyMembers() or 0) do units[#units + 1] = "party" .. i end
    end

    local zoneText = GetRealZoneText() or GetZoneText() or "?"
    local _, instType = IsInInstance()
    local hasUnitPosition = (type(UnitPosition) == "function")

    local rows = {}
    withCurrentZoneMap(function()
        for _, u in ipairs(units) do
            rows[#rows + 1] = { unit = u, name = UnitName(u) or "?", pos = readPos(u) }
        end
    end)

    out("=== POSITION PROBE ===")
    out(("zone=%s  instanceType=%s  UnitPosition_available=%s"):format(
        zoneText, tostring(instType), tostring(hasUnitPosition)))
    local mapped = 0
    for _, r in ipairs(rows) do
        local p = r.pos or {}
        local mapStr = (p.map_x and (p.map_x .. "," .. p.map_y)) or "—"
        local upStr  = "—"
        if p.up then upStr = ("%s/%s/%s @inst=%s"):format(
            tostring(p.up[1]), tostring(p.up[2]), tostring(p.up[3]), tostring(p.up[4])) end
        if p.map_x and (p.map_x ~= 0 or p.map_y ~= 0) then mapped = mapped + 1 end
        out(("  %-7s %-12s map(%s)  world(%s)"):format(r.unit, r.name, mapStr, upStr))
    end
    good(("%d/%d units returned non-zero map coords."):format(mapped, #rows))
    if not hasUnitPosition then
        bad("UnitPosition() does NOT exist on this client — world coords unavailable; map_x/map_y only.")
    end

    ConLogsSpikeDB = ConLogsSpikeDB or {}
    ConLogsSpikeDB.lastPositionProbe = {
        when = date and date("%Y-%m-%d %H:%M:%S") or time(),
        zone = zoneText, instanceType = instType,
        unitPositionAvailable = hasUnitPosition,
        unitsTotal = #rows, unitsMapped = mapped,
        rows = rows,
    }
    out("Stored to ConLogsSpikeDB.lastPositionProbe (reload/logout to flush the file).")
end

--==========================================================================--
-- RELAY + SIZE TESTS (shared SPELL_FAILED_* overwrite machinery)
--==========================================================================--

local SENTINEL = "[[WCE_TEST_0001]]"

-- Reliable subset of SPELL_FAILED_* globals. NOT_READY = "Not yet recovered" fires
-- whenever you press an ability on cooldown — the simplest failed cast to trigger.
local FAIL_GLOBALS = {
    "SPELL_FAILED_NOT_READY", "SPELL_FAILED_ITEM_NOT_READY",
    "SPELL_FAILED_OUT_OF_RANGE", "SPELL_FAILED_LINE_OF_SIGHT",
    "SPELL_FAILED_INVALID_TARGET", "SPELL_FAILED_BAD_TARGETS",
    "SPELL_FAILED_NO_TARGETS", "SPELL_FAILED_UNIT_NOT_INFRONT",
    "SPELL_FAILED_TOO_CLOSE", "SPELL_FAILED_SPELL_IN_PROGRESS",
    "SPELL_FAILED_AFFECTING_COMBAT", "SPELL_FAILED_MOVING",
    "SPELL_FAILED_NOT_HERE", "SPELL_FAILED_INTERRUPTED",
}

local testActive = false   -- a relay OR size probe is running
local testMode   = nil     -- "relay" | "size"
local origins    = {}
local landedIndex = nil
local dumpsLeft  = 0
local sizeBest   = nil     -- highest <<N>> marker seen in the CLEU field during a size probe

local function applyProbe(str)
    for _, g in ipairs(FAIL_GLOBALS) do
        if origins[g] == nil then origins[g] = _G[g] end
        _G[g] = str
    end
end

local function restoreGlobals()
    for g, v in pairs(origins) do _G[g] = v end
    origins = {}
end

-- Suppress the red on-screen error text for any of our WCE_ probe strings.
local function installUISuppress()
    if UIErrorsFrame and not UIErrorsFrame.__wceHooked then
        local orig = UIErrorsFrame.AddMessage
        UIErrorsFrame.AddMessage = function(self, msg, ...)
            if type(msg) == "string" and msg:find("WCE_", 1, true) then return end
            return orig(self, msg, ...)
        end
        UIErrorsFrame.__wceHooked = true
    end
end

-- Build a ~`total`-char probe carrying ordered <<N>> markers ~every 50 chars, so
-- after one failed cast we read back the highest surviving marker (in CLEU, and by
-- grepping the file on disk) → the max payload the writer keeps intact.
local function buildSizeProbe(total)
    local sb, len = { "[[WCE_SIZE_" }, 11
    local n = 50
    while len < total do
        local marker = ("<<%d>>"):format(n)
        sb[#sb + 1] = marker; len = len + #marker
        while (len % 50) ~= 0 and len < total do sb[#sb + 1] = "x"; len = len + 1 end
        n = n + 50
    end
    sb[#sb + 1] = "]]"
    return table.concat(sb)
end

local function highestMarker(s)
    local best
    for m in s:gmatch("<<(%d+)>>") do
        m = tonumber(m)
        if m and (not best or m > best) then best = m end
    end
    return best
end

local function inspectFailed(...)
    local nargs = select('#', ...)

    if testMode == "size" then
        for i = 1, nargs do
            local v = select(i, ...)
            if type(v) == "string" and v:find("WCE_SIZE_", 1, true) then
                local hi = highestMarker(v)
                if hi and (not sizeBest or hi > sizeBest) then
                    sizeBest = hi
                    good(("SIZE: CLEU carried the probe to the <<%d>> marker (arg %d, %d chars in that field)."):format(hi, i, #v))
                    good("Now open Logs/WoWCombatLog.txt, find the WCE_SIZE_ line, and note the HIGHEST <<N>> in it — that's the on-disk cap.")
                    ConLogsSpikeDB = ConLogsSpikeDB or {}
                    ConLogsSpikeDB.sizeProbe = {
                        cleuMarker = hi, cleuFieldLen = #v, argIndex = i,
                        when = date and date("%Y-%m-%d %H:%M:%S") or time(),
                    }
                end
                return
            end
        end
        return
    end

    -- relay landing mode
    local found = nil
    for i = 1, nargs do
        local v = select(i, ...)
        if type(v) == "string" and v:find("WCE_TEST", 1, true) then found = i; break end
    end
    if found then
        if landedIndex ~= found then
            landedIndex = found
            good(("RELAY LANDED! sentinel appeared at CLEU arg index %d."):format(found))
            good("If /combatlog is on, it's now in WoWCombatLog.txt — search it for WCE_TEST.")
            ConLogsSpikeDB = ConLogsSpikeDB or {}
            ConLogsSpikeDB.relayLanded = { argIndex = found, when = date and date("%Y-%m-%d %H:%M:%S") or time() }
        end
        return
    end
    if dumpsLeft > 0 then
        dumpsLeft = dumpsLeft - 1
        out("SPELL_CAST_FAILED (sentinel not read this time) — arg dump:")
        for i = 1, nargs do
            local v = select(i, ...)
            if type(v) == "string" then out(("   [%d] = %q"):format(i, v))
            else out(("   [%d] = %s"):format(i, tostring(v))) end
        end
    end
    applyProbe(SENTINEL)  -- re-apply in case something restored the globals
end

local relayFrame = CreateFrame("Frame")
relayFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not testActive then return end
        if select(2, ...) ~= "SPELL_CAST_FAILED" then return end
        if select(3, ...) ~= UnitGUID("player") then return end  -- player's own fails only
        inspectFailed(...)
    elseif event == "PLAYER_LOGOUT" then
        if testActive then restoreGlobals() end
    end
end)
relayFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
relayFrame:RegisterEvent("PLAYER_LOGOUT")

local function relayStart()
    if testActive then out("A spike test is already running — /epogarmory spike relaystop first."); return end
    installUISuppress()
    landedIndex, dumpsLeft, testMode = nil, 5, "relay"
    applyProbe(SENTINEL)
    testActive = true
    out("=== RELAY TEST STARTED ===")
    out("Logging combat: " .. tostring(LoggingCombat and LoggingCombat() or false)
        .. "  (type /combatlog to enable file writing if false)")
    out("Now TRIGGER A FAILED CAST — easiest: press an ability that's on cooldown.")
end

local function sizeStart()
    if testActive then out("A spike test is already running — /epogarmory spike relaystop first."); return end
    installUISuppress()
    sizeBest, testMode = nil, "size"
    applyProbe(buildSizeProbe(1200))  -- 1200 > Ascension's ~1023 cap, so PE's cutoff shows up
    testActive = true
    out("=== SIZE PROBE STARTED ===")
    out("Logging combat: " .. tostring(LoggingCombat and LoggingCombat() or false))
    out("Trigger a failed cast (ability on cooldown). I'll report how far the probe survived.")
end

local function testStop()
    if not testActive then out("No spike test running."); return end
    testActive, testMode = false, nil
    restoreGlobals()
    if landedIndex then good(("Done — relay landed at arg index %d. Globals restored."):format(landedIndex))
    elseif sizeBest then good(("Done — size probe reached the <<%d>> marker in CLEU. Globals restored (check the file for the on-disk cap)."):format(sizeBest))
    else bad("Done — nothing recorded. (Did you trigger a failed cast?) Globals restored.") end
end

--==========================================================================--
-- DUMP + SLASH WRAP
--==========================================================================--

local function dumpDB()
    ConLogsSpikeDB = ConLogsSpikeDB or {}
    out("=== ConLogsSpikeDB ===")
    local pp = ConLogsSpikeDB.lastPositionProbe
    if pp then
        out(("positions: %d/%d mapped, zone=%s, instType=%s, UnitPosition=%s (at %s)"):format(
            pp.unitsMapped or 0, pp.unitsTotal or 0, tostring(pp.zone),
            tostring(pp.instanceType), tostring(pp.unitPositionAvailable), tostring(pp.when)))
    else out("positions: (none — run /epogarmory spike pos)") end
    local rl = ConLogsSpikeDB.relayLanded
    if rl then good(("relay: LANDED at arg index %d (at %s)"):format(rl.argIndex, tostring(rl.when)))
    else out("relay: (no landing recorded — run /epogarmory spike relay)") end
    local sp = ConLogsSpikeDB.sizeProbe
    if sp then good(("size: CLEU kept up to <<%d>> (%d chars, arg %d) (at %s)"):format(
        sp.cleuMarker, sp.cleuFieldLen, sp.argIndex, tostring(sp.when)))
    else out("size: (no size probe yet — run /epogarmory spike size)") end
    out("Full data is in WTF/.../SavedVariables/ConLogs.lua — send me that file.")
end

-- Does PE's custom client expose ANY API that returns another unit's position?
-- (Stock 3.3.5 + PE have no UnitPosition; minimap blips are drawn in C, not Lua.)
-- Run INSIDE a raid with others grouped — the key question is whether anything
-- returns non-zero coords for `other`.
local function cmdUnitPos()
    out("=== position-API probe (run INSIDE a raid, others grouped) ===")
    -- 1. scan _G for any function whose name hints at unit/world position
    local found = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and type(v) == "function" then
            local lk = k:lower()
            if lk:find("position", 1, true) or lk:find("worldloc", 1, true)
               or lk:find("coord", 1, true) or lk:find("getxy", 1, true)
               or lk:find("unitxy", 1, true) or lk:find("worldpos", 1, true) then
                found[#found + 1] = k
            end
        end
    end
    table.sort(found)
    out("position-ish global fns: " .. (#found > 0 and table.concat(found, ", ") or "(none)"))

    -- 2. pick another grouped unit (not self)
    local other
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do local u = "raid" .. i
            if UnitExists(u) and not UnitIsUnit(u, "player") then other = u; break end end
    else
        for i = 1, (GetNumPartyMembers() or 0) do local u = "party" .. i
            if UnitExists(u) then other = u; break end end
    end
    local _, instType = IsInInstance()
    out(("zone=%s instanceType=%s otherUnit=%s"):format(
        GetRealZoneText() or "?", tostring(instType),
        other and (UnitName(other) .. "/" .. other) or "(none in group)"))

    -- 3. call candidate APIs on self + the other unit; report raw returns
    local function callfn(fn, u)
        local f = _G[fn]
        if type(f) ~= "function" then return "n/a" end
        local r = { pcall(f, u) }
        if not r[1] then return "error" end
        local vals = {}
        for i = 2, #r do vals[#vals + 1] = tostring(r[i]) end
        return "(" .. table.concat(vals, ", ") .. ")"
    end
    local cands = { "UnitPosition", "GetUnitPosition", "GetUnitWorldPosition",
        "UnitWorldPosition", "GetPlayerWorldPosition", "GetUnitMapPosition", "GetPlayerMapPosition" }
    local results = {}
    for _, fn in ipairs(cands) do
        local sr, orr = callfn(fn, "player"), other and callfn(fn, other) or "n/a"
        out(("  %-22s self=%s other=%s"):format(fn, sr, orr))
        results[fn] = { self = sr, other = orr }
    end

    ConLogsSpikeDB = ConLogsSpikeDB or {}
    ConLogsSpikeDB.unitPosProbe = {
        when = date and date("%Y-%m-%d %H:%M:%S") or time(),
        zone = GetRealZoneText() or "?", instanceType = instType,
        positionFns = found, results = results,
    }
    out("Stored. KEY: does ANY fn return non-zero coords for 'other' inside the raid?")
end

local function spikeHelp()
    out("Phase-2 feasibility probe (debug). Sub-commands:")
    out("  /conlogs spike pos        — probe positions for your group")
    out("  /conlogs spike relay      — relay landing test (then fail a cast)")
    out("  /conlogs spike size       — max-payload test (then fail a cast)")
    out("  /conlogs spike unitpos    — probe for any API that reads OTHER units' positions")
    out("  /conlogs spike relaystop  — stop the active test + restore globals")
    out("  /conlogs spike dump       — show stored results")
end

-- Wrap the existing /epogarmory handler (same idiom ConLogsUI uses). Loads last
-- in the .toc, so origHandler is the full existing chain; non-spike msgs pass through.
local origHandler = SlashCmdList["CONLOGS"]
SlashCmdList["CONLOGS"] = function(msg)
    msg = msg or ""
    local cmd, arg = msg:match("^(%S+)%s*(.*)$")
    if (cmd or ""):lower() == "spike" then
        local sub = ((arg or ""):match("^(%S*)") or ""):lower()
        if sub == "pos" then probePositions()
        elseif sub == "relay" then relayStart()
        elseif sub == "size" then sizeStart()
        elseif sub == "unitpos" then cmdUnitPos()
        elseif sub == "relaystop" or sub == "stop" then testStop()
        elseif sub == "dump" then dumpDB()
        else spikeHelp() end
        return
    end
    if origHandler then origHandler(msg) end
end
