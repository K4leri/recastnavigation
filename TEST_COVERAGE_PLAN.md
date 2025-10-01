# 🧪 Детальный План Покрытия Тестами

**Дата создания:** 2025-10-01
**Цель:** Максимально глубокий анализ всех тестов из оригинальной RecastNavigation C++ библиотеки и создание плана покрытия тестами для Zig порта.

---

## 📋 Оглавление

1. [Структура Тестов в Оригинальной Библиотеке](#структура-тестов-в-оригинальной-библиотеке)
2. [Текущие Тесты в Zig Порте](#текущие-тесты-в-zig-порте)
3. [Детальный Анализ Покрытия](#детальный-анализ-покрытия)
4. [План Реализации Недостающих Тестов](#план-реализации-недостающих-тестов)
5. [Приоритеты и Временная Оценка](#приоритеты-и-временная-оценка)

---

## 📁 Структура Тестов в Оригинальной Библиотеке

### Расположение тестов:
```
recastnavigation/Tests/
├── Recast/
│   ├── Tests_Recast.cpp          (основные тесты Recast - математика, структуры, rasterization)
│   ├── Tests_RecastFilter.cpp    (тесты фильтрации)
│   ├── Tests_Alloc.cpp           (тесты аллокации и rcVector)
│   └── Bench_rcVector.cpp        (бенчмарки)
├── Detour/
│   └── Tests_Detour.cpp          (тесты Detour)
├── DetourCrowd/
│   └── Tests_DetourPathCorridor.cpp  (тесты PathCorridor)
└── Contrib/
    └── catch2/                   (тестовый фреймворк)
```

---

## 🔬 РЕCAST ТЕСТЫ (Tests_Recast.cpp)

### 1. **Математические Функции** (8 тестов)
Все тесты используют Catch2 framework.

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 1.1 | `rcSwap` | rcSwap() | ❌ Отсутствует | 🟡 Средний |
| 1.2 | `rcMin` | rcMin() | ❌ Отсутствует | 🟡 Средний |
| 1.3 | `rcMax` | rcMax() | ❌ Отсутствует | 🟡 Средний |
| 1.4 | `rcAbs` | rcAbs() | ❌ Отсутствует | 🟡 Средний |
| 1.5 | `rcSqr` | rcSqr() | ❌ Отсутствует | 🟡 Средний |
| 1.6 | `rcClamp` | rcClamp() | ❌ Отсутствует | 🟡 Средний |
| 1.7 | `rcSqrt` | rcSqrt() | ❌ Отсутствует | 🟡 Средний |
| 1.8 | `rcVcross` - Cross product | rcVcross() | ❌ Отсутствует | 🔴 Высокий |

**Подтесты для rcSwap:**
- `Swap two values`

**Подтесты для rcMin:**
- `Min returns the lowest value`
- `Min with equal args`

**Подтесты для rcMax:**
- `Max returns the greatest value`
- `Max with equal args`

**Подтесты для rcAbs:**
- `Abs returns the absolute value`

**Подтесты для rcSqr:**
- `Sqr squares a number`

**Подтесты для rcClamp:**
- `Higher than range`
- `Within range`
- `Lower than range`

**Подтесты для rcSqrt:**
- `Sqrt gets the sqrt of a number`

**Подтесты для rcVcross:**
- `Computes cross product`
- `Cross product with itself is zero`

### 2. **Векторные Операции** (11 тестов)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 2.1 | `rcVdot` | rcVdot() | ❌ Отсутствует | 🔴 Высокий |
| 2.2 | `rcVmad` | rcVmad() | ❌ Отсутствует | 🔴 Высокий |
| 2.3 | `rcVadd` | rcVadd() | ❌ Отсутствует | 🔴 Высокий |
| 2.4 | `rcVsub` | rcVsub() | ❌ Отсутствует | 🔴 Высокий |
| 2.5 | `rcVmin` | rcVmin() | ❌ Отсутствует | 🟡 Средний |
| 2.6 | `rcVmax` | rcVmax() | ❌ Отсутствует | 🟡 Средний |
| 2.7 | `rcVcopy` | rcVcopy() | ❌ Отсутствует | 🟡 Средний |
| 2.8 | `rcVdist` | rcVdist() | ❌ Отсутствует | 🔴 Высокий |
| 2.9 | `rcVdistSqr` | rcVdistSqr() | ❌ Отсутствует | 🔴 Высокий |
| 2.10 | `rcVnormalize` | rcVnormalize() | ❌ Отсутствует | 🔴 Высокий |
| 2.11 | `rcCalcBounds` | rcCalcBounds() | ❌ Отсутствует | 🔴 Высокий |

**Подтесты для rcVdot:**
- `Dot normalized vector with itself`
- `Dot zero vector with anything is zero`

**Подтесты для rcVmad:**
- `scaled add two vectors`
- `second vector is scaled, first is not`

**Подтесты для rcVadd:**
- `add two vectors`

**Подтесты для rcVsub:**
- `subtract two vectors`

**Подтесты для rcVmin:**
- `selects the min component from the vectors`
- `v1 is min`
- `v2 is min`

**Подтесты для rcVmax:**
- `selects the max component from the vectors`
- `v2 is max`
- `v1 is max`

**Подтесты для rcVcopy:**
- `copies a vector into another vector`

**Подтесты для rcVdist:**
- `distance between two vectors`
- `Distance from zero is magnitude`

**Подтесты для rcVdistSqr:**
- `squared distance between two vectors`
- `squared distance from zero is squared magnitude`

**Подтесты для rcVnormalize:**
- `normalizing reduces magnitude to 1`

**Подтесты для rcCalcBounds:**
- `bounds of one vector`
- `bounds of more than one vector`

### 3. **Базовые Структуры и Создание** (3 теста)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 3.1 | `rcCalcGridSize` | rcCalcGridSize() | ❌ Отсутствует | 🔴 Высокий |
| 3.2 | `rcCreateHeightfield` | rcCreateHeightfield() | ❌ Отсутствует | 🔴 Высокий |
| 3.3 | `rcMarkWalkableTriangles` | rcMarkWalkableTriangles() | ✅ Реализован | ✅ Готов |

**Подтесты для rcCalcGridSize:**
- `computes the size of an x & z axis grid`

**Подтесты для rcCreateHeightfield:**
- `create a heightfield`

**Подтесты для rcMarkWalkableTriangles:**
- `One walkable triangle`
- `One non-walkable triangle`
- `Non-walkable triangle area id's are not modified`
- `Slopes equal to the max slope are considered unwalkable`

### 4. **Clearing и Фильтрация** (1 тест)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 4.1 | `rcClearUnwalkableTriangles` | rcClearUnwalkableTriangles() | ✅ Реализован | ✅ Готов |

**Подтесты для rcClearUnwalkableTriangles:**
- `Sets area ID of unwalkable triangle to RC_NULL_AREA`
- `Does not modify walkable triangle aread ID's`
- `Slopes equal to the max slope are considered unwalkable`

### 5. **Rasterization** (5 тестов)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 5.1 | `rcAddSpan` | rcAddSpan() | ✅ Реализован | ✅ Готов |
| 5.2 | `rcRasterizeTriangle` | rcRasterizeTriangle() | ✅ Реализован | ✅ Готов |
| 5.3 | `rcRasterizeTriangle overlapping bb but non-overlapping triangle` | rcRasterizeTriangle() | ❌ Отсутствует | 🔴 Высокий |
| 5.4 | `rcRasterizeTriangle smaller than half a voxel size in x` | rcRasterizeTriangle() | ❌ Отсутствует | 🔴 Высокий |
| 5.5 | `rcRasterizeTriangles` | rcRasterizeTriangles() | ✅ Реализован | ✅ Готов |

**Подтесты для rcAddSpan:**
- `Add a span to an empty heightfield`
- `Add a span that gets merged with an existing span`
- `Add a span that merges with two spans above and below`

**Подтесты для rcRasterizeTriangle:**
- `Rasterize a triangle`

**Подтесты для rcRasterizeTriangle overlapping bb:**
- Минимальный repro case для issue #476 (треугольник вне heightfield)

**Подтесты для rcRasterizeTriangle smaller than half voxel:**
- `Skinny triangle along x axis`
- `Skinny triangle along z axis`

**Подтесты для rcRasterizeTriangles:**
- `Rasterize some triangles`
- `Unsigned short overload`
- `Triangle list overload`

**ИТОГО Recast (Tests_Recast.cpp): 28 тестов**

---

## 🔬 RECAST FILTER ТЕСТЫ (Tests_RecastFilter.cpp)

### 1. **Low Hanging Obstacles** (1 тест, 5 подтестов)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 1.1 | `rcFilterLowHangingWalkableObstacles` | rcFilterLowHangingWalkableObstacles() | ✅ Реализован | ✅ Готов |

**Подтесты:**
- `Span with no spans above it is unchanged`
- `Span with span above that is higher than walkableHeight is unchanged`
- `Marks low obstacles walkable if they're below the walkableClimb`
- `Low obstacle that overlaps the walkableClimb distance is not changed`
- `Only the first of multiple, low obstacles are marked walkable`

### 2. **Ledge Spans** (1 тест, 1 подтест)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 2.1 | `rcFilterLedgeSpans` | rcFilterLedgeSpans() | ✅ Реализован | ✅ Готов |

**Подтесты:**
- `Edge spans are marked unwalkable`

### 3. **Low Height Spans** (1 тест, 3 подтеста)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 3.1 | `rcFilterWalkableLowHeightSpans` | rcFilterWalkableLowHeightSpans() | ✅ Реализован | ✅ Готов |

**Подтесты:**
- `span nothing above is unchanged`
- `span with lots of room above is unchanged`
- `Span with low hanging obstacle is marked as unwalkable`

**ИТОГО Recast Filter: 3 теста (9 подтестов)**

---

## 🔬 RECAST ALLOC ТЕСТЫ (Tests_Alloc.cpp)

### 1. **rcVector** (1 тест, 9 подтестов)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 1.1 | `rcVector` | rcTempVector, rcPermVector | ❌ Отсутствует | 🟢 Низкий |

**Подтесты:**
- `Vector basics` - push_back, pop_back, resize, capacity
- `Constructors/Destructors` - корректный подсчет конструкций/деструкций
- `Copying Contents` - copy-on-resize
- `Swap` - обмен между векторами
- `Overlapping init` - инициализация с overlap (realloc)
- `Vector Destructor` - вызов деструкторов при уничтожении вектора
- `Assign` - присваивание значений
- `Copy` - копирование векторов
- `Type Requirements` - проверка минимальных требований к типу T

**Примечание:** В Zig используется встроенный std.ArrayList, поэтому эти тесты менее актуальны. Можно добавить тесты для проверки корректности работы с аллокаторами.

**ИТОГО Recast Alloc: 1 тест (9 подтестов)**

---

## 🔬 DETOUR ТЕСТЫ (Tests_Detour.cpp)

### 1. **Common Functions** (1 тест, 1 подтест)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 1.1 | `dtRandomPointInConvexPoly` | dtRandomPointInConvexPoly() | ❌ Отсутствует | 🔴 Высокий |

**Подтесты:**
- `Properly works when the argument 's' is 1.0f`
  - Тест с s=0.0, s=0.5, s=1.0
  - Проверка корректности генерации случайной точки внутри выпуклого полигона

**ИТОГО Detour: 1 тест (1 подтест)**

---

## 🔬 DETOUR CROWD ТЕСТЫ (Tests_DetourPathCorridor.cpp)

### 1. **Path Corridor Merging** (1 тест, 7 подтестов)

| # | Название теста | Функция | Статус в Zig | Приоритет |
|---|----------------|---------|--------------|-----------|
| 1.1 | `dtMergeCorridorStartMoved` | dtMergeCorridorStartMoved() | ❌ Отсутствует | 🔴 Высокий |

**Подтесты:**
- `Should handle empty input` - обработка пустого ввода
- `Should handle empty visited` - обработка пустого visited массива
- `Should handle empty path` - обработка пустого пути
- `Should strip visited points from path except last` - удаление visited точек кроме последней
- `Should add visited points not present in path in reverse order` - добавление новых visited точек в обратном порядке
- `Should add visited points not present in path up to the path capacity` - добавление с учетом capacity
- `Should not change path if there is no intersection with visited` - путь не меняется если нет пересечений
- `Should save unvisited path points` - сохранение непосещенных точек
- `Should save unvisited path points up to the path capacity` - сохранение с учетом capacity

**ИТОГО DetourCrowd: 1 тест (8 подтестов)**

---

## 📊 Текущие Тесты в Zig Порте

### Структура тестов:
```
zig-recast/test/
├── filter_test.zig           (10 тестов)
└── rasterization_test.zig    (8 тестов)
```

### Детальный список текущих тестов:

#### **filter_test.zig** (10 тестов)

| # | Название теста | Соответствует оригиналу |
|---|----------------|-------------------------|
| 1 | `markWalkableTriangles - flat triangle` | ✅ Да (rcMarkWalkableTriangles) |
| 2 | `markWalkableTriangles - steep slope` | ✅ Да (rcMarkWalkableTriangles) |
| 3 | `clearUnwalkableTriangles - steep slope` | ✅ Да (rcClearUnwalkableTriangles) |
| 4 | `clearUnwalkableTriangles - flat triangle unchanged` | ✅ Да (rcClearUnwalkableTriangles) |
| 5 | `filterWalkableLowHeightSpans - removes low ceiling spans` | ✅ Да (rcFilterWalkableLowHeightSpans) |
| 6 | `filterWalkableLowHeightSpans - keeps sufficient height spans` | ✅ Да (rcFilterWalkableLowHeightSpans) |
| 7 | `filterLowHangingWalkableObstacles - marks low obstacles as walkable` | ✅ Да (rcFilterLowHangingWalkableObstacles) |
| 8 | `filterLowHangingWalkableObstacles - ignores tall obstacles` | ✅ Да (rcFilterLowHangingWalkableObstacles) |
| 9 | `filterLedgeSpans - marks edge ledges as unwalkable` | ✅ Да (rcFilterLedgeSpans) |
| 10 | `filterLedgeSpans - keeps interior spans walkable` | ✅ Да (rcFilterLedgeSpans) |

#### **rasterization_test.zig** (8 тестов)

| # | Название теста | Соответствует оригиналу |
|---|----------------|-------------------------|
| 1 | `rasterizeTriangle - single triangle` | ✅ Да (rcRasterizeTriangle) |
| 2 | `rasterizeTriangle - degenerate triangle` | ❌ Нет (дополнительный) |
| 3 | `rasterizeTriangle - outside bounds` | ❌ Нет (дополнительный) |
| 4 | `rasterizeTriangles - multiple triangles` | ✅ Да (rcRasterizeTriangles) |
| 5 | `rasterizeTrianglesU16 - with u16 indices` | ✅ Да (rcRasterizeTriangles) |
| 6 | `rasterizeTrianglesFlat - flat vertex array` | ✅ Да (rcRasterizeTriangles) |
| 7 | `rasterization - area merging` | ✅ Да (rcAddSpan) |
| 8 | `rasterization - large mesh performance` | ❌ Нет (performance test) |

**ИТОГО текущих тестов в Zig: 18 тестов**

---

## 📈 Анализ Покрытия

### Статистика по модулям:

| Модуль | Тестов в C++ | Тестов в Zig | Покрытие | Недостающие |
|--------|--------------|--------------|----------|-------------|
| **Recast (Math)** | 19 тестов | 0 | 0% | 19 |
| **Recast (Structures)** | 3 теста | 0 | 0% | 3 |
| **Recast (Clearing)** | 1 тест | 2 теста | ✅ 100% | 0 |
| **Recast (Rasterization)** | 5 тестов | 8 тестов | ✅ 100%+ | -3 (дополн.) |
| **Recast Filter** | 3 теста | 10 тестов | ✅ 100%+ | -7 (дополн.) |
| **Recast Alloc** | 1 тест | 0 | 0% | 1 (низк. приор.) |
| **Detour** | 1 тест | 0 | 0% | 1 |
| **DetourCrowd** | 1 тест | 0 | 0% | 1 |
| **ИТОГО** | **34 теста** | **18 тестов** | **~53%** | **25 тестов** |

### Критические пробелы:

🔴 **КРИТИЧЕСКИЕ (требуют немедленной реализации):**
1. **Векторные операции** - 11 тестов (rcVdot, rcVadd, rcVsub, rcVmad, rcVdist, rcVdistSqr, rcVnormalize, rcCalcBounds)
2. **Базовые структуры** - 2 теста (rcCalcGridSize, rcCreateHeightfield)
3. **Rasterization edge cases** - 2 теста (overlapping bb, skinny triangles)
4. **Detour Common** - 1 тест (dtRandomPointInConvexPoly)
5. **Path Corridor** - 1 тест (dtMergeCorridorStartMoved)

🟡 **СРЕДНИЕ (желательно реализовать):**
1. **Математические утилиты** - 8 тестов (rcSwap, rcMin, rcMax, rcAbs, rcSqr, rcClamp, rcSqrt, rcVcopy, rcVmin, rcVmax)

🟢 **НИЗКИЕ (опционально):**
1. **Alloc/Vector** - 1 тест (rcVector - менее актуален для Zig)

---

## 🎯 План Реализации Недостающих Тестов

### ФАЗА 1: Критические векторные операции (Приоритет: 🔴 Высокий)

**Файл:** `zig-recast/test/math_test.zig` (новый)
**Оценка времени:** 4-6 часов
**Тестов:** 19

#### Группа 1.1: Скалярные математические функции
- [ ] `rcMin` (2 подтеста)
- [ ] `rcMax` (2 подтеста)
- [ ] `rcAbs` (1 подтест)
- [ ] `rcSqr` (1 подтест)
- [ ] `rcClamp` (3 подтеста)
- [ ] `rcSqrt` (1 подтест)
- [ ] `rcSwap` (1 подтест)

#### Группа 1.2: Основные векторные операции
- [ ] `rcVdot` (2 подтеста) - **КРИТИЧНО для pathfinding**
- [ ] `rcVadd` (1 подтест)
- [ ] `rcVsub` (1 подтест)
- [ ] `rcVmad` (2 подтеста) - **КРИТИЧНО для движения**
- [ ] `rcVcopy` (1 подтест)
- [ ] `rcVmin` (3 подтеста)
- [ ] `rcVmax` (3 подтеста)

#### Группа 1.3: Расстояния и нормализация
- [ ] `rcVdist` (2 подтеста) - **КРИТИЧНО**
- [ ] `rcVdistSqr` (2 подтеста) - **КРИТИЧНО**
- [ ] `rcVnormalize` (1 подтест) - **КРИТИЧНО**
- [ ] `rcVcross` (2 подтеста) - **КРИТИЧНО**

#### Группа 1.4: Bounds и геометрия
- [ ] `rcCalcBounds` (2 подтеста) - **КРИТИЧНО**

**Примерная структура файла:**
```zig
const std = @import("std");
const testing = std.testing;
const math = @import("../src/math.zig");

test "rcMin - returns lowest value" {
    try testing.expectEqual(1, math.min(1, 2));
    try testing.expectEqual(1, math.min(2, 1));
}

test "rcMin - equal args" {
    try testing.expectEqual(1, math.min(1, 1));
}

// ... и так далее
```

---

### ФАЗА 2: Базовые структуры и Grid (Приоритет: 🔴 Высокий)

**Файл:** `zig-recast/test/heightfield_test.zig` (новый)
**Оценка времени:** 3-4 часа
**Тестов:** 2

#### Тесты:
- [ ] `rcCalcGridSize` (1 подтест)
  - Проверка вычисления размера grid'а по bounds и cell size
  - Тестовые данные: bounds(0,0,0)-(1,2,6), cellSize=1.5 → width=1, height=2

- [ ] `rcCreateHeightfield` (1 подтест)
  - Проверка создания heightfield с корректными параметрами
  - Валидация bmin, bmax, cs, ch, spans initialization

**Примерная структура файла:**
```zig
const std = @import("std");
const testing = std.testing;
const recast = @import("../src/recast/heightfield.zig");

test "calcGridSize - computes grid dimensions" {
    const bmin = [3]f32{0, 0, 0};
    const bmax = [3]f32{1, 2, 6};
    const cs: f32 = 1.5;

    const result = recast.calcGridSize(&bmin, &bmax, cs);
    try testing.expectEqual(@as(i32, 1), result.width);
    try testing.expectEqual(@as(i32, 2), result.height);
}

test "createHeightfield - initializes correctly" {
    var allocator = testing.allocator;
    // ... тест создания heightfield
}
```

---

### ФАЗА 3: Rasterization Edge Cases (Приоритет: 🔴 Высокий)

**Файл:** `zig-recast/test/rasterization_test.zig` (расширение)
**Оценка времени:** 2-3 часа
**Тестов:** 2

#### Новые тесты:
- [ ] `rcRasterizeTriangle - overlapping bb but non-overlapping triangle`
  - Тест для issue #476 - треугольник вне heightfield с overlapping bounding box
  - Критично для предотвращения false positive rasterization

- [ ] `rcRasterizeTriangle - skinny triangles`
  - Треугольник меньше половины вокселя по X
  - Треугольник меньше половины вокселя по Z
  - Критично для корректной обработки тонких геометрий

**Добавление в существующий файл:**
```zig
test "rasterizeTriangle - overlapping bb but non-overlapping triangle" {
    // Minimal repro case for issue #476
    // Triangle outside heightfield should not rasterize
    var allocator = testing.allocator;
    // ... implementation
}

test "rasterizeTriangle - skinny triangle along x axis" {
    // Triangle: {5,0,0.005}, {5,0,-0.005}, {-5,0,0.005}
    // Should not crash with cell_size=1
    // ... implementation
}

test "rasterizeTriangle - skinny triangle along z axis" {
    // Triangle: {0.005,0,5}, {-0.005,0,5}, {0.005,0,-5}
    // Should not crash with cell_size=1
    // ... implementation
}
```

---

### ФАЗА 4: Detour Common Functions (Приоритет: 🔴 Высокий)

**Файл:** `zig-recast/test/detour_common_test.zig` (новый)
**Оценка времени:** 2-3 часа
**Тестов:** 1

#### Тесты:
- [ ] `dtRandomPointInConvexPoly` (3 проверки)
  - s=0.0 → point at (0, 0, 1)
  - s=0.5 → point at (0.5, 0, 0.5)
  - s=1.0 → point at (1, 0, 0)
  - Критично для random point generation в навигации

**Примерная структура файла:**
```zig
const std = @import("std");
const testing = std.testing;
const detour = @import("../src/detour/common.zig");

test "dtRandomPointInConvexPoly - properly works when s is 1.0" {
    const pts = [_]f32{
        0, 0, 0,
        0, 0, 1,
        1, 0, 0,
    };
    var areas: [6]f32 = undefined;
    var out: [3]f32 = undefined;

    detour.randomPointInConvexPoly(&pts, 3, &areas, 0.0, 1.0, &out);
    try testing.expectApproxEqAbs(0.0, out[0], 0.001);
    try testing.expectApproxEqAbs(0.0, out[1], 0.001);
    try testing.expectApproxEqAbs(1.0, out[2], 0.001);

    detour.randomPointInConvexPoly(&pts, 3, &areas, 0.5, 1.0, &out);
    try testing.expectApproxEqAbs(0.5, out[0], 0.001);
    try testing.expectApproxEqAbs(0.0, out[1], 0.001);
    try testing.expectApproxEqAbs(0.5, out[2], 0.001);

    detour.randomPointInConvexPoly(&pts, 3, &areas, 1.0, 1.0, &out);
    try testing.expectApproxEqAbs(1.0, out[0], 0.001);
    try testing.expectApproxEqAbs(0.0, out[1], 0.001);
    try testing.expectApproxEqAbs(0.0, out[2], 0.001);
}
```

---

### ФАЗА 5: DetourCrowd PathCorridor (Приоритет: 🔴 Высокий)

**Файл:** `zig-recast/test/path_corridor_test.zig` (новый)
**Оценка времени:** 3-4 часа
**Тестов:** 1 (8 подтестов)

#### Тесты:
- [ ] `dtMergeCorridorStartMoved` (8 подтестов)
  - Empty input handling
  - Empty visited handling
  - Empty path handling
  - Strip visited points except last
  - Add visited points in reverse order
  - Respect path capacity
  - No intersection case
  - Save unvisited path points
  - Save with capacity limit

**Примерная структура файла:**
```zig
const std = @import("std");
const testing = std.testing;
const corridor = @import("../src/detour_crowd/path_corridor.zig");

test "dtMergeCorridorStartMoved - empty input" {
    const path: ?[]corridor.PolyRef = null;
    const visited: ?[]const corridor.PolyRef = null;
    const result = corridor.mergeCorridorStartMoved(path, 0, visited, 0);
    try testing.expectEqual(@as(usize, 0), result);
}

test "dtMergeCorridorStartMoved - strip visited points except last" {
    var path = [_]corridor.PolyRef{1, 2};
    const visited = [_]corridor.PolyRef{1, 2};
    const result = corridor.mergeCorridorStartMoved(&path, &visited);
    try testing.expectEqual(@as(usize, 1), result);
    try testing.expectEqual(@as(corridor.PolyRef, 2), path[0]);
}

// ... остальные подтесты
```

---

### ФАЗА 6: Дополнительные математические утилиты (Приоритет: 🟡 Средний)

**Файл:** Расширение `zig-recast/test/math_test.zig`
**Оценка времени:** 1-2 часа
**Тестов:** Дополнительные утилиты

Уже будет покрыто в Фазе 1.

---

## 📅 Приоритеты и Временная Оценка

### Краткосрочный План (1-2 недели):

| Фаза | Приоритет | Время | Тестов | Статус |
|------|-----------|-------|--------|--------|
| Фаза 1 | 🔴 Критический | 4-6 ч | 19 | ⏳ Не начато |
| Фаза 2 | 🔴 Критический | 3-4 ч | 2 | ⏳ Не начато |
| Фаза 3 | 🔴 Критический | 2-3 ч | 2 | ⏳ Не начато |
| Фаза 4 | 🔴 Критический | 2-3 ч | 1 | ⏳ Не начато |
| Фаза 5 | 🔴 Критический | 3-4 ч | 1 (8 подтестов) | ⏳ Не начато |
| **ИТОГО** | - | **14-20 ч** | **25 тестов** | **0% готовности** |

### Среднесрочный План (1 месяц):

После завершения критических тестов:

1. **Recast Advanced Tests:**
   - Region building tests
   - Contour building tests
   - Mesh building tests
   - Detail mesh tests
   - Layers tests

2. **Detour Advanced Tests:**
   - NavMesh tests
   - Query tests
   - Path finding tests
   - Raycast tests

3. **DetourCrowd Tests:**
   - Crowd manager tests
   - Obstacle avoidance tests
   - Local boundary tests

4. **DetourTileCache Tests:**
   - TileCache core tests
   - Builder tests
   - Dynamic obstacles tests

5. **Integration Tests:**
   - Full pipeline tests
   - Performance tests
   - Stress tests

---

## 🎯 Рекомендуемая Последовательность Работы

### Неделя 1: Математика и Базовые Структуры
1. **День 1-2:** Фаза 1 - Математические и векторные функции (19 тестов)
2. **День 3:** Фаза 2 - Базовые структуры и Grid (2 теста)
3. **День 4:** Фаза 3 - Rasterization edge cases (2 теста)
4. **День 5:** Review и исправление найденных проблем

### Неделя 2: Detour и Crowd
1. **День 1:** Фаза 4 - Detour Common (1 тест)
2. **День 2-3:** Фаза 5 - PathCorridor (1 тест, 8 подтестов)
3. **День 4:** Integration testing
4. **День 5:** Документация и итоговый review

---

## 📝 Чеклист Для Каждого Теста

При реализации каждого теста следовать этому чеклисту:

- [ ] Прочитать оригинальный C++ тест
- [ ] Понять что именно тестируется
- [ ] Найти соответствующую Zig функцию
- [ ] Написать тест в соответствующем файле
- [ ] Запустить тест: `zig build test`
- [ ] Убедиться что тест проходит
- [ ] Отметить в этом документе как ✅
- [ ] Обновить PROGRESS.md со статистикой
- [ ] Commit с описанием: `test: add <test_name> from original C++ tests`

---

## 🔍 Критерии Качества Тестов

### Хороший тест должен:
1. ✅ **Быть независимым** - не зависеть от других тестов
2. ✅ **Быть быстрым** - выполняться < 100ms
3. ✅ **Быть понятным** - ясное название и структура
4. ✅ **Тестировать одну вещь** - один аспект функциональности
5. ✅ **Быть воспроизводимым** - всегда давать одинаковый результат
6. ✅ **Покрывать edge cases** - граничные случаи и ошибки

### Структура теста:
```zig
test "module_name - function_name - what_it_tests" {
    // Arrange - подготовка данных
    var allocator = testing.allocator;
    const input = ...;

    // Act - выполнение тестируемой функции
    const result = functionUnderTest(input);

    // Assert - проверка результата
    try testing.expectEqual(expected, result);

    // Cleanup (если нужно)
    defer allocator.free(...);
}
```

---

## 📊 Метрики Прогресса

Обновлять эту секцию после каждой завершенной фазы:

### Текущий Прогресс:

**Дата:** 2025-10-01
**Тестов реализовано:** 18 / 43 (41.9%)
**Тестов осталось:** 25
**Фаз завершено:** 0 / 5 (0%)

### График Прогресса:

```
Фаза 1 (19 тестов): [                    ] 0%
Фаза 2 (2 теста):   [                    ] 0%
Фаза 3 (2 теста):   [                    ] 0%
Фаза 4 (1 тест):    [                    ] 0%
Фаза 5 (1 тест):    [                    ] 0%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ОБЩИЙ ПРОГРЕСС:     [████████            ] 41.9%
```

---

## 🔗 Связанные Документы

- [PROGRESS.md](./PROGRESS.md) - общий прогресс реализации
- [IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md) - план реализации
- [README.md](./README.md) - основная документация

---

## 📚 Дополнительные Ресурсы

### Оригинальная библиотека:
- GitHub: https://github.com/recastnavigation/recastnavigation
- Tests: `recastnavigation/Tests/`
- Catch2 Documentation: https://github.com/catchorg/Catch2

### Zig Testing:
- Testing Documentation: https://ziglang.org/documentation/master/#Testing
- std.testing API: https://ziglang.org/documentation/master/std/#A;std:testing

---

**Конец документа**

Последнее обновление: 2025-10-01
