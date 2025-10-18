# Recast Navigation - Zig Implementation Documentation

**English** | [Русский](../ru/README.md)

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
- **[DetourCrowd](02-architecture/detour-crowd.md)** - симуляция толпы агентов
- **[TileCache](02-architecture/tilecache.md)** - поддержка динамических препятствий

### 📖 [03. API Reference](03-api-reference/)
Детальная документация по всем API.

- **[Math API](03-api-reference/math-api.md)** - векторная математика и геометрические утилиты
- **[Recast API](03-api-reference/recast-api.md)** - функции построения NavMesh
- **[Detour API](03-api-reference/detour-api.md)** - функции pathfinding и запросов

### 📝 [04. Guides](04-guides/)
Практические руководства по использованию.

- **[Creating NavMesh](04-guides/creating-navmesh.md)** - step-by-step создание навигационного меша
- **[Pathfinding](04-guides/pathfinding.md)** - поиск пути между точками
- **[Raycast Queries](04-guides/raycast.md)** - проверка видимости и raycast

### 🐛 [Bug Fixes](../bug-fixes/)
История исправленных багов с детальным анализом (общие для всех языков).

- **[Watershed Fix](../bug-fixes/watershed-100-percent-fix/INDEX.md)** ⭐ - достижение 100% точности в region partitioning
  - Multi-stack system для deterministic region building
  - Byte-for-byte идентичность с C++ reference

- **[Raycast Fix](../bug-fixes/raycast-fix/INDEX.md)** ⭐ - исправление 3 критических багов
  - Area initialization bug
  - erodeWalkableArea boundary condition
  - perp2D formula sign error

- **[Hole Construction Fix](../bug-fixes/hole-construction-fix/INDEX.md)** ⭐ - обработка отверстий в NavMesh
  - Правильное слияние отверстий в контурах
  - Поддержка регионов с отверстиями

---

## 🎯 Быстрые ссылки

### Для начинающих
1. [Установка](01-getting-started/installation.md)
2. [Quick Start](01-getting-started/quick-start.md)
3. [Первый NavMesh](04-guides/creating-navmesh.md)

### Для разработчиков
1. [Архитектура](02-architecture/overview.md)
2. [API Reference](03-api-reference/)
3. [Тестирование](../../TEST_COVERAGE_ANALYSIS.md)

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

**Последнее обновление:** 2025-10-04

---

## 🏆 Достижения

- ✅ **100% функциональная эквивалентность с C++** - все компоненты реализованы
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
