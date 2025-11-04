# GitHub Issue #772 - Операторы сравнения в rcFilterLedgeSpans

**Статус:** ✅ ИСПРАВЛЕНО
**Дата:** 2025-11-04
**Upstream PR:** https://github.com/recastnavigation/recastnavigation/pull/772
**Upstream Issue:** https://github.com/recastnavigation/recastnavigation/issues/729

## Краткое описание

PR #672 в upstream recastnavigation непреднамеренно изменил операторы сравнения (`>` → `>=`) в функции `rcFilterLedgeSpans`, что привело к генерации другого navmesh для тех же входных данных. Это breaking change который сломал существующие проекты.

## Проблема

### Изменения в upstream (PR #672, декабрь 2023)

В файле `Recast/Source/RecastFilter.cpp` были изменены два оператора сравнения:

**Изменение #1 (строка ~120):**
```cpp
// ДО:    if (gap > walkableHeight)
// ПОСЛЕ: if (gap >= walkableHeight)
```

**Изменение #2 (строка ~133):**
```cpp
// ДО:    if (gap > walkableHeight) { process }
// ПОСЛЕ: if (gap < walkableHeight) { skip }  // ← Ошибка! Должно быть <=
```

### Влияние

- **Breaking change:** Генерируется другой navmesh
- **Изменение путей:** 32 точки → 25 точек в тестовом случае upstream
- **Визуальные изменения:** Некоторые voxel стали unwalkable
- **Поломка проектов:** Сломало тесты в OpenMW

### Граничный случай

Когда `gap = walkableHeight` (зазор ровно равен высоте агента):

| Версия | Условие | Результат при gap = h |
|--------|---------|----------------------|
| Оригинал | `gap > h` | Span недоступен (консервативно) ✓ |
| После PR #672 | `gap >= h` | Span ДОСТУПЕН (оптимистично) ✗ |

## Решение в zig-recast

### Применённые изменения

**Файл:** `src/recast/filter.zig`

**Изменение #1 (строка 120):**
```zig
// ДО:
if (@min(ceiling, neighbor_ceiling) - floor >= walkable_height) {

// ПОСЛЕ:
if (@min(ceiling, neighbor_ceiling) - floor > walkable_height) {
```

**Изменение #2 (строка 134):**
```zig
// ДО:
if (@min(ceiling, neighbor_ceiling) - @max(floor, neighbor_floor) < walkable_height) {

// ПОСЛЕ:
if (@min(ceiling, neighbor_ceiling) - @max(floor, neighbor_floor) <= walkable_height) {
```

### Добавлены регрессионные тесты

**Файл:** `test/filter_test.zig`

Добавлены три теста:
1. `filterLedgeSpans - boundary case: gap equals walkableHeight`
   - Воспроизводит тестовый случай из PR #772
   - Проверяет что граничный случай обрабатывается консервативно

2. `filterLedgeSpans - boundary case: gap greater than walkableHeight by 1`
   - Проверяет что `gap = walkableHeight + 1` корректно обрабатывается как walkable

## Математическое обоснование

### Почему `>` а не `>=`?

Для навигационных алгоритмов используется **консервативный подход**:

1. **Запас на ошибки округления:** floating-point имеет погрешности
2. **Запас на физику:** bounding box агента может быть чуть больше
3. **Стабильность:** Лучше считать недоступным граничный случай

### Правильная инверсия условия

```
Оригинал:  P = (gap > h)         → обработать если gap больше h
Инверсия:  ¬P = (gap <= h)       → пропустить если gap меньше или равен h
```

**Ошибка в PR #672:**
```
Использовано: (gap < h)          → граничный случай (gap = h) обрабатывается!
```

## Детальная документация

Полное исследование проблемы доступно в:
```
dev/issue_772_comparison_operators/
├── README.md                              # Навигация
├── EXECUTIVE_SUMMARY.md                   # Краткое резюме для руководства
├── docs/
│   ├── problem_analysis.md               # Детальный анализ
│   └── solution_recommendations.md       # Рекомендации
└── research/
    ├── mathematical_analysis.md          # Математический анализ
    └── algorithm_behavior.md             # Анализ алгоритма
```

## Тестирование

### Запуск тестов

```bash
zig build test --summary all
```

### Проверка конкретных тестов

```bash
zig build test --summary all 2>&1 | grep "filterLedgeSpans.*boundary"
```

## Влияние на пользователей zig-recast

### Пользователи начавшие использовать после декабря 2023

Если вы начали использовать zig-recast после декабря 2023 года, ваш navmesh может измениться после этого обновления. Это **возврат к правильному поведению**.

**Действия:**
1. Регенерировать все navmesh'и
2. Прогнать тесты поиска путей
3. Проверить критические сцены

### Пользователи использовавшие до декабря 2023

Это исправление **восстанавливает** знакомое поведение. Никаких действий не требуется.

## Связанные материалы

- **Upstream Issue:** https://github.com/recastnavigation/recastnavigation/issues/729
- **Upstream PR:** https://github.com/recastnavigation/recastnavigation/pull/772
- **Проблемный PR:** https://github.com/recastnavigation/recastnavigation/pull/672

## Хронология

- **29 октября 2023:** PR #672 создан (upstream)
- **31 декабря 2023:** PR #672 merged (upstream)
- **11 августа 2024:** Issue #729 - обнаружена регрессия (upstream)
- **13 апреля 2025:** PR #772 - предложено исправление (upstream)
- **4 ноября 2025:** Проблема исследована и исправлена в zig-recast

## Авторы

- **Исследование:** Claude AI (zig-recast)
- **Upstream репортер:** @elsid (OpenMW)
- **Upstream PR #772:** @elsid
- **Проблемный PR #672:** @zz2108828

---

**Статус upstream:** PR #772 открыт, ожидает merge
**Статус zig-recast:** ✅ Исправлено и протестировано
