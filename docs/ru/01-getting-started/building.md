# Building & Testing

Подробное руководство по сборке проекта и запуску тестов.

---

## Содержание

- [Build System](#build-system)
- [Build Modes](#build-modes)
- [Build Options](#build-options)
- [Running Tests](#running-tests)
- [Continuous Integration](#continuous-integration)
- [Troubleshooting](#troubleshooting)

---

## Build System

zig-recast использует встроенную систему сборки Zig (`build.zig`).

### Базовая сборка

```bash
# Собрать библиотеку и тесты
zig build

# Собрать только библиотеку
zig build lib

# Собрать примеры
zig build examples
```

### Очистка

```bash
# Очистить build artifacts
zig build --help | grep clean
rm -rf zig-cache zig-out
```

---

## Build Modes

### Debug (по умолчанию)

Включает проверки, отладочную информацию, no optimizations:

```bash
zig build -Doptimize=Debug
```

**Использовать для:**
- Development
- Debugging
- Memory leak detection

### ReleaseSafe

Оптимизации + safety checks:

```bash
zig build -Doptimize=ReleaseSafe
```

**Использовать для:**
- Testing performance
- Production (recommended)

### ReleaseFast

Максимальные оптимизации, minimal checks:

```bash
zig build -Doptimize=ReleaseFast
```

**Использовать для:**
- Benchmarking
- Maximum performance

### ReleaseSmall

Оптимизация размера binary:

```bash
zig build -Doptimize=ReleaseSmall
```

**Использовать для:**
- Embedded systems
- Minimal binary size

---

## Build Options

### Target Platform

Cross-compilation для других платформ:

```bash
# Linux x86_64
zig build -Dtarget=x86_64-linux

# Windows x86_64
zig build -Dtarget=x86_64-windows

# macOS ARM64
zig build -Dtarget=aarch64-macos

# WebAssembly
zig build -Dtarget=wasm32-freestanding
```

### Build Specific Components

```bash
# Только unit тесты
zig build test

# Только integration тесты
zig build test-integration

# Raycast test executable
zig build raycast-test

# Все примеры
zig build examples
```

### Custom Options

Добавьте опции в `build.zig`:

```zig
const enable_simd = b.option(bool, "simd", "Enable SIMD optimizations") orelse false;
const enable_logging = b.option(bool, "logging", "Enable debug logging") orelse false;
```

Используйте:

```bash
zig build -Dsimd=true -Dlogging=true
```

---

## Running Tests

### Unit Tests

Запустить все unit тесты (169 тестов):

```bash
zig build test
```

Output:
```
All 169 tests passed.
```

### Integration Tests

Запустить integration тесты (22 теста):

```bash
zig build test-integration
```

Отдельные integration тесты:

```bash
# Recast pipeline test
zig test test/integration/recast_pipeline_test.zig

# Detour pipeline test
zig test test/integration/detour_pipeline_test.zig

# Crowd simulation test
zig test test/integration/crowd_simulation_test.zig

# TileCache test
zig test test/integration/tilecache_pipeline_test.zig
```

### Raycast Tests

Standalone raycast test executable:

```bash
# Build
zig build raycast-test

# Run
./zig-out/bin/raycast_test.exe

# На Unix
./zig-out/bin/raycast_test
```

Expected output:
```
=== Loading nav_test.obj ===
Loaded 143 vertices, 224 triangles

=== Running Raycast Tests ===
Test 1: Hit t=0.174383, path=[359→360→358] ✅
Test 2: No hit (t=inf), path=[350→346→410→407] ✅
Test 3: Hit t=0.000877, path=[356] ✅
Test 4: Hit t=0.148204, path=[359→360→358] ✅

All tests passed!
```

### Specific Test Files

```bash
# Только math тесты
zig test src/math.zig

# Только filter тесты
zig test test/filter_test.zig

# Только mesh advanced тесты
zig test test/mesh_advanced_test.zig
```

### Test with Coverage

```bash
# Build с coverage
zig build test --summary all

# Verbose output
zig build test --summary all -Dverbose=true
```

### Test Filtering

Запустить тесты по имени pattern:

```bash
zig test src/math.zig --test-filter "vcross"
zig test test/filter_test.zig --test-filter "walkable"
```

---

## Memory Leak Detection

### Automatic Detection

Zig автоматически обнаруживает утечки в Debug mode:

```bash
zig build test -Doptimize=Debug
```

Если есть утечки, вы увидите:
```
error: memory leak detected:
  allocated at src/example.zig:42
  not freed
```

### Manual Tracking

Используйте `std.heap.GeneralPurposeAllocator`:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    const leaked = gpa.deinit();
    if (leaked == .leak) {
        std.debug.print("Memory leak detected!\n", .{});
    }
}
```

### Valgrind (Linux)

```bash
# Собрать с debug info
zig build -Doptimize=Debug

# Запустить через valgrind
valgrind --leak-check=full ./zig-out/bin/my-navmesh
```

---

## Continuous Integration

### GitHub Actions

Пример `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]

    steps:
      - uses: actions/checkout@v3

      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.14.0

      - name: Build
        run: zig build

      - name: Run Tests
        run: zig build test

      - name: Run Integration Tests
        run: zig build test-integration

      - name: Run Raycast Tests
        run: |
          zig build raycast-test
          ./zig-out/bin/raycast_test
```

---

## Build Scripts

### Custom Build Script

Создайте `scripts/build.sh`:

```bash
#!/bin/bash

set -e

echo "Building zig-recast..."

# Clean
rm -rf zig-cache zig-out

# Build library
zig build lib -Doptimize=ReleaseSafe

# Build tests
zig build test-integration -Doptimize=Debug

# Build examples
zig build examples -Doptimize=ReleaseSafe

# Run tests
zig build test

echo "Build complete!"
```

Запустите:

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

### Windows Build Script

Создайте `scripts/build.bat`:

```batch
@echo off

echo Building zig-recast...

REM Clean
rmdir /s /q zig-cache zig-out

REM Build
zig build lib -Doptimize=ReleaseSafe
zig build test-integration -Doptimize=Debug
zig build examples -Doptimize=ReleaseSafe

REM Run tests
zig build test

echo Build complete!
```

---

## Troubleshooting

### Build Fails: "OutOfMemory"

**Решение:** Увеличьте heap size:

```bash
zig build -Doptimize=Debug --heap-size 2G
```

### Build Slow on Windows

**Решение:** Добавьте antivirus исключения:
- `C:\path\to\zig-recast\zig-cache\`
- `C:\path\to\zig-recast\zig-out\`

### Tests Fail: "FileNotFound"

**Решение:** Запускайте тесты из корневой директории:

```bash
cd zig-recast
zig build test
```

### Tests Timeout

**Решение:** Увеличьте timeout:

```bash
zig build test --timeout 300  # 5 минут
```

### Linker Errors

**Решение:** Очистите cache:

```bash
rm -rf zig-cache zig-out
zig build
```

### Cross-compilation Fails

**Решение:** Установите target toolchain:

```bash
# Для Windows target на Linux
zig build -Dtarget=x86_64-windows-gnu
```

---

## Performance Profiling

### Benchmark Build

```bash
# Build для benchmarking
zig build -Doptimize=ReleaseFast

# С PGO (Profile-Guided Optimization)
zig build -Doptimize=ReleaseFast -Dpgo=true
```

### Profiling Tools

**Linux:**
```bash
# perf
perf record ./zig-out/bin/my-navmesh
perf report

# flamegraph
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

**Windows:**
- Visual Studio Profiler
- Windows Performance Analyzer

**macOS:**
```bash
# Instruments
instruments -t "Time Profiler" ./zig-out/bin/my-navmesh
```

---

## Next Steps

После успешной сборки:

1. 📖 [Quick Start Guide](quick-start.md) - создайте первый NavMesh
2. 🏗️ [Architecture Overview](../02-architecture/overview.md) - понимание системы
3. 📚 [API Reference](../03-api-reference/) - детальная документация

---

**Помощь:** [GitHub Issues](https://github.com/your-org/zig-recast/issues)
