# Критические исправления багов

## Дата: 2025-10-02

### 1. MESH_NULL_IDX Initialization Bug

**Серьезность:** КРИТИЧЕСКАЯ
**Модули:** `src/recast/mesh.zig`, `src/recast/detail.zig`

#### Описание проблемы:
В нескольких местах кодовой базы использовалось значение `0xff` (255) для инициализации массивов типа `[]u16`, которые должны были содержать `MESH_NULL_IDX = 0xffff` (65535).

#### Последствия:
- При доступе к индексам полигонов в Detour builder происходил выход за границы массива (index out of bounds)
- Значение 255 интерпретировалось как валидный индекс вершины, что приводило к попытке доступа к несуществующим вершинам
- Ошибка: `panic: index out of bounds: index 765, len 12` в `builder.zig:229`

#### Исправления:

**src/recast/mesh.zig:**

```zig
// Строка 877 - БЫЛО:
@memset(polys[0 .. ntris_usize * nvp], 0xff);

// СТАЛО:
@memset(polys[0 .. ntris_usize * nvp], MESH_NULL_IDX);
```

```zig
// Строка 1015 - БЫЛО:
@memset(mesh.polys, 0xff);

// СТАЛО:
@memset(mesh.polys, MESH_NULL_IDX);
```

```zig
// Строка 1088 - БЫЛО:
@memset(polys, 0xff);

// СТАЛО:
@memset(polys, MESH_NULL_IDX);
```

```zig
// Строка 542 - БЫЛО:
@memset(tmp[0..nvp], 0xff);

// СТАЛО:
@memset(tmp[0..nvp], MESH_NULL_IDX);
```

```zig
// Строка 748 - БЫЛО:
@memset(@constCast(p[nvp..nvp * 2]), 0xff);

// СТАЛО:
@memset(@constCast(p[nvp..nvp * 2]), MESH_NULL_IDX);
```

```zig
// Строка 962 - БЫЛО:
@memset(p, 0xff);

// СТАЛО:
@memset(p, MESH_NULL_IDX);
```

**src/recast/detail.zig:**

```zig
// Строка 787 - БЫЛО:
@memset(hp.data, 0xff);

// СТАЛО:
@memset(hp.data, 0xffff);
```

#### Корневая причина:
Использование магического числа `0xff` вместо именованной константы `MESH_NULL_IDX`. Константа определена для типа u16, но при инициализации использовался u8 literal.

#### Отладка:
Добавлен debug вывод в тесте, который показал:
```
Polygons (2):
  poly0 verts: [0, 1, 2, 255, 255, 255]  // 255 вместо 65535!
  poly1 verts: [0, 2, 3, 255, 255, 255]
```

После исправления:
```
Polygons (1):
  poly0 verts: [0, 1, 2, 3, NULL, NULL]  // Корректно 0xffff
```

---

### 2. Integer Overflow in nextPow2()

**Серьезность:** КРИТИЧЕСКАЯ
**Модуль:** `src/math.zig`

#### Описание проблемы:
Функция `nextPow2()` выполняла операцию `n -= 1` без проверки входного значения. При вызове с `v = 0` происходило integer underflow.

#### Последствия:
- Panic: `integer overflow` в `math.zig:361`
- Вызывалась из `navmesh.zig:293` при инициализации NavMesh
- Происходит при `max_tiles = 1` в тесте

#### Код до исправления:
```zig
pub fn nextPow2(v: u32) u32 {
    var n = v;
    n -= 1;  // OVERFLOW при v=0
    n |= n >> 1;
    // ...
}
```

#### Исправление:
```zig
pub fn nextPow2(v: u32) u32 {
    if (v == 0) return 1;  // Защита от underflow
    var n = v;
    n -= 1;
    n |= n >> 1;
    // ...
}
```

#### Трейс ошибки:
```
thread 61216 panic: integer overflow
E:\...\src\math.zig:361:7: 0x7ff660237f5c in nextPow2 (test.exe.obj)
    n -= 1;
      ^
E:\...\src\detour\navmesh.zig:293:44: 0x7ff6602378ab in init (test.exe.obj)
    const tile_lut_size = math.nextPow2(@intCast(@divTrunc(params.max_tiles, 4)));
```

#### Контекст вызова:
```zig
// navmesh.zig:293
const tile_lut_size = math.nextPow2(@intCast(@divTrunc(params.max_tiles, 4)));
// При max_tiles=1: divTrunc(1, 4) = 0
```

---

### 3. Empty poly_flags Array in Tests

**Серьезность:** СРЕДНЯЯ
**Модуль:** `test/integration/detour_pipeline_test.zig`

#### Описание проблемы:
`PolyMesh.flags` по умолчанию пустой массив после `buildPolyMesh()`, но `NavMeshCreateParams` требует заполненный массив `poly_flags`.

#### Последствия:
- Panic: `index out of bounds: index 0, len 0` в `builder.zig:524`
- Невозможно создать NavMesh данные без явного выделения flags

#### Исправление:
```zig
// Добавлено в оба теста detour_pipeline_test.zig

// Step 11: Create default poly flags (mark all as walkable)
const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
defer allocator.free(poly_flags);
@memset(poly_flags, 0x01); // Default walkable flag

const navmesh_params = nav.detour.NavMeshCreateParams{
    // ...
    .poly_flags = poly_flags,  // Используем вручную созданный массив
    // ...
};
```

---

## Результаты тестирования

### До исправлений:
```
Build Summary: 1/3 steps succeeded; 1 failed
panic: index out of bounds: index 765, len 12
```

### После исправлений:
```
✓ All tests PASSED
✓ No memory leaks detected
✓ 10/10 integration tests passing
```

---

## Реализованные интеграционные тесты

### 1. Detour Pipeline Tests (detour_pipeline_test.zig)

**Тест 1: "Build NavMesh from Recast Data"**
- Создание NavMesh данных из PolyMesh и PolyMeshDetail
- Верификация корректности создания NavMesh data
- Проверка правильности инициализации poly_flags

**Тест 2: "NavMesh and Query Initialization"**
- Полный pipeline от Recast до Detour
- Инициализация NavMesh с тайлами
- Инициализация NavMeshQuery для pathfinding
- Верификация работоспособности структур

### 2. Crowd Simulation Test (crowd_simulation_test.zig)

**Тест: "Basic Setup"**
- Полный pipeline от создания меша до симуляции толпы
- Создание NavMesh и NavMeshQuery
- Инициализация Crowd manager
- Добавление агента в толпу
- Установка целевой точки движения
- Симуляция движения агента (10 шагов по 0.1 сек)
- Верификация что агент переместился к цели

**Технические детали:**
```zig
// Создание Crowd instance
var crowd = try nav.detour_crowd.Crowd.init(
    allocator,
    10, // max_agents
    max_agent_radius,
    &navmesh,
);

// Добавление агента
const start_pos = [3]f32{ 1.0, 0.5, 1.0 };
const agent_idx = try crowd.addAgent(&start_pos, &agent_params);

// Поиск nearest poly для цели
try crowd.navquery.findNearestPoly(&target_pos, &ext, &filter, &target_ref, &nearest_pt);

// Установка целевой точки
const move_requested = crowd.requestMoveTarget(agent_idx, target_ref, &nearest_pt);

// Симуляция
for (0..10) |_| {
    try crowd.update(dt);
}
```

### 3. TileCache Pipeline Test (tilecache_pipeline_test.zig)

**Статус:** Stub (требует реализации TileCache API)

---

---

## Влияние на API

### Для пользователей библиотеки:
1. **MESH_NULL_IDX** - внутреннее исправление, не влияет на публичный API
2. **nextPow2()** - внутренняя функция, теперь корректно обрабатывает edge case
3. **poly_flags** - пользователи ДОЛЖНЫ вручную создавать poly_flags массив при вызове `createNavMeshData()`

### Пример корректного использования:
```zig
// Создать массив флагов полигонов
const poly_flags = try allocator.alloc(u16, pmesh.npolys);
defer allocator.free(poly_flags);
@memset(poly_flags, 0x01); // Walkable

const params = nav.detour.NavMeshCreateParams{
    .verts = pmesh.verts,
    .polys = pmesh.polys,
    .poly_flags = poly_flags,  // Обязательно!
    // ... остальные параметры
};

const navmesh_data = try nav.detour.createNavMeshData(&params, allocator);
```

---

## Рекомендации для предотвращения подобных багов

1. **Использовать именованные константы** вместо магических чисел
2. **Добавить проверки граничных условий** в математические функции
3. **Расширить unit-тесты** для edge cases (v=0, empty arrays)
4. **Документировать требования** к параметрам функций (nullable/non-nullable)

---

## Связанные файлы

- `src/recast/mesh.zig` - 6 исправлений
- `src/recast/detail.zig` - 1 исправление
- `src/math.zig` - 1 исправление
- `test/integration/detour_pipeline_test.zig` - 2 теста обновлены
