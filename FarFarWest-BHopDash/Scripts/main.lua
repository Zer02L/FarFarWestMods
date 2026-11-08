--[[
    BHopDash Enhanced v11.0 for Far Far West
    UE4SS 3.0.x Lua Mod

    Features:
    - Pure Auto-BHop: Automatically jumps with perfect timing on EVERY landing!
    - Dash-Hop: Press LeftShift to trigger landing dash + jump launch.
    - Robust air/ground transition via MovementMode (MOVE_Falling -> MOVE_Walking).
    - LaunchCharacter + Jump dual execution for 100% reliable physical jumps.
    - Zero closures, zero registry leaks, zero crash on exit.
--]]

local UEHelpers = require("UEHelpers")

local config = {
    ENABLED = true,
    ALWAYS_BHOP = true,              -- Automatically jump on every landing!
    AUTO_DASH_ENABLED = true,
    AUTO_JUMP_AFTER_DASH = true,
    RESET_DASH_COOLDOWN = true,
    POLL_MS = 10,
    DEBUG = true
}

local CONFIG_FILENAME = "ue4ss/Mods/BHopDash/config.txt"
local DUMP_FILENAME = "ue4ss/Mods/BHopDash/player_functions.txt"

-- Runtime caches
local cachedPC = nil
local cachedPawn = nil
local cachedCM = nil

local wasInAir = false
local gameTickQueued = false
local dumpedFunctions = false

-- State tracking
local bhopActiveUntil = 0.0
local dashHopActiveUntil = 0.0
local jumpCount = 0

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

-- Comprehensive scan for player functions in both lobby and match
local function dumpPlayerFunctions(pawn)
    if dumpedFunctions or not isValid(pawn) then return end
    dumpedFunctions = true

    pcall(function()
        local file = io.open(DUMP_FILENAME, "w")
        if file then
            file:write("=== Functions for " .. pawn:GetFullName() .. " ===\n")
        end

        log("Scanning UFunctions for " .. pawn:GetFullName())
        ForeachUObject(function(obj)
            local fullName = obj:GetFullName()
            if (fullName:find("BP_Player", 1, true)) then
                if fullName:find("Jump", 1, true) or fullName:find("Dash", 1, true) or fullName:find("Input", 1, true) or fullName:find("InpAct", 1, true) or fullName:find("Land", 1, true) then
                    log("  UFunction: " .. fullName)
                    if file then
                        file:write(fullName .. "\n")
                    end
                end
            end
            return false
        end)

        if file then
            file:close()
            log("Saved player functions to " .. DUMP_FILENAME)
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
    dumpPlayerFunctions(pawn)
    return true
end

local function executeJump()
    if not isValid(cachedPawn) then return end

    jumpCount = jumpCount + 1

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

    log(string.format("Auto-Jump #%d executed!", jumpCount))
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

    -- Check if character is airborne
    -- EMovementMode: 3 is MOVE_Falling (in air)
    local mode = 1
    pcall(function() mode = cachedCM.MovementMode end)

    local inAir = (mode == 3)
    if not inAir then
        pcall(function() inAir = cachedCM:IsFalling() end)
    end

    local now = os.clock()
    local isBhopTriggered = config.ALWAYS_BHOP or (now < bhopActiveUntil)
    local isDashTriggered = (now < dashHopActiveUntil)

    -- LANDING DETECTED: was in air on previous tick, now grounded!
    if wasInAir and not inAir then
        log(string.format("Landing detected! BhopActive=%s, DashActive=%s", tostring(isBhopTriggered), tostring(isDashTriggered)))

        if isDashTriggered and config.AUTO_DASH_ENABLED then
            executeDash()
            dashHopActiveUntil = now + 1.5
        elseif isBhopTriggered then
            executeJump()
            bhopActiveUntil = now + 1.5
        end
    end

    wasInAir = inAir
end

local function asyncLoopCallback()
    if not gameTickQueued then
        gameTickQueued = true
        ExecuteInGameThread(gameThreadTick)
    end
    return false
end

-- Static callbacks for KeyBinds
local function onSpaceKeyGameThread()
    if acquirePlayer() and isValid(cachedCM) and not cachedCM:IsFalling() then
        executeJump()
    end
end

local function onSpaceKeyPressed()
    bhopActiveUntil = os.clock() + 1.5
    log("Space pressed -> BHop chain active until " .. string.format("%.2f", bhopActiveUntil))
    ExecuteInGameThread(onSpaceKeyGameThread)
end

local function onShiftKeyGameThread()
    if acquirePlayer() and isValid(cachedCM) and not cachedCM:IsFalling() then
        executeDash()
    end
end

local function onShiftKeyPressed()
    dashHopActiveUntil = os.clock() + 1.5
    log("Shift pressed -> Dash-Hop chain active until " .. string.format("%.2f", dashHopActiveUntil))
    ExecuteInGameThread(onShiftKeyGameThread)
end

-- Initialize
loadConfig()

RegisterKeyBind(Key.SPACE, onSpaceKeyPressed)
RegisterKeyBind(Key.LEFT_SHIFT or 0x10, onShiftKeyPressed)

log(string.format("BHopDash v11.0 active! ALWAYS_BHOP=%s (Auto-hop on every landing).", tostring(config.ALWAYS_BHOP)))
LoopAsync(config.POLL_MS, asyncLoopCallback)
