# zig-recast

Порт на Zig навигационного тулкита [Recast & Detour](https://github.com/recastnavigation/recastnavigation) —
выпекание navmesh, поиск пути, симуляция толпы и tile cache для динамических
препятствий.

[English](README.md) | Русский

![демо zig-recast](docs/recast_demo.png)

На скриншоте — встроенное GUI-демо (`zig build run-demo`), переписанные на
Zig/dvui инструменты оригинального RecastDemo.

## Что это

Код близко следует структуре оригинала на C++ — файл-в-файл и, где это важно,
строка-в-строку — чтобы его можно было сверять с эталоном и отслеживать его
обновления. Порт сохраняет исходные `i32`-поля ядра и раскладку данных ради
fidelity, добавляя сверху конвенции Zig: явные аллокаторы, error unions вместо
возврата `bool` и очистку через `defer`.

Это активный порт (версия `0.1.x`), а не готовая 1.0. Основные конвейеры
работают и покрыты тестами, но некоторые места оригинала намеренно упрощены или
ещё дорабатываются — см. [Статус](#статус).

## Модули

| Модуль | Назначение |
| --- | --- |
| `recast` | Сборка navmesh из «супа» треугольников: heightfield → compact heightfield → регионы → контуры → poly mesh → detail mesh. |
| `detour` | Runtime-navmesh и запросы: A\* и sliced-поиск пути, string-pulling, raycast, ближайший полигон, случайные точки, расстояние до стены. |
| `detour_crowd` | Управление толпой агентов: коридоры пути, локальная граница, обход препятствий, асинхронный реплан через очередь путей. |
| `detour_tilecache` | Сжатые тайлы с runtime-препятствиями (box / cylinder / oriented box) и инкрементальной пересборкой navmesh. |
| `debug` | Примитивы debug-отрисовки и бинарный dump/read промежуточных структур (используется демо). |

## Требования

- **Zig 0.16.0** (зависимость демо `dvui` требует именно её; сама библиотека —
  чистый Zig). На 0.15.x не соберётся.

## Сборка и тесты

```bash
zig build                 # собрать библиотеку
zig build test            # unit + integration тесты
zig build test-integration

zig build examples        # собрать примеры
zig build bench-recast    # бенчмарки: -recast / -detour / -crowd
```

## Запуск демо

GUI на dvui (GLFW + OpenGL): загружает геометрию, выпекает navmesh и даёт
инструменты RecastDemo — NavMesh Tester, Crowd, Tile и debug-оверлеи.

```bash
zig build run-demo
```

## Использование как библиотеки

Добавьте зависимость в `build.zig.zon` и импортируйте модуль:

```zig
const recast = @import("recast-nav");

var ctx = recast.Context.init(allocator);

var config = recast.RecastConfig{
    .cs = 0.3,
    .ch = 0.2,
    .walkable_slope_angle = 45.0,
    .walkable_height = 20,
    .walkable_climb = 9,
    .walkable_radius = 8,
    .max_edge_len = 12,
    .max_simplification_error = 1.3,
    .min_region_area = 8,
    .merge_region_area = 20,
    .max_verts_per_poly = 6,
    .detail_sample_dist = 6.0,
    .detail_sample_max_error = 1.0,
    .bmin = recast.Vec3.init(0, 0, 0),
    .bmax = recast.Vec3.init(100, 10, 100),
};

// ... растеризовать треугольники, отфильтровать, построить регионы/контуры/меш,
//     затем создать данные Detour navmesh и делать запросы.
```

Готовые сквозные примеры — в `examples/`:

- `simple_navmesh.zig` — выпечь navmesh из коробки.
- `pathfinding_demo.zig` — найти и пройти путь.
- `crowd_simulation.zig` — провести несколько агентов к цели.
- `dynamic_obstacles.zig` — tile cache + runtime-препятствия.

## Отличия от версии на C++

- **Память** — каждый билдер принимает явный `std.mem.Allocator`; глобального
  аллокатора нет. Структуры владеют своими буферами и освобождают их в `deinit`.
- **Ошибки** — падающие операции возвращают Zig error unions (`!T`) вместо
  `bool` + out-параметров.
- **Типы** — поля ядра recast/detour остаются `i32` 1-в-1 с раскладкой C++
  (многие — знаковые сентинелы); поверх добавлены `usize`-геттеры для чистых
  call-site на Zig.

## Статус

Конвейеры выпекания Recast, запросов Detour, толпы и tile cache реализованы и
проверяются unit- и integration-тестами (`zig build test`, сейчас зелёные).
Известные намеренные отклонения от оригинала задокументированы в
`.agent/core-changes-justification.md` — например, сравнение ledge-спанов
следует текущему upstream `main` (оспаривается открытым upstream-PR), а ряд
serialization/endian-хелперов существует в основном для полноты.

## Бенчмарки

[Zig-ядро](https://github.com/K4leri/recastnavigation/tree/benchmark) против [эталонного C++ recastnavigation](https://github.com/K4leri/recastnavigation-bench), замер честный: одинаковые
плотные игровые карты, общий детерминированный контракт входов, C++ собран
`/arch:AVX2` + строгий IEEE float. Каждая функция замеряется **K=15 прогонов на
сторону, чередуясь**, результат — **медиана времени Zig÷C++ с 95 % bootstrap-CI**;
зоны суб-~200 нс (ниже floor таймера) исключены как квантовый шум.
`ratio < 1.00 = Zig быстрее`.

| Слой | Zig÷C++ | Скорость | Значимые зоны (быстрее / медленнее / ничья) |
|---|:--:|---|---|
| **BUILD** · выпечка navmesh | **0.82** | `▓▓▓▓▓▓░░░░` в 1.22× | 157 быстрее · 14 медленнее · 18 ничья |
| **CROWD** · управление толпой | **0.83** | `▓▓▓▓▓▓░░░░` в 1.20× | 68 быстрее · 10 медленнее · 3 ничья |
| **QUERY** · поиск пути / запросы | **0.93** | `▓▓░░░░░░░░` в 1.07× | 7 быстрее · 1 медленнее · 4 ничья |
| **TILECACHE** · динам. препятствия | **0.98** | `▓░░░░░░░░░` в 1.02× | 27 быстрее · 9 медленнее · 4 ничья |

**Итого ≈ 0.85** (геометрическое среднее по 322 trusted-зонам) — каждый слой на
уровне C++ или быстрее. Выигрыши — раскладка данных и `comptime` на уровне стадий
пайплайна; листовая математика уже в оптимуме (каждый аналог либо бит-идентичен,
либо отвергнут гейтом бит-идентичности). **Без SIMD** (`@Vector` сознательно вне
скоупа).

Полные пер-зонные таблицы, доверительные интервалы и методология — в
[`docs/perf-audit/`](docs/perf-audit/). Цифры измерены на
[ветке `benchmark`](https://github.com/K4leri/recastnavigation/tree/benchmark)
(Tracy-инструментация и эксперименты живут там; в shipping `master` входят только
доказанные, output-идентичные выигрыши).

## Roadmap

Корректность и fidelity были первыми — они закрыты. Производительность
**охарактеризована измерениями, а не догадками** — см. [Бенчмарки](#бенчмарки)
выше. За рамками 1-в-1 порта на горизонте один опциональный модуль:

- **Influence maps (`DetourInfluence`)** — тактический слой над navmesh (поля
  угрозы / видимости / контроля территории с temporal decay и запросами «где
  безопаснее»), в духе upstream-предложения
  ([обсуждение #794](https://github.com/recastnavigation/recastnavigation/discussions/794)).
  Независимый, подключаемый по желанию модуль вроде DetourCrowd — только после
  того, как ядро порта стабилизируется.

## Раскладка

```
src/
  math.zig            векторы, геометрические хелперы
  context.zig         build-контекст + sink логирования
  recast/             конвейер выпекания navmesh
  detour/             runtime-navmesh + запросы + builder
  detour_crowd/       толпа, коридор, обход, очередь путей
  detour_tilecache/   tile cache + препятствия
  debug/              debug-отрисовка + dump
examples/             готовые примеры использования
bench/                бенчмарки
demo/                 GUI-демо на dvui (zig build run-demo)
test/                 unit + integration тесты
```

## Лицензия

zlib, как и у оригинального RecastNavigation. См. [LICENSE](LICENSE).

Оригинальные C++ Recast & Detour © Mikko Mononen. Это независимый порт на Zig.

## Ссылки

- [RecastNavigation](https://github.com/recastnavigation/recastnavigation) — эталон на C++
- [Zig](https://ziglang.org/)
