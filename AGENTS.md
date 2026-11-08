# Rules for AI Agents: UE4SS Lua Modding & Stability Guidelines

These rules are mandatory for any AI agent creating, editing, or debugging UE4SS Lua mods for **Far Far West** (and any Unreal Engine 4/5 game using UE4SS). Violating these rules causes game freezes, memory corruption, memory leaks, and fatal crashes (`0xc0000005 EXCEPTION_ACCESS_VIOLATION`).

---

## 🚫 Critical Anti-Patterns ("КАК ДЕЛАТЬ НЕЛЬЗЯ")

### 1. НЕЛЬЗЯ вызывать функции движка и актеров из асинхронных потоков (`LoopAsync`, `ExecuteAsync`)
* **Почему:** Unreal Engine (физическая сцена, `GUObjectArray`, `KismetSystemLibrary`, `APlayerController`, `USkeletalMeshComponent`) **НЕ является потокобезопасным**. Вызов `LineTraceSingle`, `FindAllOf`, `SetOverlayMaterial`, `GetCameraLocation` из фонового потока приводит к гонке данных (Data Race), зависанию цикла отрисовки DirectX 12 и падению движка.
* **Как правильно:** Все операции с актерами, физикой, интерфейсом и материалами должны выполняться **строго в основном игровом потоке (GameThread)** с помощью `LoopInGameThreadWithDelay(ms, callback)` или `ExecuteInGameThread(callback)`.

### 2. НЕЛЬЗЯ выполнять параллельный доступ к Lua-стеку из нескольких потоков
* **Почему:** Встроенное состояние Lua (`lua_State`) в UE4SS не защищено мьютексами. Если запустить несколько `LoopAsync` параллельно с GameThread и хуками клавиш, повреждается таблица реестра функций Lua. В логе появляется:
  `Error: [Lua::Registry::get_function_ref] Ref was not function`, после чего происходит падение с кодом `0xc0000005`.
* **Как правильно:** Используйте только один способ периодического выполнения — нативный `LoopInGameThreadWithDelay`. Обработчики клавиш `RegisterKeyBind` должны только выставлять примитивные флаги (`lastPressTime = os.clock()`), не выполняя тяжелой логики.

### 3. НЕЛЬЗЯ хранить прямые ссылки на UObject без очистки и защиты `pcall` (Dangling Pointers & Memory Leaks)
* **Почему:** В Unreal Engine актеры погибают, уничтожаются или собираются сборщиком мусора (GC). Хранение ссылок на старые `AActor` или `UMeshComponent` в глобальных таблицах Lua приводит к:
  - Утечке памяти (объекты не выгружаются из таблиц мода).
  - Вылету при обращении к мертвому объекту (`Use-After-Free`).
* **Как правильно:**
  1. Всегда проверять валидность объектов через защищенную функцию с `pcall`:
     ```lua
     local function isValid(obj)
         if obj == nil then return false end
         local ok, res = pcall(function() return obj:IsValid() end)
         return ok and res == true
     end
     ```
  2. Никогда не вызывать `obj:IsValid()` напрямую без `pcall`, так как вызов метода у битого указателя сам по себе вызывает segmentation fault.
  3. Регулярно очищать таблицы от неживых врагов/актеров (`ActiveEnemies[addr] = nil`).
  4. При смене карты (`RegisterLoadMapPostHook`) **обязательно полностью очищать** все кэши (`ActiveEnemies = {}`, `cachedPawn = nil`, `cachedPC = nil`).

### 4. НЕЛЬЗЯ трогать компоненты и материалы актера внутри `NotifyOnNewObject`
* **Почему:** `NotifyOnNewObject` срабатывает в момент работы конструктора объекта (`StaticConstructObject_Internal`), когда актер еще не закончил инициализацию: компоненты не зарегистрированы, свойства не выставлены, `BeginPlay` не сработал.
* **Как правильно:** Откладывайте регистрацию на 100–200 мс с помощью `ExecuteInGameThreadWithDelay`:
  ```lua
  NotifyOnNewObject("/Game/Enemies/BP_Enemy.BP_Enemy_C", function(new_enemy)
      if isValid(new_enemy) then
          ExecuteInGameThreadWithDelay(150, function()
              if isValid(new_enemy) then
                  register_enemy(new_enemy)
              end
          end)
      end
  end)
  ```

### 5. НЕЛЬЗЯ создавать Dynamic Material Instances (`CreateDynamicMaterialInstance`) в тике
* **Почему:** Каждый вызов `CreateDynamicMaterialInstance` выделяет новый UObject в памяти движка. Создание материалов каждый кадр или секунду быстро забивает память, приводит к микрофризам GC и падению по нехватке памяти (OOM).
* **Как правильно:** Создавать материал **один раз** при загрузке карты/инициализации мода, кэшировать его в таблице `MIDs` и применять один и тот же инстанс ко всем мешам.

### 6. НЕЛЬЗЯ спамить `ExecuteInGameThread` без троттлинга
* **Почему:** Если быстрый таймер (например, каждые 5-10 мс) ставит задачи в очередь `ExecuteInGameThread`, а игра просела по FPS, очередь переполняется, вызывая огромные задержки и зависания.
* **Как правильно:** Использовать флаги занятости (`gameTickQueued`) или переходить на `LoopInGameThreadWithDelay`, который сам управляет интервалом между вызовами.

### 7. НЕЛЬЗЯ забывать синхронизировать изменения между репозиторием и папкой игры
* **Почему:** Репозиторий находится в `~/Projects/FarFarWestMods/`, а игра читает моды из `/mnt/steam/steamapps/common/FarFarWest/FarFarWest/Binaries/Win64/ue4ss/Mods/`. Редактирование только одного места приводит к рассинхронизации.
* **Как правильно:** Всегда обновлять оба расположения и проверять синтаксис Lua (`bun x luaparse`) перед запуском.

---

## ✅ Золотой стандарт реализации мода UE4SS

```lua
local UEHelpers = require("UEHelpers")

-- 1. Безопасная проверка UObject
local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- 2. Очистка кэша при смене уровней
RegisterLoadMapPostHook(function()
    cachedPlayer = nil
    cachedWorld = nil
    activeTrackedObjects = {}
end)

-- 3. Безопасный цикл в GameThread
if LoopInGameThreadWithDelay then
    LoopInGameThreadWithDelay(50, function()
        pcall(myTickFunction)
    end)
else
    -- Резервный фолбэк для старых версий
    LoopAsync(50, function()
        ExecuteInGameThread(function()
            pcall(myTickFunction)
        end)
        return false
    end)
end
```
