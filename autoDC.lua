
local timers = {
    ["mvm_mannhattan_advanced2"] = 250,  -- Metro Malice
    ["mvm_mannhattan_advanced1"] = 240,  -- Empire Escalation
    ["mvm_rottenburg_advanced1"] = 60,   -- Hamlet Hostility
    ["mvm_rottenburg_advanced2"] = 130   -- Bavarian Botbash
}

-- UI Configuration
local UI = {
    notifications = {},
    maxNotifications = 3,
    notificationHeight = 20,
    notificationLifetime = 10,
    mainFont = nil,
    colors = {
        success = {100, 255, 100},
        warning = {255, 200, 50},
        error = {255, 80, 80},
        info = {100, 180, 255},
        accent = {199, 170, 255},
        text = {255, 255, 255},
        textDim = {150, 150, 150}
    }
}

-- Script state variables
local timerStarted = false
local timerStartTime = 0
local timerDuration = 0
local lastWaveChecked = -1
local popfileName = ""
local hasAbandonedMatch = false
local currentServer = nil

-- Notification System
local function CreateNotification(message, type)
    local colors = {
        success = UI.colors.success,
        warning = UI.colors.warning,
        error = UI.colors.error,
        info = UI.colors.info
    }

    local icons = {
        success = "#",
        warning = "!",
        error = "X",
        info = "i"
    }

    return {
        message = message,
        icon = icons[type] or icons.info,
        color = colors[type] or colors.info,
        time = globals.CurTime(),
        alpha = 0,
        targetAlpha = 255
    }
end

local function AddNotification(message, type)
    table.insert(UI.notifications, 1, CreateNotification(message, type))
    if #UI.notifications > UI.maxNotifications then
        table.remove(UI.notifications)
    end
end

local function DrawRect(x, y, w, h, color)
    -- Validate and clamp color values to 0-255 range
    local function clampColor(val)
        if not val or val ~= val then return 255 end  -- nil or NaN check
        return math.max(0, math.min(255, math.floor(val)))
    end

    local r = clampColor(color[1])
    local g = clampColor(color[2])
    local b = clampColor(color[3])
    local a = clampColor(color[4])

    draw.Color(r, g, b, a)
    draw.FilledRect(
        math.floor(x),
        math.floor(y),
        math.floor(x + w),
        math.floor(y + h)
    )
end

local function DrawNotification(notif, x, y)
    if notif.alpha <= 1 then return end

    -- Validate notification has required fields
    if not notif.color or not notif.icon or not notif.message then return end

    draw.SetFont(UI.mainFont)
    local iconWidth, _ = draw.GetTextSize(notif.icon)
    local messageWidth, _ = draw.GetTextSize(notif.message)
    local width = math.floor(iconWidth + messageWidth + 30)
    local height = math.floor(UI.notificationHeight)

    local progress = 1 - ((globals.CurTime() - notif.time) / UI.notificationLifetime)
    progress = math.max(0, math.min(1, progress))  -- Clamp progress between 0 and 1
    local alpha = math.floor(notif.alpha * progress)

    -- Clamp alpha to valid range and check for NaN
    if alpha ~= alpha or alpha < 0 then alpha = 0 end
    if alpha > 255 then alpha = 255 end

    -- Helper function to clamp color values
    local function clampColor(val)
        if not val or val ~= val then return 255 end  -- nil or NaN check
        return math.max(0, math.min(255, math.floor(val)))
    end

    -- Draw background
    draw.Color(0, 0, 0, 178)
    draw.FilledRect(x, y, x + width, y + height)

    -- Draw icon with color validation
    local iconR = clampColor(notif.color[1])
    local iconG = clampColor(notif.color[2])
    local iconB = clampColor(notif.color[3])
    draw.Color(iconR, iconG, iconB, alpha)
    draw.Text(math.floor(x + 5), math.floor(y + height / 2 - 7), notif.icon)

    -- Draw message text
    local textR = clampColor(UI.colors.text[1])
    local textG = clampColor(UI.colors.text[2])
    local textB = clampColor(UI.colors.text[3])
    draw.Color(textR, textG, textB, alpha)
    draw.Text(math.floor(x + iconWidth + 15), math.floor(y + height / 2 - 7), notif.message)

    -- Draw progress bar
    if progress > 0 then
        local barAlpha = math.floor(alpha * 0.7)
        if barAlpha < 0 then barAlpha = 0 end
        if barAlpha > 255 then barAlpha = 255 end

        DrawRect(
            math.floor(x + 1),
            math.floor(y + height - 2),
            math.floor((width - 2) * progress),
            2,
            {199, 170, 255, barAlpha}
        )
    end
end

-- Debug flag to track if we've notified about MvM entry
local hasNotifiedMvMEntry = false
local objectiveResourceCache = nil
local lastEntitySearchFrame = 0

-- Function to find the CTFObjectiveResource entity
local function FindObjectiveResource()
    -- Cache the entity and only search every 66 ticks (1 second)
    local currentFrame = globals.FrameCount()
    if objectiveResourceCache and (currentFrame - lastEntitySearchFrame) < 66 then
        return objectiveResourceCache
    end

    lastEntitySearchFrame = currentFrame

    -- Get player resource entity which should exist
    local playerResource = entities.GetPlayerResources()
    if not playerResource then
        return nil
    end

    -- Search for CTFObjectiveResource starting from a known entity index
    -- CTFObjectiveResource is usually at a low entity index
    for i = 0, 64 do
        local ent = entities.GetByIndex(i)
        if ent then
            local className = ent:GetClass()
            if className == "CTFObjectiveResource" then
                objectiveResourceCache = ent
                return ent
            end
        end
    end

    return nil
end

-- Function to check if we're in MvM and get mission info
local function checkMvMStatus()
    -- Check if we're in MvM gamemode
    if not gamerules.IsMvM() then
        hasNotifiedMvMEntry = false
        objectiveResourceCache = nil
        return false
    end

    -- Notify user once when MvM is detected
    if not hasNotifiedMvMEntry then
        AddNotification("MvM Mode Detected!", "info")
        hasNotifiedMvMEntry = true
    end

    -- Find the CTFObjectiveResource entity
    local objectiveResource = FindObjectiveResource()
    if not objectiveResource then
        -- Only show error occasionally to avoid spam
            AddNotification("Searching for objective resource...", "warning")
        return false
    end

    -- Get the popfile name
    local currentPopfile = objectiveResource:GetPropString("m_iszMvMPopfileName")
    if not currentPopfile or currentPopfile == "" then
        return false
    end

    -- Store popfile name if it changed
    if popfileName ~= currentPopfile then
        popfileName = currentPopfile
        AddNotification("Detected popfile: " .. popfileName, "info")

        -- Match mission using pattern matching
        local foundMatch = false
        for missionKey, duration in pairs(timers) do
            if string.find(popfileName, missionKey, 1, true) then
                timerDuration = duration
                local minutes = math.floor(timerDuration / 60)
                local seconds = timerDuration % 60
                AddNotification(string.format("Timer: %dm %ds", minutes, seconds), "success")
                foundMatch = true
                break
            end
        end

        if not foundMatch then
            AddNotification("WARNING: No timer for this mission!", "warning")
            timerDuration = 60  -- Default to 60 seconds
        end
    end

    -- Get current wave and max waves
    local currentWave = objectiveResource:GetPropInt("m_nMannVsMachineWaveCount")
    local maxWaves = objectiveResource:GetPropInt("m_nMannVsMachineMaxWaveCount")

    -- Check if we're on the last wave
    if currentWave >= maxWaves and currentWave > 0 then
        return true, currentWave, maxWaves
    end

    return false, currentWave, maxWaves
end

-- Function to reset all state variables
local function ResetState()
    timerStarted = false
    timerStartTime = 0
    timerDuration = 0
    lastWaveChecked = -1
    popfileName = ""
    hasAbandonedMatch = false
    hasNotifiedMvMEntry = false
    objectiveResourceCache = nil
end

-- Function to check for server changes
local function CheckServerChange()
    local netChannel = clientstate.GetNetChannel()
    local serverIP = netChannel and netChannel:GetAddress() or nil
    local signonState = clientstate.GetClientSignonState()

    -- Check if server changed or disconnected
    if serverIP ~= currentServer then
        local oldServer = currentServer
        currentServer = serverIP

        ResetState()

        -- Only show notification if we're fully connected to a new server
        if oldServer and serverIP and signonState == E_SignonState.SIGNONSTATE_FULL then
            AddNotification("Connected to new server - State reset", "info")
        end
    end
end

-- Function to start the timer
local function startTimer()
    if not timerStarted and timerDuration > 0 then
        timerStarted = true
        timerStartTime = globals.RealTime()
        local minutes = math.floor(timerDuration / 60)
        local seconds = timerDuration % 60
        AddNotification(string.format("Timer Started: %dm %ds", minutes, seconds), "warning")
    end
end

-- Function to check timer and abandon if needed
local function checkTimer()
    if not timerStarted then
        return
    end

    local currentTime = globals.RealTime()
    local elapsedTime = currentTime - timerStartTime

    -- Check if timer has expired
    if elapsedTime >= timerDuration and not hasAbandonedMatch then
        AddNotification("Timer Expired - Abandoning Match!", "error")
        gamecoordinator.AbandonMatch()
        hasAbandonedMatch = true
        timerStarted = false
    end
end

-- Main callback function - called every frame
local function onFrameStageNotify(stage)
    -- Only run during network updates for efficiency
    if stage ~= E_ClientFrameStage.FRAME_NET_UPDATE_END then
        return
    end

    -- Check for server changes and reset state if needed
    CheckServerChange()

    -- Check MvM status
    local isLastWave, currentWave, maxWaves = checkMvMStatus()

    -- If not in MvM, reset everything
    if not gamerules.IsMvM() then
        if timerStarted or popfileName ~= "" then
            -- Reset state when leaving MvM
            ResetState()
            AddNotification("Left MvM Mode", "info")
        end
        return
    end

    -- If we're on the last wave, start the timer
    if isLastWave and not timerStarted and not hasAbandonedMatch then
        if lastWaveChecked ~= currentWave then
            lastWaveChecked = currentWave
            AddNotification(string.format("Final Wave! (%d/%d)", currentWave, maxWaves), "warning")
            startTimer()
        end
    end

    -- Check if timer should trigger abandon
    checkTimer()
end

-- Draw callback for visual feedback
local function onDraw()
    -- Skip if console or game UI is visible
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then
        return
    end

    -- Initialize font if needed
    if not UI.mainFont then
        UI.mainFont = draw.CreateFont("Arial", 14, 700)
    end

    -- Get screen dimensions
    local screenWidth, screenHeight = draw.GetScreenSize()
    local startX = math.floor(screenWidth*0.01)
    local startY = math.floor(screenHeight*0.4)

    -- Update and draw notifications
    for i = #UI.notifications, 1, -1 do
        local notif = UI.notifications[i]
        local age = globals.CurTime() - notif.time

        -- Fade in animation
        if notif.alpha < notif.targetAlpha then
            notif.alpha = math.min(notif.alpha + 15, notif.targetAlpha)
        end

        -- Remove expired notifications
        if age > UI.notificationLifetime then
            table.remove(UI.notifications, i)
        else
            local yOffset = startY + ((#UI.notifications - i) * (UI.notificationHeight + 5))
            DrawNotification(notif, startX, yOffset)
        end
    end

    -- Only draw timer display if in MvM and timer is active
    if not gamerules.IsMvM() or not timerStarted then
        return
    end

    -- Calculate remaining time
    local currentTime = globals.RealTime()
    local elapsedTime = currentTime - timerStartTime
    local remainingTime = timerDuration - elapsedTime

    if remainingTime < 0 then
        remainingTime = 0
    end

    -- Timer panel UI
    local paddingX, paddingY = 10, 5
    draw.SetFont(UI.mainFont)

    local minutes = math.floor(remainingTime / 60)
    local seconds = math.floor(remainingTime % 60)

    local timerLabel = "Timer: "
    local timerValue = string.format("%02d:%02d", minutes, seconds)
    local missionLabel = "Mission: "
    local missionValue = popfileName

    local timerLabelW, textHeight = draw.GetTextSize(timerLabel)
    local timerValueW, _ = draw.GetTextSize(timerValue)
    local missionLabelW, _ = draw.GetTextSize(missionLabel)
    local missionValueW, _ = draw.GetTextSize(missionValue)

    local line1Width = timerLabelW + timerValueW
    local line2Width = missionLabelW + missionValueW
    local maxWidth = math.max(line1Width, line2Width)

    local panelWidth = maxWidth + (paddingX * 2)
    local panelHeight = (textHeight * 2) + (paddingY * 3)

    local panelX = math.floor(screenWidth * 0.01)
    local panelY = math.floor(screenHeight * 0.8)

    -- Background
    draw.Color(0, 0, 0, 178)
    draw.FilledRect(panelX, panelY, panelX + panelWidth, panelY + panelHeight)

    -- Accent bar
    draw.Color(199, 170, 255, 255)
    draw.FilledRect(panelX, panelY, panelX + panelWidth, panelY + 2)

    -- Timer label (dim)
    local textY1 = panelY + paddingY + 2
    draw.Color(UI.colors.textDim[1], UI.colors.textDim[2], UI.colors.textDim[3], 255)
    draw.Text(panelX + paddingX, textY1, timerLabel)

    -- Timer value (color based on urgency)
    if remainingTime <= 30 then
        draw.Color(UI.colors.error[1], UI.colors.error[2], UI.colors.error[3], 255)
    else
        draw.Color(UI.colors.warning[1], UI.colors.warning[2], UI.colors.warning[3], 255)
    end
    draw.Text(panelX + paddingX + timerLabelW, textY1, timerValue)

    -- Mission label (dim)
    local textY2 = textY1 + textHeight + paddingY
    draw.Color(UI.colors.textDim[1], UI.colors.textDim[2], UI.colors.textDim[3], 255)
    draw.Text(panelX + paddingX, textY2, missionLabel)

    -- Mission value (white)
    draw.Color(UI.colors.text[1], UI.colors.text[2], UI.colors.text[3], 255)
    draw.Text(panelX + paddingX + missionLabelW, textY2, missionValue)
end

-- MvM wave user message handler
callbacks.Register("DispatchUserMessage", "mvmAutoAbandon_UserMsg", function(msg)
    local msgID = msg:GetID()

    if msgID == MVMWaveChange then
        local objectiveResource = FindObjectiveResource()
        if objectiveResource then
            local currentWave = objectiveResource:GetPropInt("m_nMannVsMachineWaveCount")
            local maxWaves = objectiveResource:GetPropInt("m_nMannVsMachineMaxWaveCount")
            AddNotification(string.format("Wave Changed: %d/%d", currentWave, maxWaves), "info")
        end
    elseif msgID == MVMWaveFailed then
        AddNotification("Wave Failed!", "error")
    end
end)

-- Register callbacks
callbacks.Register("FrameStageNotify", "mvmAutoAbandon_FSN", onFrameStageNotify)
callbacks.Register("Draw", "mvmAutoAbandon_Draw", onDraw)

-- Cleanup on unload
callbacks.Register("Unload", "mvmAutoAbandon_Unload", function()
    AddNotification("MvM Auto-Abandon: Unloaded", "info")
end)

-- Notify script loaded successfully
AddNotification("MvM Auto-Abandon: Script Loaded", "success")
