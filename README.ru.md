# Recast Navigation - Zig Implementation

[English](README.md) | **Русский**

Полная Zig реализация библиотеки [RecastNavigation](https://github.com/recastnavigation/recastnavigation) для создания навигационных мешей и поиска пути.

## ✨ Особенности

- **Безопасность памяти**: Явные аллокаторы, никаких скрытых выделений памяти
- **Типобезопасность**: Использование строгой системы типов Zig и comptime
- **Обработка ошибок**: Настоящие типы ошибок вместо boolean returns
- **Современный дизайн**: Чистый API следующий идиомам Zig
- **Производительность**: Оптимизация через inline функции и comptime генерацию
- **Нулевые зависимости**: Чистая Zig реализация
- **100% точность**: Byte-for-byte идентичность с C++ reference implementation

## 📁 Структура проекта

```
zig-recast/
├── src/                      # Исходный код библиотеки
│   ├── root.zig              # Главная точка входа
│   ├── math.zig              # Математические типы (Vec3, AABB, etc.)
│   ├── context.zig           # Build context и логирование
│   ├── recast.zig            # Recast модуль (построение NavMesh)
│   ├── detour.zig            # Detour модуль (pathfinding)
│   ├── detour_crowd.zig      # DetourCrowd (multi-agent симуляция)
│   └── detour_tilecache.zig  # TileCache (динамические препятствия)
│
├── examples/                 # Примеры использования
│   ├── simple_navmesh.zig    # Базовый пример создания NavMesh
│   ├── pathfinding_demo.zig  # Демо поиска пути
│   ├── crowd_simulation.zig  # Симуляция толпы агентов
│   ├── dynamic_obstacles.zig # Динамические препятствия
│   ├── 02_tiled_navmesh.zig  # Tiled NavMesh
│   ├── 03_full_pathfinding.zig # Полный pathfinding
│   └── 06_offmesh_connections.zig # Off-mesh соединения
│
├── bench/                    # Бенчмарки производительности
│   ├── recast_bench.zig      # Recast pipeline benchmark
│   ├── detour_bench.zig      # Detour queries benchmark
│   ├── crowd_bench.zig       # Crowd simulation benchmark
│   └── findStraightPath_detailed.zig
│
├── test/                     # Тесты (183 unit + 21 integration)
│   ├── integration/          # Интеграционные тесты
│   └── ...                   # Unit тесты
│
├── docs/                     # 📚 Полная документация
│   ├── README.md             # Навигация по документации
│   ├── en/                   # Английская документация
│   ├── ru/                   # Русская документация
│   └── bug-fixes/            # История исправлений багов
│
└── build.zig                 # Конфигурация сборки
```

## 🧩 Модули

### Recast - Построение NavMesh

Создание навигационных мешей из треугольных мешей:

- ✅ `Heightfield` - Voxel-based представление высотного поля
- ✅ `CompactHeightfield` - Компактное представление для обработки
- ✅ `Region Building` - Watershed partitioning с multi-stack системой
- ✅ `ContourSet` - Экстракция контуров регионов
- ✅ `PolyMesh` - Финальный полигональный меш
- ✅ `PolyMeshDetail` - Детальный меш для точных запросов высоты

### Detour - Pathfinding и запросы

Навигационные запросы и поиск пути:

- ✅ `NavMesh` - Runtime навигационный меш
- ✅ `NavMeshQuery` - Запросы поиска пути и spatial queries
- ✅ `A* Pathfinding` - Поиск оптимального пути
- ✅ `Raycast` - Проверка видимости и raycast запросы
- ✅ `Distance Queries` - Запросы расстояний

### DetourCrowd - Multi-Agent симуляция

Управление множеством агентов:

- ✅ `Crowd Manager` - Менеджер толпы
- ✅ `Agent Movement` - Движение агентов
- ✅ `Local Steering` - Локальное управление
- ✅ `Obstacle Avoidance` - Избегание препятствий

### TileCache - Динамические препятствия

Поддержка динамических препятствий:

- ✅ `TileCache` - Кеш тайлов с динамическими изменениями
- ✅ `Obstacle Management` - Управление препятствиями (box, cylinder, oriented box)
- ✅ `Dynamic NavMesh Updates` - Динамическое обновление NavMesh

## 🚀 Быстрый старт

### Требования

- Zig 0.15.0 или новее

### Сборка библиотеки

```bash
zig build
```

### Запуск тестов

```bash
# Все тесты (unit + integration)
zig build test

# Только интеграционные тесты
zig build test-integration

# Конкретный набор тестов
zig build test:filter
zig build test:rasterization
zig build test:contour
```

### Запуск примеров

```bash
# Сборка всех примеров
zig build examples

# Базовый пример NavMesh
./zig-out/bin/simple_navmesh

# Демо поиска пути
./zig-out/bin/pathfinding_demo

# Симуляция толпы
./zig-out/bin/crowd_simulation

# Динамические препятствия
./zig-out/bin/dynamic_obstacles
```

### Запуск бенчмарков

```bash
# Recast pipeline benchmark
zig build bench-recast

# Detour queries benchmark
zig build bench-detour

# Crowd simulation benchmark
zig build bench-crowd
```

## ✅ Статус тестирования

**Текущий статус:**

- ✅ **201/201 тестов проходят** (183 unit + 21 integration)
- ✅ **100% точность** по сравнению с C++ reference implementation
- ✅ **0 утечек памяти** во всех тестах
- ✅ Recast pipeline полностью протестирован
- ✅ Detour pipeline полностью протестирован (pathfinding, raycast, queries)
- ✅ DetourCrowd полностью протестирован (movement, steering, avoidance)
- ✅ TileCache полностью протестирован (все типы препятствий)

**🎉 Достижение: Идентичная генерация NavMesh**

Zig реализация производит **byte-for-byte идентичные** навигационные меши с C++ reference:

- 44/44 контура ✅
- 432/432 вершины ✅
- 206/206 полигонов ✅

См. [docs/bug-fixes/watershed-100-percent-fix](docs/bug-fixes/watershed-100-percent-fix/INDEX.md) для полной истории достижения 100% точности.

## 📝 Пример использования

```zig
const std = @import("std");
const recast_nav = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create build context
    var ctx = recast_nav.Context.init(allocator);

    // Configure navmesh parameters
    var config = recast_nav.RecastConfig{
        .cs = 0.3,  // Cell size
        .ch = 0.2,  // Cell height
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
    };

    // Set bounds from input geometry
    config.bmin = recast_nav.Vec3.init(0, 0, 0);
    config.bmax = recast_nav.Vec3.init(100, 10, 100);

    // Create heightfield
    var heightfield = try recast_nav.Heightfield.init(
        allocator,
        100, 100,  // width, height
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
    );
    defer heightfield.deinit();

    // Build navigation mesh...
    // См. examples/simple_navmesh.zig для полного примера
}
```

Больше примеров в директории `examples/`:

- `simple_navmesh.zig` - создание базового NavMesh
- `pathfinding_demo.zig` - поиск пути
- `crowd_simulation.zig` - симуляция толпы
- `dynamic_obstacles.zig` - динамические препятствия

## 🔄 Отличия от C++ версии

### Управление памятью

```zig
// Zig: Явный аллокатор
var heightfield = try Heightfield.init(allocator, ...);
defer heightfield.deinit();

// C++: Глобальный аллокатор
rcHeightfield* heightfield = rcAllocHeightfield();
rcFreeHeightfield(heightfield);
```

### Обработка ошибок

```zig
// Zig: Error unions
const result = try buildNavMesh(allocator, config);

// C++: Boolean returns
bool success = rcBuildNavMesh(...);
if (!success) { /* handle error */ }
```

### Типобезопасность

```zig
// Zig: Строгая типизация с enums
const area_id = recast_nav.recast.AreaId.WALKABLE_AREA;

// C++: Сырые константы
const unsigned char RC_WALKABLE_AREA = 63;
```

## 🗺️ Roadmap

### Phase 1: Базовые структуры ✅ (завершено)

- [x] Математические типы (Vec3, AABB)
- [x] Heightfield структуры
- [x] Compact heightfield
- [x] Polygon mesh структуры
- [x] NavMesh базовые структуры

### Phase 2: Recast Building ✅ (завершено)

- [x] Heightfield rasterization
- [x] Filtering functions
- [x] Region building (watershed partitioning с multi-stack системой)
- [x] Contour generation
- [x] Polygon mesh building
- [x] Detail mesh building
- [x] **100% точность** проверена с C++ reference

### Phase 3: Detour Queries ✅ (завершено)

- [x] NavMesh queries
- [x] Pathfinding (A\*)
- [x] Ray casting
- [x] Distance queries
- [x] Nearest polygon search
- [x] **100% точность** проверена с C++ reference

### Phase 4: Продвинутые функции ✅ (завершено)

- [x] Crowd simulation (DetourCrowd)
- [x] Dynamic obstacles (DetourTileCache)
- [x] Off-mesh connections
- [x] Area costs
- [x] Local steering
- [x] Obstacle avoidance

### Phase 5: Оптимизация и доработка 🚧 (в процессе)

- [ ] SIMD оптимизации
- [x] Benchmark suite (базовые бенчмарки готовы)
- [x] Документация (полная документация в docs/)
- [x] Примеры использования

## 🎯 Цели по производительности

- Соответствовать или превосходить производительность C++
- Ноль аллокаций в горячих путях (pathfinding)
- Использование Zig comptime для специализации кода
- Опциональные SIMD оптимизации для векторных операций

## 📊 Известные ограничения

**Текущее состояние:** Все 201 тест проходят без утечек памяти.

**Последние достижения:**

- ✅ Исправлен watershed partitioning для 100% точности ([детали](docs/bug-fixes/watershed-100-percent-fix/INDEX.md))
- ✅ Исправлены 3 критических бага в raycast ([детали](docs/bug-fixes/raycast-fix/INDEX.md)):
  - Area initialization bug
  - erodeWalkableArea boundary condition
  - perp2D formula sign error
- ✅ Реализована multi-stack система для детерминированного region building
- ✅ Полная реализация `mergeAndFilterRegions`
- ✅ Проверена byte-for-byte идентичность с C++ RecastNavigation

## 📚 Документация

📖 **[Полная документация](docs/README.md)** - навигация по всей документации проекта

### Основные разделы

#### 🚀 Для начинающих

- [Installation & Setup](docs/ru/01-getting-started/installation.md) - установка и настройка
- [Quick Start Guide](docs/ru/01-getting-started/quick-start.md) - создайте NavMesh за 5 минут
- [Building & Testing](docs/ru/01-getting-started/building.md) - сборка и тестирование

#### 🏗️ Архитектура

- [System Overview](docs/ru/02-architecture/overview.md) - обзор системы
- [Recast Pipeline](docs/ru/02-architecture/recast-pipeline.md) - процесс построения NavMesh
- [Detour Pipeline](docs/ru/02-architecture/detour-pipeline.md) - система pathfinding
- [Memory Model](docs/ru/02-architecture/memory-model.md) - управление памятью
- [DetourCrowd](docs/ru/02-architecture/detour-crowd.md) - multi-agent симуляция
- [TileCache](docs/ru/02-architecture/tilecache.md) - динамические препятствия

#### 📖 API Reference

- [Math API](docs/ru/03-api-reference/math-api.md) - математические типы
- [Recast API](docs/ru/03-api-reference/recast-api.md) - построение NavMesh
- [Detour API](docs/ru/03-api-reference/detour-api.md) - pathfinding и queries

#### 📝 Практические руководства

- [Creating NavMesh](docs/ru/04-guides/creating-navmesh.md) - пошаговое создание NavMesh
- [Pathfinding](docs/ru/04-guides/pathfinding.md) - поиск пути
- [Raycast Queries](docs/ru/04-guides/raycast.md) - raycast запросы

#### 🐛 История исправлений

- [Watershed Fix](docs/bug-fixes/watershed-100-percent-fix/INDEX.md) ⭐ - достижение 100% точности
- [Raycast Fix](docs/bug-fixes/raycast-fix/INDEX.md) ⭐ - 3 критических исправления
- [Hole Construction Fix](docs/bug-fixes/hole-construction-fix/INDEX.md) - исправление построения отверстий

#### 🧪 Тестирование

- [Test Coverage Analysis](TEST_COVERAGE_ANALYSIS.md) - анализ покрытия тестами
- [Running Tests](docs/06-testing/running-tests.md) - запуск тестов

## 🤝 Контрибуция

Проект активно развивается. Contributions приветствуются!

См. [Contributing Guide](docs/10-contributing/development.md) для настройки dev окружения и guidelines.

## 📄 Лицензия

Эта реализация следует той же лицензии, что и оригинальная RecastNavigation (zlib license).

## 🙏 Благодарности

- **Mikko Mononen** - автор оригинальной RecastNavigation
- **Zig Community** - за отличный язык и поддержку

## 🔗 Ссылки

- [RecastNavigation GitHub](https://github.com/recastnavigation/recastnavigation) - оригинальная C++ реализация
- [Zig Language](https://ziglang.org/) - официальный сайт Zig
