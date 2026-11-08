--[[
    BHopDash Enhanced v8.1 for Far Far West
    UE4SS 3.0.x Lua Mod

    Features:
    - Auto-BHop: Hold SpaceBar to automatically jump immediately upon touching the ground.
    - Auto-Dash: Hold LeftShift to automatically dash on landing.
    - Auto-Jump After Dash: Jump immediately after dash to carry momentum in the air.
    - Zero Registry Churn: Reuses persistent callbacks to prevent UE4SS memory crashes.
    - Zero Hook Overhead: No global engine hooks to ensure 100% stability.
    - Auto-recovers on respawn or map change without lag.
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
    DEBUG = false
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"

-- Pre-built keys to avoid any allocation during game ticks
local dashKeyPrimary = nil
local dashKeySecondary = nil
local bhopKeyPrimary = nil
local bhopKeySecondary = nil

-- Runtime player caches
local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasGrounded = false
local hadGroundState = false
local gameTickQueued = false
local lastDebugLog = 0.0

-- Logging
local function log(msg)
    print("[BHopDash] " .. tostring(msg))
end

local function debugLog(msg)
    if config.DEBUG then
        log("[DEBUG] " .. tostring(msg))
    end
end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parseBool(val)
    if not val then return false end
    val = trim(val):lower()
    return val == "true" or val == "1" or val == "yes" or val == "on"
end

local function buildKey(name)
    if not name or name == "" then return nil end
    local ok, k = pcall(function()
        local obj = {}
        obj.KeyName = FName(name)
        return obj
    end)
    if ok and k then return k end
    return nil
end

local function setupKeyStructs()
    dashKeyPrimary = buildKey(config.DASH_KEY)
    local dashLower = config.DASH_KEY:lower()
    if dashLower == "leftshift" or dashLower == "shift" then
        dashKeyPrimary = buildKey("LeftShift")
        dashKeySecondary = buildKey("RightShift")
    elseif dashLower == "leftcontrol" or dashLower == "control" or dashLower == "ctrl" then
        dashKeyPrimary = buildKey("LeftControl")
        dashKeySecondary = buildKey("RightControl")
    else
        dashKeySecondary = nil
    end

    bhopKeyPrimary = buildKey(config.BHOP_KEY)
    local bhopLower = config.BHOP_KEY:lower()
    if bhopLower == "space" or bhopLower == "spacebar" then
        bhopKeyPrimary = buildKey("SpaceBar")
        bhopKeySecondary = buildKey("Space")
    else
        bhopKeySecondary = nil
    end
end

local function loadConfig()
    local file = io.open(CONFIG_FILENAME, "r")
    if not file then
        log("config.txt not found, using default configuration.")
        setupKeyStructs()
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
                    if n and n >= 5 then config.POLL_MS = n end
                elseif key == "DEBUG" then
                    config.DEBUG = parseBool(value)
                end
            end
        end
    end
    file:close()
    setupKeyStructs()
    debugLog("Configuration loaded successfully.")
end

local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

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
        if isValid(pc.AcknowledgedPawn) then
            pawn = pc.AcknowledgedPawn
        elseif isValid(pc.Pawn) then
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

    debugLog("Local player and CharacterMovement acquired.")
    return true
end

local function isKeyHeld(pc, primaryKey, secondaryKey)
    if not isValid(pc) then return false end

    if primaryKey then
        local ok, held = pcall(function()
            return pc:IsInputKeyDown(primaryKey)
        end)
        if ok and held == true then return true end
    end

    if secondaryKey then
        local ok2, held2 = pcall(function()
            return pc:IsInputKeyDown(secondaryKey)
        end)
        if ok2 and held2 == true then return true end
    end

    return false
end

local function executeJump()
    if not isValid(cachedPawn) then return end
    pcall(function()
        cachedPawn:StopJumping()
        cachedPawn:Jump()
    end)
    debugLog("Jump executed")
end

local function executeDash()
    if not isValid(cachedPawn) then return end

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

    local ok = pcall(function()
        cachedPawn:F_Dash()
    end)

    if ok then
        debugLog("Dash executed")
        if config.AUTO_JUMP_AFTER_DASH then
            pcall(function()
                cachedPawn:StopJumping()
                cachedPawn:Jump()
            end)
            debugLog("Auto-jump after dash executed")
        end
    end
end

-- Reused persistent tick function - NEVER allocated per frame
local function gameThreadTick()
    gameTickQueued = false

    if not config.ENABLED then return end

    if not acquirePlayer() then
        if config.DEBUG and os.clock() - lastDebugLog >= 5.0 then
            log("Waiting for player pawn in level...")
            lastDebugLog = os.clock()
        end
        return
    end

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

    local dashHeld = config.AUTO_DASH_ENABLED and isKeyHeld(cachedPC, dashKeyPrimary, dashKeySecondary)
    local bhopHeld = config.AUTO_BHOP_ENABLED and isKeyHeld(cachedPC, bhopKeyPrimary, bhopKeySecondary)

    if not hadGroundState then
        hadGroundState = true
        wasGrounded = onGround
        if onGround then
            if dashHeld then
                executeDash()
            elseif bhopHeld then
                executeJump()
            end
        end
        return
    end

    -- Landing detected: was in air last tick, now touching ground
    if onGround and not wasGrounded then
        if dashHeld then
            executeDash()
        elseif bhopHeld then
            executeJump()
        end
    -- Holding bhop key while on ground: keep hopping
    elseif onGround and bhopHeld then
        local okFall, isFall = pcall(function() return cachedCM:IsFalling() end)
        if not okFall or not isFall then
            executeJump()
        end
    end

    wasGrounded = onGround
end

-- Reused persistent loop callback - zero registry churn
local function asyncLoopCallback()
    if not gameTickQueued then
        gameTickQueued = true
        ExecuteInGameThread(gameThreadTick)
    end
    return false
end

-- Initialize
loadConfig()

log(string.format("v8.1 loaded successfully! DashKey=%s, BhopKey=%s, AutoJumpAfterDash=%s",
    config.DASH_KEY, config.BHOP_KEY, tostring(config.AUTO_JUMP_AFTER_DASH)))

LoopAsync(config.POLL_MS, asyncLoopCallback)
