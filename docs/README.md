# Recast Navigation - Zig Implementation Documentation

Полная документация по Zig реализации библиотеки RecastNavigation для создания навигационных мешей и поиска пути.

## 📚 Содержание

### 🚀 [01. Getting Started](01-getting-started/)
Начните здесь, если вы новичок в библиотеке.

- **[Installation & Setup](01-getting-started/installation.md)** - установка Zig и настройка проекта
- **[Quick Start Guide](01-getting-started/quick-start.md)** - создайте свой первый NavMesh за 5 минут
- **[Building & Testing](01-getting-started/building.md)** - как собрать проект и запустить тесты

### 🏗️ [02. Architecture](02-architecture/)
Понимание внутреннего устройства библиотеки.

- **[System Overview](02-architecture/overview.md)** - общая архитектура и компоненты
- **[Recast Pipeline](02-architecture/recast-pipeline.md)** - процесс построения NavMesh из mesh
- **[Detour Pipeline](02-architecture/detour-pipeline.md)** - pathfinding и query система
- **[Memory Model](02-architecture/memory-model.md)** - управление памятью в Zig
- **[Error Handling](02-architecture/error-handling.md)** - обработка ошибок

### 📖 [03. API Reference](03-api-reference/)
Детальная документация по всем API.

#### Recast (NavMesh Building)
- **[Heightfield](03-api-reference/recast/heightfield.md)** - voxel representation
- **[Compact Heightfield](03-api-reference/recast/compact.md)** - compressed representation
- **[Regions](03-api-reference/recast/regions.md)** - region partitioning
- **[Contours](03-api-reference/recast/contours.md)** - contour extraction
- **[PolyMesh](03-api-reference/recast/polymesh.md)** - polygon mesh
- **[Detail Mesh](03-api-reference/recast/detail-mesh.md)** - detail triangulation

#### Detour (Pathfinding)
- **[NavMesh](03-api-reference/detour/navmesh.md)** - runtime navigation mesh
- **[NavMeshQuery](03-api-reference/detour/query.md)** - pathfinding queries
- **[Pathfinding](03-api-reference/detour/pathfinding.md)** - A* path search

#### DetourCrowd (Multi-Agent)
- **[Crowd Manager](03-api-reference/detour-crowd/crowd.md)** - crowd simulation
- **[Agents](03-api-reference/detour-crowd/agents.md)** - agent behavior

#### TileCache (Dynamic Obstacles)
- **[TileCache](03-api-reference/tile-cache/tilecache.md)** - dynamic navmesh
- **[Obstacles](03-api-reference/tile-cache/obstacles.md)** - obstacle management

### 📝 [04. Guides](04-guides/)
Практические руководства по использованию.

- **[Creating NavMesh](04-guides/creating-navmesh.md)** - step-by-step создание навигационного меша
- **[Pathfinding](04-guides/pathfinding.md)** - поиск пути между точками
- **[Raycast Queries](04-guides/raycast.md)** - проверка видимости и raycast
- **[Crowd Simulation](04-guides/crowd-simulation.md)** - симуляция множества агентов
- **[Dynamic Obstacles](04-guides/dynamic-obstacles.md)** - работа с TileCache

### 💡 [05. Examples](05-examples/)
Примеры использования библиотеки.

- **[Simple NavMesh](05-examples/simple-navmesh.md)** - базовый пример
- **[Dungeon NavMesh](05-examples/dungeon-navmesh.md)** - сложная геометрия
- **[Pathfinding Demo](05-examples/pathfinding-demo.md)** - поиск пути
- **[Crowd Demo](05-examples/crowd-demo.md)** - crowd simulation

### 🧪 [06. Testing](06-testing/)
Тестирование и верификация.

- **[Test Coverage Analysis](../TEST_COVERAGE_ANALYSIS.md)** - анализ покрытия тестами (169 unit + 22 integration)
- **[Integration Tests](06-testing/integration-tests.md)** - end-to-end тесты
- **[Running Tests](06-testing/running-tests.md)** - как запускать тесты

### 🐛 [07. Debugging](07-debugging/)
Отладка и решение проблем.

- **[Common Issues](07-debugging/common-issues.md)** - частые проблемы и решения
- **[Memory Leaks](07-debugging/memory-leaks.md)** - поиск утечек памяти
- **[C++ Comparison](07-debugging/comparison-cpp.md)** - сравнение с C++ версией

### 🔧 [08. Bug Fixes](bug-fixes/)
История исправленных багов с детальным анализом.

- **[Watershed Fix](watershed-100-percent-fix/INDEX.md)** ⭐ - достижение 100% точности в region partitioning
  - Multi-stack system для deterministic region building
  - Byte-for-byte идентичность с C++ reference

- **[Raycast Fix](bug-fixes/raycast-fix/INDEX.md)** ⭐ - исправление 3 критических багов
  - Area initialization bug
  - erodeWalkableArea boundary condition
  - perp2D formula sign error

### 🔄 [09. Migration](09-migration/)
Миграция с C++ версии.

- **[From C++](09-migration/from-cpp.md)** - руководство по миграции
- **[API Differences](09-migration/api-differences.md)** - отличия API

### 🤝 [10. Contributing](10-contributing/)
Внесение вклада в проект.

- **[Development Guide](10-contributing/development.md)** - настройка dev окружения
- **[Coding Style](10-contributing/coding-style.md)** - code style guidelines
- **[Pull Requests](10-contributing/pull-requests.md)** - процесс PR

---

## 🎯 Быстрые ссылки

### Для начинающих
1. [Установка](01-getting-started/installation.md)
2. [Quick Start](01-getting-started/quick-start.md)
3. [Первый NavMesh](04-guides/creating-navmesh.md)

### Для разработчиков
1. [Архитектура](02-architecture/overview.md)
2. [API Reference](03-api-reference/)
3. [Тестирование](../TEST_COVERAGE_ANALYSIS.md)

### Для мигрирующих с C++
1. [Отличия API](09-migration/api-differences.md)
2. [Руководство по миграции](09-migration/from-cpp.md)
3. [Сравнение производительности](07-debugging/comparison-cpp.md)

---

## 📊 Статус проекта

| Компонент | Статус | Тесты | Точность |
|-----------|--------|-------|----------|
| **Recast Pipeline** | ✅ Complete | 169 unit tests | 100% |
| **Detour Queries** | ✅ Complete | 22 integration tests | 100% |
| **DetourCrowd** | ✅ Complete | Tested | 100% |
| **TileCache** | ✅ Complete | 7 integration tests | 100% |
| **Raycast** | ✅ Complete | 4 integration tests | 100% |
| **Memory Safety** | ✅ Verified | 0 leaks | - |

**Последнее обновление:** 2025-10-02

---

## 🏆 Достижения

- ✅ **100% функциональная пар equivalence с C++** - все компоненты реализованы
- ✅ **191/191 тестов проходят** - 169 unit + 22 integration
- ✅ **0 утечек памяти** - все тесты проходят чисто
- ✅ **Byte-for-byte идентичность** - NavMesh идентичен C++ reference
- ✅ **3 критических бага исправлено** - area init, erode, perp2D

---

## 💬 Поддержка

- **Issues:** [GitHub Issues](https://github.com/your-repo/zig-recast/issues)
- **Discussions:** [GitHub Discussions](https://github.com/your-repo/zig-recast/discussions)
- **Email:** support@example.com

---

## 📜 Лицензия

Эта реализация следует той же лицензии, что и оригинальная RecastNavigation (zlib license).

## 🙏 Благодарности

- **Mikko Mononen** - автор оригинальной RecastNavigation
- **Zig Community** - за отличный язык и поддержку
- **Contributors** - за помощь в разработке
