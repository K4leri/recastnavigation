# GitHub Issue #765 / PR #766: Несогласованное округление при растеризации

**Статус:** ✅ Исправлено
**Дата применения:** 2025-11-04
**Upstream Issue:** [#765](https://github.com/recastnavigation/recastnavigation/issues/765)
**Upstream PR:** [#766](https://github.com/recastnavigation/recastnavigation/pull/766)
**Автор fix:** @pec27 (Mercuna)

---

## Краткое описание

Исправлена критическая ошибка в алгоритме растеризации треугольников, которая приводила к несогласованности между смежными тайлами в multi-tile navmesh когда координаты вершин находились в диапазоне (-1.0, 0.0).

**Корневая причина:** Использование truncation (приведение к int) вместо floor для вычисления индексов ячеек.

**Последствия:** Gaps на границах тайлов, несогласованность высот span'ов, проблемы с навигацией.

---

## Техническое описание проблемы

### Поведение операций округления

**Truncation (cast to int/`@intFromFloat`):**
- Округление **к нулю**
- Для положительных чисел: округление вниз (как floor)
- Для отрицательных чисел: округление **вверх** (к нулю)

**Floor (`@floor`):**
- Округление **вниз** (к минус бесконечности)
- Всегда округляет в направлении уменьшения значения
- Обладает свойством монотонности и коммутирует с трансляцией

### Критический диапазон: (-1.0, 0.0)

Для координат в диапазоне (-1.0, 0.0):

```zig
// Truncation (было):
@intFromFloat(-0.5) = 0  // ❌ Неправильно

// Floor (стало):
@intFromFloat(@floor(-0.5)) = -1  // ✅ Правильно
```

**Разница:** Ровно 1 индекс ячейки!

### Влияние на multi-tile navmesh

При обработке смежных тайлов:
- **Тайл A** обрабатывает вершину с положительной относительной координатой → правильный индекс
- **Тайл B** обрабатывает ту же вершину с отрицательной относительной координатой → неправильный индекс (с truncation)
- **Результат:** Несогласованность на границе тайлов

---

## Применённые изменения

### Файл: `src/recast/rasterization.zig`

#### Изменение 1: Вычисление z0/z1 (строки 208-212)

**Было:**
```zig
var z0 = @as(i32, @intFromFloat((tri_bb_min.z - heightfield_bb_min.z) * inverse_cell_size));
var z1 = @as(i32, @intFromFloat((tri_bb_max.z - heightfield_bb_min.z) * inverse_cell_size));
```

**Стало:**
```zig
// Fix from PR #766: Use @floor for consistent rounding between adjacent tiles
// Issue #765: @intFromFloat does truncation towards zero, causing inconsistencies
// when coordinates are in range (-1.0, 0.0). floor() ensures proper cell indexing.
var z0 = @as(i32, @intFromFloat(@floor((tri_bb_min.z - heightfield_bb_min.z) * inverse_cell_size)));
var z1 = @as(i32, @intFromFloat(@floor((tri_bb_max.z - heightfield_bb_min.z) * inverse_cell_size)));
```

#### Изменение 2: Вычисление x0/x1 (строки 256-260)

**Было:**
```zig
var x0 = @as(i32, @intFromFloat((min_x - heightfield_bb_min.x) * inverse_cell_size));
var x1 = @as(i32, @intFromFloat((max_x - heightfield_bb_min.x) * inverse_cell_size));
```

**Стало:**
```zig
// Fix from PR #766: Use @floor for consistent rounding between adjacent tiles
// Issue #765: @intFromFloat does truncation towards zero, causing inconsistencies
// when coordinates are in range (-1.0, 0.0). floor() ensures proper cell indexing.
var x0 = @as(i32, @intFromFloat(@floor((min_x - heightfield_bb_min.x) * inverse_cell_size)));
var x1 = @as(i32, @intFromFloat(@floor((max_x - heightfield_bb_min.x) * inverse_cell_size)));
```

---

## Математическое обоснование

### Свойства floor

1. **Монотонность:** x ≤ y ⇒ floor(x) ≤ floor(y)
2. **Трансляция:** floor(x + n) = floor(x) + n, для n ∈ ℤ
3. **Согласованность:** Обеспечивает одинаковый индекс для одной координаты во всех тайлах

### Теорема согласованности

Для смежных тайлов A и B с общей границей, использование floor гарантирует:
```
∀p ∈ ℝ: cellIndex_A(p) = cellIndex_B(p) + offset
```
где `offset` - смещение между тайлами в ячейках.

**Доказательство:** См. `dev/issue_766_rasterization_rounding/research/mathematical_analysis.md`

---

## Влияние на пользователей

### Кто затронут

**Все пользователи multi-tile navmesh:**
- Особенно критично для больших открытых миров
- Сцены с крутыми склонами и мелкими треугольниками
- Ландшафты с геометрией пересекающей границы тайлов

### Что изменится

✅ **Улучшения:**
- Устранены gaps на границах тайлов
- Согласованные высоты span'ов между тайлами
- Корректная навигация через границы
- Отсутствие визуальных артефактов

⚠️ **Возможные изменения:**
- Navmesh может незначительно измениться
- Рекомендуется регенерировать navmesh после обновления

### Действия пользователей

1. **Обновить библиотеку** до версии с этим fix
2. **Регенерировать navmesh** для всех сцен
3. **Протестировать** навигацию на границах тайлов
4. **Проверить** критические сцены с крутой геометрией

---

## Тестирование

### Регрессионные тесты

В данной реализации не добавлены специфические регрессионные тесты для этого fix, так как:
- Проблема специфична для multi-tile конфигураций
- Требует сложной настройки граничных случаев
- Существующие интеграционные тесты покрывают общую функциональность растеризации

### Проверка fix

Исправление проверено:
- ✅ Все существующие тесты проходят
- ✅ Математическое доказательство корректности
- ✅ Соответствие upstream PR #766

---

## Дополнительная информация

### Связь с upstream

- **Issue:** https://github.com/recastnavigation/recastnavigation/issues/765
- **PR:** https://github.com/recastnavigation/recastnavigation/pull/766
- **Статус upstream:** Open (ожидает merge)
- **Автор:** @pec27 (Mercuna - профессиональная навигационная система)

### Детальное исследование

Полное математическое и алгоритмическое исследование проблемы доступно в:
- `dev/issue_766_rasterization_rounding/README.md` - навигация
- `dev/issue_766_rasterization_rounding/EXECUTIVE_SUMMARY.md` - краткое резюме
- `dev/issue_766_rasterization_rounding/docs/problem_analysis.md` - детальный анализ
- `dev/issue_766_rasterization_rounding/research/mathematical_analysis.md` - математика

---

## История изменений

| Дата | Версия | Автор | Изменения |
|------|--------|-------|-----------|
| 2025-11-04 | 1.0 | Claude AI | Применено исправление из PR #766 |

---

## Заключение

Данное исправление является **критическим** для правильной работы multi-tile navmesh. Использование `@floor` вместо простого приведения к int обеспечивает математически корректное и согласованное поведение на границах тайлов.

**Рекомендация:** Обязательно применить это исправление для production использования multi-tile navmesh.
