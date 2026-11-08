--[[
    BHopDash Enhanced v8.0 for Far Far West
    UE4SS 3.0.x Lua Mod

    Features:
    - Auto-BHop: Hold SpaceBar to automatically jump immediately upon touching the ground.
    - Auto-Dash: Hold LeftShift (or configured key) to automatically dash on landing.
    - Auto-Jump After Dash: Immediately jumps after a landing dash, launching you with full dash momentum into a continuous bunnyhop dash loop.
    - Reset Dash Cooldown: Keeps dash always available during bhopping.
    - Dual landing detection: Event-based (OnLanded & K2_OnMovementModeChanged) + 10ms high-frequency polling backup.
    - Robust local player acquisition via UEHelpers and PlayerController.AcknowledgedPawn.
    - Auto-recovers on player respawn, death, or level change (ClientRestart hook).
--]]

local UEHelpers = require("UEHelpers")

-- Configuration Defaults
local config = {
    ENABLED = true,
    DASH_KEY = "LeftShift",
    BHOP_KEY = "SpaceBar",
    AUTO_BHOP_ENABLED = true,
    AUTO_DASH_ENABLED = true,
    AUTO_JUMP_AFTER_DASH = true,
    RESET_DASH_COOLDOWN = true,
    POLL_MS = 10,
    AUTO_JUMP_DELAY_MS = 15,
    DEBUG = false
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"

-- Runtime state
local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasGrounded = false
local hadGroundState = false
local gameTickQueued = false
local lastDebugTime = 0
local pendingJumpAfterDash = false
local jumpQueuedTime = 0

-- Logging helpers
local function log(msg)
    print("[BHopDash] " .. tostring(msg))
end

local function debugLog(msg)
    if config.DEBUG then
        log("[DEBUG] " .. tostring(msg))
    end
end

-- String trim helper
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse boolean values
local function parseBool(val)
    if not val then return false end
    val = trim(val):lower()
    return val == "true" or val == "1" or val == "yes" or val == "on"
end

-- Load configuration from config.txt
local function loadConfig()
    local file = io.open(CONFIG_FILENAME, "r")
    if not file then
        log("config.txt not found, using default settings.")
        return
    end

    for line in file:lines() do
        line = trim(line)
        if line ~= "" and not line:match("^#") and not line:match("^;") then
            local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
            if key and value then
                key = trim(key):upper()
                value = trim(value)
                if key == "ENABLED" then
                    config.ENABLED = parseBool(value)
                elseif key == "DASH_KEY" and value ~= "" then
                    config.DASH_KEY = value
                elseif key == "BHOP_KEY" and value ~= "" then
                    config.BHOP_KEY = value
                elseif key == "AUTO_BHOP_ENABLED" then
                    config.AUTO_BHOP_ENABLED = parseBool(value)
                elseif key == "AUTO_DASH_ENABLED" then
                    config.AUTO_DASH_ENABLED = parseBool(value)
                elseif key == "AUTO_JUMP_AFTER_DASH" then
                    config.AUTO_JUMP_AFTER_DASH = parseBool(value)
                elseif key == "RESET_DASH_COOLDOWN" then
                    config.RESET_DASH_COOLDOWN = parseBool(value)
                elseif key == "POLL_MS" then
                    local n = tonumber(value)
                    if n and n > 0 then config.POLL_MS = n end
                elseif key == "AUTO_JUMP_DELAY_MS" then
                    local n = tonumber(value)
                    if n and n >= 0 then config.AUTO_JUMP_DELAY_MS = n end
                elseif key == "DEBUG" then
                    config.DEBUG = parseBool(value)
                end
            end
        end
    end
    file:close()
    debugLog("Configuration loaded successfully")
end

-- Validate UE Object
local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- Invalidate caches
local function invalidatePlayer()
    cachedPC = nil
    cachedPawn = nil
    cachedCM = nil
    wasGrounded = false
    hadGroundState = false
    pendingJumpAfterDash = false
    debugLog("Player cache cleared")
end

-- Acquire Player Controller and Pawn
local function acquirePlayer()
    if isValid(cachedPawn) and isValid(cachedPC) and isValid(cachedCM) then
        return true
    end

    local pc = UEHelpers.GetPlayerController()
    if not isValid(pc) then
        return false
    end

    local pawn = nil
    pcall(function()
        if pc.AcknowledgedPawn and pc.AcknowledgedPawn:IsValid() then
            pawn = pc.AcknowledgedPawn
        elseif pc.Pawn and pc.Pawn:IsValid() then
            pawn = pc.Pawn
        end
    end)

    if not isValid(pawn) then
        local okFind, foundPawn = pcall(function()
            return FindFirstOf("BP_Player_C")
        end)
        if okFind and isValid(foundPawn) then
            local okLoc, isLoc = pcall(function() return foundPawn:IsLocallyControlled() end)
            if okLoc and isLoc then
                pawn = foundPawn
            end
        end
    end

    if not isValid(pawn) then
        return false
    end

    local cm = nil
    pcall(function()
        cm = pawn.CharacterMovement
    end)

    if not isValid(cm) then
        return false
    end

    cachedPC = pc
    cachedPawn = pawn
    cachedCM = cm
    wasGrounded = false
    hadGroundState = false

    debugLog("Acquired local PlayerController, Pawn and CharacterMovement")
    return true
end

-- Key state check helper
local function isKeyHeld(pc, keyName)
    if not isValid(pc) or not keyName or keyName == "" then return false end

    -- Helper to test single FKey name
    local function testKey(name)
        local ok, held = pcall(function()
            return pc:IsInputKeyDown({ KeyName = FName(name) })
        end)
        return ok and held == true
    end

    if testKey(keyName) then return true end

    -- Normalize common aliases
    local lower = keyName:lower()
    if lower == "space" or lower == "spacebar" then
        if testKey("SpaceBar") or testKey("Space") then return true end
    elseif lower == "shift" or lower == "leftshift" then
        if testKey("LeftShift") or testKey("RightShift") then return true end
    elseif lower == "ctrl" or lower == "control" or lower == "leftcontrol" then
        if testKey("LeftControl") or testKey("RightControl") then return true end
    elseif lower == "alt" or lower == "leftalt" then
        if testKey("LeftAlt") or testKey("RightAlt") then return true end
    elseif lower == "mouse4" or lower == "thumbmousebutton" then
        if testKey("ThumbMouseButton") then return true end
    elseif lower == "mouse5" or lower == "thumbmousebutton2" then
        if testKey("ThumbMouseButton2") then return true end
    end

    return false
end

-- Execute jump on character
local function executeJump()
    if not isValid(cachedPawn) then return false end

    local ok, err = pcall(function()
        cachedPawn:StopJumping()
        cachedPawn:Jump()
    end)

    if ok then
        debugLog("Jump executed!")
        return true
    else
        debugLog("Jump error: " .. tostring(err))
        return false
    end
end

-- Execute dash on character
local function executeDash()
    if not isValid(cachedPawn) then return false end

    if config.RESET_DASH_COOLDOWN then
        pcall(function()
            cachedPawn.isDashOnCooldown = false
            if cachedPawn.maxDash and cachedPawn.maxDash > 0 then
                cachedPawn.currentDashLeft = cachedPawn.maxDash
            end
            cachedPawn.dashCooldown = 0.0
            cachedPawn.dashedTimes = 0
        end)
    end

    local ok, err = pcall(function()
        cachedPawn:F_Dash()
    end)

    if ok then
        debugLog("Dash fired!")

        if config.AUTO_JUMP_AFTER_DASH then
            if config.AUTO_JUMP_DELAY_MS <= 0 then
                executeJump()
            else
                pendingJumpAfterDash = true
                jumpQueuedTime = os.clock()
            end
        end

        return true
    else
        debugLog("F_Dash error: " .. tostring(err))
        return false
    end
end

-- Triggered on landing
local function onLandedTrigger()
    if not config.ENABLED or not isValid(cachedPawn) or not isValid(cachedPC) then
        return
    end

    local dashHeld = config.AUTO_DASH_ENABLED and isKeyHeld(cachedPC, config.DASH_KEY)
    local bhopHeld = config.AUTO_BHOP_ENABLED and isKeyHeld(cachedPC, config.BHOP_KEY)

    debugLog(string.format("Landing detected! DashHeld: %s, BhopHeld: %s", tostring(dashHeld), tostring(bhopHeld)))

    if dashHeld then
        executeDash()
    elseif bhopHeld then
        executeJump()
    end
end

-- Main tick running in game thread
local function gameThreadTick()
    gameTickQueued = false

    if not config.ENABLED then return end

    if not acquirePlayer() then
        if config.DEBUG and os.clock() - lastDebugTime >= 3.0 then
            log("Waiting for local player pawn...")
            lastDebugTime = os.clock()
        end
        return
    end

    -- Process pending jump after dash if delay elapsed
    if pendingJumpAfterDash then
        local elapsedMs = (os.clock() - jumpQueuedTime) * 1000.0
        if elapsedMs >= config.AUTO_JUMP_DELAY_MS then
            pendingJumpAfterDash = false
            executeJump()
        end
    end

    -- Check ground state
    local okG, onGround = pcall(function()
        return cachedCM:IsMovingOnGround()
    end)

    if not okG then
        cachedCM = nil
        wasGrounded = false
        hadGroundState = false
        return
    end

    onGround = (onGround == true)

    if not hadGroundState then
        hadGroundState = true
        wasGrounded = onGround
        if onGround then
            onLandedTrigger()
        end
        return
    end

    -- Just landed this frame: was in air, now on ground
    if onGround and not wasGrounded then
        onLandedTrigger()
    -- If already on ground and holding bhop key:
    elseif onGround and config.AUTO_BHOP_ENABLED and isKeyHeld(cachedPC, config.BHOP_KEY) then
        local okFalling, isFalling = pcall(function() return cachedCM:IsFalling() end)
        if not okFalling or not isFalling then
            executeJump()
        end
    end

    wasGrounded = onGround
end

-- Register hooks for instant responsiveness
pcall(function()
    RegisterHook("/Script/Engine.Character:OnLanded", function(Context)
        ExecuteInGameThread(function()
            if acquirePlayer() then
                onLandedTrigger()
            end
        end)
    end)
end)

pcall(function()
    RegisterHook("/Script/Engine.Character:K2_OnMovementModeChanged", function(Context, PrevMode, NewMode)
        ExecuteInGameThread(function()
            local p = PrevMode:get()
            local n = NewMode:get()
            -- Mode 3 = Falling, Mode 1 = Walking (landed)
            if p == 3 and n == 1 then
                if acquirePlayer() then
                    onLandedTrigger()
                end
            end
        end)
    end)
end)

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(Context)
        ExecuteInGameThread(function()
            invalidatePlayer()
            acquirePlayer()
        end)
    end)
end)

-- Main loop
loadConfig()

log(string.format("v8.0 loaded! DashKey=%s, BhopKey=%s, AutoJumpAfterDash=%s",
    config.DASH_KEY, config.BHOP_KEY, tostring(config.AUTO_JUMP_AFTER_DASH)))

LoopAsync(config.POLL_MS, function()
    if not gameTickQueued then
        gameTickQueued = true
        ExecuteInGameThread(gameThreadTick)
    end
    return false
end)
