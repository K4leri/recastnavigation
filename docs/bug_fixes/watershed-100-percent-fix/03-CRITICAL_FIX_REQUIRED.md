# КРИТИЧЕСКОЕ ИСПРАВЛЕНИЕ: Реализация mergeAndFilterRegions

## Проблема

**Zig реализация НЕ выполняет слияние и фильтрацию регионов**, что является КРИТИЧЕСКОЙ частью алгоритма watershed partitioning.

В `src/recast/region.zig:565-566`:
```zig
_ = min_region_area; // TODO: Implement region filtering
_ = merge_region_area; // TODO: Implement region merging
```

## Последствия

Без `mergeAndFilterRegions`:

1. **Маленькие регионы не удаляются**
   - Zig: регионы 43-44 имеют 1 и 2 spans
   - C++: регионы 43-44 имеют 44 и 127 spans (после слияния)

2. **Регионы не объединяются с соседями**
   - Различные region assignments каскадируются по всему mesh
   - 2 missing contours в Zig (42 vs 44)
   - 3 missing polygons в Zig (203 vs 206)

3. **Неправильная навигационная сетка**
   - Фрагментированные регионы
   - Лишние или отсутствующие полигоны
   - Потенциально непроходимые области

## Алгоритм mergeAndFilterRegions

### Шаг 1: Построение rcRegion структур

```cpp
struct rcRegion {
    int spanCount;              // Количество spans в регионе
    unsigned short id;          // ID региона
    unsigned char areaType;     // Тип области
    bool remap;                 // Флаг для remapping
    bool visited;               // Флаг посещения при обходе
    bool overlap;               // Флаг перекрывающихся регионов
    bool connectsToBorder;      // Соединен с границей тайла
    unsigned short ymin, ymax;  // Min/max высоты
    vector<int> connections;    // Соседние регионы (упорядочены вокруг контура)
    vector<int> floors;         // Регионы под/над текущим
};
```

Для каждого региона:
- Подсчитать spanCount
- Найти границы (контуры) используя walkContour
- Собрать connections (соседние регионы)
- Собрать floors (вертикально соседние регионы)
- Пометить overlap регионы

### Шаг 2: Удаление слишком малых регионов

```cpp
// Для каждого региона
if (spanCount < minRegionArea && !connectsToBorder) {
    // Удалить регион (установить spanCount = 0, id = 0)
    // НЕ удалять регионы, соединенные с границей тайла
}
```

**minRegionArea = 8** (в нашем тесте)

### Шаг 3: Слияние малых регионов

```cpp
do {
    mergeCount = 0;
    for each region {
        // Условие для слияния:
        if (spanCount > mergeRegionSize && connectsToBorder)
            continue; // Не сливать большие регионы у границы

        // Найти наименьшего соседа для слияния
        smallest = infinity;
        for each neighbor {
            if (canMergeWithRegion(reg, neighbor)) {
                if (neighbor.spanCount < smallest) {
                    smallest = neighbor.spanCount;
                    mergeId = neighbor.id;
                }
            }
        }

        // Выполнить слияние
        if (mergeId != reg.id) {
            mergeRegions(target, reg);
            // Обновить все ссылки
        }
    }
} while (mergeCount > 0);
```

**mergeRegionSize = 20** (в нашем тесте)

### Шаг 4: Сжатие Region IDs

После удаления и слияния регионов остаются "дыры" в нумерации.
Перенумеровать регионы последовательно: 1, 2, 3, ...

### Шаг 5: Remapping

Применить новые region IDs к spans в compact heightfield.

## Вспомогательные функции

### walkContour
- Обходит контур региона
- Собирает соседние регионы в порядке обхода
- Используется для построения connections

### canMergeWithRegion
- Проверяет, можно ли слить два региона:
  - Одинаковый areaType
  - Не более 1 соединения между ними
  - Не вертикально соседние (floors)

### mergeRegions
- Объединяет connections двух регионов
- Объединяет floors
- Обновляет spanCount

### isSolidEdge
- Проверяет, является ли край solid (граничный)
- Используется в walkContour

### replaceNeighbour
- Заменяет oldId на newId в connections и floors
- Удаляет дубликаты

## План реализации

1. ✅ Создать структуру `Region` в Zig
2. ✅ Реализовать вспомогательные функции:
   - removeAdjacentNeighbours
   - replaceNeighbour
   - canMergeWithRegion
   - addUniqueFloorRegion
   - mergeRegions
   - isRegionConnectedToBorder
   - isSolidEdge
   - walkContour

3. ✅ Реализовать mergeAndFilterRegions:
   - Построение rcRegion структур
   - Удаление малых регионов
   - Слияние регионов
   - Сжатие IDs
   - Remapping

4. ✅ Интегрировать в buildRegions
5. ✅ Тестировать с nav_test.obj
6. ✅ Достичь 100% соответствия с C++

## Ожидаемый результат

После реализации:
- **Zig**: 432 vertices, 206 polygons, 44 contours
- **C++**: 432 vertices, 206 polygons, 44 contours
- **100% точное соответствие** ✅
