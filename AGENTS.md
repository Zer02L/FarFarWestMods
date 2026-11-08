# Rules for AI Agents: UE4SS Lua Modding & Stability Guidelines

These rules are mandatory for any AI agent creating, editing, or debugging UE4SS Lua mods for **Far Far West** (and any Unreal Engine 4/5 game using UE4SS). Violating these rules causes game freezes, silent logic failures, memory corruption, memory leaks, and fatal crashes (`0xc0000005 EXCEPTION_ACCESS_VIOLATION`).

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

### 4. НЕЛЬЗЯ путать имена параметров UFunction с именами полей структуры (`convert_lua_table_to_struct`)
* **Почему:** В UE4SS при передаче таблицы Lua в качестве UStruct-аргумента (`convert_lua_table_to_struct` в `LuaUObject.cpp`) маппинг полей происходит **по именам отражённых полей самой структуры (UStruct)**, а **НЕ** по имени параметра в сигнатуре функции!
  - Неизвестные ключи таблицы **молча игнорируются** движком без ошибки Lua и без предупреждения в лог.
  - *Классическая ошибка:* в `APlayerController::IsInputKeyDown(Key)` имя параметра — `Key`, но тип параметра — `struct FKey`. У `FKey` единственное отражённое поле называется **`KeyName`** (тип `FName`). Передача `{ Key = FName("SpaceBar") }` молча игнорируется: игра получает пустой ключ `None`, функция всегда возвращает `false`, а `pcall` завершается с успехом (`ok == true`).
* **Как правильно:** Передавать поля строго в соответствии с именами членов C++ структуры:
  ```lua
  -- Для FKey (единственное поле KeyName):
  pc:IsInputKeyDown({ KeyName = FName("SpaceBar") })

  -- Для FVector:
  { X = 0.0, Y = 0.0, Z = 100.0 }

  -- Для FRotator:
  { Pitch = 0.0, Yaw = 90.0, Roll = 0.0 }

  -- Для FLinearColor:
  { R = 1.0, G = 0.5, B = 0.0, A = 1.0 }
  ```

### 5. НЕЛЬЗЯ полагаться на `RegisterKeyBind` для удержания клавиш (Hold-действий)
* **Почему:** `RegisterKeyBind` в UE4SS является **edge-triggered** (событие физического нажатия), а не level-triggered (состояние зажатия). Эвристики «временных окон» (`now - lastPress < threshold`) неизбежно сбоят при длительных прыжках/дэшах: в момент приземления окно истекает (`spaceHeld == false`), и распрыжка прерывается.
* **Как правильно:**
  - Для непрерывных действий (Bhop, Dash hold, приседания) опрашивать `PlayerController:IsInputKeyDown({ KeyName = FName(keyName) })` синхронно в GameThread цикле (`LoopInGameThreadWithDelay`).
  - Добавлять self-check / watchdog (если за N циклов статус клавиши подозрительно завис или не отвечает — fallback или предупреждение).
  - Делать **однократный лог первого результата опроса** (`one-shot log`), чтобы по `UE4SS.log` сразу видеть: движок получает корректное состояние клавиши или нет.

### 6. НЕЛЬЗЯ делать слепой probe сигнатур, если ошибочный вариант «проглатывается» без ошибки
* **Почему:** Если метод или функция движка молча игнорирует неверные параметры (как в случае с полями структур выше), слепой probe с перебором вариантов (`ok, res = pcall(variant1); if not ok then ...`) посчитает нерабочий вариант успешным (`ok == true`), выберет мёртвую ветку и мод будет вечно работать вхолостую.
* **Как правильно:**
  - Проводить probe конкретной сигнатуры с проверкой не только факта вызова (`ok`), но и валидности возвращённого значения / реального эффекта.
  - Если probe завершился неудачно — переводить подсистему в явное состояние `disabled`/`suspended` с записью в лог, а не маскировать под дефолтный `false`.
  - Кэшировать найденную сигнатуру один раз при старте или первом вызове.

### 7. НЕЛЬЗЯ трогать компоненты и материалы актера внутри `NotifyOnNewObject`
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

### 8. НЕЛЬЗЯ создавать Dynamic Material Instances (`CreateDynamicMaterialInstance`) в тике
* **Почему:** Каждый вызов `CreateDynamicMaterialInstance` выделяет новый UObject в памяти движка. Создание материалов каждый кадр или секунду быстро забивает память, приводит к микрофризам GC и падению по нехватке памяти (OOM).
* **Как правильно:** Создавать материал **один раз** при загрузке карты/инициализации мода, кэшировать его в таблице `MIDs` и применять один и тот же инстанс ко всем мешам.

### 9. НЕЛЬЗЯ забывать про дистанционный куллинг Overlay-материалов
* **Почему:** При использовании `SetOverlayMaterial` движок Unreal Engine по умолчанию может применять дистанционный куллинг (`OverlayMaterialMaxDrawDistance`), из-за чего подсветка (ESP, Glow, Highlights) внезапно исчезает при отдалении от объекта.
* **Как правильно:** Принудительно отключать куллинг оверлея: `mesh:SetOverlayMaterialMaxDrawDistance(0.0)`.

### 10. НЕЛЬЗЯ спамить `ExecuteInGameThread` без троттлинга
* **Почему:** Если быстрый таймер (например, каждые 5-10 мс) ставит задачи в очередь `ExecuteInGameThread`, а игра просела по FPS, очередь переполняется, вызывая огромные задержки и зависания.
* **Как правильно:** Использовать флаги занятости (`gameTickQueued`) или переходить на `LoopInGameThreadWithDelay`, который сам управляет интервалом между вызовами.

### 11. Опасность нативных DLL: `mods.txt` НЕ выключает `.dll`!
* **Почему:** В UE4SS файлы нативных библиотек `Mods/<ModName>/dlls/main.dll` загружаются загрузчиком движка **безусловно**, даже если мод помечен как `0` (отключен) в `mods.txt`! Если в папке осталась старая или отладочная DLL, она продолжит выполняться и конфликтовать с Lua-скриптами.
* **Как правильно:** Чтобы гарантированно отключить нативную DLL, переименовывать её (например, в `main.dll.disabled`) или удалять из каталога `dlls/`.

### 12. НЕЛЬЗЯ забывать синхронизировать изменения между репозиторием и папкой игры
* **Почему:** Репозиторий находится в `~/Projects/FarFarWestMods/`, а игра читает моды из `/mnt/steam/steamapps/common/FarFarWest/FarFarWest/Binaries/Win64/ue4ss/Mods/`. Редактирование только одного места приводит к рассинхронизации.
* **Как правильно:** Всегда обновлять оба расположения и проверять синтаксис Lua (`bun x luaparse <file>`) перед запуском.

### 13. Правила коммитов и работы в терминале
* **Conventional Commits:** Репозиторий использует pre-commit hook, требующий строгий формат: `type(scope): description` (например, `fix(bhopdash): pass FKey as KeyName field to IsInputKeyDown`). Допустимые типы: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
* **Экранирование в shell:** Не используйте обратные кавычки (backticks) внутри строк с двойными кавычками `git commit -m "..."`, иначе bash попытается выполнить содержимое кавычек как команду (`KeyName: command not found`). Всегда оборачивайте сообщения коммитов в одинарные кавычки: `git commit -m 'type(scope): description'`.

---

## ✅ Золотой стандарт реализации мода UE4SS

```lua
local UEHelpers = require("UEHelpers")

-- 1. Безопасная проверка валидности UObject
local function isValid(obj)
    if obj == nil then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and res == true
end

-- 2. Безопасный опрос клавиш через PlayerController (GameThread)
local function isKeyDown(pc, keyName)
    if not isValid(pc) then return false end
    -- ВАЖНО: поле структуры FKey называется KeyName, а не Key!
    local ok, pressed = pcall(function()
        return pc:IsInputKeyDown({ KeyName = FName(keyName) })
    end)
    return ok and pressed == true
end

-- 3. Очистка кэша при смене уровней
RegisterLoadMapPostHook(function()
    cachedPlayer = nil
    cachedPC = nil
    cachedWorld = nil
    activeTrackedObjects = {}
end)

-- 4. Безопасный цикл в GameThread с защитой pcall
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
