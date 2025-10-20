# Recast Navigation - Zig Implementation Documentation

**Choose your language / Выберите язык:**

📖 **[English Documentation](en/)** (Main)

📖 **[Русская документация](ru/)**

---

## Quick Links

### English
- [Getting Started](en/01-getting-started/) - Installation and setup
- [Quick Start Guide](en/01-getting-started/quick-start.md) - Build your first NavMesh in 5 minutes
- [Architecture Overview](en/02-architecture/overview.md) - System design
- [API Reference](en/03-api-reference/) - Complete API documentation
- [Guides](en/04-guides/) - Practical tutorials

### Русский
- [Начало работы](ru/01-getting-started/) - Установка и настройка
- [Быстрый старт](ru/01-getting-started/quick-start.md) - Создайте NavMesh за 5 минут
- [Обзор архитектуры](ru/02-architecture/overview.md) - Устройство системы
- [Справочник API](ru/03-api-reference/) - Полная документация API
- [Руководства](ru/04-guides/) - Практические примеры

### 🚨 Critical Bug Fixes
- [Bug Fixes Documentation](bug_fixes/README.md) - **Important fixes for issues #788, #793 and more**

---

## Project Status

| Component | Status | Tests | Accuracy |
|-----------|--------|-------|----------|
| **Recast Pipeline** | ✅ Complete | 169 unit tests | 100% |
| **Detour Queries** | ✅ Complete | 22 integration tests | 100% |
| **DetourCrowd** | ✅ Complete | Tested | 100% |
| **TileCache** | ✅ Complete | 7 integration tests | 100% |
| **Memory Safety** | ✅ Verified | 0 leaks | - |

**Last Update:** 2025-10-04

---

## Contributing

See documentation in your preferred language for contribution guidelines:
- [English Contributing Guide](en/10-contributing/)
- [Русское руководство по внесению вклада](ru/10-contributing/)

---

## License

This implementation follows the same license as the original RecastNavigation (zlib license).

## Acknowledgments

- **Mikko Mononen** - original RecastNavigation author
- **Zig Community** - for the excellent language and support
- **Contributors** - for help in development
