--[[ ===========================================================================
  ConLogsRelay.lua — embed ConLogs gear/talent data into WoWCombatLog.txt via the
  SPELL_CAST_FAILED relay (a.k.a. CLEU hijack / "LegacyPlayers-style").

  How it works: while logging + in an instance (in OR out of combat), the head chunk
  string is written into the SPELL_FAILED_* global error strings. The next failed cast
  makes the client write that string as the SPELL_CAST_FAILED `failedType` field into
  WoWCombatLog.txt. The server reassembles the chunks from the uploaded log. (v2.2.1:
  out-of-combat coverage is what lets LOOT looted after a kill — incl. the LAST boss,
  after which there's no more combat — still land on a post-kill failed cast.)

  Spike-confirmed on the Project Epoch client (2026-06-03): the sentinel lands at CLEU
  arg index 12, and the failedType field carries ~1023 chars (~950 usable after the
  chunk header). No UnitPosition / LibDeflate on this client, so payloads are the
  addon's existing `^`-delimited wire string, base64'd (no compression yet).

  Gear/talents (CI) DEFAULT ON — any /combatlog auto-embeds them. Pre-pull buffs (BU)
  DEFAULT ON — a snapshot of self + own-pet auras taken at each combat start, so the log
  records flasks/food/blessings/etc. that were applied BEFORE the fight (the combat log
  has no aura event for those, so they'd otherwise be invisible). Each meshed client
  contributes its own complete buff list. Positions (TS) DEFAULT ON — for the replay map.
  Each client broadcasts its OWN position over the mesh and the logging client relays the
  whole group (inside instances you can't read other players' coords, so the mesh fills
  them in; a battleground exposes everyone to one logger). A map-validity guard relays
  NOTHING on continent fallbacks (e.g. Onyxia, no instance map), making default-on safe.
  Disable positions with `/conlogs relay pos off`, or the whole relay with `relay off`.
  Pet->owner (PO) DEFAULT ON — a tiny snapshot of each group member's pet GUID -> owner,
  read straight from UnitGUID (the 3.3.5 combat log has no owner link for warlock demons /
  hunter pets), so the server attributes pets by exact GUID instead of guessing (which
  cross-matched two warlocks' pets). Re-emitted on pet/roster change; dedup keeps it cheap.
  NOTE: overwriting the fail-reason globals taints the secure environment; the taint/
  UIErrors suppression below keeps that invisible, but harden before a public release.
  Commands: /conlogs relay on | off | status | test
=========================================================================== ]]--

local PREFIX_FAMILY = "[[CL_"   -- landed-evidence family prefix (all our chunk kinds share it)
local CI_PREFIX     = "[[CL_CI_v1_"
local TS_PREFIX     = "[[CL_TS_v1_"   -- telemetry snapshot (positions)
local BU_PREFIX     = "[[CL_BU_v1_"   -- buff snapshot (pre-pull auras: self + own pet)
local LT_PREFIX     = "[[CL_LT_v1_"   -- loot drops (item id/qty/quality/timestamp per row)
local VR_PREFIX     = "[[CL_VR_v1_"   -- addon version string (one tiny chunk per session)
local PO_PREFIX     = "[[CL_PO_v1_"   -- pet->owner (deterministic UnitGUID scan; petGUID^owner^ownerGUID rows)
local LOOT_FLUSH_DELAY = 3.0          -- seconds to batch loot events into one chunk
local TELEMETRY_INTERVAL = 3.0        -- Claude (v2.5.1): 2.0 -> 3.0s between position snapshots (less per-tick overhead; POS_TTL=5 still covers it)
local BUFF_POLL_INTERVAL = 3.0        -- seconds between buff-aura polls (catches juju/totem up/down edges)
local CHUNK_BODY    = 850       -- base64 chars per chunk (field cap ~1023, header ~46)
local QUEUE_MAX     = 400       -- ring cap
local CHUNK_TTL     = 600       -- seconds a chunk waits before TTL-evict
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
local pending = nil   -- forward-declared (used by enqueue's resync); the chunk currently in the globals
-- Queue entry: { chunk = str, exp = unixSec, onLand = fn|nil }. onLand fires only
-- when the chunk is confirmed landed (see onFailed) — used to advance the dedup
-- baseline AFTER the data reached the log, never on mere enqueue (so a chunk that's
-- TTL-evicted/ring-dropped before landing gets re-offered instead of lost).
local queue = {}
-- Claude (v2.5.1): priority lanes. The failed-cast budget is shared across ALL kinds
-- (~9 chunks/min organic), so small high-value payloads must not starve behind a BU
-- backlog. Lower number = drains first: VR (tiny, once) > PO (pet->owner, tiny, fixes
-- attribution) > LT (loot) > CI (gear) > BU (buff snapshots) > TS (positions). The queue
-- stays ordered by prio (stable/FIFO within a lane). The in-flight head (index 1, already
-- written to the globals) is NEVER displaced — the landed-evidence model in onFailed assumes
-- queue[1] is what the next failed cast carries — so new chunks insert among positions 2..N only.
-- Claude (v2.6.0): PO added at priority 1 (just under VR) — one tiny chunk per snapshot whose
-- correctness payoff (deterministic pet->owner) is high, so it must not wait behind loot/gear.
local PRIO_VR, PRIO_PO, PRIO_LT, PRIO_CI, PRIO_BU, PRIO_TS = 0, 1, 2, 3, 4, 5
local function enqueue(chunk, onLand, prio)
    prio = prio or PRIO_BU
    local entry = { chunk = chunk, exp = (time() or 0) + CHUNK_TTL, onLand = onLand, prio = prio }
    -- Insert before the first position >=2 holding a lower-priority (higher-number) chunk;
    -- else append. Never touches index 1.
    local at = #queue + 1
    for i = 2, #queue do
        if queue[i].prio > prio then at = i; break end
    end
    table.insert(queue, at, entry)
    if #queue > QUEUE_MAX then
        -- Over cap: drop the LOWEST-priority newest chunk (the tail), protecting the
        -- in-flight head and all higher-value chunks. Its onLand is intentionally NOT
        -- called, so the data is simply re-offered by the next snapshot.
        table.remove(queue)
    end
end

--==========================================================================--
-- SPELL_FAILED_* hijack
--==========================================================================--
-- Capture the PRISTINE FrameXML SPELL_FAILED_* strings ONCE at file load, before any
-- overwrite can happen. We always restore to these captured defaults — never to a
-- value read at first-overwrite time, which could already be a chunk string (a missed
-- restore, or the dev-only Spike probe). This makes "globals stuck showing chunk
-- strings" impossible: every restore path returns the true defaults.
local PRISTINE = {}
for _, g in ipairs(FAIL_GLOBALS) do PRISTINE[g] = _G[g] end

local dirty   = false  -- have we overwritten the globals since the last restore?
local active  = false
-- `pending` is forward-declared above the queue section (enqueue resyncs it).

local function applyChunk(s)
    for _, g in ipairs(FAIL_GLOBALS) do _G[g] = s end
    dirty = true
end

local function restoreGlobals()
    -- Unconditionally restore the captured pristine defaults (idempotent).
    for _, g in ipairs(FAIL_GLOBALS) do _G[g] = PRISTINE[g] end
    dirty   = false
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

-- Claude (v2.2.3): zone-name overrides for zones that report the WRONG instance type
-- from IsInInstance() on this client. Tol Barad comes back as a world/pvp zone, so the
-- relay's instance gate (raid/party) and the loot gate (raid/party) never engage there
-- even though it plays like an instanced encounter zone. Match by substring (plain text)
-- so subzone variants like "Tol Barad Peninsula" still count. Treated as a party/raid
-- instance for BOTH shouldBeActive (arm the relay) and lootCaptureOK (capture loot).
local INSTANCE_ZONE_OVERRIDES = { "Tol Barad" }
local function zoneOverrideActive()
    local z = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or ""
    if z == "" then return false end
    for _, name in ipairs(INSTANCE_ZONE_OVERRIDES) do
        if z:find(name, 1, true) then return true end
    end
    return false
end
local function relayEnabled()
    -- DEFAULT ON: the relay runs for every user (so any /combatlog automatically
    -- carries gear/talents/positions). Only an explicit `/conlogs relay off`
    -- (relayEnabled == false) disables it; nil/true both mean on.
    if ConLogsDB and ConLogsDB.config and ConLogsDB.config.relayEnabled == false then return false end
    return true
end
-- DEFAULT OFF: position telemetry (replay map). MESH-OF-SELF model: a client can only
-- read its OWN position inside a PvE instance (GetPlayerMapPosition returns 0,0 for other
-- units there, and PE has no UnitPosition), so each client relays just its own coords and
-- the server stitches all addon-users' tracks into one replay — same pattern as the buff
-- mesh. Works in any instance that has a real (per-floor) map; raids with no instance map
-- (e.g. Onyxia) fall back to useless continent coords. In battlegrounds GetPlayerMapPosition
-- DOES read everyone, so a single logger covers the whole BG. Opt-in: `/conlogs relay pos on`.
local function positionsEnabled()
    -- DEFAULT ON: the map-validity guard makes this safe — it only ever produces
    -- data on a real instance/BG map, and stays silent on continent fallbacks.
    -- Only an explicit `/conlogs relay pos off` disables it.
    if ConLogsDB and ConLogsDB.config and ConLogsDB.config.relayPositions == false then return false end
    return true
end
local function shouldBeActive()
    if not (relayEnabled() or testForce) then return false end
    if not (LoggingCombat and LoggingCombat()) then return false end
    if testForce then return true end
    local _, instType = IsInInstance()
    if instType ~= "raid" and instType ~= "party" and instType ~= "pvp" and not zoneOverrideActive() then return false end
    -- Claude (v2.2.1): active for the WHOLE instance stay, not just while in combat.
    -- Loot is captured at the kill (out of combat) and queued; keeping the relay armed
    -- out of combat lets that chunk land on the next failed cast — critically for the
    -- LAST boss, after which there is no further combat to carry it. Combat-only
    -- producers (positions/buffs) are gated on UnitAffectingCombat at their OnUpdate call
    -- sites so they don't begin relaying out of combat. The globals are only overwritten
    -- while chunks are queued (onFailed restores them the moment the queue drains), so the
    -- out-of-combat taint window stays proportional to pending data — usually nil.
    return true
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
    return best, bestTime
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

local function enqueueCI(guid, raw, onLand)
    local b64 = b64encode(raw)
    local short = tostring(guid):gsub("^0x", "")
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        -- Attach the dedup-commit to the LAST chunk so the baseline only advances
        -- once the full payload has landed.
        enqueue(string.format("%s%s_%s_%d/%d]]%s", CI_PREFIX, session, short, i, total, piece),
            (i == total) and onLand or nil, PRIO_CI)
    end
    return total
end

-- Relay each player's gear ONCE per version: enqueue a player's CI only when first
-- seen this session, or when their stored snapshot changed (scanTime bumped — e.g.
-- a respec/regear got re-scanned). The relay queue holds chunks until they land
-- (TTL), so a single enqueue is reliable — no periodic re-spam (which just bloated
-- the combat log). `force` (relay test) ignores the version check and re-sends all.
local relayedVersion = {}   -- guid -> scanTime of the gear-version already relayed this session
local function enqueueGroupCI(force)
    ConLogsDB = ConLogsDB or {}
    local players = ConLogsDB.players or {}
    local n = 0
    for _, guid in ipairs(groupGUIDs()) do
        local raw, st = freshestRaw(players[guid])
        if raw then
            st = st or 0
            if force or st > (relayedVersion[guid] or -1) then
                -- Advance the per-guid baseline only when the CI chunk lands (onLand),
                -- so a chunk dropped before landing is re-offered next pull. `guid`/`st`
                -- are fresh per loop iteration, so the closure captures them correctly.
                local g, sv = guid, st
                n = n + enqueueCI(guid, raw, function() relayedVersion[g] = sv end)
            end
        end
    end
    return n
end

-- Claude (v2.3.0): relay the addon's OWN version once per session, so the server can
-- tell which addon build produced a log — and the website can nudge uploaders on an
-- older-than-latest build to update for the most detailed parse. One tiny VR chunk
-- (version string only); enqueued at the first pull alongside CI/buffs. Re-offered if
-- it doesn't land (versionRelayed flips only on land); a rare duplicate is harmless
-- (the server just re-reads the same version).
local versionRelayed = false
local function enqueueVersion()
    if versionRelayed then return end
    local ver = (GetAddOnMetadata and GetAddOnMetadata("ConLogs-Epoch", "Version")) or "0"
    enqueue(string.format("%s%s_%d_%d/%d]]%s", VR_PREFIX, session, 1, 1, 1, b64encode(ver)),
        function() versionRelayed = true end, PRIO_VR)
end

--==========================================================================--
-- pet->owner producer (PO) — Claude (v2.6.0). DETERMINISTIC in-game pet ownership.
-- The 3.3.5 combat log gives NO owner link for permanent pets (warlock demons, hunter
-- pets) — only totems fire an owner-stamped SPELL_SUMMON — so when two warlocks/hunters
-- act together the server can't tell whose pet is whose and falls back to co-activity
-- heuristics that SWAP them (real bug: two warlocks' succubus/felguard cross-matched).
-- Here we read UnitGUID on each group member's pet (self "pet", "raidpetN"/"partypetN")
-- and relay petGUID->owner so the server attributes by EXACT GUID, overriding its
-- name-keyed pet DB + every heuristic. A handful of pets => ONE tiny chunk (unlike the
-- whole-raid BU snapshots that never completed), so it lands reliably.
--
-- MESH-OF-SELF: a logger reads its groupmates' pet GUIDs directly (the owner needs no
-- addon), but a pet that's out of range/phase may read nil — so we re-scan on UNIT_PET
-- (summon/dismiss/resummon) + roster change, and coverage fills in as pets come into range.
--
-- ONCE PER PET: a pet GUID's owner is immutable and the server applies it across the WHOLE
-- log, so each GUID only needs to LAND once. relayedPO tracks per-GUID landed state — a pet
-- already landed is never re-sent, and we only ever relay GUIDs not yet confirmed. So the
-- first pull lands every current pet, a resummon lands just its (new) GUID, a pet dropping
-- out of range relays NOTHING (it's already landed), and steady-state is zero. A chunk that
-- doesn't land leaves its GUIDs un-marked, so the next trigger re-offers exactly those.
-- Payload: "\n"-joined rows "<petGuidHex>^<ownerName>^<ownerGuidHex>" (0x stripped).
--==========================================================================--
local relayedPO = {}    -- petGuidHex -> true once that pet's row has LANDED (truly once per pet)
local poSeq = 0
-- Collect pet->owner rows for pets NOT yet landed (or ALL, when force=true for the relay
-- test). Returns the body + the list of pet GUIDs it contains, so onLand marks exactly those.
local function capturePetOwners(force)
    local rows, guids, seen = {}, {}, {}
    local function addPair(ownerUnit, petUnit)
        if not (UnitExists(ownerUnit) and UnitExists(petUnit)) then return end
        local pg, og = UnitGUID(petUnit), UnitGUID(ownerUnit)
        if not (pg and og) or pg == og then return end
        local pgh = tostring(pg):gsub("^0x", "")
        if pgh == "" or seen[pgh] then return end
        if not force and relayedPO[pgh] then return end   -- already landed → never re-relay
        local oname = UnitName(ownerUnit)
        if not oname or oname == "" or oname == "Unknown" then return end
        seen[pgh] = true
        guids[#guids + 1] = pgh
        rows[#rows + 1] = string.format("%s^%s^%s", pgh, oname, (tostring(og):gsub("^0x", "")))
    end
    addPair("player", "pet")
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do addPair("raid" .. i, "raidpet" .. i) end
    else
        for i = 1, (GetNumPartyMembers() or 0) do addPair("party" .. i, "partypet" .. i) end
    end
    if #rows == 0 then return nil end
    return table.concat(rows, "\n"), guids
end

-- Enqueue any pet->owner pairs not yet landed (force re-sends all current pets, for the relay
-- test). The onLand closure marks exactly the GUIDs in THIS chunk as landed, so they're never
-- re-relayed; a dropped chunk leaves them un-marked and the next trigger re-offers them.
-- Almost always 1 tiny chunk (a raid has a handful of pets; usually just the deltas).
local function enqueuePetOwners(force)
    local body, guids = capturePetOwners(force)
    if not body then return 0 end
    poSeq = poSeq + 1
    local landed = guids
    local b64 = b64encode(body)
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        enqueue(string.format("%s%s_%d_%d/%d]]%s", PO_PREFIX, session, poSeq, i, total, piece),
            (i == total) and function() for _, g in ipairs(landed) do relayedPO[g] = true end end or nil, PRIO_PO)
    end
    return total
end

--==========================================================================--
-- position telemetry (TS) producer — replay map. MESH-OF-SELF for instances:
-- a client can't read other players' coords inside a PvE instance, so every client
-- BROADCASTS its own position over the addon-message mesh and the logging client
-- aggregates self + all received peers into one snapshot. In a battleground
-- GetPlayerMapPosition reads everyone directly, so a single logger covers it.
--
-- Map-validity guard: only relay when on a real (per-floor) instance/BG map. If the
-- client falls back to a continent map (e.g. Onyxia, which has no instance map →
-- "Kalimdor"), the coords are meaningless, so we relay NOTHING. This makes the
-- default-on safe: it produces data only where a usable map exists.
-- Payload: TS|<getTimeMs>|<unixSec>|<mapFile>|<guidHex>:<x>,<y>,<floor>|<guidHex>:...
--==========================================================================--
local POS_PREFIX  = "ConLogsPos"   -- DEDICATED addon-message prefix for the position mesh,
                                   -- kept separate from the gear mesh's "EpogArmory" prefix
                                   -- so position broadcasts never hit the gear reassembly path.
local POS_TTL     = 5              -- seconds; drop peer positions older than this
-- Claude (v2.5.1) PERF: cache "this zone has no usable replay map" so the position
-- producer stops doing the SetMapToCurrentZone "dance" every 2s. Inside every PvE raid/
-- dungeon GetPlayerMapPosition("player") returns 0,0, so withCurrentZoneMap can't take its
-- fast path and calls SetMapToCurrentZone + SetMapZoom each tick — only to read a continent
-- fallback we then discard (TS stays empty). That world-map state mutation is engine-side
-- expensive and recurs every 2s for EVERY addon user in combat (logger or not) → a real,
-- raid-wide FPS hitch. With the cache we dance at most a couple of times per zone, then go
-- silent. Re-armed on every zone change (see OnEvent ZONE_CHANGED_NEW_AREA/ENTERING_WORLD).
local posMapUnusable = false

-- Continent/world maps that signal a fallback (NOT a usable replay map).
local CONTINENT_MAPS = {
    [""] = true, ["World"] = true, ["Cosmic"] = true, ["AzerothContinent"] = true,
    ["Kalimdor"] = true, ["Azeroth"] = true, ["Expansion01"] = true, ["Northrend"] = true,
}
local function isReplayMap(mapFile)
    return mapFile ~= nil and not CONTINENT_MAPS[mapFile]
end

-- peer positions received over the mesh: guidHex -> { x, y, floor, recvAt(GetTime) }
local peerPos = {}

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

local function positionUnits()
    local units = { "player" }
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then for i = 1, raidN do units[#units + 1] = "raid" .. i end
    else for i = 1, (GetNumPartyMembers() or 0) do units[#units + 1] = "party" .. i end end
    return units
end

-- Read self position + current map identity (under the map-set dance). Returns
-- x, y, mapFile, floor — x/y nil when no usable position.
local function readSelfPos()
    local x, y, mapFile, floor
    withCurrentZoneMap(function()
        if type(GetMapInfo) == "function" then mapFile = GetMapInfo() or "" end
        if type(GetCurrentMapDungeonLevel) == "function" then floor = GetCurrentMapDungeonLevel() or 0 end
        if type(GetPlayerMapPosition) == "function" then x, y = GetPlayerMapPosition("player") end
    end)
    return x, y, mapFile or "", floor or 0
end

-- Broadcast our own position so the logging client can relay everyone's. Runs for
-- EVERY client (logging or not) while in combat in an instance on a real map.
-- BG doesn't need it (direct reads cover everyone there).
local function broadcastSelfPos()
    if not positionsEnabled() then return end
    if not UnitAffectingCombat("player") then return end
    local _, instType = IsInInstance()
    if instType ~= "party" and instType ~= "raid" then return end
    local x, y, mapFile, floor = readSelfPos()
    if not isReplayMap(mapFile) then
        -- Claude (v2.5.1): a non-empty continent name ("Kalimdor"…) is stable for the whole
        -- instance → cache it so the OnUpdate gate stops the per-tick map dance. An empty
        -- mapFile is the transient post-zone-in state; keep retrying until the real map
        -- resolves (a few ticks at most), then cache.
        if mapFile ~= "" then posMapUnusable = true end
        return
    end
    if not (x and y and (x ~= 0 or y ~= 0)) then return end
    local g = (UnitGUID("player") or ""):gsub("^0x", "")
    if g == "" or type(SendAddonMessage) ~= "function" then return end
    SendAddonMessage(POS_PREFIX,
        string.format("POS^%s^%s^%s^%d", g, round4(x), round4(y), floor),
        (instType == "raid") and "RAID" or "PARTY")
end

local snapId = 0
local function captureSnapshot()
    local nowT = GetTime() or 0
    local merged = {}   -- guidHex -> "x,y,floor"
    local mapFile, selfFloor = "", 0
    withCurrentZoneMap(function()
        if type(GetMapInfo) == "function" then mapFile = GetMapInfo() or "" end
        if type(GetCurrentMapDungeonLevel) == "function" then selfFloor = GetCurrentMapDungeonLevel() or 0 end
        -- Direct reads: a BG yields every unit; an instance yields only self.
        for _, u in ipairs(positionUnits()) do
            if UnitExists(u) then
                local x, y = GetPlayerMapPosition(u)
                if x and y and (x ~= 0 or y ~= 0) then
                    local g = (UnitGUID(u) or ""):gsub("^0x", "")
                    if g ~= "" then merged[g] = string.format("%s,%s,%d", round4(x), round4(y), selfFloor) end
                end
            end
        end
    end)
    -- Continent fallback (no usable instance map) → relay nothing.
    if not isReplayMap(mapFile) then return nil end
    -- Merge fresh peer broadcasts (other players in the instance); don't overwrite
    -- a direct read (BG case), and honor TTL so stale dots drop out.
    for g, p in pairs(peerPos) do
        if (nowT - (p.recvAt or 0)) <= POS_TTL and not merged[g] then
            merged[g] = string.format("%s,%s,%d", p.x, p.y, p.floor or 0)
        end
    end
    local parts = {}
    for g, v in pairs(merged) do parts[#parts + 1] = g .. ":" .. v end
    if #parts == 0 then return nil end
    return string.format("TS|%d|%d|%s|%s", math.floor(nowT * 1000), time() or 0, tostring(mapFile), table.concat(parts, "|"))
end

local function enqueueTS()
    local payload = captureSnapshot()
    if not payload then return end
    snapId = snapId + 1
    local b64 = b64encode(payload)
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        enqueue(string.format("%s%s_%d_%d/%d]]%s", TS_PREFIX, session, snapId, i, total, piece), nil, PRIO_TS)
    end
end

--==========================================================================--
-- buff snapshot (BU) producer — capture group members' auras for buffs the combat
-- log can't show. Two blind spots this fills:
--   1. Pre-pull buffs (flask/food/blessings cast in town): applied before logging,
--      so no SPELL_AURA_APPLIED — the pull-time snapshot records them.
--   2. PE buffs that emit NO aura events at all for the whole fight (observed:
--      "Juju" elixirs, totem buffs): the log never sees them up OR down, so a single
--      snapshot can't give uptime. The OnUpdate poll re-scans on an interval and
--      relays a unit only when its aura-set CHANGES, so the server gets the up/down
--      EDGES and reconstructs each window (uptime = sum of present intervals).
-- Both feed the same BU stream; the server injects synthetic APPLIED at the first
-- snapshot a buff appears in, and REMOVED at the snapshot it disappears from.
--
-- Claude (v2.5.1): we scan SELF + own pet only (was whole-raid — see buffUnitTokens), and
-- only the curated blind-spot allowlist (see readAuras). A whole-raid full-aura snapshot was
-- 28-47 chunks and NEVER completed against the ~9 chunks/min failed-cast budget; self+pet
-- curated is ~1 chunk and completes atomically. The MESH-OF-SELF gives per-player breadth:
-- every ConLogs user relays their own buffs in their own log, and merged groups stitch them.
--
-- Per-unit dedup: a unit's (allowlisted) aura set is relayed only when it CHANGES — the
-- first pull captures the static pre-pull buffs, later polls relay just totem/juju up/down
-- edges. The server carries an unchanged unit forward. Restricting to the stable allowlist is
-- what keeps "changed" rare (volatile procs/forms are excluded, so they don't trigger re-sends).
-- Payload: BU|<getTimeMs>|<unixSec>|<M/D HH:MM:SS>|<guidHex>=<spellId>~<name>,…|<guidHex>=…
-- Delimiters |=,~ never occur in 3.3.5 buff names; the whole payload is base64'd anyway.
--==========================================================================--
-- Claude (v2.5.1): curated blind-spot allowlist. BU only needs the buffs the combat log
-- CAN'T otherwise show — totems (emit NO aura events at all), jujus/flasks/food/elixirs
-- (pre-pull, applied before /combatlog), world buffs, and the stable raid auras/blessings.
-- Buffs that DO emit SPELL_AURA_APPLIED are tracked by the parser from real CLEU and are
-- de-duped away server-side, so relaying them is wasted budget. Critically, this EXCLUDES
-- volatile self-buffs (procs, combo abilities like Slice and Dice, shapeshift forms): their
-- constant flicker would flip the per-unit dedup every poll and re-flood the queue — the
-- exact failure that left BU at 0% completion. Substring match (case-sensitive 3.3.5 names)
-- so new Epoch blessings/auras are caught without an ID table. Note: the totem AURA names
-- ("Strength of Earth", "Grace of Air", "Mana Spring") contain no "Totem", so they're listed
-- explicitly. Errs toward under-relaying (miss an unknown buff) over churn.
local RELAY_BUFF_SUBSTRINGS = {
    -- totem auras (the granted buff names — distinct from the "* Totem" object names)
    "Totem", "Strength of Earth", "Grace of Air", "Mana Spring", "Stoneskin",
    "Windfury", "Flametongue", "Frostbrand", "Healing Stream", "Mana Tide",
    "Tranquil Air", "Grounding", "Wrath of Air",
    -- blessings / paladin + hunter + druid auras
    "Blessing", "Aura", "Sanctity", "Devotion", "Concentration", "Retribution",
    "Trueshot", "Moonkin", "Leader of the Pack", "Ferocious",
    -- raid-wide caster/healer/warrior buffs
    "Gift of the Wild", "Mark of the Wild", "Prayer of", "Fortitude", "Spirit",
    "Intellect", "Brilliance", "Shout", "Inspiration", "Unleashed Rage",
    -- consumables / world buffs
    "Flask", "Elixir", "Well Fed", "Juju", "Scroll", "Resistance", "Knowledge",
}
local function isRelayBuff(name)
    if type(name) ~= "string" then return false end
    for _, s in ipairs(RELAY_BUFF_SUBSTRINGS) do
        if name:find(s, 1, true) then return true end
    end
    return false
end
local function readAuras(unit)
    local list = {}
    for i = 1, 40 do
        local name, _, _, _, _, _, _, _, _, _, spellId = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        if isRelayBuff(name) then
            list[#list + 1] = string.format("%s~%s", tostring(spellId or 0), name)
        end
    end
    return list
end

-- Claude (v2.5.1): SELF + own pet ONLY. The whole-raid scan produced 28-47-chunk payloads
-- that never completed (the failed-cast budget is ~9 chunks/min, and a fresh full-raid
-- snapshot enqueued every 3s buried the queue). Self+pet curated is ~1 chunk and completes
-- atomically. Per-player breadth comes from the MESH-OF-SELF — every ConLogs user relays
-- their OWN buffs in their OWN log, and merged raid groups stitch the loggers together —
-- so one log no longer has to (and never successfully did) carry the whole raid.
local function buffUnitTokens()
    return { "player", "pet" }
end

local buffSnapId = 0
local relayedBuffs = {}   -- guidHex -> last relayed aura-list string (dedup: skip unchanged)
-- Returns payload, commit. The dedup baseline (relayedBuffs) is NOT updated here —
-- the returned commit() applies it, and is only invoked once the chunk lands (so a
-- dropped chunk re-offers its buffs next poll instead of being lost permanently).
local function captureBuffs(force)
    if type(UnitAura) ~= "function" then return nil end
    local blocks, seen, updates = {}, {}, {}
    for _, u in ipairs(buffUnitTokens()) do
        if UnitExists(u) then
            local g = (UnitGUID(u) or ""):gsub("^0x", "")
            if g ~= "" and not seen[g] then
                seen[g] = true
                local listStr = table.concat(readAuras(u), ",")   -- "" when no readable buffs
                local prev = relayedBuffs[g]
                -- Relay a block when this unit's aura-set CHANGED. A transition to empty
                -- ("g=") tells the server the unit's tracked buffs all dropped (closes
                -- open windows). Skip units that have never had buffs (prev==nil & empty)
                -- so out-of-range/buffless units don't spam empty blocks. force (test)
                -- re-sends present sets only.
                if force then
                    if listStr ~= "" then updates[g] = listStr; blocks[#blocks + 1] = g .. "=" .. listStr end
                elseif not (listStr == "" and prev == nil) and listStr ~= prev then
                    updates[g] = listStr
                    blocks[#blocks + 1] = g .. "=" .. listStr
                end
            end
        end
    end
    if #blocks == 0 then return nil end
    -- Claude (v2.5.1): field 4 is a combat-log-format date stamp (same as LT). It lets the
    -- server rebase this snapshot onto the fight timeline exactly (synth aura windows compare
    -- to fight.startMs) instead of guessing from the failed-cast line that finally carried it.
    -- The server tells label-vs-block apart by the '=' every block has and a date never does.
    local payload = string.format("BU|%d|%d|%s|%s",
        math.floor((GetTime() or 0) * 1000), time() or 0, date("%m/%d %H:%M:%S"), table.concat(blocks, "|"))
    local commit = function() for g, v in pairs(updates) do relayedBuffs[g] = v end end
    return payload, commit
end

local function enqueueBuffs(force)
    local payload, commit = captureBuffs(force)
    if not payload then return 0 end
    buffSnapId = buffSnapId + 1
    local b64 = b64encode(payload)
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        -- commit on the LAST chunk's landing only
        enqueue(string.format("%s%s_%d_%d/%d]]%s", BU_PREFIX, session, buffSnapId, i, total, piece),
            (i == total) and commit or nil, PRIO_BU)
    end
    return total
end

--==========================================================================--
-- driver: on each of the player's SPELL_CAST_FAILED events
--==========================================================================--
local function onFailed(...)
    -- Landed-evidence: if the failedType the engine just read starts with our family
    -- prefix, the previously-applied chunk made it into the log → drop it.
    local ft = select(FAILEDTYPE_ARG, ...)
    if pending and type(ft) == "string" and ft:sub(1, #PREFIX_FAMILY) == PREFIX_FAMILY then
        local landed = table.remove(queue, 1)  -- this head is what just landed
        pending = nil
        if landed and landed.onLand then landed.onLand() end  -- advance dedup baseline ONLY now
    end
    -- TTL-evict stale heads (never landed → onLand intentionally NOT called, so the
    -- data will be re-offered by the next snapshot instead of being lost).
    local now = time() or 0
    while queue[1] and queue[1].exp <= now do table.remove(queue, 1); pending = nil end
    if not queue[1] then
        if dirty then restoreGlobals() end  -- drained: revert so the last chunk can't re-land
        return
    end
    -- (Re-)apply the current head so the next failed cast carries it.
    applyChunk(queue[1].chunk)
    pending = queue[1].chunk
end

--==========================================================================--
-- loot producer (LT) — capture what dropped during a logged instance run via
-- CHAT_MSG_LOOT, batch a few seconds of events into one chunk, enqueue. Quality
-- is read from the item link's colour (no GetItemInfo dependency). Uncommon+ only.
-- Timestamp is emitted in the SAME combat-log format (date "%m/%d %H:%M:%S") so the
-- server can map each drop onto the fight timeline (boss attribution) — even though
-- the chunk itself only relays at the next in-combat window. "What dropped" only:
-- no looter name is captured (per site design).
--==========================================================================--
local QUALITY_BY_COLOR = {
    ["1eff00"] = 2, ["0070dd"] = 3, ["a335ee"] = 4, ["ff8000"] = 5, ["e6cc80"] = 6, ["e5cc80"] = 6,
}
local lootBuf   = {}     -- array of "itemID^qty^quality^M/D HH:MM:SS"
local lootAccum = 0
local lootSeq   = 0
local lootNudged = false -- Claude (v2.2.1): throttle the out-of-combat "cast to save loot" reminder to once per fight
-- Set true by ConLogsDungeon (via _G.ConLogs_OnRunComplete) when ALL roster bosses are
-- down — i.e. the last boss is dead and there may be no more combat to carry chunks.
-- The loot reminder only fires when this is set, so it shows ONCE at end-of-run instead
-- of after every trash pack. Reset on zone change (new run). Loot during the run still
-- relays silently — ongoing combat carries those chunks.
local runComplete = false
_G.ConLogs_OnRunComplete = function() runComplete = true end
local function lootCaptureOK()
    if not (LoggingCombat and LoggingCombat()) then return false end
    local _, instType = IsInInstance()
    -- Claude (v2.2.3): zoneOverrideActive() lets mis-typed zones (Tol Barad) capture loot.
    return instType == "raid" or instType == "party" or zoneOverrideActive()
end
-- Claude (v2.3.2): de-spam loot capture. Project Epoch re-fires CHAT_MSG_LOOT for the
-- SAME drop many times (observed ~7 identical events per item — visible as the in-game
-- loot-message spam). Without dedup that produced 300+ rows from one Strat run (a single
-- common item appeared 104×) and flooded the site's Loot tab. We collapse repeats of the
-- same item+qty seen within LOOT_DEDUP_WINDOW seconds; the window resets on every hit, so
-- a sustained spam burst stays collapsed while genuinely separate drops (spaced further
-- apart) are still captured. Keyed on itemID^qty so a different stack size still counts.
local LOOT_DEDUP_WINDOW = 5      -- seconds
local lootSeen = {}             -- "itemID^qty" -> last GetTime() it was seen
local function captureLoot(msg)
    if type(msg) ~= "string" or not lootCaptureOK() then return end
    local itemID = msg:match("|Hitem:(%d+)")
    if not itemID then return end
    local color   = msg:match("|cff(%x%x%x%x%x%x)|Hitem")
    local quality = (color and QUALITY_BY_COLOR[color:lower()]) or 1
    if quality < 2 then return end -- skip poor/common vendor trash
    local qty = tonumber(msg:match("|h|rx(%d+)") or msg:match("x(%d+)%.?$") or "1") or 1
    -- de-spam: ignore a repeat of the same item+qty within the dedup window
    local now  = GetTime() or 0
    local key  = itemID .. "^" .. qty
    local prev = lootSeen[key]
    lootSeen[key] = now
    if prev and (now - prev) < LOOT_DEDUP_WINDOW then return end
    lootBuf[#lootBuf + 1] = string.format("%s^%d^%d^%s", itemID, qty, quality, date("%m/%d %H:%M:%S"))
end
local function flushLoot()
    if #lootBuf == 0 then return end
    local b64 = b64encode(table.concat(lootBuf, "\n"))
    local n = #lootBuf
    lootBuf = {}
    lootSeq = lootSeq + 1
    local total = math.max(1, math.ceil(#b64 / CHUNK_BODY))
    for i = 1, total do
        local piece = b64:sub((i - 1) * CHUNK_BODY + 1, i * CHUNK_BODY)
        enqueue(string.format("%s%s_%d_%d/%d]]%s", LT_PREFIX, session, lootSeq, i, total, piece), nil, PRIO_LT)
    end
    -- Claude (v2.2.1): if this was looted OUT of combat (the usual case, and the only one
    -- at risk — e.g. after the last boss there's no further combat to carry the chunk),
    -- remind the player once that any failed cast lands it. In combat we stay silent — the
    -- ongoing fight's failed casts carry it immediately. Reset per fight (PLAYER_REGEN_DISABLED).
    if runComplete and (LoggingCombat and LoggingCombat())
        and not (UnitAffectingCombat and UnitAffectingCombat("player")) and not lootNudged then
        lootNudged = true
        print(string.format("|cff66ccff[ConLogs]|r logged %d loot drop%s - cast any spell before leaving the instance to save %s to your log (an ability on cooldown counts).",
            n, n == 1 and "" or "s", n == 1 and "it" or "them"))
    end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not active then return end
        if select(2, ...) ~= "SPELL_CAST_FAILED" then return end
        if select(3, ...) ~= UnitGUID("player") then return end
        onFailed(...)
    elseif event == "CHAT_MSG_ADDON" then
        -- position mesh receive: peers broadcast "POS^<guid>^<x>^<y>^<floor>"
        local prefix, msg = ...
        if prefix == POS_PREFIX and type(msg) == "string" and msg:sub(1, 4) == "POS^" then
            local _, g, x, y, fl = strsplit("^", msg)
            if g and x and y then
                peerPos[g] = { x = tonumber(x) or 0, y = tonumber(y) or 0, floor = tonumber(fl) or 0, recvAt = GetTime() or 0 }
            end
        end
    elseif event == "CHAT_MSG_LOOT" then
        captureLoot((select(1, ...)))
    elseif event == "PLAYER_REGEN_DISABLED" then
        reevaluate()
        lootNudged = false   -- Claude (v2.2.1): new fight → re-allow one post-kill loot reminder
        -- Snapshot buffs at each pull; per-unit dedup means only changed sets relay
        -- (first pull captures the raid, later pulls are near-zero unless someone
        -- rebuffs). Gear stays once-per-version via enqueueGroupCI. Claude (v2.6.0):
        -- pet->owner snapshot too (deterministic attribution; dedup keeps it cheap).
        if active then enqueueGroupCI(false); enqueueBuffs(false); enqueueVersion(); enqueuePetOwners(false) end
    elseif event == "UNIT_PET" or event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        -- Claude (v2.6.0): a pet was summoned/dismissed/resummoned (new GUID) or the roster
        -- changed (a member's pet may now be readable, or a new petN slot appeared) — re-scan
        -- and relay if the pet->owner set changed. Dedup (relayedPO) drops no-op re-emits.
        if active then enqueuePetOwners(false) end
    elseif event == "PLAYER_REGEN_ENABLED" or event == "ZONE_CHANGED_NEW_AREA"
        or event == "PLAYER_ENTERING_WORLD" then
        -- New zone = new run → re-arm the end-of-run loot reminder. NOT on REGEN_ENABLED:
        -- the last boss's loot flushes out of combat, so clearing on combat-end would
        -- suppress the one reminder we actually want.
        -- Claude (v2.5.1): re-arm the position map-usability probe on every real zone change
        -- (a new instance may have a usable map; a continent may not).
        if event ~= "PLAYER_REGEN_ENABLED" then runComplete = false; lootNudged = false; posMapUnusable = false end
        reevaluate()
    elseif event == "PLAYER_LOGOUT" or event == "PLAYER_LEAVING_WORLD" then
        -- Restore unconditionally on every teardown path (logout, /reload, zoning out
        -- mid-combat). restoreGlobals is idempotent, so the dropped `if active` guard
        -- just guarantees the globals are never left holding a chunk string.
        active = false
        if dirty then restoreGlobals() end
    end
end)
-- Tickers:
--  • Position mesh every TELEMETRY_INTERVAL — EVERY client (logger or not) broadcasts
--    its own position so the logging client can relay the whole group; the logger also
--    relays the aggregated snapshot into its log. broadcastSelfPos guards internally on
--    in-combat + instance + real map, so it's idle elsewhere. Runs outside the `active`
--    gate because non-logging members still need to broadcast.
--  • Buff poll every BUFF_POLL_INTERVAL (logging client only) — re-scan auras and relay
--    any unit whose set changed; captures uptime for buffs the log emits no events for
--    (jujus, totems) via the up/down edges. Dedup keeps steady-state at zero chunks.
-- Seed the position accumulator with a random phase so clients in a big raid don't
-- all broadcast on the same interval boundary (desyncs the addon-channel pulses; each
-- client still sends once per TELEMETRY_INTERVAL).
local tsAccum  = (math.random and (math.random() * TELEMETRY_INTERVAL)) or 0
local buffAccum = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    -- Claude (v2.5.1) PERF: skip the entire position producer (incl. the SetMapToCurrentZone
    -- dance) once this zone is known to have no usable replay map. broadcastSelfPos sets
    -- posMapUnusable on the first failed read; it re-arms on zone change.
    if positionsEnabled() and not posMapUnusable then
        tsAccum = tsAccum + (elapsed or 0)
        if tsAccum >= TELEMETRY_INTERVAL then
            tsAccum = 0
            broadcastSelfPos()
            -- Claude (v2.2.1): explicit in-combat gate (active is no longer combat-only).
            -- Claude (v2.5.1): re-check posMapUnusable — broadcastSelfPos may have just set it
            -- this tick, and enqueueTS→captureSnapshot would otherwise do its own map dance.
            if active and not posMapUnusable and UnitAffectingCombat("player") then enqueueTS() end
        end
    end
    -- Claude (v2.2.1): buffs poll only in combat (active alone now spans the instance stay).
    if active and UnitAffectingCombat("player") then
        buffAccum = buffAccum + (elapsed or 0)
        if buffAccum >= BUFF_POLL_INTERVAL then
            buffAccum = 0
            enqueueBuffs(false)
        end
    end
    -- Loot flush runs outside the `active` gate (loot is usually looted out of
    -- combat). The chunk queue holds the enqueued chunk until the next failed cast
    -- carries it (v2.2.1: in OR out of combat, as long as you're still in the
    -- instance); each row carries its own capture timestamp for boss attribution.
    if #lootBuf > 0 then
        lootAccum = lootAccum + (elapsed or 0)
        if lootAccum >= LOOT_FLUSH_DELAY then lootAccum = 0; flushLoot() end
    else
        lootAccum = 0
    end
end)
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_LEAVING_WORLD") -- extra teardown path: restore globals on zone-out
frame:RegisterEvent("UNIT_PET")             -- Claude (v2.6.0): pet summon/dismiss/resummon → re-relay PO
frame:RegisterEvent("RAID_ROSTER_UPDATE")   -- Claude (v2.6.0): roster change → a member's pet may now be readable
frame:RegisterEvent("PARTY_MEMBERS_CHANGED") -- Claude (v2.6.0): party variant of the above

--==========================================================================--
-- slash: /conlogs relay <on|off|status|test>
--==========================================================================--
local function out(s) print("|cff66ccff[ConLogs relay]|r " .. tostring(s)) end

local function cmdRelay(sub)
    sub = (sub or ""):lower()
    local action, val = sub:match("^(%S*)%s*(.*)$")
    ConLogsDB = ConLogsDB or {}; ConLogsDB.config = ConLogsDB.config or {}
    if action == "on" then
        ConLogsDB.config.relayEnabled = true
        out("gear/talents relay enabled. Active while logging (/combatlog) + in an instance/BG + in combat.")
        reevaluate()
    elseif action == "off" then
        ConLogsDB.config.relayEnabled = false
        testForce = false
        active = false
        restoreGlobals()
        out("relay disabled + globals restored.")
    elseif action == "pos" or action == "positions" then
        if val == "on" then
            ConLogsDB.config.relayPositions = true
            out(("position telemetry ON (default) — every %ds in combat. Each client broadcasts its own position over the mesh; the logger relays the whole group into its log. Only on a real instance/BG map (continent fallbacks relay nothing). Verify with /conlogs spike pos."):format(TELEMETRY_INTERVAL))
        elseif val == "off" then
            ConLogsDB.config.relayPositions = false
            out("position telemetry OFF (won't broadcast or relay positions).")
        else
            out("position telemetry is " .. (positionsEnabled() and "ON (default)" or "OFF") .. ". Use: /conlogs relay pos on|off")
        end
    elseif action == "test" then
        testForce = true
        installSuppress()
        active = true
        local n = enqueueGroupCI(true)
        local b = enqueueBuffs(true)
        local po = enqueuePetOwners(true)   -- Claude (v2.6.0): force a pet->owner snapshot too
        out(("test mode ON — queued %d gear chunk(s) + %d buff chunk(s) + %d pet-owner chunk(s)."):format(n, b, po))
        out("Make sure /combatlog is on, then fail casts (on cooldown). Search the log for [[CL_CI_ (gear), [[CL_BU_ (buffs), [[CL_PO_ (pet-owner)"
            .. (positionsEnabled() and " and [[CL_TS_ (positions)" or "; enable positions first with /conlogs relay pos on")
            .. ". /conlogs relay off to stop.")
    elseif action == "status" then
        local _, instType = IsInInstance()
        out(("relay=%s positions=%s active=%s queued=%d logging=%s instance=%s testForce=%s"):format(
            tostring(relayEnabled()), tostring(positionsEnabled()), tostring(active), #queue,
            tostring(LoggingCombat and LoggingCombat() or false), tostring(instType), tostring(testForce)))
    else
        out("usage: /conlogs relay on | off | pos on|off | test | status")
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
