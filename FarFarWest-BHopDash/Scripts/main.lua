--[[
    BHopDash Enhanced v10.0 for Far Far West
    UE4SS 3.0.x Lua Mod

    Features:
    - Auto-BHop: Press Space to start chaining hops. Automatically executes perfect jump on EVERY landing while moving!
    - Dash-Hop: Press/hold LeftShift to auto-dash on landing and launch into the air carrying dash momentum.
    - Zero crash on exit: All callbacks to ExecuteInGameThread are static persistent functions (zero registry leaks).
    - LaunchCharacter + Jump dual execution for 100% reliable physical jumps.
--]]

local UEHelpers = require("UEHelpers")

local config = {
    ENABLED = true,
    DASH_KEY = "LeftShift",
    BHOP_KEY = "SpaceBar",
    AUTO_BHOP_ENABLED = true,
    AUTO_DASH_ENABLED = true,
    AUTO_JUMP_AFTER_DASH = true,
    RESET_DASH_COOLDOWN = true,
    ALWAYS_BHOP_WHEN_MOVING = false,
    POLL_MS = 10,
    DEBUG = true
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"

-- Runtime caches
local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasGrounded = false
local hadGroundState = false
local gameTickQueued = false

-- State tracking
local bhopActiveUntil = 0.0
local dashHopActiveUntil = 0.0
local lastLogTime = 0.0

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

local function loadConfig()
    local file = io.open(CONFIG_FILENAME, "r")
    if not file then
        log("config.txt not found, using default configuration.")
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
                elseif key == "AUTO_BHOP_ENABLED" then
                    config.AUTO_BHOP_ENABLED = parseBool(value)
                elseif key == "AUTO_DASH_ENABLED" then
                    config.AUTO_DASH_ENABLED = parseBool(value)
                elseif key == "AUTO_JUMP_AFTER_DASH" then
                    config.AUTO_JUMP_AFTER_DASH = parseBool(value)
                elseif key == "RESET_DASH_COOLDOWN" then
                    config.RESET_DASH_COOLDOWN = parseBool(value)
                elseif key == "ALWAYS_BHOP_WHEN_MOVING" then
                    config.ALWAYS_BHOP_WHEN_MOVING = parseBool(value)
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
            return FindFirstOf("BP_Player_C") or FindFirstOf("BP_Player_Lobby_C")
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

    log("Local player acquired: " .. pawn:GetFullName())
    return true
end

local function isCharacterMoving()
    if not isValid(cachedCM) then return false end
    local ok, vel = pcall(function() return cachedCM.Velocity end)
    if ok and vel then
        local speedSq = (vel.X or 0)^2 + (vel.Y or 0)^2
        return speedSq > 2500 -- > 50 units/sec
    end
    return false
end

local function executeJump()
    if not isValid(cachedPawn) then return end

    -- Unreal Character Jump
    pcall(function()
        cachedPawn:StopJumping()
        cachedPawn:Jump()
    end)

    -- Physical jump impulse
    pcall(function()
        if isValid(cachedCM) then
            local zVel = 600.0
            if cachedCM.JumpZVelocity and cachedCM.JumpZVelocity > 100.0 then
                zVel = cachedCM.JumpZVelocity
            end
            cachedPawn:LaunchCharacter({ X = 0.0, Y = 0.0, Z = zVel }, false, true)
        end
    end)

    log("Auto-Jump executed!")
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

    pcall(function()
        cachedPawn:F_Dash()
    end)

    log("Auto-Dash executed!")

    if config.AUTO_JUMP_AFTER_DASH then
        executeJump()
    end
end

-- Persistent static game thread tick
local function gameThreadTick()
    gameTickQueued = false

    if not config.ENABLED then return end

    if not acquirePlayer() then
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

    local now = os.clock()
    local moving = isCharacterMoving()

    -- Check if bhop or dash-hop is active
    local bhopActive = config.AUTO_BHOP_ENABLED and (config.ALWAYS_BHOP_WHEN_MOVING or (now < bhopActiveUntil)) and moving
    local dashActive = config.AUTO_DASH_ENABLED and (now < dashHopActiveUntil) and moving

    if not hadGroundState then
        hadGroundState = true
        wasGrounded = onGround
        if onGround then
            if dashActive then
                executeDash()
                dashHopActiveUntil = now + 1.2
            elseif bhopActive then
                executeJump()
                bhopActiveUntil = now + 1.2
            end
        end
        return
    end

    -- Landing detected: was in air last tick, now on ground
    if onGround and not wasGrounded then
        if dashActive then
            log("Landing with Dash-Hop active! Dashing and leaping...")
            executeDash()
            dashHopActiveUntil = now + 1.2
        elseif bhopActive then
            log("Landing with Bhop active! Hopping...")
            executeJump()
            bhopActiveUntil = now + 1.2
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

-- Static pre-declared callbacks for KeyBinds - zero closures, zero exit crashes
local function onSpaceKeyGameThread()
    if acquirePlayer() and isValid(cachedCM) and cachedCM:IsMovingOnGround() then
        executeJump()
    end
end

local function onSpaceKeyPressed()
    bhopActiveUntil = os.clock() + 1.2
    log("Space pressed -> BHop chain activated!")
    ExecuteInGameThread(onSpaceKeyGameThread)
end

local function onShiftKeyGameThread()
    if acquirePlayer() and isValid(cachedCM) and cachedCM:IsMovingOnGround() then
        executeDash()
    end
end

local function onShiftKeyPressed()
    dashHopActiveUntil = os.clock() + 1.2
    log("Shift pressed -> Dash-Hop chain activated!")
    ExecuteInGameThread(onShiftKeyGameThread)
end

-- Initialize
loadConfig()

RegisterKeyBind(Key.SPACE, onSpaceKeyPressed)
RegisterKeyBind(Key.LEFT_SHIFT or 0x10, onShiftKeyPressed)

log("BHopDash v10.0 initialized! Press Space to bunnyhop, Shift to dash-hop.")
LoopAsync(config.POLL_MS, asyncLoopCallback)
