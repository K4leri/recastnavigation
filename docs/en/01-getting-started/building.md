# Building & Testing

[Русская версия](../../ru/01-getting-started/building.md) | **English**

Complete guide to building and testing zig-recast.

---

## Building the Library

### Standard Build

```bash
zig build
```

This builds the library in Debug mode.

### Optimized Build

```bash
zig build -Doptimize=ReleaseFast
```

Available optimization modes:
- `Debug` - no optimization, full debug info (default)
- `ReleaseSafe` - optimized with safety checks
- `ReleaseFast` - maximum speed, no safety
- `ReleaseSmall` - optimize for size

---

## Running Tests

### All Tests

```bash
zig build test
```

Runs all 191 tests (169 unit + 22 integration).

### Specific Test Suite

```bash
# Unit tests only
zig build test --summary all

# Integration tests
zig build run -Dtest=integration
```

### With Memory Leak Detection

```bash
zig build test -Doptimize=Debug
```

---

## Building Examples

### All Examples

```bash
zig build examples
```

### Run Specific Example

```bash
zig build examples
./zig-out/bin/simple_navmesh
./zig-out/bin/pathfinding_demo
./zig-out/bin/crowd_simulation
```

---

## Build Options

View all available options:

```bash
zig build --help
```

Common options:
- `-Doptimize=<mode>` - optimization level
- `-Dtarget=<triple>` - cross-compile target
- `--summary all` - detailed build output

---

## Next Steps

- 📖 [Quick Start](quick-start.md) - Create your first NavMesh
- 📚 [Architecture](../02-architecture/overview.md) - Understand the system
