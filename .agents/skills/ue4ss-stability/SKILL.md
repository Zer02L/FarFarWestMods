---
name: ue4ss-stability
description: Mandatory rules and guidelines for developing and debugging UE4SS Lua mods without memory leaks, deadlocks, and crashes in Unreal Engine.
---

# UE4SS Stability & Memory Safety Rules

This skill provides essential guidelines for writing robust, thread-safe, and leak-free Lua mods for Unreal Engine games using UE4SS (specifically Far Far West).

## Critical Anti-Patterns ("Как делать нельзя")

1. **Never call Unreal Engine functions or access UObjects from async threads**
   - Do NOT use `LoopAsync` or `ExecuteAsync` for calling `LineTraceSingle`, `FindAllOf`, `SetOverlayMaterial`, etc.
   - Use `LoopInGameThreadWithDelay(ms, callback)` or `ExecuteInGameThread(callback)`.

2. **Never access Lua state concurrently across multiple threads**
   - Multi-threaded execution in `lua_State` corrupts the Lua registry (`Ref was not function`), resulting in `0xc0000005` access violation crashes.
   - Run periodic timers exclusively on the GameThread. Keybind callbacks should only update atomic primitive values.

3. **Always wrap `obj:IsValid()` in `pcall`**
   ```lua
   local function isValid(obj)
       if obj == nil then return false end
       local ok, res = pcall(function() return obj:IsValid() end)
       return ok and res == true
   end
   ```
   Calling methods on dangling/garbage-collected pointers crashes the game immediately.

4. **Never manipulate actor components immediately inside `NotifyOnNewObject`**
   - Defer registration with `ExecuteInGameThreadWithDelay(150, callback)` so that the actor finishes spawning and `BeginPlay`.

5. **Do not create Dynamic Material Instances (`CreateDynamicMaterialInstance`) every tick**
   - Cache DMI instances once upon map load, and reuse them across all meshes.

6. **Clear object tables on map transitions**
   - In `RegisterLoadMapPostHook`, wipe tracking tables (`ActiveEnemies = {}`) and cached player/pawn references to prevent memory leaks and use-after-free bugs.

7. **Synchronize repository and game directories**
   - Always deploy changes from `/home/zerg/Projects/FarFarWestMods/` to `/mnt/steam/steamapps/common/FarFarWest/FarFarWest/Binaries/Win64/ue4ss/Mods/`.
