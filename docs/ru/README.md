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
- **[PolyRef Scaling](02-architecture/polyref-scaling.md)** - 32-bit vs 64-bit ссылки на полигоны
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

### 🌍 [Поддержка больших миров](#поддержка-больших-миров)
Поддержка огромных игровых миров с 64-bit ссылками на полигоны.

- **По умолчанию (32-bit):** миры ~16×16 км, оптимально для большинства игр
- **Режим 64-bit:** миры ~268,000×268,000 км, для планетарных симуляций
- **Легкая миграция:** Простое изменение 2 строк кода для включения 64-bit режима
- **Эффективно по памяти:** Всего +4 байта на полигон при использовании 64-bit

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

### Разработка больших миров
1. [Ограничения размеров мира](#ограничения-размеров-мира)
2. [Миграция на 64-bit](#миграция-на-64-bit)
3. [Влияние на память](#влияние-на-память)

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

**Последнее обновление:** 2025-10-20

---

## 🌍 Поддержка больших миров

### Ограничения размеров мира

| Режим | Размер PolyRef | Макс. размер мира | Макс. тайлов | Макс. полигонов/тайл | Применение |
|-------|---------------|-------------------|-------------|---------------------|------------|
| **32-bit** | 4 байта | ~16×16 км² | 16,383 | 1,023 | Инди-игры, мобильные |
| **64-bit** | 8 байт | ~268,000×268,000 км² | 268,435,455 | 1,048,575 | MMORPG, планетарные |

### Миграция на 64-bit

Для включения 64-bit ссылок на полигоны для огромных миров:

```zig
// В src/detour/common.zig, измените:
pub const PolyRef = u32;  // → pub const PolyRef = u64;
pub const TileRef = u32;  // → pub const TileRef = u64;
```

**Преимущества:**
- Миры в 16,384 раз больше
- В 1,024 раза больше полигонов на тайл
- Полная совместимость с C++ 64-bit сборками
- Всего +4 байта накладных расходов на полигон

### Влияние на память

| Размер мира | Память 32-bit | Память 64-bit | Накладные расходы |
|-------------|---------------|---------------|-------------------|
| 1M полигонов | 3.91 МБ | 7.63 МБ | +3.72 МБ |
| 10M полигонов | 39.1 МБ | 76.3 МБ | +37.2 МБ |
| 100M полигонов | 391 МБ | 763 МБ | +372 МБ |

---

## 🏆 Достижения

- ✅ **100% функциональная эквивалентность с C++** - все компоненты реализованы
- ✅ **191/191 тестов проходят** - 169 unit + 22 integration
- ✅ **0 утечек памяти** - все тесты проходят чисто
- ✅ **Byte-for-byte идентичность** - NavMesh идентичен C++ reference
- ✅ **3 критических бага исправлено** - area init, erode, perp2D
- ✅ **Поддержка 64-bit PolyRef** - миры планетарного масштаба

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
