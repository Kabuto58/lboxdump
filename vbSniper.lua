local config = {
    autoWalkEnabled = true,
    moneyThreshold = 5500
}

-- UI Configuration
local UI = {
    notifications = {},
    maxNotifications = 3,
    notificationHeight = 20,
    notificationLifetime = 10,
    mainFont = nil,
    colors = {
        success = {100, 255, 100}, warning = {255, 200, 50},
        error = {255, 80, 80}, info = {100, 180, 255},
        accent = {199, 170, 255}, text = {255, 255, 255},
        friendly = {100, 255, 100}, enemy = {255, 80, 80}
    },
    icons = {success = "#", warning = "!", error = "X", info = "i"}
}

-- State variables
local needToLeaveZone, hasTriedClassChange = false, false
local leaveZoneStartPos = nil
local thresholdNotificationShown, lastVaccWarning = false, false
local lastProcessTime, lastCleanupTime, lastToggleTime = 0, 0, 0
local nextUpgradeTime, sequenceEndTime = 0, 0
local upgradeQueue, isProcessing, respawnExpected = {}, false, false
local currentServer, shouldGuidePlayer, midpoint = nil, false, nil
local wasAlive, alreadyRequested = false, false
local waitingForSniperClass, isSniperUpgrade, sniperUpgradeCompleted = false, false, false
local sniperUpgradeCompletedTime = 0  -- Timestamp when Sniper upgrades finished
local hasResetForEndOfMatch = false

local COOLDOWN_TIME = 0.5
local UPGRADE_DELAY, SEQUENCE_END_COOLDOWN = 0.1, 1.0
local SNIPER_UPGRADE_DELAY = 0.2
local TOGGLE_COOLDOWN = 0.2
local TELEPORTER_AUTOWALK_DELAY = 2.0  -- Delay before enabling teleporter auto-walk
local KEY_L, KEY_K = 22, 21
local TF_CLASS_SNIPER = 2
local TF_CLASS_MEDIC = 5

-- ===== TELEPORTER SCANNER CONFIGURATION =====
local teleporterConfig = {
    scanEnabled = true,
    maxScanDistance = 10000,
    showOnlyFriendly = true,
    autoWalkEnabled = false,  -- Will be enabled after Sniper upgrades
    walkSpeed = 450
}

-- Teleporter scanner state
local hasScannedTeleporter = false
local foundTeleporters = {}
local tpPathSelected = false
local tpCurrentPathIndex = nil
local tpCurrentPathWaypointIndex = 1
local tpUsingPredefinedPath = false
local tpLOSDetectedTime = 0  -- Timestamp when LOS was first detected
local tpLOSDelay = 1.0  -- Delay in seconds before abandoning path
local teleporterManuallyDisabled = false  -- Tracks if user manually disabled via L key

-- Predefined map paths for teleporter navigation (recorded from actual gameplay)
local mapPaths = {
    ["maps/mvm_mannhattan.bsp"] = {
        {
            -- Path 1: Left route (4 waypoints)
            {x = 249.31, y = 2305.73, z = -159.97},  -- Start
            {x = 407.42, y = 2212.99, z = -159.97},  -- Turn
            {x = 407.42, y = 2069.59, z = -159.97},  -- End point
        },
        {
            -- Path 2: Right route (3 waypoints)
            {x = -360.67, y = 2337.54, z = -159.97}, -- Start
            {x = -453.66, y = 2163.57, z = -159.97}, -- Turn
            {x = -360.84, y = 1982.38, z = -159.97}  -- End point
        }
    },

    ["maps/mvm_rottenburg.bsp"] = {
        {
            -- Path 1: Closed spawn (4 waypoints - cleaned)
            {x = -1174.54, y = 2397.37, z = -127.97},  -- Start
            {x = -760.03, y = 2161.80, z = -127.97},   -- Turn
            {x = -1127.16, y = 1730.38, z = -169.79},  -- Turn + descent
            {x = -1084.47, y = 1275.69, z = -170.00}   -- End point
        },
        {
            -- Path 2: Open spawn (6 waypoints - cleaned)
            {x = -1507.05, y = 669.63, z = -167.97},   -- Start
            {x = -1530.55, y = 1126.37, z = -169.98},  -- Turn
            {x = -972.86, y = 1195.13, z = -170.83},   -- Turn
            {x = -832.51, y = 2156.71, z = -127.98}    -- End point
        }
    }
}


-- Helper functions
local function clampColor(val)
    if not val or val ~= val then return 255 end
    return math.max(0, math.min(255, math.floor(val)))
end

local function AddNotification(message, type)
    type = type or "info"
    table.insert(UI.notifications, 1, {
        message = message,
        icon = UI.icons[type],
        color = UI.colors[type],
        time = globals.CurTime(),
        alpha = 0,
        targetAlpha = 255
    })
    if #UI.notifications > UI.maxNotifications then
        table.remove(UI.notifications)
    end
end

local function IsGameInputAllowed()
    return not (engine.Con_IsVisible() or engine.IsGameUIVisible() or engine.IsChatOpen())
end

local function IsMoneyThresholdReached()
    local me = entities.GetLocalPlayer()
    if not me then return false end
    local currency = me:GetPropInt("m_nCurrency")
    return currency and currency >= config.moneyThreshold
end

local function IsMvMWaveActive()
    return gamerules.IsMvM() and gamerules.GetRoundState() == 4
end

local function ChangeClass()
    AddNotification("ChangeClass() called - hasTriedClassChange: " .. tostring(hasTriedClassChange), "info")

    if not hasTriedClassChange then
        hasTriedClassChange = true
        waitingForSniperClass = true
        -- Send joinclass command directly
        client.Command("wait 300;joinclass sniper", true)
        AddNotification("Changing class to Sniper...", "success")
    else
        AddNotification("Already tried class change, skipping", "warning")
    end
end

-- ===== TELEPORTER SCANNER HELPER FUNCTIONS =====
local function GetDistanceTP(pos1, pos2)
    local dx = pos2.x - pos1.x
    local dy = pos2.y - pos1.y
    local dz = pos2.z - pos1.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function GetCurrentMapTP()
    return engine.GetMapName()
end

local function ChooseBestPathTP(playerPos, mapName)
    local paths = mapPaths[mapName]
    if not paths then return nil end

    local closestPathIndex = nil
    local closestDistance = math.huge

    for i, path in ipairs(paths) do
        local firstWaypoint = Vector3(path[1].x, path[1].y, path[1].z)
        local distance = GetDistanceTP(playerPos, firstWaypoint)

        if distance < closestDistance then
            closestDistance = distance
            closestPathIndex = i
        end
    end

    return closestPathIndex
end

local function GetCurrentPathWaypointTP()
    if not tpCurrentPathIndex then return nil end

    local mapName = GetCurrentMapTP()
    local paths = mapPaths[mapName]
    if not paths or not paths[tpCurrentPathIndex] then return nil end

    local path = paths[tpCurrentPathIndex]
    if tpCurrentPathWaypointIndex > #path then return nil end

    local wp = path[tpCurrentPathWaypointIndex]
    return Vector3(wp.x, wp.y, wp.z)
end

local function HasLineOfSightToTeleporter(fromPos, toPos)
    -- Trace a line from player position to teleporter
    -- Offset the start position slightly upward to trace from eye level
    local startPos = fromPos + Vector3(0, 0, 64)
    local endPos = toPos + Vector3(0, 0, 32)

    local trace = engine.TraceLine(startPos, endPos, MASK_SHOT_HULL)

    -- If trace fraction is close to 1.0, nothing significant was hit - clear line of sight
    return trace.fraction == 1.0
end

local function ComputeMoveTP(userCmd, fromPos, toPos)
    -- Use the same proven approach as ComputeMove
    local diff = toPos - fromPos
    if diff:Length() == 0 then
        return 0, 0  -- Already at target
    end

    -- Convert direction to angles
    local ang = Vector3(diff.x, diff.y, 0):Angles()

    -- Get current view yaw
    local _, cYaw, _ = userCmd:GetViewAngles()

    -- Calculate angle difference
    local yaw = math.rad(ang.y - cYaw)

    -- Compute forward and side movement using the angle difference
    local forwardMove = math.cos(yaw) * teleporterConfig.walkSpeed
    local sideMove = -math.sin(yaw) * teleporterConfig.walkSpeed

    return forwardMove, sideMove
end

local function WalkToTeleporterTP(userCmd, me, targetPos)
    -- Safety check: Only execute if Sniper upgrades are complete
    if not sniperUpgradeCompleted then
        return
    end

    local myPos = me:GetAbsOrigin()
    local mapName = GetCurrentMapTP()
    local hasPredefinedPaths = mapPaths[mapName] ~= nil

    -- Check for line of sight to teleporter
    local hasLOS = HasLineOfSightToTeleporter(myPos, targetPos)
    local currentTime = globals.CurTime()

    -- If we have line of sight, start delay timer before abandoning path
    if hasLOS and tpUsingPredefinedPath then
        -- Start the delay timer on first LOS detection
        if tpLOSDetectedTime == 0 then
            tpLOSDetectedTime = currentTime
        end

        -- Check if delay has passed
        if currentTime - tpLOSDetectedTime >= tpLOSDelay then
            tpUsingPredefinedPath = false
            tpLOSDetectedTime = 0  -- Reset for next time
            AddNotification("LOS detected - Direct path", "info")
        end
    elseif not hasLOS then
        -- Reset the timer if we lose line of sight
        tpLOSDetectedTime = 0
    end

    -- Use predefined paths if available and no line of sight
    if hasPredefinedPaths and not tpPathSelected and not hasLOS then
        tpCurrentPathIndex = ChooseBestPathTP(myPos, mapName)
        if tpCurrentPathIndex then
            tpCurrentPathWaypointIndex = 1
            tpUsingPredefinedPath = true
            tpPathSelected = true

            local paths = mapPaths[mapName]
            local selectedPath = paths[tpCurrentPathIndex]
        end
    elseif not hasPredefinedPaths and not tpPathSelected then
        tpPathSelected = true
    elseif hasLOS and not tpPathSelected then
        -- Have line of sight from the start, skip predefined path
        tpPathSelected = true
    end

    -- Follow predefined path (only if no line of sight)
    if tpUsingPredefinedPath and not hasLOS then
        local pathWaypoint = GetCurrentPathWaypointTP()

        if pathWaypoint then
            local waypointDistance = GetDistanceTP(myPos, pathWaypoint)

            if waypointDistance < 100 then
                tpCurrentPathWaypointIndex = tpCurrentPathWaypointIndex + 1
                local nextWaypoint = GetCurrentPathWaypointTP()

                if nextWaypoint then
                    pathWaypoint = nextWaypoint
                else
                    tpUsingPredefinedPath = false
                end
            end

            if tpUsingPredefinedPath and pathWaypoint then
                local forwardMove, sideMove = ComputeMoveTP(userCmd, myPos, pathWaypoint)
                userCmd:SetForwardMove(forwardMove)
                userCmd:SetSideMove(sideMove)
                return
            end
        end
    end

    -- Direct navigation to teleporter (when LOS detected or path complete)
    local forwardMove, sideMove = ComputeMoveTP(userCmd, myPos, targetPos)
    userCmd:SetForwardMove(forwardMove)
    userCmd:SetSideMove(sideMove)
end

local function ScanForTeleportersTP()
    local me = entities.GetLocalPlayer()
    if not me then return end

    local myPos = me:GetAbsOrigin()
    local myTeam = me:GetTeamNumber()
    foundTeleporters = {}

    for i = 0, 2048 do
        local entity = entities.GetByIndex(i)
        if entity then
            local class = entity:GetClass()

            if class == "CObjectTeleporter" then
                local pos = entity:GetAbsOrigin()
                if pos then
                    local distance = GetDistanceTP(myPos, pos)

                    if distance <= teleporterConfig.maxScanDistance then
                        local team = entity:GetTeamNumber()
                        local mode = entity:GetPropInt("m_iObjectMode")
                        local level = entity:GetPropInt("m_iUpgradeLevel")
                        local health = entity:GetHealth()
                        local maxHealth = entity:GetMaxHealth()
                        local builder = entity:GetPropEntity("m_hBuilder")

                        if mode == 0 then
                            local isEnemy = team ~= myTeam
                            local isFriendly = team == myTeam

                            if isFriendly and teleporterConfig.showOnlyFriendly then
                                local builderName = "Unknown"
                                if builder then
                                    builderName = builder:GetName()
                                end

                                table.insert(foundTeleporters, {
                                    entity = entity,
                                    pos = pos,
                                    distance = distance,
                                    team = team,
                                    isEnemy = isEnemy,
                                    level = level,
                                    health = health,
                                    maxHealth = maxHealth,
                                    builderName = builderName
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(foundTeleporters, function(a, b) return a.distance < b.distance end)
end

local function HasVaccinator()
    local me = entities.GetLocalPlayer()
    if not me then return false end
    for i = 0, 7 do
        local weapon = me:GetEntityForLoadoutSlot(i)
        if weapon and weapon:GetPropInt("m_iItemDefinitionIndex") == 998 then
            return true
        end
    end
    return false
end

local function ResetState()
    isProcessing, respawnExpected = false, false
    upgradeQueue, sequenceEndTime, nextUpgradeTime = {}, 0, 0
    shouldGuidePlayer, thresholdNotificationShown, hasTriedClassChange = false, false, false
    needToLeaveZone, leaveZoneStartPos = false, nil
    lastToggleTime, lastVaccWarning = 0, false
    waitingForSniperClass, isSniperUpgrade, sniperUpgradeCompleted = false, false, false
    sniperUpgradeCompletedTime = 0
    config.autoWalkEnabled = true

    -- Reset time-based variables to prevent cooldown issues when changing servers
    lastProcessTime, lastCleanupTime = 0, 0

    -- Reset teleporter scanner state
    hasScannedTeleporter, foundTeleporters = false, {}
    tpPathSelected, tpCurrentPathIndex = false, nil
    tpCurrentPathWaypointIndex, tpUsingPredefinedPath = 1, false
    tpLOSDetectedTime = 0
    teleporterManuallyDisabled = false
    teleporterConfig.autoWalkEnabled = false

    -- Turn off MVM Auto Ready for time to upgrade
    gui.SetValue("mvm auto ready (f4)", 0)
end

local function CheckServerChange()
    local netChannel = clientstate.GetNetChannel()
    local serverIP = netChannel and netChannel:GetAddress() or nil
    local signonState = clientstate.GetClientSignonState()

    -- Check if server changed or disconnected
    if serverIP ~= currentServer then
        local oldServer = currentServer
        currentServer = serverIP
        ResetState()
        hasResetForEndOfMatch = false
        -- Only show notification if we're fully connected to a new server
        if oldServer and serverIP and signonState == E_SignonState.SIGNONSTATE_FULL then
            AddNotification("Connected to new server - Reset state", "info")
        end
    end
end

local function ComputeMove(userCmd, a, b)
    local diff = b - a
    if diff:Length() == 0 then return Vector3(0, 0, 0) end

    local ang = Vector3(diff.x, diff.y, 0):Angles()
    local _, cYaw, _ = userCmd:GetViewAngles()
    local yaw = math.rad(ang.y - cYaw)
    return Vector3(math.cos(yaw) * 450, -math.sin(yaw) * 450, 0)
end

local function WalkTo(userCmd, me, destination)
    local result = ComputeMove(userCmd, me:GetAbsOrigin(), destination)
    userCmd:SetForwardMove(result.x)
    userCmd:SetSideMove(result.y)
end

local function FindUpgradeStations(me)
    local myPos = me:GetAbsOrigin()
    local signs = {}

    for i = 0, 2048 do
        local entity = entities.GetByIndex(i)
        if entity and entity:GetClass() == "CDynamicProp" then
            if models.GetModelName(entity:GetModel()) == "models/props_mvm/mvm_upgrade_sign.mdl" then
                local pos = entity:GetAbsOrigin()
                if pos then
                    local dist = vector.Length(vector.Subtract(pos, myPos))
                    if dist < 5000 then
                        table.insert(signs, {pos = pos, distance = dist})
                    end
                end
            end
        end
    end

    if #signs >= 2 then
        table.sort(signs, function(a, b) return a.distance < b.distance end)
        local pos1 = signs[1].pos
        local closestDist, pos2 = math.huge, nil

        for i = 2, #signs do
            local dist = vector.Length(vector.Subtract(signs[i].pos, pos1))
            if dist < closestDist then
                closestDist, pos2 = dist, signs[i].pos
            end
        end

        if pos2 then
            return Vector3((pos1.x + pos2.x) / 2, (pos1.y + pos2.y) / 2, (pos1.z + pos2.z) / 2)
        end
    end
    return nil
end

local function SendMvMUpgrade(itemslot, upgrade, count)
    -- Support both integer and float upgrade IDs
    local upgradeStr = (upgrade % 1 == 0) and string.format("%d", upgrade) or string.format("%.1f", upgrade)
    return engine.SendKeyValues(string.format(
        [["MVM_Upgrade" { "Upgrade" { "itemslot" "%d" "Upgrade" "%s" "count" "%d" } }]],
        itemslot, upgradeStr, count))
end

local function ForceCleanup()
    engine.SendKeyValues('"MvM_UpgradesDone" { "num_upgrades" "0" }')
    isProcessing, respawnExpected = false, false
    upgradeQueue = {}
    AddNotification("Cleaned up upgrade state", "warning")
end

local function ProcessQueue()
    local currentTime = globals.CurTime()

    if sequenceEndTime > 0 and currentTime < sequenceEndTime then return end
    sequenceEndTime = 0

    if #upgradeQueue == 0 then
        if isProcessing then
            engine.SendKeyValues('"MvM_UpgradesDone" { "num_upgrades" "0" }')
            AddNotification("Sequence completed!", "success")
            isProcessing, respawnExpected, shouldGuidePlayer = false, true, false
            isSniperUpgrade = false
            sequenceEndTime = currentTime + SEQUENCE_END_COOLDOWN
            nextUpgradeTime = currentTime + SEQUENCE_END_COOLDOWN
            upgradeQueue = {{type = "cleanup"}}
        end
        return
    end

    if upgradeQueue[1].type == "respec" then
        respawnExpected = true
    end

    if currentTime < nextUpgradeTime then return end

    local action = table.remove(upgradeQueue, 1)

    if action.type == "cleanup" then
        ForceCleanup()
        isSniperUpgrade = false
    elseif action.type == "begin" then
        engine.SendKeyValues('"MvM_UpgradesBegin" {}')
    elseif action.type == "upgrade" then
        SendMvMUpgrade(action.slot, action.id, action.count)
    elseif action.type == "respec" then
        engine.SendKeyValues('"MVM_Respec" {}')
    elseif action.type == "end" then
        engine.SendKeyValues('"MvM_UpgradesDone" { "num_upgrades" "' .. action.count .. '" }')
    elseif action.type == "kill" then
        client.Command("kill", true)
        AddNotification("Sniper upgrades purchased - Respawning...", "success")
        sniperUpgradeCompleted = true
        sniperUpgradeCompletedTime = currentTime  -- Record completion time for delay
        isSniperUpgrade = false
        isProcessing = false
        AddNotification("Teleporter scanner will activate in 2 seconds...", "info")
        return
    end

    -- Use appropriate delay based on upgrade type
    local delay = isSniperUpgrade and SNIPER_UPGRADE_DELAY or UPGRADE_DELAY
    nextUpgradeTime = currentTime + delay
end

local function TriggerProcess()
    local currentTime = globals.CurTime()

    if isProcessing then
        AddNotification("Sequence already in progress!", "error")
        return
    end

    if currentTime - lastProcessTime < COOLDOWN_TIME then return end
    if sequenceEndTime > 0 and currentTime < sequenceEndTime then return end

    if IsMvMWaveActive() then
        if config.autoWalkEnabled then
            config.autoWalkEnabled = false
            AddNotification("Auto walk disabled - Wave active", "warning")
        end
        shouldGuidePlayer = false
        return
    end

    local me = entities.GetLocalPlayer()
    if not me then
        AddNotification("Local player not found!", "error")
        return
    end

    if me:GetPropInt('m_bInUpgradeZone') ~= 1 then
        AddNotification("Must be in upgrade zone!", "error")
        return
    end

    if not me:IsAlive() then
        AddNotification("Must be alive to use!", "error")
        return
    end

    lastProcessTime, isProcessing = currentTime, true
    AddNotification("Starting sequence...", "success")
    
    
    upgradeQueue = {
        {type = "begin"},
        {type = "upgrade", slot = 1, id = 19, count = 10},
        {type = "upgrade", slot = 1, id = 19, count = 10},
        {type = "end", count = 20},
        {type = "begin"},
        {type = "upgrade", slot = 1, id = 19, count = -10},
        {type = "upgrade", slot = 1, id = 19, count = -10},
        {type = "end", count = -20},
        {type = "begin"},
        {type = "upgrade", slot = 1, id = 19, count = 10},
        {type = "upgrade", slot = 1, id = 19, count = 10},
        {type = "end", count = 20},
        {type = "begin"},
        {type = "respec"},
        {type = "end", count = 0}
    }

    nextUpgradeTime = currentTime + UPGRADE_DELAY
end

local function TriggerSniperUpgrades()
    local currentTime = globals.CurTime()

    if isProcessing then
        AddNotification("Sequence already in progress!", "error")
        return
    end

    if currentTime - lastProcessTime < COOLDOWN_TIME then return end
    if sequenceEndTime > 0 and currentTime < sequenceEndTime then return end

    local me = entities.GetLocalPlayer()
    if not me then
        AddNotification("Local player not found!", "error")
        return
    end

    if me:GetPropInt('m_bInUpgradeZone') ~= 1 then
        AddNotification("Must be in upgrade zone!", "error")
        return
    end

    if not me:IsAlive() then
        AddNotification("Must be alive to use!", "error")
        return
    end

    lastProcessTime, isProcessing, isSniperUpgrade = currentTime, true, true
    AddNotification("Starting Sniper upgrade sequence...", "success")

    upgradeQueue = {
        {type = "begin"},
        -- Slot 0 upgrades
        {type = "upgrade", slot = 0, id = -0.9, count = 10},
        {type = "upgrade", slot = 0, id = -0.8, count = 10},
        {type = "upgrade", slot = 0, id = -0.7, count = 10},
        {type = "upgrade", slot = 0, id = -0.6, count = 10},
        {type = "upgrade", slot = 0, id = 40, count = 10},
        {type = "upgrade", slot = 0, id = 40, count = 10},
        {type = "upgrade", slot = 0, id = 40.1, count = 10},
        {type = "upgrade", slot = 0, id = 40.2, count = 10},
        {type = "upgrade", slot = 0, id = 35.1, count = 10},
        {type = "upgrade", slot = 0, id = 35.2, count = 10},
        {type = "upgrade", slot = 0, id = 35.3, count = 10},
        {type = "upgrade", slot = 0, id = 12, count = 10},
        {type = "upgrade", slot = 0, id = 12, count = 10},
        {type = "upgrade", slot = 0, id = 59, count = 10},
        {type = "upgrade", slot = 0, id = 59, count = 10},
        {type = "upgrade", slot = 0, id = 59.1, count = 10},
        {type = "upgrade", slot = 0, id = 59.2, count = 10},
        {type = "upgrade", slot = 0, id = 62, count = 10},
        {type = "upgrade", slot = 0, id = 62.1, count = 10},
        {type = "upgrade", slot = 0, id = 62.2, count = 10},
        {type = "upgrade", slot = 0, id = 17, count = 10},
        {type = "upgrade", slot = 0, id = 17.1, count = 10},
        {type = "upgrade", slot = 0, id = 17.2, count = 10},
        {type = "upgrade", slot = 0, id = 17.3, count = 10},
        -- Slot 9 upgrades
        {type = "upgrade", slot = 9, id = 29.0, count = 10},
        {type = "upgrade", slot = 9, id = 29.1, count = 10},
        {type = "upgrade", slot = 9, id = 29.2, count = 10},
        {type = "end", count = 270},
        {type = "kill"}
    }

    nextUpgradeTime = currentTime + SNIPER_UPGRADE_DELAY
end

local function HandleMoneyThreshold(me, inZone)
    if not thresholdNotificationShown then
        AddNotification("Money threshold ($" .. config.moneyThreshold .. ") reached!", "warning")
        config.autoWalkEnabled = false
        thresholdNotificationShown = true

        AddNotification("InZone: " .. tostring(inZone) .. ", hasTriedClassChange: " .. tostring(hasTriedClassChange), "info")

        if not hasTriedClassChange then
            if inZone then
                leaveZoneStartPos = me:GetAbsOrigin()
                needToLeaveZone = true
                AddNotification("Moving out of upgrade zone...", "info")
            else
                AddNotification("Not in zone, calling ChangeClass() now", "info")
                ChangeClass()
            end
        else
            AddNotification("Already tried class change", "warning")
        end
    end
end

-- Main callback
callbacks.Register("CreateMove", function(cmd)
    local currentTime = globals.CurTime()
    CheckServerChange()

    -- Reset state when match ends so script works consistently across games
    if gamecoordinator.InEndOfMatch() then
        if not hasResetForEndOfMatch then
            hasResetForEndOfMatch = true
            if isProcessing then ForceCleanup() end
            ResetState()
            AddNotification("End of match - State reset", "info")
        end
        return
    else
        hasResetForEndOfMatch = false
    end

    local me = entities.GetLocalPlayer()

    if me and thresholdNotificationShown and not hasTriedClassChange then
        if me:GetPropInt('m_bInUpgradeZone') ~= 1 then
            ChangeClass()
        end
    end

    if not me then return end

    -- Detect Sniper class change
    if waitingForSniperClass and not sniperUpgradeCompleted then
        local playerClass = me:GetPropInt("m_iClass")
        if playerClass == TF_CLASS_SNIPER then
            waitingForSniperClass = false
            config.autoWalkEnabled = true
            AddNotification("Sniper class detected! Auto-walking to upgrade station...", "success")
        end
    end

    -- Handle leaving zone for class change
    if needToLeaveZone then
        local inZone = me:GetPropInt('m_bInUpgradeZone') == 1

        if inZone then
            -- Still in zone, move backwards to exit
            if leaveZoneStartPos then
                cmd:SetForwardMove(-450)
                local viewAngles = engine.GetViewAngles()
                cmd:SetViewAngles(0, viewAngles.y, 0)
            end
        else
            -- Out of zone, change class immediately
            needToLeaveZone, leaveZoneStartPos = false, nil

            if not hasTriedClassChange then
                if IsMvMWaveActive() then
                    AddNotification("Wave is active, waiting...", "warning")
                    needToLeaveZone = true  -- Retry next frame
                else
                    AddNotification("Left upgrade zone, changing class now...", "info")
                    ChangeClass()
                end
            end
        end
        -- Return early - don't run other logic while handling class change
        return
    end

    -- If waiting for Sniper class change, don't do anything else
    if waitingForSniperClass and not hasTriedClassChange then
        return
    end

    -- Auto walk logic
    if config.autoWalkEnabled then
        local inZone = me:GetPropInt('m_bInUpgradeZone') == 1
        local playerClass = me:GetPropInt("m_iClass")
        local isSniper = playerClass == TF_CLASS_SNIPER

        -- Only check money threshold if not Sniper and not currently processing upgrades
        if not isSniper and not isProcessing and IsMoneyThresholdReached() then
            HandleMoneyThreshold(me, inZone)
            return
        end

        local hasVacc = HasVaccinator()

        -- Only warn about Vaccinator if not Sniper
        if not hasVacc and not lastVaccWarning and not isSniper then
            AddNotification("Secondary weapon is not the Vaccinator!", "error")
            lastVaccWarning = true
        elseif hasVacc then
            lastVaccWarning = false
        end

        -- Allow auto-walk for both Vaccinator users and Sniper
        if not inZone and (hasVacc or isSniper) and not isProcessing then
            local newMidpoint = FindUpgradeStations(me)
            if newMidpoint then
                midpoint = newMidpoint
                if not shouldGuidePlayer then
                    shouldGuidePlayer = true
                    AddNotification("Found upgrade station", "info")
                end
            else
                if shouldGuidePlayer then
                    AddNotification("Lost sight of upgrade station!", "warning")
                end
                shouldGuidePlayer = false
            end
        else
            if shouldGuidePlayer then
                AddNotification("Stopped guidance - reached zone or started process", "info")
            end
            shouldGuidePlayer = false
        end

        if shouldGuidePlayer and midpoint then
            WalkTo(cmd, me, midpoint)
        end
    end

    -- Trigger upgrade process
    if me:GetPropInt('m_bInUpgradeZone') == 1 and not isProcessing then
        local playerClass = me:GetPropInt("m_iClass")

        -- Check if Sniper upgrades should be triggered
        if playerClass == TF_CLASS_SNIPER and not sniperUpgradeCompleted then
            TriggerSniperUpgrades()
        elseif sniperUpgradeCompleted then
            -- Sniper upgrades already completed, stop all automation
            if config.autoWalkEnabled then
                config.autoWalkEnabled = false
                AddNotification("Sniper upgrades complete - Automation stopped", "info")
            end
        elseif IsMoneyThresholdReached() then
            -- Don't run Medic upgrade sequence if already at threshold
            if not thresholdNotificationShown then
                AddNotification("Skipping upgrade - money threshold already reached", "warning")
                HandleMoneyThreshold(me, true)
            end
        else
            -- Only run Medic upgrade sequence if below threshold
            TriggerProcess()
        end
    end

    -- Cancel if left zone
    if isProcessing and me:GetPropInt('m_bInUpgradeZone') ~= 1 and not respawnExpected then
        ForceCleanup()
        AddNotification("Sequence cancelled - left zone!", "error")
        return
    end

    -- Reset respawn flag
    if respawnExpected and me:GetPropInt('m_bInUpgradeZone') == 1 then
        respawnExpected = false
    end

    -- Cancel if died
    if isProcessing and not me:IsAlive() and not respawnExpected then
        ForceCleanup()
        AddNotification("Sequence interrupted!", "error")
        return
    end

    -- Process queue
    if isProcessing then
        ProcessQueue()
    end

    -- L key: Manual trigger for Medic upgrade sequence (only before Sniper upgrades)
    if not sniperUpgradeCompleted and IsGameInputAllowed() and input.IsButtonPressed(KEY_L) then
        local playerClass = me:GetPropInt("m_iClass")
        if playerClass == TF_CLASS_MEDIC then
            TriggerProcess()
        end
    end

    -- ===== TELEPORTER AUTO-WALK (after Sniper upgrades) =====
    if sniperUpgradeCompleted then
        local playerClass = me:GetPropInt("m_iClass")
        local isSniper = playerClass == TF_CLASS_SNIPER

        -- Only allow teleporter walk for Sniper class
        if not isSniper then
            if teleporterConfig.autoWalkEnabled then
                teleporterConfig.autoWalkEnabled = false
                AddNotification("Teleporter ESP Disabled: Not Sniper class","error")
            end
            return
        end

        -- Check if delay has passed before enabling auto-walk (only if not manually disabled)
        if not teleporterConfig.autoWalkEnabled and sniperUpgradeCompletedTime > 0 and not teleporterManuallyDisabled then
            if currentTime - sniperUpgradeCompletedTime >= TELEPORTER_AUTOWALK_DELAY then
                teleporterConfig.autoWalkEnabled = true
                AddNotification("Teleporter ESP initiated", "success")
            end
        end

        -- Emergency stop with L key
        if IsGameInputAllowed() and input.IsButtonPressed(KEY_L) then
            teleporterConfig.autoWalkEnabled = not teleporterConfig.autoWalkEnabled

            if teleporterConfig.autoWalkEnabled then
                -- Re-enabling auto-walk: rescan teleporters for fresh data
                teleporterManuallyDisabled = false
                hasScannedTeleporter = false
                AddNotification("Auto-walk ENABLED (L key)", "success")
            else
                -- Disabling auto-walk
                teleporterManuallyDisabled = true
                AddNotification("Auto-walk DISABLED (L key)", "warning")
            end

            -- Reset path state when toggling
            tpCurrentPathIndex = nil
            tpCurrentPathWaypointIndex = 1
            tpUsingPredefinedPath = false
            tpPathSelected = false
            tpLOSDetectedTime = 0
            return  -- Skip auto-walk logic this frame to prevent immediate distance check
        end

        -- Auto-walk logic
        if teleporterConfig.autoWalkEnabled then
            if #foundTeleporters > 0 then
                local nearestTele = foundTeleporters[1]
                local currentDistance = GetDistanceTP(me:GetAbsOrigin(), nearestTele.pos)

                if currentDistance > 100 then  -- Reduced from 100 to 50 - disable when touching teleporter
                    WalkToTeleporterTP(cmd, me, nearestTele.pos)
                else
                    teleporterConfig.autoWalkEnabled = false
                    sniperUpgradeCompletedTime = 0  -- Reset to prevent delay check from re-enabling
                    gui.SetValue("mvm auto ready (f4)", 1)
                    AddNotification("Touched teleporter - Auto-walk OFF", "success")
                end
            end
        end
    end
end)

-- Draw callback
callbacks.Register("Draw", function()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then return end

    if not UI.mainFont then
        UI.mainFont = draw.CreateFont("Arial", 14, 700)
    end

    local screenWidth, screenHeight = draw.GetScreenSize()
    local startX = math.floor(screenWidth*0.01)
    local startY = 50

    for i = #UI.notifications, 1, -1 do
        local notif = UI.notifications[i]
        local age = globals.CurTime() - notif.time

        if notif.alpha < notif.targetAlpha then
            notif.alpha = math.min(notif.alpha + 15, notif.targetAlpha)
        end

        if age > UI.notificationLifetime then
            table.remove(UI.notifications, i)
        else
            local yOffset = startY + ((#UI.notifications - i) * (UI.notificationHeight + 5))

            -- Draw notification
            if notif.alpha > 1 and notif.color and notif.icon and notif.message then
                draw.SetFont(UI.mainFont)
                local iconWidth = draw.GetTextSize(notif.icon)
                local messageWidth = draw.GetTextSize(notif.message)
                local width = math.floor(iconWidth + messageWidth + 30)
                local height = UI.notificationHeight

                local progress = 1 - (age / UI.notificationLifetime)
                progress = math.max(0, math.min(1, progress))  -- Clamp progress between 0 and 1
                local alpha = clampColor(notif.alpha * progress)

                -- Background
                draw.Color(0, 0, 0, 178)
                draw.FilledRect(startX, yOffset, startX + width, yOffset + height)

                -- Icon
                draw.Color(clampColor(notif.color[1]), clampColor(notif.color[2]), clampColor(notif.color[3]), clampColor(alpha))
                draw.Text(math.floor(startX + 5), math.floor(yOffset + height / 2 - 7), notif.icon)

                -- Message
                draw.Color(clampColor(UI.colors.text[1]), clampColor(UI.colors.text[2]), clampColor(UI.colors.text[3]), clampColor(alpha))
                draw.Text(math.floor(startX + iconWidth + 15), math.floor(yOffset + height / 2 - 7), notif.message)

                -- Progress bar
                if progress > 0 then
                    local barAlpha = clampColor(alpha * 0.7)
                    draw.Color(clampColor(199), clampColor(170), clampColor(255), clampColor(barAlpha))
                    draw.FilledRect(
                        math.floor(startX + 1),
                        math.floor(yOffset + height - 2),
                        math.floor(startX + 1 + (width - 2) * progress),
                        math.floor(yOffset + height)
                    )
                end
            end
        end
    end

    -- ===== TELEPORTER SCANNER DISPLAY (after Sniper upgrades) =====
    if sniperUpgradeCompleted then
        -- Scan once on first execution
        if teleporterConfig.scanEnabled and not hasScannedTeleporter then
            hasScannedTeleporter = true
            ScanForTeleportersTP()
        end

        local paddingX, paddingY = 10, 5
        local tpX = math.floor(screenWidth * 0.02)
        local tpY = 100
        local lineH = 18
        local healthBarH = 4
        local healthBarSpacing = 6

        draw.SetFont(UI.mainFont)

        -- Build text content for measurement
        local headerText = "Teleporter ESP"
        local awLabel = "[L] Auto-Walk"
        local awStatus = teleporterConfig.autoWalkEnabled and " (Active)" or ""

        -- Measure max width across all content
        local maxW = 0
        maxW = math.max(maxW, draw.GetTextSize(headerText))
        maxW = math.max(maxW, draw.GetTextSize(awLabel .. awStatus))

        -- Pre-build teleporter entry strings and measure
        local teleTexts = {}
        local displayCount = math.min(#foundTeleporters, 2)
        if #foundTeleporters == 0 then
            maxW = math.max(maxW, draw.GetTextSize("No teleporter entrances found"))
        else
            for i = 1, displayCount do
                local tele = foundTeleporters[i]
                local teamStr = tele.isEnemy and "[ENEMY]" or "[TEAM]"
                local txt = string.format("%s %s - Lvl %d - %.0fm",
                    teamStr, tele.builderName, tele.level, tele.distance / 52.5)
                table.insert(teleTexts, txt)
                maxW = math.max(maxW, draw.GetTextSize(txt))
            end
            if #foundTeleporters > 2 then
                maxW = math.max(maxW, draw.GetTextSize("... and " .. (#foundTeleporters - 2) .. " more"))
            end
        end

        -- Calculate panel dimensions
        local panelW = maxW + paddingX * 2
        local panelH = 2 + paddingY + lineH + lineH + paddingY  -- accent + pad + header + autowalk + separator
        if #foundTeleporters == 0 then
            panelH = panelH + lineH
        else
            panelH = panelH + displayCount * (lineH + healthBarH + healthBarSpacing)
            if #foundTeleporters > 2 then
                panelH = panelH + lineH
            end
        end
        panelH = panelH + paddingY  -- bottom padding

        -- bg
        draw.Color(0, 0, 0, 178)
        draw.FilledRect(tpX, tpY, tpX + panelW, tpY + panelH)

        -- top bar
        draw.Color(clampColor(199), clampColor(170), clampColor(255), 255)
        draw.FilledRect(tpX, tpY, tpX + panelW, tpY + 2)

        -- content
        local cx = tpX + paddingX
        local cy = tpY + 2 + paddingY

        -- header text
        draw.Color(clampColor(UI.colors.text[1]), clampColor(UI.colors.text[2]), clampColor(UI.colors.text[3]), 255)
        draw.Text(cx, cy, headerText)
        cy = cy + lineH

        -- autowalk text (dim label + colored status)
        draw.Color(200, 200, 200, 255)
        draw.Text(cx, cy, awLabel)
        if teleporterConfig.autoWalkEnabled then
            local labelW = draw.GetTextSize(awLabel)
            draw.Color(clampColor(UI.colors.success[1]), clampColor(UI.colors.success[2]), clampColor(UI.colors.success[3]), 255)
            draw.Text(cx + labelW, cy, awStatus)
        end
        cy = cy + lineH + paddingY

        -- teleporter entries
        if #foundTeleporters == 0 then
            draw.Color(200, 200, 200, 255)
            draw.Text(cx, cy, "No teleporter entrances found")
        else
            local barW = panelW - paddingX * 2
            for i = 1, displayCount do
                local tele = foundTeleporters[i]
                local color = tele.isEnemy and UI.colors.enemy or UI.colors.friendly

                draw.Color(clampColor(color[1]), clampColor(color[2]), clampColor(color[3]), 200)
                draw.Text(cx, cy, teleTexts[i])
                cy = cy + lineH

                -- health bar
                local healthPercent = tele.health / tele.maxHealth
                draw.Color(clampColor(50), clampColor(50), clampColor(50), 255)
                draw.FilledRect(cx, cy, cx + barW, cy + healthBarH)
                draw.Color(clampColor(color[1]), clampColor(color[2]), clampColor(color[3]), 255)
                draw.FilledRect(cx, cy, cx + math.floor(barW * healthPercent), cy + healthBarH)
                cy = cy + healthBarH + healthBarSpacing

                if i >= 2 and #foundTeleporters > 2 then
                    draw.Color(clampColor(200), clampColor(200), clampColor(200), 255)
                    draw.Text(cx, cy, "... and " .. (#foundTeleporters - 2) .. " more")
                    break
                end
            end
        end
    end
end)

-- Instant Respawn
callbacks.Register("CreateMove", function(cmd)
    local currentTime = globals.CurTime()
    local me = entities.GetLocalPlayer()
    
    if me then
        local alive = me:IsAlive()
        
        if wasAlive and not alive then
            alreadyRequested = false
        end
        
        if not alive and not alreadyRequested then
            local kv = [["MVM_Revive_Response"{"accepted"    "1"}]]
            engine.SendKeyValues(kv)
            alreadyRequested = true
        end
        
        wasAlive = alive
    end
end)

-- Unload callback for cleanup
callbacks.Register("Unload", function()
    if isProcessing then ForceCleanup() end
    ResetState()
    AddNotification("Script unloaded - State cleaned up", "info")
end)
