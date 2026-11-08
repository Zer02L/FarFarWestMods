--[[
    BHopDash Enhanced v14.0 for Far Far West
    UE4SS 3.0.x Lua Mod

    Key improvements in v14.0:
    - REAL hold detection: UE4SS RegisterKeyBind is edge-triggered (it fires once
      per physical press and never again while the key is held, because OS
      key-repeat is ignored). The old press-time-window heuristic therefore
      reported spaceHeld=false on EVERY landing and hold-to-bhop never worked.
      v14.0 polls the game's own input state via
      APlayerController::IsInputKeyDown(FKey) inside the GameThread loop and
      falls back to the old window heuristic if that API is unavailable.
    - Short 0.10s "fresh press" grace so a press that happens on the very same
      frame as a landing is never missed (input processing latency).
    - Automatic self-check: if polling never sees a key that was physically
      pressed, the mod logs a warning and falls back instead of silently
      breaking hold-to-bhop.

    Retained from v13.0:
    - Immediate stop on release, single tap = single jump.
    - No artificial timer extension on landing.
    - Thread-safe input handling with watchdog-protected async tick loop.
--]]

local UEHelpers = require("UEHelpers")

local config = {
    ENABLED = true,
    ALWAYS_BHOP = false,             -- If false, holding Space continues hopping; if true, hops on every landing
    SPACE_HOLD_WINDOW = 0.30,        -- Fallback only: press-window used when IsInputKeyDown polling is unavailable
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
local lastSpacePressTime = 0.0
local lastShiftPressTime = 0.0
local spaceTriggerRequested = false
local shiftTriggerRequested = false
local jumpCounter = 0

-- Live input polling state (GameThread only)
-- variant: 0 = not probed yet, 1/2 = working call form, 3 = disabled (API missing)
-- suspended: API works but has not yet proven it sees real presses (self-check)
local inputPoll = {
    variant = 0,
    fails = 0,
    warned = false,
    suspended = false,
}
local spacePollState = { lastTrue = 0.0, checkedAt = 0.0, misses = 0 }
local shiftPollState = { lastTrue = 0.0, checkedAt = 0.0, misses = 0 }

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
                elseif key == "SPACE_HOLD_WINDOW" or key == "HOLD_WINDOW" then
                    local n = tonumber(value)
                    if n and n >= 0.05 and n <= 2.0 then config.SPACE_HOLD_WINDOW = n end
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
    log(string.format("Config loaded: ALWAYS_BHOP=%s, SPACE_HOLD_WINDOW=%.2fs, AUTO_DASH=%s",
        tostring(config.ALWAYS_BHOP), config.SPACE_HOLD_WINDOW, tostring(config.AUTO_DASH_ENABLED)))
end

local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- ==================== Real key-held polling (v14.0) ====================
-- UE4SS RegisterKeyBind is edge-triggered: it fires once per physical press and
-- never again while the key stays down (OS key-repeat is not re-delivered), so a
-- press-time window can never represent "currently held". We instead ask the game
-- itself: APlayerController::IsInputKeyDown(FKey Key) is BlueprintCallable and
-- reflects the exact key state the game is processing right now.
local function tryInputKeyDown(pc, variant, keyName)
    if variant == 1 then
        return pc:IsInputKeyDown({ Key = FName(keyName) })
    end
    return pc:IsInputKeyDown({ Key = keyName })
end

-- Returns the live held-state of `keyName`.
-- If polling is unavailable (API missing / unexpected parameter encoding) it
-- returns `fallback` (the legacy press-window heuristic) and, after repeated
-- failures, permanently disables polling so we never spam errors.
-- `edgeTime` is the timestamp of the last physical press; it drives a self-check
-- that catches a poll which runs fine but always reports false.
local function pollKeyHeld(pc, keyName, fallback, edgeTime, st)
    if inputPoll.variant == 3 then
        return fallback
    end

    local got = nil
    local lastErr = nil

    if inputPoll.variant == 0 then
        for _, v in ipairs({ 1, 2 }) do
            local ok, res = pcall(tryInputKeyDown, pc, v, keyName)
            if ok and type(res) == "boolean" then
                inputPoll.variant = v
                got = res
                break
            end
            lastErr = res
        end
    else
        local ok, res = pcall(tryInputKeyDown, pc, inputPoll.variant, keyName)
        if ok and type(res) == "boolean" then
            got = res
        else
            lastErr = res
        end
    end

    if got == nil then
        inputPoll.fails = inputPoll.fails + 1
        if not inputPoll.warned then
            inputPoll.warned = true
            log("IsInputKeyDown probe failed (will retry): " .. tostring(lastErr))
        end
        if inputPoll.fails >= 100 then
            inputPoll.variant = 3
            log("IsInputKeyDown unavailable - using press-window fallback: " .. tostring(lastErr))
        end
        return fallback
    end

    local now = os.clock()
    if got then
        -- Proof of life: polling sees a real held key, so all suspicion is cleared
        st.lastTrue = now
        st.misses = 0
        if inputPoll.suspended then
            inputPoll.suspended = false
            log("IsInputKeyDown polling recovered.")
        end
    elseif edgeTime and edgeTime > st.checkedAt and (now - edgeTime) > 0.5 then
        -- Self-check: once a press edge is older than 0.5s, polling must have seen
        -- that key as held at least once, otherwise this poll path looks dead.
        st.checkedAt = edgeTime
        if st.lastTrue < edgeTime then
            st.misses = st.misses + 1
            if st.misses >= 3 and not inputPoll.suspended then
                inputPoll.suspended = true
                log("IsInputKeyDown never saw the pressed key - using press-window fallback until polling proves alive.")
            end
        end
    end

    if inputPoll.suspended and not got then
        return fallback
    end
    return got
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

    -- Legacy press-window values (used as fallback and as a 0.10s fresh-press grace)
    local spaceWindow = (now - lastSpacePressTime <= config.SPACE_HOLD_WINDOW)
    local shiftWindow = (now - lastShiftPressTime <= config.SPACE_HOLD_WINDOW)
    local spaceFresh = (now - lastSpacePressTime <= 0.10)
    local shiftFresh = (now - lastShiftPressTime <= 0.10)

    -- Live held-state from the game's input system (fallback = press-window)
    local spaceHeld = spaceFresh
        or pollKeyHeld(cachedPC, "SpaceBar", spaceWindow, lastSpacePressTime, spacePollState)
    local shiftHeld = shiftFresh
        or pollKeyHeld(cachedPC, "LeftShift", shiftWindow, lastShiftPressTime, shiftPollState)

    local isBhopActive = config.ALWAYS_BHOP or spaceHeld
    local isDashActive = shiftHeld

    -- Landing detection: was airborne last tick, now grounded
    if wasInAir and not inAir then
        -- Consume any pending triggers from airborne repeats so they don't double-fire
        spaceTriggerRequested = false
        shiftTriggerRequested = false

        log(string.format("Landing detected! spaceHeld=%s, isBhopActive=%s, shiftHeld=%s",
            tostring(spaceHeld), tostring(isBhopActive), tostring(shiftHeld)))

        if isDashActive and config.AUTO_DASH_ENABLED then
            executeDash()
        elseif isBhopActive then
            executeJump()
        else
            log("Space released: BHop stopped on landing.")
        end
    else
        -- Ground-based initial triggers (starting jump or dash while grounded)
        if shiftTriggerRequested then
            shiftTriggerRequested = false
            if isGrounded and config.AUTO_DASH_ENABLED then
                executeDash()
            end
        end

        if spaceTriggerRequested then
            spaceTriggerRequested = false
            if isGrounded then
                executeJump()
            end
        end
    end

    wasInAir = inAir

    -- Heartbeat log every 10 seconds in debug mode to confirm loop health
    if config.DEBUG and (now - lastHeartbeat >= 10.0) then
        lastHeartbeat = now
        local probeStatus = "poll:v" .. tostring(inputPoll.variant)
        if inputPoll.variant == 3 then
            probeStatus = "fallback"
        elseif inputPoll.suspended then
            probeStatus = "suspended"
        end
        log(string.format("Heartbeat: active, grounded=%s, inAir=%s, spaceHeld=%s, shiftHeld=%s, input=%s",
            tostring(isGrounded), tostring(inAir), tostring(spaceHeld), tostring(shiftHeld), probeStatus))
    end
end

-- Watchdog-protected async loop fallback for older UE4SS environments
local function asyncLoopCallback()
    local now = os.clock()
    if not gameTickQueued or (now - lastDispatchTime > 0.05) then
        gameTickQueued = true
        lastDispatchTime = now
        ExecuteInGameThread(function()
            gameTickQueued = false
            pcall(gameThreadTick)
        end)
    end
    return false
end

-- Input thread handlers: ONLY update state flags, ZERO ExecuteInGameThread calls!
local function onSpaceKeyPressed()
    lastSpacePressTime = os.clock()
    spaceTriggerRequested = true
end

local function onShiftKeyPressed()
    lastShiftPressTime = os.clock()
    shiftTriggerRequested = true
end

-- Initialize
loadConfig()

RegisterKeyBind(Key.SPACE, onSpaceKeyPressed)
RegisterKeyBind(Key.LEFT_SHIFT or 0x10, onShiftKeyPressed)

log("BHopDash v14.0 initialized! Hold-to-BHop with live IsInputKeyDown polling (GameThread synchronized).")
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(config.POLL_MS, function()
        pcall(gameThreadTick)
    end)
else
    LoopAsync(config.POLL_MS, asyncLoopCallback)
end
