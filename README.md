# Recast Navigation - Zig Implementation

**English** | [Русский](README.ru.md)

Complete Zig implementation of the [RecastNavigation](https://github.com/recastnavigation/recastnavigation) library for navigation mesh creation and pathfinding.

## ✨ Features

- **Memory Safety**: Explicit allocators, no hidden memory allocations
- **Type Safety**: Leveraging Zig's strong type system and comptime
- **Error Handling**: Proper error types instead of boolean returns
- **Modern Design**: Clean API following Zig idioms
- **Performance**: Optimization through inline functions and comptime generation
- **Zero Dependencies**: Pure Zig implementation
- **100% Accuracy**: Byte-for-byte identical with C++ reference implementation
- **Enhanced Triangulation**: Robust ear clipping algorithm with infinite loop protection

## 📁 Project Structure

```
zig-recast/
├── src/                      # Library source code
│   ├── root.zig              # Main entry point
│   ├── math.zig              # Math types (Vec3, AABB, etc.)
│   ├── context.zig           # Build context and logging
│   ├── recast.zig            # Recast module (NavMesh building)
│   ├── detour.zig            # Detour module (pathfinding)
│   ├── detour_crowd.zig      # DetourCrowd (multi-agent simulation)
│   └── detour_tilecache.zig  # TileCache (dynamic obstacles)
│
├── examples/                 # Usage examples
│   ├── simple_navmesh.zig    # Basic NavMesh creation example
│   ├── pathfinding_demo.zig  # Pathfinding demo
│   ├── crowd_simulation.zig  # Crowd agent simulation
│   ├── dynamic_obstacles.zig # Dynamic obstacles
│   ├── 02_tiled_navmesh.zig  # Tiled NavMesh
│   ├── 03_full_pathfinding.zig # Full pathfinding
│   └── 06_offmesh_connections.zig # Off-mesh connections
│
├── bench/                    # Performance benchmarks
│   ├── recast_bench.zig      # Recast pipeline benchmark
│   ├── detour_bench.zig      # Detour queries benchmark
│   ├── crowd_bench.zig       # Crowd simulation benchmark
│   └── findStraightPath_detailed.zig
│
├── test/                     # Tests (183 unit + 21 integration)
│   ├── integration/          # Integration tests
│   └── ...                   # Unit tests
│
├── docs/                     # 📚 Complete documentation
│   ├── README.md             # Documentation navigation
│   ├── en/                   # English documentation
│   ├── ru/                   # Russian documentation
│   └── bug_fixes/            # Bug fix history
│
└── build.zig                 # Build configuration
```

## 🧩 Modules

### Recast - NavMesh Building

Creating navigation meshes from triangle meshes:

- ✅ `Heightfield` - Voxel-based heightfield representation
- ✅ `CompactHeightfield` - Compact representation for processing
- ✅ `Region Building` - Watershed partitioning with multi-stack system
- ✅ `ContourSet` - Region contour extraction
- ✅ `PolyMesh` - Final polygon mesh
- ✅ `PolyMeshDetail` - Detailed mesh for precise height queries

### Detour - Pathfinding and Queries

Navigation queries and pathfinding:

- ✅ `NavMesh` - Runtime navigation mesh
- ✅ `NavMeshQuery` - Pathfinding and spatial queries
- ✅ `A* Pathfinding` - Optimal path search
- ✅ `Raycast` - Visibility checks and raycast queries
- ✅ `Distance Queries` - Distance queries

### DetourCrowd - Multi-Agent Simulation

Managing multiple agents:

- ✅ `Crowd Manager` - Crowd management
- ✅ `Agent Movement` - Agent movement
- ✅ `Local Steering` - Local steering
- ✅ `Obstacle Avoidance` - Obstacle avoidance

### TileCache - Dynamic Obstacles

Dynamic obstacle support:

- ✅ `TileCache` - Tile cache with dynamic changes
- ✅ `Obstacle Management` - Managing obstacles (box, cylinder, oriented box)
- ✅ `Dynamic NavMesh Updates` - Dynamic NavMesh updates

## 🚀 Quick Start

### Requirements

- Zig 0.15.0 or newer

### Build Library

```bash
zig build
```

### Run Tests

```bash
# All tests (unit + integration)
zig build test

# Integration tests only
zig build test-integration

# Specific test suite
zig build test:filter
zig build test:rasterization
zig build test:contour
```

### Run Examples

```bash
# Build all examples
zig build examples

# Basic NavMesh example
./zig-out/bin/simple_navmesh

# Pathfinding demo
./zig-out/bin/pathfinding_demo

# Crowd simulation
./zig-out/bin/crowd_simulation

# Dynamic obstacles
./zig-out/bin/dynamic_obstacles
```

### Run Benchmarks

```bash
# Recast pipeline benchmark
zig build bench-recast

# Detour queries benchmark
zig build bench-detour

# Crowd simulation benchmark
zig build bench-crowd
```

## ✅ Testing Status

**Current Status:**

- ✅ **201/201 tests passing** (183 unit + 21 integration)
- ✅ **100% accuracy** compared to C++ reference implementation
- ✅ **0 memory leaks** in all tests
- ✅ Recast pipeline fully tested
- ✅ Detour pipeline fully tested (pathfinding, raycast, queries)
- ✅ DetourCrowd fully tested (movement, steering, avoidance)
- ✅ TileCache fully tested (all obstacle types)

**🎉 Achievement: Identical NavMesh Generation**

The Zig implementation produces **byte-for-byte identical** navigation meshes with the C++ reference:

- 44/44 contours ✅
- 432/432 vertices ✅
- 206/206 polygons ✅

See [docs/bug-fixes/watershed-100-percent-fix](docs/bug-fixes/watershed-100-percent-fix/INDEX.md) for the complete story of achieving 100% accuracy.

## 📝 Usage Example

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
    // See examples/simple_navmesh.zig for complete example
}
```

More examples in the `examples/` directory:

- `simple_navmesh.zig` - basic NavMesh creation
- `pathfinding_demo.zig` - pathfinding
- `crowd_simulation.zig` - crowd simulation
- `dynamic_obstacles.zig` - dynamic obstacles

## 🔄 Differences from C++ Version

### Memory Management

```zig
// Zig: Explicit allocator
var heightfield = try Heightfield.init(allocator, ...);
defer heightfield.deinit();

// C++: Global allocator
rcHeightfield* heightfield = rcAllocHeightfield();
rcFreeHeightfield(heightfield);
```

### Error Handling

```zig
// Zig: Error unions
const result = try buildNavMesh(allocator, config);

// C++: Boolean returns
bool success = rcBuildNavMesh(...);
if (!success) { /* handle error */ }
```

### Type Safety

```zig
// Zig: Strong typing with enums
const area_id = recast_nav.recast.AreaId.WALKABLE_AREA;

// C++: Raw constants
const unsigned char RC_WALKABLE_AREA = 63;
```

## 🗺️ Roadmap

### Phase 1: Basic Structures ✅ (Complete)

### Phase 2: Recast Building ✅ (Complete)

### Phase 3: Detour Queries ✅ (Complete)

### Phase 4: Advanced Features ✅ (Complete)

### Phase 5: Optimization and Polish 🚧 (In Progress)

- [ ] SIMD optimizations
- [ ] influence map
- [x] Benchmark suite (basic benchmarks ready)
- [x] Documentation (complete documentation in docs/)
- [x] Usage examples

## 🎯 Performance Goals

- Match or exceed C++ performance
- Zero allocations in hot paths (pathfinding)
- Use Zig comptime for code specialization
- Optional SIMD optimizations for vector operations

## 📊 Known Achievements

**Current State:** All 201 tests passing with no memory leaks.

**Recent Achievements:**

- ✅ Fixed watershed partitioning for 100% accuracy ([details](docs/bug-fixes/watershed-100-percent-fix/INDEX.md))
- ✅ Fixed 3 critical raycast bugs ([details](docs/bug-fixes/raycast-fix/INDEX.md)):
- ✅ Implemented multi-stack system for deterministic region building
- ✅ Full implementation of `mergeAndFilterRegions`
- ✅ Verified byte-for-byte identity with C++ RecastNavigation

## 📚 Documentation

📖 **[Complete Documentation](docs/README.md)** - navigation for all project documentation

### Main Sections

#### 🚀 For Beginners

- [Installation & Setup](docs/en/01-getting-started/installation.md) - installation and setup
- [Quick Start Guide](docs/en/01-getting-started/quick-start.md) - create NavMesh in 5 minutes
- [Building & Testing](docs/en/01-getting-started/building.md) - building and testing

#### 🏗️ Architecture

- [System Overview](docs/en/02-architecture/overview.md) - system overview
- [Recast Pipeline](docs/ru/02-architecture/recast-pipeline.md) - NavMesh building process
- [Detour Pipeline](docs/ru/02-architecture/detour-pipeline.md) - pathfinding system
- [Memory Model](docs/ru/02-architecture/memory-model.md) - memory management
- [DetourCrowd](docs/ru/02-architecture/detour-crowd.md) - multi-agent simulation
- [TileCache](docs/ru/02-architecture/tilecache.md) - dynamic obstacles

#### 📖 API Reference

- [Math API](docs/en/03-api-reference/math-api.md) - math types
- [Recast API](docs/en/03-api-reference/recast-api.md) - NavMesh building
- [Detour API](docs/en/03-api-reference/detour-api.md) - pathfinding and queries

#### 📝 Practical Guides

- [Creating NavMesh](docs/en/04-guides/creating-navmesh.md) - step-by-step NavMesh creation
- [Pathfinding](docs/ru/04-guides/pathfinding.md) - pathfinding
- [Raycast Queries](docs/ru/04-guides/raycast.md) - raycast queries

#### 🧪 Testing

- [Test Coverage Analysis](TEST_COVERAGE_ANALYSIS.md) - test coverage analysis
- [Running Tests](docs/en/01-getting-started/building.md) - running tests

## 🤝 Contributing

The project is actively developed. Contributions are welcome!

See [Contributing Guide](docs/en/10-contributing/development.md) for dev environment setup and guidelines.

## 📄 License

This implementation follows the same license as the original RecastNavigation (zlib license).

## 🙏 Acknowledgments

- **Mikko Mononen** - author of the original RecastNavigation
- **Zig Community** - for the excellent language and support

## 🔗 Links

- [RecastNavigation GitHub](https://github.com/recastnavigation/recastnavigation) - original C++ implementation
- [Zig Language](https://ziglang.org/) - official Zig website
- [Project Documentation](docs/README.md) - complete documentation (EN/RU)
- [Progress Report](PROGRESS.md) - bilingual progress report

---

**Status:** ✅ Production Ready | **Version:** 1.0.0-beta | **Tests:** 201/201 ✅ | **Accuracy:** 100% 🎯
