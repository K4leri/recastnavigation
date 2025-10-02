# Raycast Bug Fixes - Complete Story

**Дата:** 2025-10-02
**Статус:** ✅ Все баги исправлены, raycast работает идентично C++

---

## 📋 Содержание

1. [Краткое резюме](#краткое-резюме)
2. [Проблема](#проблема)
3. [Найденные баги](#найденные-баги)
4. [Процесс отладки](#процесс-отладки)
5. [Исправления](#исправления)
6. [Результаты](#результаты)
7. [Файлы](#файлы)

---

## Краткое резюме

В процессе интеграционного тестирования raycast было обнаружено и исправлено **3 критических бага**, которые приводили к неправильным результатам raycast тестов. После исправления все 4 raycast теста проходят с **идентичными результатами** C++ reference implementation.

### Исправленные баги:
1. ✅ **Area initialization bug** - неправильная инициализация triangle areas
2. ✅ **erodeWalkableArea bug** - неправильное условие boundary erosion
3. ✅ **perp2D formula bug** - неправильная формула 2D perpendicular dot product

---

## Проблема

### Исходная ситуация

При запуске raycast integration тестов все 4 теста возвращали неправильные результаты:

**Симптомы:**
- `path_count = 0` (должно быть 1-4 полигона)
- `hit_t` значения некорректны
- NavMesh содержит 194 polygons вместо 207

**Ожидаемое поведение:**
```
Test #1: Hit t=0.174383, path=[359,360,358] (3 polys)
Test #2: No hit (t=FLT_MAX), path=[350,346,410,407] (4 polys)
Test #3: Hit t=0.000877, path=[356] (1 poly)
Test #4: Hit t=0.148204, path=[359,360,358] (3 polys)
```

**Фактическое поведение (до исправления):**
```
Test #1: path_count=0 ❌
Test #2: path_count=0 ❌
Test #3: path_count=0 ❌
Test #4: path_count=0 ❌
```

---

## Найденные баги

### 🐛 Bug #1: Area Initialization

**Файл:** `test/integration/raycast_test.zig:156`

**Проблема:**
```zig
// НЕПРАВИЛЬНО:
const areas = try allocator.alloc(u8, mesh.tri_count);
@memset(areas, 1);  // ❌ Инициализация как 1 вместо 0
// Отсутствует вызов markWalkableTriangles!
```

**Последствия:**
- Все spans получали `area=1` вместо `area=63` (WALKABLE_AREA)
- Span count: 55,226 вместо 55,218 (+8 лишних spans)
- Compact heightfield indices смещены на +1
- Distance field propagation использует неправильные neighbor indices
- Systematic +1 error в distance values

**Исправление:**
```zig
// ПРАВИЛЬНО:
const areas = try allocator.alloc(u8, mesh.tri_count);
@memset(areas, 0); // ✅ Initialize as NULL_AREA

// Mark walkable triangles
nav.recast.filter.markWalkableTriangles(
    &ctx,
    config.walkable_slope_angle,
    mesh.vertices,
    mesh.indices,
    areas,
);
```

---

### 🐛 Bug #2: erodeWalkableArea Over-Erosion

**Файл:** `src/recast/area.zig:367-368`

**Проблема:**
```zig
// НЕПРАВИЛЬНО:
if (dist[i] <= min_boundary_dist) {  // ❌ Использует <=
    chf.areas[i] = NULL_AREA;
}
```

**C++ reference:**
```cpp
// ПРАВИЛЬНО:
if (distanceToBoundary[spanIndex] < minBoundaryDistance) {  // ✅ Использует <
    compactHeightfield.areas[spanIndex] = RC_NULL_AREA;
}
```

**Последствия:**
- Incorrectly eroded one extra "ring" of walkable spans
- Spans 6612, 6666 и другие неправильно помечались как NULL_AREA
- Wrong boundary detection в distance field calculation
- max_distance: 46 вместо 47
- watershed regions: 47 вместо 46
- contours: 40 вместо 44
- polygons: 194 вместо 207

**Исправление:**
```zig
// ПРАВИЛЬНО:
if (dist[i] < min_boundary_dist) {  // ✅ Использует <
    chf.areas[i] = NULL_AREA;
}
```

---

### 🐛 Bug #3: perp2D Formula Sign Error

**Файл:** `src/math.zig:688-690`

**Проблема:**
```zig
// НЕПРАВИЛЬНО:
const n = edge[0] * diff[2] - edge[2] * diff[0];  // ❌ Неправильный порядок
const d = dir[0] * edge[2] - dir[2] * edge[0];    // ❌ Неправильный порядок
```

**C++ reference (DetourCommon.h:326):**
```cpp
// ПРАВИЛЬНО:
inline float dtVperp2D(const float* u, const float* v) {
    return u[2]*v[0] - u[0]*v[2];  // ✅ Правильный порядок
}
```

**Последствия:**
- Inverted sign of perpendicular dot product
- Entering/leaving edge detection backwards
- Intersection tests возвращают false positives/negatives
- Raycast всегда возвращал `path_count=0`

**Исправление:**
```zig
// ПРАВИЛЬНО (perp2D formula):
// perp2D(u, v) = u[2]*v[0] - u[0]*v[2]
const n = edge[2] * diff[0] - edge[0] * diff[2];  // ✅
const d = dir[2] * edge[0] - dir[0] * edge[2];    // ✅
```

---

## Процесс отладки

### Этап 1: Обнаружение различий в NavMesh

**Обнаружено:**
- Zig NavMesh: 194 polygons
- C++ NavMesh: 207 polygons
- Разница: -13 polygons

**Вывод:** Проблема в NavMesh generation, не в raycast алгоритме.

### Этап 2: Анализ pipeline

**Trace backwards:**
```
Raycast fails (path_count=0)
  ↑ caused by
Different polygon indices (poly 351 vs 359)
  ↑ caused by
Fewer polygons (194 vs 207)
  ↑ caused by
Fewer contours (40 vs 44)
  ↑ caused by
Different regions (41 vs 45)
  ↑ caused by
Wrong max_distance (46 vs 47)
  ↑ caused by
Distance field +1 error
  ↑ caused by
Wrong boundary detection
  ↑ caused by
erodeWalkableArea over-erosion (BUG #2)
  ↑ caused by
8 extra spans (55,226 vs 55,218)
  ↑ caused by
Wrong area values (area=1 vs area=63)
  ↑ caused by
Area initialization bug (BUG #1)
```

### Этап 3: Сравнение с C++

**Добавлены debug outputs:**
- Span count comparison
- Distance field values
- Region boundaries
- Contour vertices
- Polygon counts

**Обнаружена цепочка:**
1. Bug #1 → 8 extra spans
2. Bug #2 → wrong boundary erosion → wrong regions
3. Bug #3 → raycast intersection fails

### Этап 4: Верификация исправлений

После каждого исправления:
1. Rebuild NavMesh
2. Compare with C++ output
3. Run raycast tests
4. Verify 0 memory leaks

---

## Исправления

### Исправление #1: Area Initialization

**Commit:** [Add markWalkableTriangles call](link-to-commit)

**Файлы изменены:**
- `test/integration/raycast_test.zig`

**Изменения:**
```diff
  const areas = try allocator.alloc(u8, mesh.tri_count);
- @memset(areas, 1);
+ @memset(areas, 0); // Initialize as NULL_AREA
+
+ // Mark walkable triangles
+ nav.recast.filter.markWalkableTriangles(
+     &ctx,
+     config.walkable_slope_angle,
+     mesh.vertices,
+     mesh.indices,
+     areas,
+ );
```

**Результат:**
- ✅ Span count: 55,218 (было 55,226)
- ✅ All spans have area=63 (было area=1)
- ✅ Compact heightfield indices правильные

### Исправление #2: erodeWalkableArea Condition

**Commit:** [Fix erode boundary condition](link-to-commit)

**Файлы изменены:**
- `src/recast/area.zig`

**Изменения:**
```diff
- if (dist[i] <= min_boundary_dist) {
+ if (dist[i] < min_boundary_dist) {
      chf.areas[i] = NULL_AREA;
  }
```

**Результат:**
- ✅ max_distance: 47 (было 46)
- ✅ regions: 46 (было 47)
- ✅ contours: 44 (было 40)
- ✅ polygons: 207 (было 194)

### Исправление #3: perp2D Formula

**Commit:** [Fix perp2D cross product order](link-to-commit)

**Файлы изменены:**
- `src/math.zig`

**Изменения:**
```diff
- const n = edge[0] * diff[2] - edge[2] * diff[0];
- const d = dir[0] * edge[2] - dir[2] * edge[0];
+ const n = edge[2] * diff[0] - edge[0] * diff[2];
+ const d = dir[2] * edge[0] - dir[0] * edge[2];
```

**Результат:**
- ✅ Entering/leaving edge detection правильное
- ✅ Intersection tests корректные
- ✅ Raycast возвращает правильные path_count

---

## Результаты

### Raycast Tests - До исправления ❌

```
Test #1: path_count=0 ❌
Test #2: path_count=0 ❌
Test #3: path_count=0 ❌
Test #4: path_count=0 ❌
```

### Raycast Tests - После исправления ✅

```
Test #1: Hit t=0.174383, normal=(-0.894428, 0.000000, -0.447213), path=[359→360→358] (3 polys) ✅
Test #2: Hit t=FLT_MAX (no hit), path=[350→346→410→407] (4 polys) ✅
Test #3: Hit t=0.000877, normal=(-1.000000, 0.000000, 0.000000), path=[356] (1 poly) ✅
Test #4: Hit t=0.148204, normal=(-0.894428, 0.000000, -0.447213), path=[359→360→358] (3 polys) ✅
```

### Сравнение C++ vs Zig

| Метрика | C++ | Zig (до) | Zig (после) | Статус |
|---------|-----|----------|-------------|--------|
| **Span count** | 55,218 | 55,226 | 55,218 | ✅ |
| **Max distance** | 47 | 46 | 47 | ✅ |
| **Regions** | 46 | 47 | 46 | ✅ |
| **Contours** | 44 | 40 | 44 | ✅ |
| **Polygons** | 207 | 194 | 207 | ✅ |
| **BVH nodes** | 413 | - | 413 | ✅ |
| **Raycast t values** | exact | wrong | exact | ✅ |
| **Path polygons** | exact | wrong | exact | ✅ |

**Итог:** 100% идентичность с C++ reference implementation ✅

### Memory Leaks

- **До исправления:** 0 leaks
- **После исправления:** 0 leaks ✅

---

## Файлы

### Измененные исходники
- `test/integration/raycast_test.zig` - area initialization fix
- `src/recast/area.zig` - erode boundary condition fix
- `src/math.zig` - perp2D formula fix

### Документация
- `ALL_BUGS_FIXED.md` - summary в корне проекта
- `BUG_FIXED.md` - area initialization
- `ERODE_BUG_FIXED.md` - erode boundary
- `DEBUG_HISTORY.md` - полная история отладки

### Тестовые файлы
- `test/integration/raycast_test.zig` - standalone raycast test executable
- `test/integration/raycast_test.txt` - test case file (4 scenarios)

---

## Уроки

### Что узнали

1. **Инициализация критична** - неправильная инициализация areas привела к каскадным ошибкам
2. **Boundary conditions важны** - `<=` vs `<` может изменить весь pipeline
3. **Математические формулы требуют точности** - порядок операций в cross product критичен
4. **Debug early, debug often** - добавление debug outputs на каждом этапе помогло найти root cause
5. **Сравнение с reference** - byte-by-byte comparison выявил все различия

### Best Practices

1. **Всегда инициализируйте правильно** - используйте правильные константы (NULL_AREA, WALKABLE_AREA)
2. **Проверяйте граничные условия** - `<` vs `<=` может быть критичным
3. **Верифицируйте математику** - сверяйтесь с reference implementation для формул
4. **Тестируйте end-to-end** - integration тесты выявляют каскадные ошибки
5. **Добавляйте debug outputs** - помогает trace проблемы через весь pipeline

---

## Заключение

Все 3 бага были успешно исправлены. Raycast теперь работает **идентично C++ reference implementation** с точностью до последней цифры float.

**Статус:** ✅ **ИСПРАВЛЕНО - ВЕРИФИЦИРОВАНО - СТАБИЛЬНО**

**Дата завершения:** 2025-10-02

---

**См. также:**
- [Watershed Fix](../watershed-100-percent-fix/INDEX.md) - история исправления watershed bug
- [Test Coverage](../../TEST_COVERAGE_ANALYSIS.md) - полный анализ тестового покрытия
- [Debug History](../../../DEBUG_HISTORY.md) - архив отладочных отчетов
