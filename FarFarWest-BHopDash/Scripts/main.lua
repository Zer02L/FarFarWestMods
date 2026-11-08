--[[
    BHopDash Enhanced v9.0 for Far Far West
    UE4SS 3.0.x Lua Mod
--]]

local UEHelpers = require("UEHelpers")

local config = {
    ENABLED = true,
    AUTO_BHOP_ENABLED = true,
    AUTO_DASH_ENABLED = true,
    AUTO_JUMP_AFTER_DASH = true,
    RESET_DASH_COOLDOWN = true,
    POLL_MS = 10,
    DEBUG = true
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"
local DUMP_FILENAME = "ue4ss/Mods/BHopDash/player_functions.txt"

local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasGrounded = false
local hadGroundState = false
local gameTickQueued = false
local dumpedFunctions = false

-- Input tracking via RegisterKeyBind + repeat timers
local spaceHeldUntil = 0.0
local shiftHeldUntil = 0.0

local function log(msg)
    print("[BHopDash] " .. tostring(msg))
end

local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- Dump all functions of BP_Player_C to discover exact names
local function dumpPlayerFunctions(pawn)
    if dumpedFunctions or not isValid(pawn) then return end
    dumpedFunctions = true

    pcall(function()
        local file = io.open(DUMP_FILENAME, "w")
        if file then
            file:write("=== Functions for " .. pawn:GetFullName() .. " ===\n")
        end

        log("Scanning UFunctions for BP_Player_C...")
        ForeachUObject(function(obj)
            local fullName = obj:GetFullName()
            if fullName:find("BP_Player_C:", 1, true) then
                if fullName:find("Jump", 1, true) or fullName:find("Dash", 1, true) or fullName:find("Input", 1, true) or fullName:find("InpAct", 1, true) or fullName:find("Land", 1, true) then
                    log("  Found: " .. fullName)
                    if file then
                        file:write(fullName .. "\n")
                    end
                end
            end
            return false
        end)

        if file then
            file:close()
            log("Dump saved to " .. DUMP_FILENAME)
        end
    end)
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

    log("Local player acquired: " .. pawn:GetFullName())
    dumpPlayerFunctions(pawn)
    return true
end

local function executeJump()
    if not isValid(cachedPawn) then return end

    local jumpSuccess = false

    -- Method 1: Standard Unreal Character Jump
    pcall(function()
        cachedPawn:StopJumping()
        cachedPawn:Jump()
        jumpSuccess = true
    end)

    -- Method 2: If CharacterMovement is on ground, force JumpZVelocity
    pcall(function()
        if isValid(cachedCM) and cachedCM:IsMovingOnGround() then
            local zVel = 600.0
            if cachedCM.JumpZVelocity and cachedCM.JumpZVelocity > 100.0 then
                zVel = cachedCM.JumpZVelocity
            end
            cachedPawn:LaunchCharacter({ X = 0.0, Y = 0.0, Z = zVel }, false, true)
            jumpSuccess = true
        end
    end)

    log("Auto-Jump fired! (success=" .. tostring(jumpSuccess) .. ")")
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

    log("Auto-Dash fired! (F_Dash ok=" .. tostring(ok) .. ")")

    if ok and config.AUTO_JUMP_AFTER_DASH then
        executeJump()
    end
end

-- Game thread tick
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
    local spaceHeld = (now < spaceHeldUntil)
    local shiftHeld = (now < shiftHeldUntil)

    if not hadGroundState then
        hadGroundState = true
        wasGrounded = onGround
        if onGround then
            if shiftHeld and config.AUTO_DASH_ENABLED then
                executeDash()
            elseif spaceHeld and config.AUTO_BHOP_ENABLED then
                executeJump()
            end
        end
        return
    end

    -- Landing detection: was falling/in-air, now on ground
    if onGround and not wasGrounded then
        log("Landing detected! SpaceHeld=" .. tostring(spaceHeld) .. " ShiftHeld=" .. tostring(shiftHeld))
        if shiftHeld and config.AUTO_DASH_ENABLED then
            executeDash()
        elseif spaceHeld and config.AUTO_BHOP_ENABLED then
            executeJump()
        end
    -- Still on ground while holding space: continuous jump
    elseif onGround and spaceHeld and config.AUTO_BHOP_ENABLED then
        local okFall, isFall = pcall(function() return cachedCM:IsFalling() end)
        if not okFall or not isFall then
            executeJump()
        end
    end

    wasGrounded = onGround
end

local function asyncLoopCallback()
    if not gameTickQueued then
        gameTickQueued = true
        ExecuteInGameThread(gameThreadTick)
    end
    return false
end

-- Keybind registrations
-- SpaceBar
RegisterKeyBind(Key.SPACE, function()
    spaceHeldUntil = os.clock() + 0.35
    log("Key.SPACE pressed / repeat! Held until " .. string.format("%.2f", spaceHeldUntil))
    ExecuteInGameThread(function()
        if acquirePlayer() and isValid(cachedCM) and cachedCM:IsMovingOnGround() then
            executeJump()
        end
    end)
end)

-- Left Shift
RegisterKeyBind(Key.LEFT_SHIFT or 0xA0, function()
    shiftHeldUntil = os.clock() + 0.35
    log("Key.SHIFT pressed / repeat! Held until " .. string.format("%.2f", shiftHeldUntil))
end)

log("BHopDash v9.0 loaded! Keybinds active on SpaceBar and Shift.")
LoopAsync(config.POLL_MS, asyncLoopCallback)
