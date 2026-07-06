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

  Commands (hidden sub-commands of the existing /conlogs slash):
    /conlogs spike pos        — probe positions for your whole group, print + store
    /conlogs spike relay      — relay landing test (then fail a cast)
    /conlogs spike size       — max-payload test (then fail a cast)
    /conlogs spike buffs      — probe whether OTHER raiders' buffs are readable (range test)
    /conlogs spike relaystop  — stop the active test, restore globals
    /conlogs spike dump       — print stored results
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
-- Capture pristine SPELL_FAILED_* once at load and always restore to those (same
-- hardening as ConLogsRelay) so a spike test can never leave a chunk/sentinel string
-- stuck in the globals — even if it overlaps the relay.
local PRISTINE   = {}
for _, g in ipairs(FAIL_GLOBALS) do PRISTINE[g] = _G[g] end
local landedIndex = nil
local dumpsLeft  = 0
local sizeBest   = nil     -- highest <<N>> marker seen in the CLEU field during a size probe

local function applyProbe(str)
    for _, g in ipairs(FAIL_GLOBALS) do _G[g] = str end
end

local function restoreGlobals()
    for _, g in ipairs(FAIL_GLOBALS) do _G[g] = PRISTINE[g] end
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
    if testActive then out("A spike test is already running — /conlogs spike relaystop first."); return end
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
    if testActive then out("A spike test is already running — /conlogs spike relaystop first."); return end
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
    else out("positions: (none — run /conlogs spike pos)") end
    local rl = ConLogsSpikeDB.relayLanded
    if rl then good(("relay: LANDED at arg index %d (at %s)"):format(rl.argIndex, tostring(rl.when)))
    else out("relay: (no landing recorded — run /conlogs spike relay)") end
    local sp = ConLogsSpikeDB.sizeProbe
    if sp then good(("size: CLEU kept up to <<%d>> (%d chars, arg %d) (at %s)"):format(
        sp.cleuMarker, sp.cleuFieldLen, sp.argIndex, tostring(sp.when)))
    else out("size: (no size probe yet — run /conlogs spike size)") end
    local bp = ConLogsSpikeDB.buffProbe
    if bp then good(("buffs: visible %d/%d have buffs; out-of-range %d/%d have buffs (UnitAura=%s) (at %s)"):format(
        bp.visWith or 0, bp.visTotal or 0, bp.hidWith or 0, bp.hidTotal or 0,
        tostring(bp.unitAuraAvailable), tostring(bp.when)))
    else out("buffs: (no buff probe yet — run /conlogs spike buffs)") end
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

-- BUFF VISIBILITY PROBE. Can the addon read OTHER raid members' (and their pets')
-- auras, and does it depend on range? Self/own-pet are always complete; the open
-- question is whether out-of-range raiders return buffs. The KEY output is the
-- not-visible-with-buffs count: if out-of-range units always return 0 buffs, the
-- "scan everyone" approach is range-bound and the per-client self-snapshot mesh is
-- the real fix. Run INSIDE a raid, pre-pull, with people spread out.
local function readAuraCount(unit)
    if type(UnitAura) ~= "function" then return 0, {} end
    local names = {}
    for i = 1, 40 do
        local name = UnitAura(unit, i, "HELPFUL")
        if not name then break end
        names[#names + 1] = name
    end
    return #names, names
end

local function cmdBuffs()
    out("=== BUFF VISIBILITY PROBE (run INSIDE a raid, pre-pull, people spread out) ===")
    local units = {}
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do units[#units + 1] = "raid" .. i; units[#units + 1] = "raidpet" .. i end
    else
        units[#units + 1] = "player"; units[#units + 1] = "pet"
        for i = 1, (GetNumPartyMembers() or 0) do units[#units + 1] = "party" .. i; units[#units + 1] = "partypet" .. i end
    end

    local _, instType = IsInInstance()
    local rows = {}
    local visTotal, visWith, hidTotal, hidWith = 0, 0, 0, 0
    for _, u in ipairs(units) do
        if UnitExists(u) then
            local vis  = UnitIsVisible(u) and true or false
            local isSelf = UnitIsUnit(u, "player") or UnitIsUnit(u, "pet")
            local cnt, names = readAuraCount(u)
            if vis then visTotal = visTotal + 1; if cnt > 0 then visWith = visWith + 1 end
            else hidTotal = hidTotal + 1; if cnt > 0 then hidWith = hidWith + 1 end end
            rows[#rows + 1] = { unit = u, name = UnitName(u) or "?", visible = vis, self = isSelf, count = cnt, names = names }
        end
    end

    out(("zone=%s instanceType=%s units=%d"):format(GetRealZoneText() or "?", tostring(instType), #rows))
    for _, r in ipairs(rows) do
        out(("  %-9s %-12s vis=%s%s buffs=%d"):format(
            r.unit, r.name, r.visible and "T" or "F", r.self and " (self)" or "", r.count))
    end
    good(("visible units with buffs:     %d/%d"):format(visWith, visTotal))
    if hidTotal > 0 then
        if hidWith > 0 then good(("NOT-visible units with buffs: %d/%d  → out-of-range scanning WORKS"):format(hidWith, hidTotal))
        else bad(("NOT-visible units with buffs: 0/%d  → out-of-range returns nothing; rely on the self-snapshot mesh"):format(hidTotal)) end
    else
        out("(no out-of-range units this run — re-run with the raid spread out to test range dependence)")
    end

    ConLogsSpikeDB = ConLogsSpikeDB or {}
    ConLogsSpikeDB.buffProbe = {
        when = date and date("%Y-%m-%d %H:%M:%S") or time(),
        zone = GetRealZoneText() or "?", instanceType = instType,
        unitAuraAvailable = (type(UnitAura) == "function"),
        visTotal = visTotal, visWith = visWith, hidTotal = hidTotal, hidWith = hidWith,
        rows = rows,
    }
    out("Stored to ConLogsSpikeDB.buffProbe (reload/logout to flush the file).")
end

-- AURA SEARCH. Scan everyone (self, raid/party, pets) for a HELPFUL aura whose name
-- contains <query> (case-insensitive) and print who has it + time left. Use to check
-- totem/stat buffs live, e.g. /conlogs spike aura strength | grace | earth | totem.
local function cmdAura(query)
    query = (query or ""):gsub("^%s+",""):gsub("%s+$",""):lower()
    if query == "" then
        out("usage: /conlogs spike aura <name substring>  e.g. strength | agility | grace | earth | totem")
        return
    end
    if type(UnitAura) ~= "function" then bad("UnitAura not available on this client."); return end
    local units = {}
    local raidN = GetNumRaidMembers() or 0
    if raidN > 0 then
        for i = 1, raidN do units[#units + 1] = "raid" .. i; units[#units + 1] = "raidpet" .. i end
    else
        units[#units + 1] = "player"; units[#units + 1] = "pet"
        for i = 1, (GetNumPartyMembers() or 0) do units[#units + 1] = "party" .. i; units[#units + 1] = "partypet" .. i end
    end
    out(("=== aura search: '%s' ==="):format(query))
    local hits, withAura, scanned = 0, 0, 0
    for _, u in ipairs(units) do
        if UnitExists(u) then
            scanned = scanned + 1
            local found = false
            for i = 1, 40 do
                local name, _, _, _, _, _, expiration = UnitAura(u, i, "HELPFUL")
                if not name then break end
                if name:lower():find(query, 1, true) then
                    local left = (expiration and expiration > 0) and math.floor(expiration - (GetTime() or 0)) or nil
                    out(("  %-12s %s%s"):format(UnitName(u) or u, name, left and (" |cff888888("..left.."s)|r") or ""))
                    hits = hits + 1; found = true
                end
            end
            if found then withAura = withAura + 1 end
        end
    end
    good(("%d match(es) on %d/%d units."):format(hits, withAura, scanned))
end

-- CoA PROBE. Hunt how the Conquest-of-Azeroth 3.3.5 client exposes difficulty /
-- keystone level / flex scaling — the data ConLogs-CoA needs to relay. Four angles:
-- GetInstanceInfo tuple, bag items, player auras, and an _G global scan. Run at EACH
-- difficulty (normal/heroic/mythic/M+N) + a flex raid, then dump + send the SV file.
local function cmdCoa()
    out("=== CoA probe (run INSIDE a CoA instance at a known difficulty) ===")
    local iname, itype, idiff, idiffName, imax = "?", "?", "?", "?", "?"
    if type(GetInstanceInfo) == "function" then
        iname, itype, idiff, idiffName, imax = GetInstanceInfo()
    end
    local realm  = (type(GetRealmName) == "function" and GetRealmName()) or "?"
    local zone   = (type(GetRealZoneText) == "function" and GetRealZoneText()) or "?"
    local groupN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    if groupN == 0 then groupN = ((GetNumPartyMembers and GetNumPartyMembers()) or 0) + 1 end
    out(("realm=%s  zone=%s"):format(tostring(realm), tostring(zone)))
    out(("GetInstanceInfo: name='%s' type='%s' difficulty=%s difficultyName='%s' maxPlayers=%s"):format(
        tostring(iname), tostring(itype), tostring(idiff), tostring(idiffName), tostring(imax)))
    out(("group size (players)=%s"):format(tostring(groupN)))

    -- bag hunt: a keystone-like item
    local keyHits = {}
    if type(GetContainerNumSlots) == "function" and type(GetContainerItemLink) == "function" then
        for bag = 0, 4 do
            for slot = 1, (GetContainerNumSlots(bag) or 0) do
                local link = GetContainerItemLink(bag, slot)
                if link then
                    local nm = (link:match("%[(.-)%]") or ""):lower()
                    if nm:find("keystone", 1, true) or nm:find("mythic", 1, true) or nm:find("key", 1, true) then
                        keyHits[#keyHits + 1] = link
                    end
                end
            end
        end
    end
    out("bag keystone-like items: " .. (#keyHits > 0 and table.concat(keyHits, "  ") or "(none)"))

    -- aura hunt: affix / scaling / mythic-like buffs or debuffs on the player
    local auraHits = {}
    if type(UnitAura) == "function" then
        for _, filt in ipairs({ "HELPFUL", "HARMFUL" }) do
            for i = 1, 40 do
                local name = UnitAura("player", i, filt)
                if not name then break end
                local low = name:lower()
                if low:find("mythic",1,true) or low:find("keystone",1,true) or low:find("affix",1,true)
                    or low:find("fortif",1,true) or low:find("tyrann",1,true) or low:find("scal",1,true)
                    or low:find("challenge",1,true) or low:find("ascend",1,true) or low:find("flex",1,true) then
                    auraHits[#auraHits + 1] = name .. "[" .. filt:sub(1,1) .. "]"
                end
            end
        end
    end
    out("affix/scaling-like auras: " .. (#auraHits > 0 and table.concat(auraHits, ", ") or "(none)"))

    -- _G scan for keystone/mythic/affix/challenge/flex functions or tables
    local gHits = {}
    for k, v in pairs(_G) do
        if type(k) == "string" and (type(v) == "function" or type(v) == "table") then
            local lk = k:lower()
            if lk:find("keystone",1,true) or lk:find("mythic",1,true) or lk:find("affix",1,true)
                or lk:find("challenge",1,true) or lk:find("flexib",1,true) then
                gHits[#gHits + 1] = k .. "(" .. type(v) .. ")"
            end
        end
    end
    table.sort(gHits)
    out("keystone/mythic/affix globals: " .. #gHits .. " found (full list stored to SV)")

    -- Enumerate the CoA M+ API surface (method names) AND auto-call the likely no-arg
    -- getters (pcall-guarded) so one run reveals how to read keystone level / affixes /
    -- difficulty and what they return. Run in an ACTUAL M+ keystone dungeon for live values.
    local API_TABLES = { "C_Challenge", "C_Keystones", "C_MythicPlus", "ChallengeUtil",
        "MythicPlusUtil", "WeeklyKeystoneMixin", "KeystoneAffixMixin" }
    local apiMethods, apiCalls = {}, {}
    local function briefret(r)
        local parts = {}
        for i = 2, math.min(#r, 8) do
            local v = r[i]
            parts[#parts + 1] = (type(v) == "table") and "{table}" or tostring(v)
        end
        return "(" .. table.concat(parts, ", ") .. ")"
    end
    for _, tn in ipairs(API_TABLES) do
        local t = _G[tn]
        if type(t) == "table" then
            local keys = {}
            for k, v in pairs(t) do
                keys[#keys + 1] = tostring(k) .. "(" .. type(v) .. ")"
                if type(v) == "function" then
                    local lk = tostring(k):lower()
                    if lk:find("keystone",1,true) or lk:find("affix",1,true) or lk:find("active",1,true)
                        or lk:find("level",1,true) or lk:find("current",1,true) or lk:find("difficult",1,true)
                        or lk:find("owned",1,true) or lk:find("map",1,true) then
                        local r = { pcall(v) }
                        if r[1] and #r > 1 then apiCalls[tn .. "." .. tostring(k)] = briefret(r) end
                    end
                end
            end
            table.sort(keys)
            apiMethods[tn] = keys
            out("  " .. tn .. ": " .. #keys .. " methods (stored)")
        end
    end
    -- The getter RETURNS are the useful bit — keep these in chat (short).
    for name, ret in pairs(apiCalls) do out("  call " .. name .. "() -> " .. ret) end

    -- GOAL / ENCOUNTER probe: what completes THIS run (e.g. SM Library => Arcanist Doan).
    -- Shallow-dump the table-returning getters (to expose fields like mapID + encounter
    -- lists) and try the map-encounter getters both with a candidate mapID and no-arg.
    local function shallowStr(v, depth)
        if type(v) ~= "table" then return tostring(v) end
        local parts = {}
        for k, vv in pairs(v) do
            local s = (type(vv) == "table")
                and (((depth or 0) > 0) and ("{" .. shallowStr(vv, depth - 1) .. "}") or "{..}")
                or tostring(vv)
            parts[#parts + 1] = tostring(k) .. "=" .. s
        end
        return table.concat(parts, ", ")
    end
    local goalDumps = {}
    local function dumpCall(label, tbl, fn, ...)
        local t = _G[tbl]
        if type(t) ~= "table" or type(t[fn]) ~= "function" then return end
        local r = { pcall(t[fn], ...) }
        if not r[1] then goalDumps[label] = "ERR"; return end
        local parts = {}
        for i = 2, #r do
            parts[#parts + 1] = (type(r[i]) == "table") and ("{" .. shallowStr(r[i], 1) .. "}") or tostring(r[i])
        end
        goalDumps[label] = "(" .. table.concat(parts, " | ") .. ")"
    end
    dumpCall("GetActiveKeystoneInfo", "C_MythicPlus", "GetActiveKeystoneInfo")
    dumpCall("GetKeystoneInfo", "C_MythicPlus", "GetKeystoneInfo")
    dumpCall("GetActiveKeystoneEncounters", "C_MythicPlus", "GetActiveKeystoneEncounters")
    dumpCall("GetActiveChallenges", "C_Challenge", "GetActiveChallenges")
    local mapID = (type(GetCurrentMapAreaID) == "function" and GetCurrentMapAreaID()) or nil
    goalDumps._mapAreaID = tostring(mapID)
    dumpCall("GetMapFinalEncounter()", "C_MythicPlus", "GetMapFinalEncounter")
    dumpCall("GetMapEncounters()", "C_MythicPlus", "GetMapEncounters")
    if mapID then
        dumpCall("GetMapFinalEncounter(mapID)", "C_MythicPlus", "GetMapFinalEncounter", mapID)
        dumpCall("GetMapEncounters(mapID)", "C_MythicPlus", "GetMapEncounters", mapID)
    end
    for k, v in pairs(goalDumps) do out("  goal " .. k .. " = " .. tostring(v)) end

    ConLogsSpikeDB = ConLogsSpikeDB or {}
    ConLogsSpikeDB.coaProbe = {
        when = date and date("%Y-%m-%d %H:%M:%S") or time(),
        realm = realm, zone = zone, groupSize = groupN,
        instance = { name = iname, type = itype, difficulty = idiff, difficultyName = idiffName, maxPlayers = imax },
        bagKeystones = keyHits, affixAuras = auraHits, globals = gHits,
        apiMethods = apiMethods, apiCalls = apiCalls, goalDumps = goalDumps,
    }
    out("Stored to ConLogsSpikeDB.coaProbe (incl. goal/encounter dump). /conlogs spike dump + send me the SV file.")
end

local function spikeHelp()
    out("Phase-2 feasibility probe (debug). Sub-commands:")
    out("  /conlogs spike pos        — probe positions for your group")
    out("  /conlogs spike relay      — relay landing test (then fail a cast)")
    out("  /conlogs spike size       — max-payload test (then fail a cast)")
    out("  /conlogs spike unitpos    — probe for any API that reads OTHER units' positions")
    out("  /conlogs spike buffs      — probe whether OTHER raiders' buffs are readable (range test)")
    out("  /conlogs spike aura <txt> — who has a buff matching <txt> (e.g. strength, grace, earth)")
    out("  /conlogs spike coa        — CoA: probe difficulty/keystone/flex exposure")
    out("  /conlogs spike relaystop  — stop the active test + restore globals")
    out("  /conlogs spike dump       — show stored results")
end

-- Wrap the existing /conlogs handler (same idiom ConLogsUI uses). Loads last
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
        elseif sub == "buffs" then cmdBuffs()
        elseif sub == "aura" then cmdAura((arg or ""):match("^%S*%s+(.*)$"))
        elseif sub == "coa" then cmdCoa()
        elseif sub == "relaystop" or sub == "stop" then testStop()
        elseif sub == "dump" then dumpDB()
        else spikeHelp() end
        return
    end
    if origHandler then origHandler(msg) end
end
