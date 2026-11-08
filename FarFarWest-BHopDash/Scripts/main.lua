--[[
    BHopDash Enhanced v12.0 for Far Far West
    UE4SS 3.0.x Lua Mod

    Fixes:
    - Eliminates thread race condition in ExecuteInGameThread (input thread no longer calls it).
    - Prevents loop deadlock by adding a 50ms watchdog timeout to gameTickQueued.
    - Continuous auto-bhop on holding Space (key-repeat continually extends bhop window).
    - Re-activates seamlessly on every new Spacebar press without freezing.
    - Dash-hop on LeftShift.
--]]

local UEHelpers = require("UEHelpers")

local config = {
    ENABLED = true,
    ALWAYS_BHOP = false,             -- If false, holding Space continues hopping; if true, hops on every landing
    AUTO_DASH_ENABLED = true,
    AUTO_JUMP_AFTER_DASH = true,
    RESET_DASH_COOLDOWN = true,
    POLL_MS = 10,
    DEBUG = true
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"

-- Runtime caches
local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasInAir = false
local gameTickQueued = false
local lastDispatchTime = 0.0
local lastHeartbeat = 0.0

-- Thread-safe state flags modified by input thread
local bhopActiveUntil = 0.0
local dashHopActiveUntil = 0.0
local spaceTriggerRequested = false
local shiftTriggerRequested = false
local jumpCounter = 0

local function log(msg)
    print("[BHopDash] " .. tostring(msg))
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
                elseif key == "ALWAYS_BHOP" then
                    config.ALWAYS_BHOP = parseBool(value)
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
    log(string.format("Config loaded: ALWAYS_BHOP=%s, AUTO_DASH=%s", tostring(config.ALWAYS_BHOP), tostring(config.AUTO_DASH_ENABLED)))
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
    wasInAir = false

    log("Local player acquired: " .. pawn:GetFullName())
    return true
end

local function executeJump()
    if not isValid(cachedPawn) then return end

    jumpCounter = jumpCounter + 1

    -- Unreal Character Jump
    pcall(function()
        cachedPawn:StopJumping()
        cachedPawn:Jump()
    end)

    -- Guaranteed physical launch
    pcall(function()
        if isValid(cachedCM) then
            local zVel = 600.0
            if cachedCM.JumpZVelocity and cachedCM.JumpZVelocity > 100.0 then
                zVel = cachedCM.JumpZVelocity
            end
            cachedPawn:LaunchCharacter({ X = 0.0, Y = 0.0, Z = zVel }, false, true)
        end
    end)

    log(string.format("Auto-Jump #%d executed!", jumpCounter))
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

    local isGrounded = false
    pcall(function()
        isGrounded = cachedCM:IsMovingOnGround()
    end)

    local isFalling = false
    pcall(function()
        isFalling = cachedCM:IsFalling()
    end)

    local inAir = isFalling or (not isGrounded)
    local now = os.clock()

    -- Process pending initial jump from key press if grounded
    if spaceTriggerRequested then
        spaceTriggerRequested = false
        if isGrounded then
            executeJump()
        end
    end

    if shiftTriggerRequested then
        shiftTriggerRequested = false
        if isGrounded and config.AUTO_DASH_ENABLED then
            executeDash()
        end
    end

    local isBhopActive = config.ALWAYS_BHOP or (now < bhopActiveUntil)
    local isDashActive = (now < dashHopActiveUntil)

    -- Landing detection: was airborne last tick, now grounded
    if wasInAir and not inAir then
        log(string.format("Landing detected! BhopActive=%s, DashActive=%s", tostring(isBhopActive), tostring(isDashActive)))

        if isDashActive and config.AUTO_DASH_ENABLED then
            executeDash()
            dashHopActiveUntil = now + 1.2
        elseif isBhopActive then
            executeJump()
            bhopActiveUntil = now + 1.2
        end
    end

    wasInAir = inAir

    -- Heartbeat log every 10 seconds in debug mode to confirm loop health
    if config.DEBUG and (now - lastHeartbeat >= 10.0) then
        lastHeartbeat = now
        log(string.format("Heartbeat: active, grounded=%s, inAir=%s, bhopActive=%s", tostring(isGrounded), tostring(inAir), tostring(isBhopActive)))
    end
end

-- Watchdog-protected async loop: guarantees NO deadlocks even on frame drops
local function asyncLoopCallback()
    local now = os.clock()
    if not gameTickQueued or (now - lastDispatchTime > 0.05) then
        gameTickQueued = true
        lastDispatchTime = now
        ExecuteInGameThread(gameThreadTick)
    end
    return false
end

-- Input thread handlers: ONLY update state flags, ZERO ExecuteInGameThread calls!
local function onSpaceKeyPressed()
    bhopActiveUntil = os.clock() + 1.2
    spaceTriggerRequested = true
end

local function onShiftKeyPressed()
    dashHopActiveUntil = os.clock() + 1.2
    shiftTriggerRequested = true
end

-- Initialize
loadConfig()

RegisterKeyBind(Key.SPACE, onSpaceKeyPressed)
RegisterKeyBind(Key.LEFT_SHIFT or 0x10, onShiftKeyPressed)

log("BHopDash v12.0 initialized! Thread-safe, watchdog protected.")
LoopAsync(config.POLL_MS, asyncLoopCallback)
