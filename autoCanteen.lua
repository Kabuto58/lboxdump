-- Auto Canteen/Action Slot Script
-- Automatically uses action slot item when clip ammo drops below 5%

local config = {
    ammoThreshold = 0.05,  -- 5% ammo threshold
    cooldown = 1.0,        -- Cooldown between uses (seconds)
    enabled = true
}

local lastUseTime = 0

-- Track max clip per weapon for accurate percentage calculation
local maxClipTracker = {}

callbacks.Register("CreateMove", "AutoCanteen", function(cmd)
    if not config.enabled then return end

    local currentTime = globals.CurTime()

    -- Check cooldown
    if currentTime - lastUseTime < config.cooldown then return end

    local me = entities.GetLocalPlayer()
    if not me or not me:IsAlive() then return end

    -- Get active weapon
    local weapon = me:GetPropEntity("m_hActiveWeapon")
    if not weapon then return end

    -- Get weapon ID for tracking
    local weaponID = weapon:GetPropInt("m_iItemDefinitionIndex") or 0

    -- Get clip ammo
    local clip = weapon:GetPropInt("m_iClip1")
    if not clip or clip < 0 then return end  -- No clip (melee, etc.)

    -- Track max clip seen for this weapon
    if not maxClipTracker[weaponID] or clip > maxClipTracker[weaponID] then
        maxClipTracker[weaponID] = clip
    end

    local maxClip = maxClipTracker[weaponID]
    if not maxClip or maxClip <= 0 then return end

    -- Calculate percentage
    local ammoPercent = clip / maxClip

    -- Check if below threshold
    if ammoPercent <= config.ammoThreshold then
        client.Command("+use_action_slot_item", true)
        lastUseTime = currentTime
        print(string.format("[AutoCanteen] Ammo at %.1f%% - Using action slot item!", ammoPercent * 100))

        -- Release the button after a short delay (next frame)
        callbacks.Register("CreateMove", "AutoCanteenRelease", function()
            client.Command("-use_action_slot_item", true)
            callbacks.Unregister("CreateMove", "AutoCanteenRelease")
        end)
    end
end)

print("[AutoCanteen] Loaded - Will use action slot item when ammo drops below 5%")
