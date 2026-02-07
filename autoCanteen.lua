
local config = {
    ammoThreshold = 0.1,  -- 10% ammo threshold
    cooldown = 3.0,        -- Cooldown between uses (seconds)
    enabled = true
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
        textDim = {150, 150, 150}
    },
    icons = {success = "#", warning = "!", error = "X", info = "i"}
}

local lastUseTime = 0
local maxAmmoTracker = {}
local canteenHoldFrames = 0  -- Frames remaining to hold the action slot button
local CANTEEN_HOLD_DURATION = 10  -- Hold for 10 ticks (~150ms)

local function clampColor(val)
    if not val or val ~= val then return 255 end
    return math.max(0, math.min(255, math.floor(val)))
end

local function AddNotification(message, nType)
    nType = nType or "info"
    table.insert(UI.notifications, 1, {
        message = message,
        icon = UI.icons[nType],
        color = UI.colors[nType],
        time = globals.CurTime(),
        alpha = 0,
        targetAlpha = 255
    })
    if #UI.notifications > UI.maxNotifications then
        table.remove(UI.notifications)
    end
end

local function DrawNotification(notif, x, y)
    if notif.alpha <= 1 then return end
    if not notif.color or not notif.icon or not notif.message then return end

    draw.SetFont(UI.mainFont)
    local iconWidth, _ = draw.GetTextSize(notif.icon)
    local messageWidth, _ = draw.GetTextSize(notif.message)
    local width = math.floor(iconWidth + messageWidth + 30)
    local height = math.floor(UI.notificationHeight)

    local progress = 1 - ((globals.CurTime() - notif.time) / UI.notificationLifetime)
    progress = math.max(0, math.min(1, progress))  -- Clamp progress between 0 and 1
    local alpha = math.floor(notif.alpha * progress)
    if alpha ~= alpha or alpha < 0 then alpha = 0 end
    if alpha > 255 then alpha = 255 end

    -- Background
    draw.Color(0, 0, 0, 178)
    draw.FilledRect(x, y, x + width, y + height)

    -- Icon with color
    draw.Color(clampColor(notif.color[1]), clampColor(notif.color[2]), clampColor(notif.color[3]), clampColor(alpha))
    draw.Text(math.floor(x + 5), math.floor(y + height / 2 - 7), notif.icon)

    -- Message text
    draw.Color(clampColor(UI.colors.text[1]), clampColor(UI.colors.text[2]), clampColor(UI.colors.text[3]), clampColor(alpha))
    draw.Text(math.floor(x + iconWidth + 15), math.floor(y + height / 2 - 7), notif.message)

    -- Progress bar
    if progress > 0 then
        local barAlpha = math.floor(alpha * 0.7)
        if barAlpha < 0 then barAlpha = 0 end
        if barAlpha > 255 then barAlpha = 255 end

        draw.Color(199, 170, 255, clampColor(barAlpha))
        draw.FilledRect(
            math.floor(x + 1),
            math.floor(y + height - 2),
            math.floor(x + 1 + (width - 2) * progress),
            math.floor(y + height)
        )
    end
end

-- Debug mode for testing ammo access methods
local debugAmmo = false
local lastDebugTime = 0

-- Get reserve ammo from player's m_iAmmo data table
local function getReserveAmmo(player, ammoTypeIndex)
    -- Get the m_iAmmo data table from localdata
    local ok, ammoTable = pcall(function() return player:GetPropDataTableInt("localdata", "m_iAmmo") end)

    if ok and ammoTable and type(ammoTable) == "table" then
        -- Try the exact ammo type index first (but only if > 0)
        if ammoTypeIndex and ammoTable[ammoTypeIndex] and ammoTable[ammoTypeIndex] > 0 then
            return ammoTable[ammoTypeIndex]
        end

        -- Fallback: Try nearby indices
        for _, idx in ipairs({ammoTypeIndex + 1, ammoTypeIndex - 1, 1, 2, 3, 0}) do
            if ammoTable[idx] ~= nil and ammoTable[idx] >= 0 then
                return ammoTable[idx]
            end
        end

        -- Last resort: return the exact index even if 0
        if ammoTypeIndex and ammoTable[ammoTypeIndex] ~= nil then
            return ammoTable[ammoTypeIndex]
        end
    end

    return -1
end

callbacks.Register("CreateMove", "AutoCanteen", function(cmd)
    if not config.enabled then return end

    -- If we're holding the canteen button, execute the action slot command
    if canteenHoldFrames > 0 then
        client.Command("+use_action_slot_item", true)
        canteenHoldFrames = canteenHoldFrames - 1
        if canteenHoldFrames == 0 then
            client.Command("-use_action_slot_item", true)
        end
        return
    end

    local currentTime = globals.CurTime()
    if currentTime - lastUseTime < config.cooldown then return end

    local me = entities.GetLocalPlayer()
    if not me or not me:IsAlive() then return end

    local weapon = me:GetPropEntity("m_hActiveWeapon")
    if not weapon then return end

    local weaponID = weapon:GetPropInt("m_iItemDefinitionIndex") or 0
    local clip = weapon:GetPropInt("m_iClip1")
    local ammoTypeIndex = weapon:GetPropInt("m_iPrimaryAmmoType")
    local className = weapon:GetClass() or ""
    local weaponName = className:gsub("^CTF", ""):gsub("^CWeapon", "")

    -- Hardcoded check for SniperRifle
    local currentAmmo = -1
    local isSniperRifle = weaponName == "SniperRifle"

    if isSniperRifle then
        -- Directly get m_iAmmo[2] for sniper rifle
        local ok, ammoTable = pcall(function() return me:GetPropDataTableInt("localdata", "m_iAmmo") end)
        if ok and ammoTable and type(ammoTable) == "table" and ammoTable[2] then
            currentAmmo = ammoTable[2]
        end
    else
        -- Determine current ammo: clip for clip-based weapons, reserve for non-clip
        if clip and clip >= 0 then
            currentAmmo = clip
        else
            currentAmmo = getReserveAmmo(me, ammoTypeIndex)
        end
    end

    if currentAmmo < 0 then return end

    -- Track max ammo seen per weapon for percentage calculation
    if not maxAmmoTracker[weaponID] or currentAmmo > maxAmmoTracker[weaponID] then
        maxAmmoTracker[weaponID] = currentAmmo
    end

    -- Sniper rifle uses fixed threshold of 3, others use percentage
    local shouldUseCanteen = false
    if isSniperRifle then
        shouldUseCanteen = currentAmmo <= 3
    else
        local maxAmmo = maxAmmoTracker[weaponID]
        if maxAmmo and maxAmmo > 0 then
            local ammoPercent = currentAmmo / maxAmmo
            shouldUseCanteen = ammoPercent <= config.ammoThreshold
        end
    end

    if shouldUseCanteen then
        -- Use action slot command to activate canteen
        client.Command("+use_action_slot_item", true)
        canteenHoldFrames = CANTEEN_HOLD_DURATION
        lastUseTime = currentTime
        AddNotification(string.format("Ammo at %d - Using canteen!", currentAmmo), "warning")
    end
end)

-- Draw callback for notifications and status panel
callbacks.Register("Draw", "AutoCanteenDraw", function()
    if engine.Con_IsVisible() or engine.IsGameUIVisible() then return end

    if not UI.mainFont then
        UI.mainFont = draw.CreateFont("Arial", 14, 700)
    end

    local screenWidth, screenHeight = draw.GetScreenSize()

    -- Draw notifications
    local startX = math.floor(screenWidth * 0.01)
    local startY = 250

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
            DrawNotification(notif, startX, yOffset)
        end
    end

    -- Status panel (centre-right)
    local me = entities.GetLocalPlayer()
    if not me or not me:IsAlive() then return end

    draw.SetFont(UI.mainFont)
    local paddingX, paddingY = 10, 5
    local lineH = 18

    -- Gather weapon data
    local weapon = me:GetPropEntity("m_hActiveWeapon")
    local weaponName = "None"
    local ammoText = "N/A"
    local ammoColor = UI.colors.textDim

    if weapon then
        local className = weapon:GetClass() or "Unknown"
        weaponName = className:gsub("^CTF", ""):gsub("^CWeapon", "")

        local weaponID = weapon:GetPropInt("m_iItemDefinitionIndex") or 0
        local clip = weapon:GetPropInt("m_iClip1")
        local ammoTypeIndex = weapon:GetPropInt("m_iPrimaryAmmoType")
        local isSniperRifle = weaponName == "SniperRifle"

        -- Hardcoded check for SniperRifle
        local currentAmmo = -1
        if isSniperRifle then
            -- Directly get m_iAmmo[2] for sniper rifle
            local ok, ammoTable = pcall(function() return me:GetPropDataTableInt("localdata", "m_iAmmo") end)
            if ok and ammoTable and type(ammoTable) == "table" and ammoTable[2] then
                currentAmmo = ammoTable[2]
            end
        else
            if clip and clip >= 0 then
                currentAmmo = clip
            else
                currentAmmo = getReserveAmmo(me, ammoTypeIndex)
            end
        end

        if currentAmmo >= 0 then
            local maxAmmo = maxAmmoTracker[weaponID]
            if maxAmmo and maxAmmo > 0 then
                if isSniperRifle then
                    -- Sniper rifle uses fixed threshold
                    ammoText = string.format("%d/%d", currentAmmo, maxAmmo)
                    if currentAmmo <= 3 then
                        ammoColor = UI.colors.error
                    elseif currentAmmo <= 8 then
                        ammoColor = UI.colors.warning
                    else
                        ammoColor = UI.colors.success
                    end
                else
                    -- Other weapons use percentage
                    local pct = currentAmmo / maxAmmo
                    ammoText = string.format("%d/%d (%.0f%%)", currentAmmo, maxAmmo, pct * 100)
                    if pct <= config.ammoThreshold then
                        ammoColor = UI.colors.error
                    elseif pct <= 0.35 then
                        ammoColor = UI.colors.warning
                    else
                        ammoColor = UI.colors.success
                    end
                end
            else
                ammoText = tostring(currentAmmo)
                ammoColor = UI.colors.text
            end
        end
    end

    -- Gather canteen data
    local canteenText = "None"
    local canteenColor = UI.colors.textDim
    local ok, canteen = pcall(function() return me:GetEntityForLoadoutSlot(LOADOUT_POSITION_ACTION) end)
    if ok and canteen then
        local charges = canteen:GetPropInt("m_iClip1")
        if charges and charges >= 0 then
            canteenText = tostring(charges) .. " charges"
            if charges == 0 then
                canteenColor = UI.colors.error
            elseif charges <= 1 then
                canteenColor = UI.colors.warning
            else
                canteenColor = UI.colors.success
            end
        else
            canteenText = "Equipped"
            canteenColor = UI.colors.info
        end
    end

    -- Build text for measurement
    local headerText = "AutoCanteen"
    local weaponLabel, ammoLabel, canteenLabel = "Weapon: ", "Ammo: ", "Canteen: "

    local headerW = draw.GetTextSize(headerText)
    local wlW = draw.GetTextSize(weaponLabel)
    local wnW = draw.GetTextSize(weaponName)
    local alW = draw.GetTextSize(ammoLabel)
    local atW = draw.GetTextSize(ammoText)
    local clW = draw.GetTextSize(canteenLabel)
    local ctW = draw.GetTextSize(canteenText)
    local _, textH = draw.GetTextSize(headerText)

    local maxW = math.max(headerW, wlW + wnW, alW + atW, clW + ctW)
    local panelW = maxW + paddingX * 2
    local panelH = 2 + paddingY + lineH * 4 + paddingY * 3 + paddingY

    -- Position: right side, vertically centred
    local panelX = screenWidth - panelW - math.floor(screenWidth * 0.01)
    local panelY = math.floor((screenHeight - panelH) / 2)

    -- Background
    draw.Color(0, 0, 0, 178)
    draw.FilledRect(panelX, panelY, panelX + panelW, panelY + panelH)

    -- Accent bar
    draw.Color(199, 170, 255, 255)
    draw.FilledRect(panelX, panelY, panelX + panelW, panelY + 2)

    local cx = panelX + paddingX
    local cy = panelY + 2 + paddingY

    -- Header
    draw.Color(UI.colors.text[1], UI.colors.text[2], UI.colors.text[3], 255)
    draw.Text(cx, cy, headerText)
    cy = cy + lineH + paddingY

    -- Weapon line
    draw.Color(UI.colors.textDim[1], UI.colors.textDim[2], UI.colors.textDim[3], 255)
    draw.Text(cx, cy, weaponLabel)
    draw.Color(UI.colors.text[1], UI.colors.text[2], UI.colors.text[3], 255)
    draw.Text(cx + wlW, cy, weaponName)
    cy = cy + lineH + paddingY

    -- Ammo line
    draw.Color(UI.colors.textDim[1], UI.colors.textDim[2], UI.colors.textDim[3], 255)
    draw.Text(cx, cy, ammoLabel)
    draw.Color(ammoColor[1], ammoColor[2], ammoColor[3], 255)
    draw.Text(cx + alW, cy, ammoText)
    cy = cy + lineH + paddingY

    -- Canteen line
    draw.Color(UI.colors.textDim[1], UI.colors.textDim[2], UI.colors.textDim[3], 255)
    draw.Text(cx, cy, canteenLabel)
    draw.Color(canteenColor[1], canteenColor[2], canteenColor[3], 255)
    draw.Text(cx + clW, cy, canteenText)
end)

callbacks.Register("Unload", "AutoCanteenUnload", function()
    maxAmmoTracker = {}
    AddNotification("AutoCanteen unloaded", "info")
end)

AddNotification("AutoCanteen loaded - Action slot at <10% ammo", "success")
