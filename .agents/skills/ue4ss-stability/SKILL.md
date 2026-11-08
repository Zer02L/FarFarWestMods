---
name: ue4ss-stability
description: Mandatory rules and guidelines for developing and debugging UE4SS Lua mods without memory leaks, deadlocks, and crashes in Unreal Engine.
---

# UE4SS Stability & Modding Guidelines

This skill provides essential guidelines for writing robust, thread-safe, and leak-free Lua mods for Unreal Engine games using UE4SS (specifically Far Far West).

## Critical Anti-Patterns ("Как делать нельзя")

1. **Never call Unreal Engine functions or access UObjects from async threads (`LoopAsync`, `ExecuteAsync`)**
   - Unreal Engine physics, actors, and rendering are not thread-safe. Calls to `LineTraceSingle`, `FindAllOf`, `SetOverlayMaterial`, etc. from async threads cause data races, DX12 render stalls, and crashes.
   - Always execute game code on the **GameThread** via `LoopInGameThreadWithDelay(ms, callback)` or `ExecuteInGameThread(callback)`.

2. **Never access Lua state concurrently across multiple threads**
   - Multi-threaded execution in `lua_State` corrupts the Lua registry (`Error: [Lua::Registry::get_function_ref] Ref was not function`), leading to `0xc0000005` access violation crashes.
   - Run periodic timers exclusively on GameThread. `RegisterKeyBind` handlers should only update atomic primitive values.

3. **Always wrap `obj:IsValid()` in `pcall`**
   ```lua
   local function isValid(obj)
       if obj == nil then return false end
       local ok, res = pcall(function() return obj:IsValid() end)
       return ok and res == true
   end
   ```
   Calling methods directly on dangling/garbage-collected pointers crashes immediately (segmentation fault).

4. **Never confuse UFunction parameter names with UStruct member fields (`convert_lua_table_to_struct`)**
   - UE4SS converts Lua tables to UStruct parameters by matching keys against the **C++ reflected fields of the struct itself**, NOT the function parameter name.
   - Unrecognized table keys are **silently ignored** without error!
   - *Example:* For `APlayerController::IsInputKeyDown(Key)`, the parameter is named `Key`, but the struct `FKey` has only one member field: **`KeyName`** (FName). Calling `pc:IsInputKeyDown({ Key = FName("SpaceBar") })` silently passes an empty default key (`None`) and always returns `false` while `pcall` succeeds (`ok == true`).
   - *Fix:* Always pass `{ KeyName = FName("SpaceBar") }`. Similarly, `FVector` requires `{ X=..., Y=..., Z=... }`, `FRotator` requires `{ Pitch=..., Yaw=..., Roll=... }`, `FLinearColor` requires `{ R=..., G=..., B=..., A=... }`.

5. **Never rely on `RegisterKeyBind` for continuous hold actions (Bhop / Dash hold)**
   - `RegisterKeyBind` is edge-triggered (press event), not level-triggered (continuous hold). Time-window heuristics fail between jumps/dashes.
   - For hold actions, poll `PlayerController:IsInputKeyDown({ KeyName = FName(...) })` synchronously in the GameThread loop.
   - Add a watchdog self-check and a one-shot log of the first poll result in `UE4SS.log`.

6. **Never run blind multi-variant probes if invalid variants are accepted silently**
   - Because UE4SS silently ignores mismatched struct fields, a wrong variant can return `ok == true` and get selected as a "working" signature while being completely dead.
   - Probe specific signatures explicitly, verify actual return values or side effects, and fail into an explicit `disabled`/`suspended` state with a descriptive log message instead of silently returning false.
   - Cache signature probes once on initialization.

7. **Never manipulate actor components immediately inside `NotifyOnNewObject`**
   - Defer registration with `ExecuteInGameThreadWithDelay(150, callback)` so the actor finishes construction and `BeginPlay`.

8. **Do not create Dynamic Material Instances (`CreateDynamicMaterialInstance`) every tick**
   - Cache DMI instances once upon map load and reuse them across meshes to prevent out-of-memory crashes and GC hitching.

9. **Always disable distance culling for overlay materials**
   - Unreal Engine's `SetOverlayMaterial` is subject to distance culling (`OverlayMaterialMaxDrawDistance`), which can cause highlights to disappear when moving away.
   - Disable culling explicitly: `mesh:SetOverlayMaterialMaxDrawDistance(0.0)`.

10. **Throttle or avoid spamming `ExecuteInGameThread`**
    - High-frequency queues without throttling overflow the GameThread queue during low-FPS moments. Use `LoopInGameThreadWithDelay` or busy flags.

11. **Native DLLs in `Mods/<ModName>/dlls/main.dll` are loaded unconditionally!**
    - UE4SS loads native DLLs even if the mod is set to `0` (disabled) in `mods.txt`.
    - To truly disable a native DLL, rename it (e.g. `main.dll.disabled`) or delete it.

12. **Clear object tables on map transitions**
    - In `RegisterLoadMapPostHook`, wipe tracking tables (`ActiveEnemies = {}`) and cached player/pawn references to prevent memory leaks and use-after-free bugs.

13. **Synchronize repository and game directories & check syntax**
    - Always deploy changes from `/home/zerg/Projects/FarFarWestMods/` to `/mnt/steam/steamapps/common/FarFarWest/FarFarWest/Binaries/Win64/ue4ss/Mods/`.
    - Validate Lua syntax using `bun x luaparse <file>` before testing in-game.

14. **Conventional Commits & Shell Escaping**
    - Follow `type(scope): description` for git commits (enforced by pre-commit hook).
    - Wrap commit messages in single quotes `'...'` to prevent bash from executing backtick expressions.
