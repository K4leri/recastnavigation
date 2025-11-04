# Changelog

Все заметные изменения в проекте zig-recast будут документированы в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Fixed
- **Исправлены операторы сравнения в `filterLedgeSpans`** ([#772](https://github.com/recastnavigation/recastnavigation/issues/729))
  - Исправлена регрессия введенная в upstream PR #672 (декабрь 2023)
  - Возвращены операторы сравнения к оригинальным значениям (`>=` → `>`, `<` → `<=`)
  - Восстановлен консервативный подход к граничным случаям (gap = walkableHeight)
  - **BREAKING:** Navmesh может измениться для пользователей начавших использовать библиотеку после декабря 2023
  - Файлы:
    - `src/recast/filter.zig` (строки 120, 134)
  - Тесты:
    - `test/filter_test.zig`: добавлены регрессионные тесты для граничных случаев
  - Документация:
    - `docs/bug_fixes/github_issues/ISSUE_772_comparison_operators.md`
    - `dev/issue_772_comparison_operators/` (полное исследование проблемы)

- **Исправлено несогласованное округление при растеризации** ([#766](https://github.com/recastnavigation/recastnavigation/issues/765))
  - Заменена truncation (cast to int) на floor для вычисления индексов ячеек
  - Устранена несогласованность между смежными тайлами когда координаты в диапазоне (-1.0, 0.0)
  - Критично для multi-tile navmesh: устраняет gaps на границах тайлов
  - Математическое обоснование: floor обладает свойством монотонности и коммутирует с трансляцией
  - Файлы:
    - `src/recast/rasterization.zig` (строки 208-212, 256-260)
  - Документация:
    - `docs/bug_fixes/github_issues/ISSUE_766_rasterization_rounding.md`
    - `dev/issue_766_rasterization_rounding/` (математический анализ проблемы)

## История версий

_История версий будет добавлена при первом релизе_

---

## Категории изменений

- `Added` - новый функционал
- `Changed` - изменения в существующем функционале
- `Deprecated` - функционал который скоро будет удален
- `Removed` - удаленный функционал
- `Fixed` - исправления багов
- `Security` - исправления уязвимостей
