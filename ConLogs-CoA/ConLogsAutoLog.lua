--[[ ===========================================================================
  ConLogsAutoLog.lua — CoA auto-combatlogging (replaces the Epoch dungeon-run tracker).

  CoA has no per-dungeon boss roster (difficulty/keystone/goal ride the relay's DI
  chunk + server-side data), so there's NO dungeon-run frame and NO training-dummy
  parser here — just log management:
    • auto-START /combatlog on entering ANY instance (party or raid), and
    • auto-STOP on leaving the instance OR leaving the group.
  Only ever touches a log WE started (addonStartedLog); a manual /combatlog is left
  alone. Gated by ConLogsDB.config.raidAutoLog (toggled via `/conlogs raidlog`, handled
  in ConLogs.lua). Solo instance runs aren't stopped by the group check (wasGrouped edge).
=========================================================================== ]]--

local addonStartedLog = false   -- true only when WE turned /combatlog on
local wasInInstance   = false
local wasGrouped      = false

local function IsLoggingActive()
    if not LoggingCombat then return false end
    local ok, isOn = pcall(LoggingCombat)
    return (ok and isOn) and true or false
end

-- Stop a /combatlog we auto-started (never a user's manual log).
local function StopAutoLog(reason)
    if not addonStartedLog then return end
    if LoggingCombat then LoggingCombat(false) end
    addonStartedLog = false
    ConLogsDB = ConLogsDB or {}
    ConLogsDB.session = ConLogsDB.session or {}
    ConLogsDB.session.addonStartedLog = false
    print(string.format("|cffffd200ConLogs|r |cffff9966AUTO-LOG STOPPED|r |cff888888(%s) — /combatlog closed.|r", tostring(reason)))
end

local f = CreateFrame("Frame")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        ConLogsDB = ConLogsDB or {}
        ConLogsDB.config = ConLogsDB.config or {}
        if ConLogsDB.config.raidAutoLog == nil then ConLogsDB.config.raidAutoLog = true end
        -- Restore our "we started the log" claim across /reload; drop it if /combatlog
        -- isn't actually running (a full logout stops it).
        ConLogsDB.session = ConLogsDB.session or {}
        addonStartedLog = ConLogsDB.session.addonStartedLog and true or false
        if addonStartedLog and not IsLoggingActive() then
            addonStartedLog = false
            ConLogsDB.session.addonStartedLog = false
        end
        -- seed the transition flags from current state
        local inInst, itype = false, nil
        if IsInInstance then inInst, itype = IsInInstance() end
        wasInInstance = inInst and (itype == "party" or itype == "raid")
        wasGrouped = (((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0)
            or (((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local inInst, itype = false, nil
        if IsInInstance then inInst, itype = IsInInstance() end
        local nowInInstance = inInst and (itype == "party" or itype == "raid")
        if nowInInstance and not wasInInstance and not addonStartedLog
           and ConLogsDB and ConLogsDB.config and ConLogsDB.config.raidAutoLog
           and not IsLoggingActive() then
            if LoggingCombat then LoggingCombat(true) end
            addonStartedLog = true
            ConLogsDB.session = ConLogsDB.session or {}
            ConLogsDB.session.addonStartedLog = true
            print("|cffffd200ConLogs|r |cff66ff66AUTO-LOG STARTED|r |cff888888(instance) — auto-stops on leaving the instance or group. /conlogs raidlog off to disable.|r")
        elseif not nowInInstance and wasInInstance and addonStartedLog then
            StopAutoLog("left the instance")
        end
        wasInInstance = nowInInstance
        return
    end

    if event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        -- Leaving the group entirely stops an auto-log we started. Edge-triggered
        -- (grouped -> ungrouped) so a SOLO instance run isn't stopped by this.
        local grouped = (((GetNumRaidMembers and GetNumRaidMembers()) or 0) > 0)
            or (((GetNumPartyMembers and GetNumPartyMembers()) or 0) > 0)
        if wasGrouped and not grouped and addonStartedLog then
            StopAutoLog("left the group")
        end
        wasGrouped = grouped
        return
    end
end)
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("PARTY_MEMBERS_CHANGED")
f:RegisterEvent("RAID_ROSTER_UPDATE")
