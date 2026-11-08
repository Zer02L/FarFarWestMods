-- ==============================================================================
-- EnemyHighlights v1.0.2
-- Warframe-style Fresnel Rim Glow on Enemies (Client-Side, Depth-Tested)
--
-- Features:
--   - Warframe-style Fresnel rim glow highlighting enemy silhouettes
--   - 100% Client-side & Depth-tested (GPU hardware Z-buffer test, NO wallhack)
--   - Fully configurable colors (RGB/Hex) and intensity per tier (Regular, Elite, Boss)
--   - Aimed-part & target acquisition overlay: dynamically recolors aimed enemy or
--     aimed body part / weakspot under your crosshair for instant visual feedback
--   - Live configuration reload (F7) and instant toggle (F8) without restarting
--   - v1.0.2: Universal Character/Pawn scanning and native NotifyOnNewObject hook
--     covering all game enemy subclasses (BP_Enemy_*), with TArray compatibility.
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
    ScanIntervalMs      = 350,
    AimUpdateIntervalMs = 30,
}

-- ==================== LOGGING & UTILS ====================
local function LogInfo(msg)
    print(string.format("[%s] %s", MOD_NAME, msg))
end

local function LogWarn(msg)
    print(string.format("[%s] [WARN] %s", MOD_NAME, msg))
end

local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- ==================== CONFIG PARSER ====================
local function trim(s)
    if not s then return "" end
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
        f = io.open("Mods/EnemyHighlights/config.ini", "r")
    end
    if not f then
        LogWarn(string.format("Config file '%s' not found, using built-in defaults.", CONFIG_FILE))
        return
    end

    local raw = f:read("*a")
    f:close()

    for line in raw:gmatch("[^\r\n]+") do
        line = trim(line)
        if line ~= "" and not line:match("^[;#]") and not line:match("^%[") then
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

    LogInfo(string.format("Configuration loaded. Enabled=%s, Intensity=%.1f, AimedIntensity=%.1f",
        tostring(Config.Enabled), Config.IntensityMultiplier, Config.AimedIntensity))
end

-- ==================== MATERIAL & SHADER MANAGER ====================
local MATERIAL_CANDIDATES = {
    "/Game/FX/Materials/Element_Cryptic/M_FX_Cryptic_OrbShield_Translucent.M_FX_Cryptic_OrbShield_Translucent",
    "/Game/FX/Materials/M_FX_GlowLight.M_FX_GlowLight",
    "/Game/Materials/M_Translucent_Orange.M_Translucent_Orange",
    "/Game/Materials/M_Translucent.M_Translucent",
    "/Engine/EngineDebugMaterials/M_SimpleUnlitTranslucent.M_SimpleUnlitTranslucent",
}

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
    if isValid(CachedBaseMaterial) then
        return CachedBaseMaterial
    end

    for _, path in ipairs(MATERIAL_CANDIDATES) do
        local ok, mat = pcall(StaticFindObject, path)
        if ok and isValid(mat) then
            CachedBaseMaterial = mat
            LogInfo(string.format("Found base highlight material: %s", path))
            return CachedBaseMaterial
        end
    end

    return nil
end

local function apply_mid_parameters(mid, linear_color, intensity, exponent, alpha)
    if not isValid(mid) then return end

    local scaled_color = {
        R = linear_color.R * intensity,
        G = linear_color.G * intensity,
        B = linear_color.B * intensity,
        A = linear_color.A,
    }

    for _, param in ipairs(VECTOR_PARAM_NAMES) do
        pcall(function()
            mid:SetVectorParameterValue(UEHelpers.FindOrAddFName(param), scaled_color)
        end)
    end

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
    if not isValid(parent_mat) then return nil end

    local kml = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local world_ctx = UEHelpers.GetWorldContextObject()

    if isValid(kml) and isValid(world_ctx) then
        -- In UE 5.3+, CreateDynamicMaterialInstance takes 4 parameters:
        -- (WorldContextObject, Parent, OptionalName, CreationFlags)
        local ok, dyn_mat = pcall(function()
            return kml:CreateDynamicMaterialInstance(world_ctx, parent_mat, UEHelpers.FindOrAddFName(name_str), 0)
        end)
        if ok and isValid(dyn_mat) then
            return dyn_mat
        end

        -- Fallback: 3 parameters for older engine versions
        ok, dyn_mat = pcall(function()
            return kml:CreateDynamicMaterialInstance(world_ctx, parent_mat, UEHelpers.FindOrAddFName(name_str))
        end)
        if ok and isValid(dyn_mat) then
            return dyn_mat
        end

        -- Fallback: 2 parameters
        ok, dyn_mat = pcall(function()
            return kml:CreateDynamicMaterialInstance(world_ctx, parent_mat)
        end)
        if ok and isValid(dyn_mat) then
            return dyn_mat
        end
    end

    LogWarn(string.format("Could not create dynamic material instance for '%s', using base material fallback.", name_str))
    return parent_mat
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

local function is_enemy_actor(actor)
    if not isValid(actor) then return false end

    local ok_fn, full_name = pcall(function() return actor:GetFullName() end)
    if not ok_fn or not full_name then return false end

    -- Filter out Class Default Objects
    if full_name:find("Default__", 1, true) then return false end

    -- Filter out player
    if full_name:find("BP_Player", 1, true) or full_name:find("Player", 1, true) then
        return false
    end

    -- Filter out friendly NPCs
    if full_name:find("BP_NPC", 1, true) then
        return false
    end

    -- All enemies in Far Far West start with BP_Enemy (e.g. BP_Enemy_Cryptic_Grunt_C)
    if full_name:find("BP_Enemy", 1, true) then
        -- Exclude non-character entities such as projectiles and proxies
        if full_name:find("Projectile", 1, true)
            or full_name:find("Proxy", 1, true)
            or full_name:find("Spawner", 1, true) then
            return false
        end
        return true
    end

    return false
end

local function collect_actor_meshes(actor)
    local meshes = {}
    local seen = {}

    -- Primary Character SkeletalMesh
    local ok_mesh, char_mesh = pcall(function() return actor.Mesh end)
    if ok_mesh and isValid(char_mesh) then
        table.insert(meshes, char_mesh)
        pcall(function() seen[tostring(char_mesh:GetAddress())] = true end)
    end

    -- Also check RootComponent in case actor has mesh as RootComponent
    pcall(function()
        local root = actor.RootComponent
        if isValid(root) then
            local ok_sm, is_sm = pcall(function() return root:IsA(StaticFindObject("/Script/Engine.MeshComponent")) end)
            if ok_sm and is_sm then
                local addr = tostring(root:GetAddress())
                if not seen[addr] then
                    table.insert(meshes, root)
                    seen[addr] = true
                end
            end
        end
    end)

    -- Query any attached MeshComponents (shields, armor, weakpoint parts)
    pcall(function()
        local static_mesh_class = StaticFindObject("/Script/Engine.MeshComponent")
        if isValid(static_mesh_class) then
            local comps = actor:K2_GetComponentsByClass(static_mesh_class)
            if comps then
                if comps.ForEach then
                    comps:ForEach(function(index, elem)
                        local comp = elem and elem:get()
                        if isValid(comp) then
                            local ok_addr, addr_str = pcall(function() return tostring(comp:GetAddress()) end)
                            if ok_addr and addr_str and not seen[addr_str] then
                                local is_visible = true
                                pcall(function() is_visible = comp:IsVisible() end)
                                if is_visible then
                                    table.insert(meshes, comp)
                                    seen[addr_str] = true
                                end
                            end
                        end
                    end)
                else
                    for i = 1, #comps do
                        local comp = comps[i]
                        if isValid(comp) then
                            local ok_addr, addr_str = pcall(function() return tostring(comp:GetAddress()) end)
                            if ok_addr and addr_str and not seen[addr_str] then
                                local is_visible = true
                                pcall(function() is_visible = comp:IsVisible() end)
                                if is_visible then
                                    table.insert(meshes, comp)
                                    seen[addr_str] = true
                                end
                            end
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
    if not isValid(mesh) or not isValid(mid) then return end
    -- UE 5.1+ UMeshComponent::SetOverlayMaterial requires 3 parameters:
    -- (NewOverlayMaterial, bSetMaterialSlot, SlotIndex)
    local ok, err = pcall(function()
        mesh:SetOverlayMaterial(mid, false, 0)
    end)
    if not ok then
        -- Fallback for older engine versions with 1 parameter
        ok, err = pcall(function()
            mesh:SetOverlayMaterial(mid)
        end)
    end
    if not ok then
        -- Direct UProperty assignment fallback
        pcall(function()
            mesh.OverlayMaterial = mid
        end)
        LogWarn(string.format("Failed to SetOverlayMaterial on mesh: %s", tostring(err)))
    end
end

local function remove_highlight_from_mesh(mesh, original_native_overlay)
    if not isValid(mesh) then return end
    local ok = pcall(function()
        mesh:SetOverlayMaterial(original_native_overlay or nil, false, 0)
    end)
    if not ok then
        ok = pcall(function()
            mesh:SetOverlayMaterial(original_native_overlay or nil)
        end)
    end
    if not ok and original_native_overlay == nil then
        pcall(function()
            mesh.OverlayMaterial = nil
        end)
    end
end

local function register_enemy(actor)
    if not isValid(actor) then return end
    local ok_addr, addr = pcall(function() return tostring(actor:GetAddress()) end)
    if not ok_addr or not addr or ActiveEnemies[addr] then return end

    local tier = get_enemy_tier(actor)
    local meshes = collect_actor_meshes(actor)
    if #meshes == 0 then return end

    local native_overlays = {}
    for _, m in ipairs(meshes) do
        if isValid(m) then
            pcall(function()
                local existing = m:GetOverlayMaterial()
                if isValid(existing) then
                    native_overlays[tostring(m:GetAddress())] = existing
                end
            end)
        end
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

    LogInfo(string.format("Enemy registered: %s (Tier: %s, Meshes: %d)", actor:GetFullName(), tier, #meshes))
end

local function unregister_enemy(addr)
    local entry = ActiveEnemies[addr]
    if not entry then return end

    if entry.meshes then
        for _, m in ipairs(entry.meshes) do
            if isValid(m) then
                local native = nil
                if entry.nativeOverlays then
                    local ok_maddr, maddr = pcall(function() return tostring(m:GetAddress()) end)
                    if ok_maddr and maddr then
                        native = entry.nativeOverlays[maddr]
                    end
                end
                remove_highlight_from_mesh(m, native)
            end
        end
    end

    ActiveEnemies[addr] = nil
end

local function is_enemy_alive(actor)
    if not isValid(actor) then return false end

    -- Check if being destroyed
    local ok_dest, being_destroyed = pcall(function() return actor:IsActorBeingDestroyed() end)
    if ok_dest and being_destroyed then
        return false
    end

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
local function recolor_native_overlay(overlay_mat)
    if not isValid(overlay_mat) then return end
    apply_mid_parameters(overlay_mat, Config.AimedColor, Config.AimedIntensity, Config.FresnelExponent * 0.8, Config.InnerAlpha * 2.0)
end

local function update_aim_highlight()
    if not Config.Enabled or not Config.RecolorAimedPart then
        if CurrentAimedEnemyAddr then
            local prev = ActiveEnemies[CurrentAimedEnemyAddr]
            if prev then
                local tier_mid = get_tier_mid(prev.tier)
                for _, m in ipairs(prev.meshes or {}) do
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
    if not isValid(pc) then return end

    local cam = pc.PlayerCameraManager
    if not isValid(cam) then return end

    local math_lib = UEHelpers.GetKismetMathLibrary()
    local sys_lib  = UEHelpers.GetKismetSystemLibrary()
    if not isValid(math_lib) or not isValid(sys_lib) then return end

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
    local was_hit = false
    pcall(function()
        was_hit = sys_lib:LineTraceSingle(
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
    end)

    local aimed_enemy_addr = nil
    local aimed_part_mesh  = nil

    if was_hit then
        local hit_actor = nil
        pcall(function() hit_actor = UEHelpers.GetActorFromHitResult(hit_result) end)
        if isValid(hit_actor) then
            local addr = tostring(hit_actor:GetAddress())
            if ActiveEnemies[addr] then
                aimed_enemy_addr = addr
                local ok_comp, comp = pcall(function()
                    return hit_result.HitComponent and hit_result.HitComponent:Get()
                end)
                if ok_comp and isValid(comp) then
                    aimed_part_mesh = comp
                end
            end
        end
    end

    -- Secondary native aim check: player pawn weapon's targetedEnemy
    if not aimed_enemy_addr and isValid(player_pawn) then
        pcall(function()
            local target = player_pawn.targetedEnemy
            if isValid(target) then
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
            for _, m in ipairs(prev.meshes or {}) do
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
                local aimed_addr = tostring(aimed_part_mesh:GetAddress())
                for _, m in ipairs(current.meshes or {}) do
                    if isValid(m) then
                        local maddr = tostring(m:GetAddress())
                        if maddr == aimed_addr then
                            apply_highlight_to_mesh(m, aimed_mid)
                            local native_mat = current.nativeOverlays and current.nativeOverlays[maddr]
                            if native_mat then recolor_native_overlay(native_mat) end
                        else
                            apply_highlight_to_mesh(m, get_tier_mid(current.tier))
                        end
                    end
                end
            else
                for _, m in ipairs(current.meshes or {}) do
                    if isValid(m) then
                        local maddr = tostring(m:GetAddress())
                        apply_highlight_to_mesh(m, aimed_mid)
                        local native_mat = current.nativeOverlays and current.nativeOverlays[maddr]
                        if native_mat then recolor_native_overlay(native_mat) end
                    end
                end
            end
        end
    end
end

-- ==================== PERIODIC SCAN & SWEEP ====================
local function scan_and_update_enemies()
    if not isValid(MIDs.Regular) then
        refresh_all_materials()
    end

    -- 1. Scan for all enemy instances in the level (Characters and Pawns)
    local candidates = {}
    local seen_cand = {}

    local function add_candidates(list)
        if not list then return end
        for _, obj in ipairs(list) do
            if isValid(obj) then
                local ok_a, a = pcall(function() return tostring(obj:GetAddress()) end)
                if ok_a and a and not seen_cand[a] then
                    seen_cand[a] = true
                    table.insert(candidates, obj)
                end
            end
        end
    end

    local ok_chars, chars = pcall(function() return FindAllOf("Character") end)
    if ok_chars and chars then add_candidates(chars) end

    local ok_pawns, pawns = pcall(function() return FindAllOf("Pawn") end)
    if ok_pawns and pawns then add_candidates(pawns) end

    for _, cand in ipairs(candidates) do
        if is_enemy_actor(cand) then
            register_enemy(cand)
        end
    end

    -- 2. Sweep active enemies: prune dead, invalid, or out-of-distance enemies
    local pc = UEHelpers.GetPlayerController()
    local cam_loc = nil
    if isValid(pc) and isValid(pc.PlayerCameraManager) then
        pcall(function() cam_loc = pc.PlayerCameraManager:GetCameraLocation() end)
    end

    local math_lib = UEHelpers.GetKismetMathLibrary()
    local max_dist_sq = Config.MaxDistance > 0 and (Config.MaxDistance * Config.MaxDistance) or 0

    for addr, entry in pairs(ActiveEnemies) do
        local actor = entry.actor
        if not is_enemy_alive(actor) then
            unregister_enemy(addr)
        else
            -- Check distance if camera is available and max distance is configured
            local in_range = true
            if max_dist_sq > 0 and cam_loc and isValid(math_lib) then
                local ok_loc, loc = pcall(function() return actor:K2_GetActorLocation() end)
                if ok_loc and loc then
                    local ok_dist, dist_sq = pcall(function() return math_lib:Vector_DistanceSquared(cam_loc, loc) end)
                    if ok_dist and dist_sq and dist_sq > max_dist_sq then
                        in_range = false
                    end
                end
            end

            if not in_range then
                -- Out of range: temporarily clear overlay
                for _, m in ipairs(entry.meshes or {}) do
                    if isValid(m) then
                        local native = entry.nativeOverlays and entry.nativeOverlays[tostring(m:GetAddress())]
                        remove_highlight_from_mesh(m, native)
                    end
                end
            elseif Config.Enabled and not entry.isAimed then
                -- Within range: ensure tier highlight is applied
                local tier_mid = get_tier_mid(entry.tier)
                for _, m in ipairs(entry.meshes or {}) do
                    if isValid(m) then
                        apply_highlight_to_mesh(m, tier_mid)
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
            for _, m in ipairs(entry.meshes or {}) do
                if isValid(m) then
                    local native = entry.nativeOverlays and entry.nativeOverlays[tostring(m:GetAddress())]
                    remove_highlight_from_mesh(m, native)
                end
            end
        end
        CurrentAimedEnemyAddr = nil
        CurrentAimedPartMesh  = nil
    else
        refresh_all_materials()
        for addr, entry in pairs(ActiveEnemies) do
            local mid = get_tier_mid(entry.tier)
            for _, m in ipairs(entry.meshes or {}) do
                if isValid(m) then
                    apply_highlight_to_mesh(m, mid)
                end
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
        for _, m in ipairs(entry.meshes or {}) do
            if isValid(m) then
                apply_highlight_to_mesh(m, mid)
            end
        end
    end
    LogInfo("Config reloaded and highlights updated.")
end

-- ==================== INITIALIZATION & HOOKS ====================
local function init_mod()
    LogInfo("Initializing EnemyHighlights v1.0.2 (GameThread Synchronized)...")

    -- Load configuration
    load_config()

    -- Map key strings to Key enum
    local toggle_key = Key[Config.ToggleKey] or Key.F8
    local reload_key = Key[Config.ReloadConfigKey] or Key.F7

    RegisterKeyBind(toggle_key, toggle_mod)
    RegisterKeyBind(reload_key, reload_config)
    LogInfo(string.format("Keybinds registered: [%s] Toggle, [%s] Reload Config", Config.ToggleKey, Config.ReloadConfigKey))

    -- Native Character construction hook for zero-latency detection
    NotifyOnNewObject("/Script/Engine.Character", function(new_char)
        if isValid(new_char) then
            if ExecuteInGameThreadWithDelay then
                ExecuteInGameThreadWithDelay(150, function()
                    if isValid(new_char) and is_enemy_actor(new_char) then
                        pcall(function() register_enemy(new_char) end)
                    end
                end)
            else
                ExecuteInGameThread(function()
                    if isValid(new_char) and is_enemy_actor(new_char) then
                        pcall(function() register_enemy(new_char) end)
                    end
                end)
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
        if ExecuteInGameThreadWithDelay then
            ExecuteInGameThreadWithDelay(200, function()
                pcall(refresh_all_materials)
            end)
        else
            pcall(refresh_all_materials)
        end
    end)

    -- GameThread native loops (NO background thread race conditions, NO Lua state corruption)
    if LoopInGameThreadWithDelay then
        LoopInGameThreadWithDelay(Config.AimUpdateIntervalMs or 30, function()
            pcall(update_aim_highlight)
        end)
        LoopInGameThreadWithDelay(Config.ScanIntervalMs or 350, function()
            pcall(scan_and_update_enemies)
        end)
    else
        LoopAsync(Config.AimUpdateIntervalMs or 30, function()
            ExecuteInGameThread(function() pcall(update_aim_highlight) end)
            return false
        end)
        LoopAsync(Config.ScanIntervalMs or 350, function()
            ExecuteInGameThread(function() pcall(scan_and_update_enemies) end)
            return false
        end)
    end

    LogInfo("EnemyHighlights v1.0.2 initialized and active! Ready to hunt.")
end

-- Run initialization
init_mod()
