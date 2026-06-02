# Changelog

Все заметные изменения в проекте zig-recast документированы в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
проект следует [семантическому версионированию](https://semver.org/lang/ru/).

## [Unreleased]

_Нет незарелиженных изменений._

## [0.1.0] - 2026-06-02

Первый тегированный релиз. Чистый Zig-порт Recast & Detour (recast / detour / crowd /
tilecache) под Zig 0.16 + интерактивное GUI-демо (порт RecastDemo на dvui + GLFW/OpenGL).
Готовые бинари демо под Windows / Linux / macOS собираются нативно через GitHub Actions.

Релиз: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0

### Added
- **GUI-демо** (`demo/`, порт RecastDemo на dvui 0.5 + zgl): сэмплы solo/tile/temp-obstacles,
  navmesh-tester, инструменты off-mesh / convex / crowd, режимы отрисовки voxels/contours/navmesh.
- **Crowd-инструмент 1-в-1 с `Tool_Crowd.cpp`**: опции применяются к уже созданным агентам
  (`updateAgentParameters`), оверлей VO / соседей / меток (`%.3f` дистанции), пауза по `SPACE`,
  пошаговая симуляция по `1`, 4 пресета obstacle-avoidance (Avoidance Quality 0–3).
- **Standalone-резолвер ассетов**: демо находит `test_data` рядом с exe / в cwd / вверх по дереву —
  `recast_demo` запускается из любого каталога.
- `rcAddSpan` — публичная обёртка с guard `smin >= smax` (1-в-1 `RecastRasterization.cpp`).
- `dtCrowd.updateAgentParameters`, `CrowdAgentDebugInfo`, `normalizeSamples` для VO-дебага.
- Опциональный `LogSink` в `Context` (перенаправление логов в панель Log демо).
- **Кросс-платформенная сборка** (Windows / Linux / macOS × x86_64 / aarch64) и
  GitHub Actions workflow (`.github/workflows/release.yml`), собирающий нативные бинари демо
  на каждой ОС и публикующий их в Release.

### Changed
- **ztracy сделан опциональным**: по умолчанию — no-op stub (`demo/src/ztracy_stub.zig`),
  реальный ztracy подключается только при `-Dtracy`. Демо собирается без внешних зависимостей
  (CI / свежий clone).
- Ассеты демо устанавливаются рядом с exe (`zig-out/bin/test_data`).
- Установка Zig в CI — прямой загрузкой 0.16.0 с `ziglang.org/download` (исходники Zig переехали
  на Codeberg, старый download-индекс `setup-zig` неактуален).
- Добавлены `.gitattributes` (нормализация переводов строк в LF), почищены dev-артефакты,
  удалён мёртвый таргет `query-diff` из `build.zig`.

### Fixed
- **detail-меш**: `getHeight` переписан на upstream-спираль (выбор высоты по `|nh*ch − fy|`,
  ring-based early-exit), `seedArrayWithPolyCenter` — на корректный DFS-к-центру; добавлен guard
  против `distToTriMesh` на пустом списке треугольников ([upstream #796]) — устраняет UB на больших
  навмешах. (`src/recast/detail.zig`)
- **math**: `distancePtSegSqr2D` теперь клампит к отрезку, а не считает расстояние до бесконечной
  прямой (1-в-1 `DetourCommon.cpp:170-184`). (`src/math.zig`)
- **`filterLedgeSpans`**: операторы приведены к **upstream main** (`>=` / `<`, `RecastFilter.cpp:120,133`).
  Альтернатива `>` / `<=` из открытого [upstream #772] **НЕ принята** — консенсуса в upstream нет.
  _(исправляет прежнюю запись changelog, ошибочно утверждавшую обратное)_. (`src/recast/filter.zig`)
- **detour(navmesh)**: guard числа бит poly-id в `addTile` — поддержка больших миров
  (1-в-1 `DetourNavMesh.cpp:927`). (`src/detour/navmesh.zig`)
- **crowd**: индексы соседей конвертируются active→global (1-в-1 `DetourCrowd.cpp:1095`) — чинит
  порчу separation/collision/рендера при удалённых агентах. (`src/detour_crowd/crowd.zig`)
- **crowd(path_corridor)**: исправлено направление копирования в `mergeCorridorStartMoved/Shortcut`
  (восстановлена семантика `memmove` — порча хвоста коридора при сдвиге влево). (`src/detour_crowd/path_corridor.zig`)
- **recast(layers)**: устранён usize-underflow в цикле перекрытий и краш `deinit` из-за неустановленного
  аллокатора слоя. (`src/recast/layers.zig`)
- **recast(mesh)**: обнуление временных буферов в `removeVertex` (детерминизм под debug-аллокатором). (`src/recast/mesh.zig`)
- Согласованное округление при растеризации — floor вместо truncation на границах тайлов
  ([upstream #766]). (`src/recast/rasterization.zig`)

Сопутствующие исследования багов: `docs/bug_fixes/github_issues/`
(ISSUE_687, ISSUE_766, ISSUE_772, ISSUE_780, ISSUE_783, ISSUE_788, ISSUE_793).

### Known divergences from upstream C++
- `crowd.updateMoveRequest` — упрощённый синхронный `findPath` (без async sliced-pathfinding и
  без merge старого/нового пути с удалением trackbacks).
- `path_queue.getPathResult` — отбрасывает detail-биты (безвредно при синхронном move-request).

---

## Категории изменений

- `Added` — новый функционал
- `Changed` — изменения в существующем функционале
- `Deprecated` — функционал, который скоро будет удалён
- `Removed` — удалённый функционал
- `Fixed` — исправления багов
- `Security` — исправления уязвимостей

[Unreleased]: https://github.com/K4leri/recastnavigation/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/K4leri/recastnavigation/releases/tag/v0.1.0
[upstream #772]: https://github.com/recastnavigation/recastnavigation/pull/772
[upstream #766]: https://github.com/recastnavigation/recastnavigation/pull/766
[upstream #796]: https://github.com/recastnavigation/recastnavigation/pull/796
