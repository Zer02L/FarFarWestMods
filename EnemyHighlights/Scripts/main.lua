-- ==============================================================================
-- EnemyHighlights v1.0.0
-- Warframe-style Fresnel Rim Glow on Enemies (Client-Side, Depth-Tested)
--
-- Features:
--   - Warframe-style Fresnel rim glow highlighting enemy silhouettes
--   - 100% Client-side & Depth-tested (GPU hardware Z-buffer test, NO wallhack)
--   - Fully configurable colors (RGB/Hex) and intensity per tier (Regular, Elite, Boss)
--   - Aimed-part & target acquisition overlay: dynamically recolors aimed enemy or
--     aimed body part / weakspot under your crosshair for instant visual feedback
--   - Live configuration reload (F7) and instant toggle (F8) without restarting
-- ==============================================================================

local UEHelpers = require("UEHelpers")

local MOD_NAME = "EnemyHighlights"
local CONFIG_FILE = "ue4ss/Mods/EnemyHighlights/config.ini"

-- ==================== DEFAULT CONFIGURATION ====================
local Config = {
    Enabled             = true,
    IntensityMultiplier = 3.0,
    FresnelExponent     = 2.5,
    InnerAlpha          = 0.05,
    MaxDistance         = 15000.0, -- cm (150 meters)

    -- Colors (RGBA linear floats 0.0 - 1.0)
    EnemyColor = { R = 1.0,  G = 0.40, B = 0.0,  A = 1.0 }, -- Warframe Energy Orange (#FF6600)
    EliteColor = { R = 0.72, G = 0.0,  B = 1.0,  A = 1.0 }, -- Vibrant Violet (#B800FF)
    BossColor  = { R = 1.0,  G = 0.06, B = 0.18, A = 1.0 }, -- Blazing Crimson (#FF1030)

    -- Aimed Overlay
    RecolorAimedPart    = true,
    AimedColor = { R = 0.0,  G = 0.90, B = 1.0,  A = 1.0 }, -- Electric Cyan (#00E5FF)
    AimedIntensity      = 5.0,
    AimedPartOnly       = false,
    MaxAimDistance      = 20000.0, -- cm (200 meters)

    -- Keybinds
    ToggleKey           = "F8",
    ReloadConfigKey     = "F7",

    -- Timing intervals
    ScanIntervalMs      = 250,
    AimUpdateIntervalMs = 25,
}

-- ==================== LOGGING ====================
local function LogInfo(msg)
    print(string.format("[%s] %s", MOD_NAME, msg))
end

local function LogWarn(msg)
    print(string.format("[%s] [WARN] %s", MOD_NAME, msg))
end

-- ==================== CONFIG PARSER ====================
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function parse_bool(v)
    local s = tostring(v):lower()
    return s == "1" or s == "true" or s == "yes" or s == "on"
end

local function parse_float(v, default)
    local n = tonumber(v)
    return n or default
end

local function hex_to_linear(hex)
    hex = hex:gsub("#", "")
    if #hex == 6 then
        local r = tonumber(hex:sub(1, 2), 16) or 255
        local g = tonumber(hex:sub(3, 4), 16) or 255
        local b = tonumber(hex:sub(5, 6), 16) or 255
        return { R = r / 255.0, G = g / 255.0, B = b / 255.0, A = 1.0 }
    elseif #hex == 8 then
        local r = tonumber(hex:sub(1, 2), 16) or 255
        local g = tonumber(hex:sub(3, 4), 16) or 255
        local b = tonumber(hex:sub(5, 6), 16) or 255
        local a = tonumber(hex:sub(7, 8), 16) or 255
        return { R = r / 255.0, G = g / 255.0, B = b / 255.0, A = a / 255.0 }
    end
    return nil
end

local function load_config()
    local f = io.open(CONFIG_FILE, "r")
    if not f then
        -- Attempt fallback relative path
        f = io.open("Mods/EnemyHighlights/config.ini", "r")
    end
    if not f then
        LogWarn(string.format("Config file '%s' not found, using built-in defaults.", CONFIG_FILE))
        return
    end

    local raw = f:read("*a")
    f:close()

    local current_section = ""
    for line in raw:gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and not line:match("^[;#]") then
            local sec = line:match("^%[([^%]]+)%]$")
            if sec then
                current_section = trim(sec):lower()
            else
                local k, v = line:match("^([^=]+)=(.*)$")
                if k and v then
                    k = trim(k)
                    v = trim(v)

                    -- General
                    if k == "Enabled" then Config.Enabled = parse_bool(v)
                    elseif k == "IntensityMultiplier" then Config.IntensityMultiplier = parse_float(v, Config.IntensityMultiplier)
                    elseif k == "FresnelExponent" then Config.FresnelExponent = parse_float(v, Config.FresnelExponent)
                    elseif k == "InnerAlpha" then Config.InnerAlpha = parse_float(v, Config.InnerAlpha)
                    elseif k == "MaxDistance" then Config.MaxDistance = parse_float(v, Config.MaxDistance)

                    -- Colors
                    elseif k == "EnemyColorR" then Config.EnemyColor.R = parse_float(v, Config.EnemyColor.R)
                    elseif k == "EnemyColorG" then Config.EnemyColor.G = parse_float(v, Config.EnemyColor.G)
                    elseif k == "EnemyColorB" then Config.EnemyColor.B = parse_float(v, Config.EnemyColor.B)
                    elseif k == "EnemyColorA" then Config.EnemyColor.A = parse_float(v, Config.EnemyColor.A)
                    elseif k == "EnemyColorHex" then
                        local col = hex_to_linear(v)
                        if col then Config.EnemyColor = col end

                    elseif k == "EliteColorR" then Config.EliteColor.R = parse_float(v, Config.EliteColor.R)
                    elseif k == "EliteColorG" then Config.EliteColor.G = parse_float(v, Config.EliteColor.G)
                    elseif k == "EliteColorB" then Config.EliteColor.B = parse_float(v, Config.EliteColor.B)
                    elseif k == "EliteColorA" then Config.EliteColor.A = parse_float(v, Config.EliteColor.A)
                    elseif k == "EliteColorHex" then
                        local col = hex_to_linear(v)
                        if col then Config.EliteColor = col end

                    elseif k == "BossColorR" then Config.BossColor.R = parse_float(v, Config.BossColor.R)
                    elseif k == "BossColorG" then Config.BossColor.G = parse_float(v, Config.BossColor.G)
                    elseif k == "BossColorB" then Config.BossColor.B = parse_float(v, Config.BossColor.B)
                    elseif k == "BossColorA" then Config.BossColor.A = parse_float(v, Config.BossColor.A)
                    elseif k == "BossColorHex" then
                        local col = hex_to_linear(v)
                        if col then Config.BossColor = col end

                    -- Aimed Overlay
                    elseif k == "RecolorAimedPart" then Config.RecolorAimedPart = parse_bool(v)
                    elseif k == "AimedColorR" then Config.AimedColor.R = parse_float(v, Config.AimedColor.R)
                    elseif k == "AimedColorG" then Config.AimedColor.G = parse_float(v, Config.AimedColor.G)
                    elseif k == "AimedColorB" then Config.AimedColor.B = parse_float(v, Config.AimedColor.B)
                    elseif k == "AimedColorA" then Config.AimedColor.A = parse_float(v, Config.AimedColor.A)
                    elseif k == "AimedColorHex" then
                        local col = hex_to_linear(v)
                        if col then Config.AimedColor = col end
                    elseif k == "AimedIntensity" then Config.AimedIntensity = parse_float(v, Config.AimedIntensity)
                    elseif k == "AimedPartOnly" then Config.AimedPartOnly = parse_bool(v)
                    elseif k == "MaxAimDistance" then Config.MaxAimDistance = parse_float(v, Config.MaxAimDistance)

                    -- Keybinds
                    elseif k == "ToggleKey" then Config.ToggleKey = v
                    elseif k == "ReloadConfigKey" then Config.ReloadConfigKey = v
                    end
                end
            end
        end
    end

    LogInfo(string.format("Configuration loaded. Enabled=%s, Intensity=%.1f, AimedIntensity=%.1f",
        tostring(Config.Enabled), Config.IntensityMultiplier, Config.AimedIntensity))
end

-- ==================== MATERIAL & SHADER MANAGER ====================
-- Candidates for translucent / additive edge rim overlay materials present in Far Far West
local MATERIAL_CANDIDATES = {
    "/Game/FX/Materials/Element_Cryptic/M_FX_Cryptic_OrbShield_Translucent.M_FX_Cryptic_OrbShield_Translucent",
    "/Game/FX/Materials/M_FX_GlowLight.M_FX_GlowLight",
    "/Game/Materials/M_Translucent_Orange.M_Translucent_Orange",
    "/Game/Materials/M_Translucent.M_Translucent",
    "/Engine/EngineDebugMaterials/M_SimpleUnlitTranslucent.M_SimpleUnlitTranslucent",
}

-- Parameter names commonly found across Unreal Engine translucent and rim shaders
local VECTOR_PARAM_NAMES = {
    "Color", "BaseColor", "EmissiveColor", "EColor", "Tint", "GlowColor", "RimColor", "FresnelColor", "HighlightColor"
}

local SCALAR_PARAM_NAMES = {
    "Intensity", "EmissiveIntensity", "GlowIntensity", "Density", "FresnelPower", "FresnelExponent", "RimPower", "Power", "Exponent", "Alpha", "Opacity"
}

local CachedBaseMaterial = nil
local MIDs = {
    Regular = nil,
    Elite   = nil,
    Boss    = nil,
    Aimed   = nil,
}

local function find_base_material()
    if CachedBaseMaterial and CachedBaseMaterial:IsValid() then
        return CachedBaseMaterial
    end

    for _, path in ipairs(MATERIAL_CANDIDATES) do
        local ok, mat = pcall(StaticFindObject, path)
        if ok and mat and mat:IsValid() then
            CachedBaseMaterial = mat
            LogInfo(string.format("Found base highlight material: %s", path))
            return CachedBaseMaterial
        end
    end

    return nil
end

local function apply_mid_parameters(mid, linear_color, intensity, exponent, alpha)
    if not mid or not mid:IsValid() then return end

    -- Scaled emissive color
    local scaled_color = {
        R = linear_color.R * intensity,
        G = linear_color.G * intensity,
        B = linear_color.B * intensity,
        A = linear_color.A,
    }

    -- Set vector parameters
    for _, param in ipairs(VECTOR_PARAM_NAMES) do
        pcall(function()
            mid:SetVectorParameterValue(UEHelpers.FindOrAddFName(param), scaled_color)
        end)
    end

    -- Set scalar parameters
    for _, param in ipairs(SCALAR_PARAM_NAMES) do
        pcall(function()
            if param:find("Power") or param:find("Exponent") then
                mid:SetScalarParameterValue(UEHelpers.FindOrAddFName(param), exponent)
            elseif param:find("Alpha") or param:find("Opacity") then
                mid:SetScalarParameterValue(UEHelpers.FindOrAddFName(param), alpha)
            else
                mid:SetScalarParameterValue(UEHelpers.FindOrAddFName(param), intensity)
            end
        end)
    end
end

local function create_dynamic_material(parent_mat, name_str)
    if not parent_mat or not parent_mat:IsValid() then return nil end

    local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local world_ctx = UEHelpers.GetWorldContextObject()

    if kml and kml:IsValid() and world_ctx and world_ctx:IsValid() then
        local ok, dyn_mat = pcall(function()
            return kml:CreateDynamicMaterialInstance(world_ctx, parent_mat, UEHelpers.FindOrAddFName(name_str))
        end)
        if ok and dyn_mat and dyn_mat:IsValid() then
            return dyn_mat
        end
    end

    return parent_mat -- Fallback directly to parent if DMI creation fails
end

local function refresh_all_materials()
    local base_mat = find_base_material()
    if not base_mat then
        LogWarn("No valid base material found for highlights yet. Will retry when level loads.")
        return false
    end

    MIDs.Regular = create_dynamic_material(base_mat, "EnemyHighlight_Regular")
    MIDs.Elite   = create_dynamic_material(base_mat, "EnemyHighlight_Elite")
    MIDs.Boss    = create_dynamic_material(base_mat, "EnemyHighlight_Boss")
    MIDs.Aimed   = create_dynamic_material(base_mat, "EnemyHighlight_Aimed")

    apply_mid_parameters(MIDs.Regular, Config.EnemyColor, Config.IntensityMultiplier, Config.FresnelExponent, Config.InnerAlpha)
    apply_mid_parameters(MIDs.Elite,   Config.EliteColor, Config.IntensityMultiplier * 1.25, Config.FresnelExponent, Config.InnerAlpha)
    apply_mid_parameters(MIDs.Boss,    Config.BossColor,  Config.IntensityMultiplier * 1.5,  Config.FresnelExponent, Config.InnerAlpha)
    apply_mid_parameters(MIDs.Aimed,   Config.AimedColor, Config.AimedIntensity,      Config.FresnelExponent * 0.9, Config.InnerAlpha * 1.5)

    LogInfo("Dynamic highlight materials initialized successfully.")
    return true
end

-- ==================== ENEMY TRACKING & STATE ====================
-- Table mapping enemy address (string) -> {
--     actor = Actor,
--     tier = "Regular" | "Elite" | "Boss",
--     meshes = { MeshComponent, ... },
--     nativeOverlays = { [Mesh] = NativeOverlayMaterial },
--     isAimed = boolean,
-- }
local ActiveEnemies = {}
local CurrentAimedEnemyAddr = nil
local CurrentAimedPartMesh = nil

local function get_enemy_tier(actor)
    local ok, full_name = pcall(function() return actor:GetFullName() end)
    if not ok or not full_name then return "Regular" end

    local name = full_name:lower()
    if name:find("boss") or name:find("halloween_boss") or name:find("train") then
        return "Boss"
    elseif name:find("elite") or name:find("shielder") or name:find("necromancer") or name:find("invoker") then
        return "Elite"
    end
    return "Regular"
end

local function collect_actor_meshes(actor)
    local meshes = {}
    local seen = {}

    -- Primary Character SkeletalMesh
    local ok_mesh, char_mesh = pcall(function() return actor.Mesh end)
    if ok_mesh and char_mesh and char_mesh:IsValid() then
        table.insert(meshes, char_mesh)
        seen[char_mesh:GetAddress()] = true
    end

    -- Query any attached MeshComponents (shields, armor, weakpoint parts)
    pcall(function()
        local static_mesh_class = StaticFindObject("/Script/Engine.MeshComponent")
        if static_mesh_class and static_mesh_class:IsValid() then
            local comps = actor:K2_GetComponentsByClass(static_mesh_class)
            if comps then
                for i = 1, #comps do
                    local comp = comps[i]
                    if comp and comp:IsValid() and not seen[comp:GetAddress()] then
                        -- Check if component is visible
                        local is_visible = true
                        pcall(function() is_visible = comp:IsVisible() end)
                        if is_visible then
                            table.insert(meshes, comp)
                            seen[comp:GetAddress()] = true
                        end
                    end
                end
            end
        end
    end)

    return meshes
end

local function get_tier_mid(tier)
    if tier == "Boss" then
        return MIDs.Boss or MIDs.Regular
    elseif tier == "Elite" then
        return MIDs.Elite or MIDs.Regular
    end
    return MIDs.Regular
end

local function apply_highlight_to_mesh(mesh, mid)
    if not mesh or not mesh:IsValid() or not mid or not mid:IsValid() then return end
    pcall(function()
        mesh:SetOverlayMaterial(mid)
    end)
end

local function remove_highlight_from_mesh(mesh, original_native_overlay)
    if not mesh or not mesh:IsValid() then return end
    pcall(function()
        mesh:SetOverlayMaterial(original_native_overlay or nil)
    end)
end

local function register_enemy(actor)
    if not actor or not actor:IsValid() then return end
    local addr = tostring(actor:GetAddress())
    if ActiveEnemies[addr] then return end

    local tier = get_enemy_tier(actor)
    local meshes = collect_actor_meshes(actor)
    if #meshes == 0 then return end

    local native_overlays = {}
    for _, m in ipairs(meshes) do
        pcall(function()
            local existing = m:GetOverlayMaterial()
            if existing and existing:IsValid() then
                native_overlays[m:GetAddress()] = existing
            end
        end)
    end

    local entry = {
        actor          = actor,
        tier           = tier,
        meshes         = meshes,
        nativeOverlays = native_overlays,
        isAimed        = false,
    }
    ActiveEnemies[addr] = entry

    if Config.Enabled then
        local mid = get_tier_mid(tier)
        for _, m in ipairs(meshes) do
            apply_highlight_to_mesh(m, mid)
        end
    end
end

local function unregister_enemy(addr)
    local entry = ActiveEnemies[addr]
    if not entry then return end

    for _, m in ipairs(entry.meshes) do
        remove_highlight_from_mesh(m, entry.nativeOverlays[m:GetAddress()])
    end

    ActiveEnemies[addr] = nil
end

local function is_enemy_alive(actor)
    if not actor or not actor:IsValid() then return false end

    -- Check Health property if present
    local ok_hp, hp = pcall(function() return actor.Health end)
    if ok_hp and hp and type(hp) == "number" and hp <= 0.0 then
        return false
    end

    -- Check bIsDead / isDead property if present
    local ok_dead, dead = pcall(function() return actor.bIsDead or actor.isDead end)
    if ok_dead and dead == true then
        return false
    end

    -- Check if hidden
    local ok_hidden, hidden = pcall(function() return actor:IsHidden() end)
    if ok_hidden and hidden == true then
        return false
    end

    return true
end

-- ==================== AIMED-PART OVERLAY RECOLORING ====================
-- Recolor existing native overlay material on an aimed part if one exists
local function recolor_native_overlay(overlay_mat)
    if not overlay_mat or not overlay_mat:IsValid() then return end
    apply_mid_parameters(overlay_mat, Config.AimedColor, Config.AimedIntensity, Config.FresnelExponent * 0.8, Config.InnerAlpha * 2.0)
end

local function update_aim_highlight()
    if not Config.Enabled or not Config.RecolorAimedPart then
        if CurrentAimedEnemyAddr then
            local prev = ActiveEnemies[CurrentAimedEnemyAddr]
            if prev then
                local tier_mid = get_tier_mid(prev.tier)
                for _, m in ipairs(prev.meshes) do
                    apply_highlight_to_mesh(m, tier_mid)
                end
                prev.isAimed = false
            end
            CurrentAimedEnemyAddr = nil
            CurrentAimedPartMesh = nil
        end
        return
    end

    local pc = UEHelpers.GetPlayerController()
    if not pc or not pc:IsValid() then return end

    local cam = pc.PlayerCameraManager
    if not cam or not cam:IsValid() then return end

    local math_lib = UEHelpers.GetKismetMathLibrary()
    local sys_lib  = UEHelpers.GetKismetSystemLibrary()
    if not math_lib or not sys_lib then return end

    -- Camera forward raycast along player crosshair
    local start_pos = cam:GetCameraLocation()
    local cam_rot   = cam:GetCameraRotation()
    local forward   = math_lib:GetForwardVector(cam_rot)
    local trace_dist = Config.MaxAimDistance or 20000.0
    local trace_delta = math_lib:Multiply_VectorFloat(forward, trace_dist)
    local end_pos   = math_lib:Add_VectorVector(start_pos, trace_delta)

    local player_pawn = pc.Pawn
    local hit_result = {}
    local actors_to_ignore = {}
    local dummy_color = { R = 0, G = 0, B = 0, A = 0 }

    -- Visibility channel (0 = TraceTypeQuery1)
    local was_hit = sys_lib:LineTraceSingle(
        player_pawn,
        start_pos,
        end_pos,
        0, -- ETraceTypeQuery_TraceTypeQuery1 (Visibility)
        false, -- bTraceComplex
        actors_to_ignore,
        0, -- EDrawDebugTrace_Type_None
        hit_result,
        true, -- bIgnoreSelf
        dummy_color,
        dummy_color,
        0.0
    )

    local aimed_enemy_addr = nil
    local aimed_part_mesh  = nil

    if was_hit then
        local hit_actor = UEHelpers.GetActorFromHitResult(hit_result)
        if hit_actor and hit_actor:IsValid() then
            local addr = tostring(hit_actor:GetAddress())
            if ActiveEnemies[addr] then
                aimed_enemy_addr = addr
                -- Component aimed at
                local ok_comp, comp = pcall(function()
                    return hit_result.HitComponent and hit_result.HitComponent:Get()
                end)
                if ok_comp and comp and comp:IsValid() then
                    aimed_part_mesh = comp
                end
            end
        end
    end

    -- Secondary native aim check: player pawn weapon's targetedEnemy
    if not aimed_enemy_addr and player_pawn and player_pawn:IsValid() then
        pcall(function()
            local target = player_pawn.targetedEnemy
            if target and target:IsValid() then
                local addr = tostring(target:GetAddress())
                if ActiveEnemies[addr] then
                    aimed_enemy_addr = addr
                end
            end
        end)
    end

    -- If aimed target changed, revert previous target to tier color
    if CurrentAimedEnemyAddr and CurrentAimedEnemyAddr ~= aimed_enemy_addr then
        local prev = ActiveEnemies[CurrentAimedEnemyAddr]
        if prev then
            local tier_mid = get_tier_mid(prev.tier)
            for _, m in ipairs(prev.meshes) do
                apply_highlight_to_mesh(m, tier_mid)
            end
            prev.isAimed = false
        end
        CurrentAimedEnemyAddr = nil
        CurrentAimedPartMesh  = nil
    end

    -- Apply Aimed Overlay to newly acquired target
    if aimed_enemy_addr then
        local current = ActiveEnemies[aimed_enemy_addr]
        if current then
            CurrentAimedEnemyAddr = aimed_enemy_addr
            current.isAimed = true

            local aimed_mid = MIDs.Aimed or MIDs.Regular

            if Config.AimedPartOnly and aimed_part_mesh then
                -- Highlight only the specific aimed limb / mesh component
                for _, m in ipairs(current.meshes) do
                    if m:GetAddress() == aimed_part_mesh:GetAddress() then
                        apply_highlight_to_mesh(m, aimed_mid)
                        -- Also recolor native weakspot overlay if present
                        local native_mat = current.nativeOverlays[m:GetAddress()]
                        if native_mat then recolor_native_overlay(native_mat) end
                    else
                        apply_highlight_to_mesh(m, get_tier_mid(current.tier))
                    end
                end
            else
                -- Highlight the entire aimed enemy
                for _, m in ipairs(current.meshes) do
                    apply_highlight_to_mesh(m, aimed_mid)
                    -- Also recolor native weakspot overlay if present
                    local native_mat = current.nativeOverlays[m:GetAddress()]
                    if native_mat then recolor_native_overlay(native_mat) end
                end
            end
        end
    end
end

-- ==================== PERIODIC SCAN & SWEEP ====================
local function scan_and_update_enemies()
    if not MIDs.Regular or not MIDs.Regular:IsValid() then
        refresh_all_materials()
    end

    -- 1. Scan for all enemy instances in the level
    local found_enemies = FindAllOf("BP_Enemy_C") or {}
    for _, enemy in ipairs(found_enemies) do
        if enemy and enemy:IsValid() then
            local ok_fn, name = pcall(function() return enemy:GetFullName() end)
            if ok_fn and name and not name:find("Default__", 1, true) then
                register_enemy(enemy)
            end
        end
    end

    -- 2. Sweep active enemies: prune dead, invalid, or out-of-distance enemies
    local pc = UEHelpers.GetPlayerController()
    local cam_loc = nil
    if pc and pc:IsValid() and pc.PlayerCameraManager and pc.PlayerCameraManager:IsValid() then
        cam_loc = pc.PlayerCameraManager:GetCameraLocation()
    end

    local math_lib = UEHelpers.GetKismetMathLibrary()
    local max_dist_sq = Config.MaxDistance > 0 and (Config.MaxDistance * Config.MaxDistance) or 0

    for addr, entry in pairs(ActiveEnemies) do
        local actor = entry.actor
        if not is_enemy_alive(actor) then
            unregister_enemy(addr)
        else
            -- Distance culling (if enabled)
            if max_dist_sq > 0 and cam_loc and math_lib then
                local ok_loc, loc = pcall(function() return actor:K2_GetActorLocation() end)
                if ok_loc and loc then
                    local dist_sq = math_lib:Vector_DistanceSquared(cam_loc, loc)
                    if dist_sq > max_dist_sq then
                        -- Out of range: temporarily clear overlay
                        for _, m in ipairs(entry.meshes) do
                            remove_highlight_from_mesh(m, entry.nativeOverlays[m:GetAddress()])
                        end
                    elseif Config.Enabled and not entry.isAimed then
                        -- Within range: ensure tier highlight is applied
                        local tier_mid = get_tier_mid(entry.tier)
                        for _, m in ipairs(entry.meshes) do
                            apply_highlight_to_mesh(m, tier_mid)
                        end
                    end
                end
            end
        end
    end
end

-- ==================== TOGGLE & RELOAD HANDLERS ====================
local function set_enabled(new_state)
    Config.Enabled = new_state
    LogInfo(string.format("Enemy Highlights %s.", Config.Enabled and "ENABLED" or "DISABLED"))

    if not Config.Enabled then
        for addr, entry in pairs(ActiveEnemies) do
            for _, m in ipairs(entry.meshes) do
                remove_highlight_from_mesh(m, entry.nativeOverlays[m:GetAddress()])
            end
        end
        CurrentAimedEnemyAddr = nil
        CurrentAimedPartMesh  = nil
    else
        refresh_all_materials()
        for addr, entry in pairs(ActiveEnemies) do
            local mid = get_tier_mid(entry.tier)
            for _, m in ipairs(entry.meshes) do
                apply_highlight_to_mesh(m, mid)
            end
        end
    end
end

local function toggle_mod()
    set_enabled(not Config.Enabled)
end

local function reload_config()
    load_config()
    refresh_all_materials()
    -- Reapply updated colors immediately
    for addr, entry in pairs(ActiveEnemies) do
        local mid = entry.isAimed and (MIDs.Aimed or MIDs.Regular) or get_tier_mid(entry.tier)
        for _, m in ipairs(entry.meshes) do
            apply_highlight_to_mesh(m, mid)
        end
    end
    LogInfo("Config reloaded and highlights updated.")
end

-- ==================== INITIALIZATION & HOOKS ====================
local function init_mod()
    LogInfo("Initializing EnemyHighlights...")

    -- Load configuration
    load_config()

    -- Map key strings to Key enum
    local toggle_key = Key[Config.ToggleKey] or Key.F8
    local reload_key = Key[Config.ReloadConfigKey] or Key.F7

    RegisterKeyBind(toggle_key, toggle_mod)
    RegisterKeyBind(reload_key, reload_config)
    LogInfo(string.format("Keybinds registered: [%s] Toggle, [%s] Reload Config", Config.ToggleKey, Config.ReloadConfigKey))

    -- Realtime notification on new enemy construction for instant zero-latency detection
    NotifyOnNewObject("/Game/Enemies/BP_Enemy.BP_Enemy_C", function(new_enemy)
        if new_enemy and new_enemy:IsValid() then
            local ok, name = pcall(function() return new_enemy:GetFullName() end)
            if ok and name and not name:find("Default__", 1, true) then
                register_enemy(new_enemy)
            end
        end
    end)

    -- Register map load hook to refresh materials on new levels
    RegisterLoadMapPostHook(function()
        LogInfo("Map loaded, resetting active enemy registry and refreshing materials...")
        ActiveEnemies = {}
        CurrentAimedEnemyAddr = nil
        CurrentAimedPartMesh = nil
        CachedBaseMaterial = nil
        refresh_all_materials()
    end)

    -- Fast Loop: Aim tracking and aimed-part overlay recoloring (~40-50 FPS)
    LoopAsync(Config.AimUpdateIntervalMs or 25, function()
        update_aim_highlight()
        return false -- keep looping
    end)

    -- Slow Loop: Periodic sweep for streaming levels, distance culling, and dead enemy purge
    LoopAsync(Config.ScanIntervalMs or 250, function()
        scan_and_update_enemies()
        return false -- keep looping
    end)

    LogInfo("EnemyHighlights initialized and active! Ready to hunt.")
end

-- Run initialization
init_mod()
