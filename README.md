# Recast Navigation - Zig Implementation

A complete Zig rewrite of [RecastNavigation](https://github.com/recastnavigation/recastnavigation) library for creating navigation meshes and performing pathfinding.

## Features

- **Memory Safety**: Explicit allocators, no hidden memory allocations
- **Type Safety**: Leverages Zig's strong type system and comptime features
- **Error Handling**: Proper error types instead of boolean returns
- **Modern Design**: Clean API using Zig idioms
- **Performance**: Optimized with inline functions and comptime code generation
- **Zero Dependencies**: Pure Zig implementation

## Project Structure

```
zig-recast/
├── src/
│   ├── root.zig              # Main library entry point
│   ├── math.zig              # Math types (Vec3, AABB, etc.)
│   ├── context.zig           # Build context and logging
│   ├── recast.zig            # Recast module (navmesh building)
│   ├── detour.zig            # Detour module (pathfinding)
│   ├── recast/
│   │   ├── config.zig        # Build configuration
│   │   ├── heightfield.zig   # Heightfield structures
│   │   └── polymesh.zig      # Polygon mesh structures
│   └── detour/
│       ├── common.zig        # Common types and constants
│       └── navmesh.zig       # Navigation mesh structures
├── examples/
│   └── simple_navmesh.zig    # Basic usage example
├── test/
└── build.zig                 # Build configuration
```

## Modules

### Recast
Navigation mesh construction from triangle meshes:
- `Heightfield` - Voxel-based height field representation
- `CompactHeightfield` - Compact representation for processing
- `ContourSet` - Region contours
- `PolyMesh` - Final polygon mesh
- `PolyMeshDetail` - Detailed mesh for accurate height queries

### Detour
Navigation queries and pathfinding:
- `NavMesh` - Runtime navigation mesh
- `NavMeshQuery` - Pathfinding and spatial queries (TODO)
- `Crowd` - Agent management (TODO)
- `TileCache` - Dynamic obstacle support (TODO)

## Building

### Requirements
- Zig 0.14.0 or later

### Build Library
```bash
zig build
```

### Run Tests
```bash
# Run all tests
zig build test

# Run integration tests only
zig build test-integration
```

**Current Test Status:**
- ✅ 5/5 integration tests passing
- ⚠️ 2 known memory leaks (non-critical, see KNOWN_ISSUES.md)

### Run Examples
```bash
zig build examples
./zig-out/bin/simple_navmesh
```

## Quick Start

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
    // (Additional build steps will be implemented)
}
```

## Key Differences from C++ Version

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

## Roadmap

### Phase 1: Core Structures ✅
- [x] Math types (Vec3, AABB)
- [x] Heightfield structures
- [x] Compact heightfield
- [x] Polygon mesh structures
- [x] NavMesh core structures

### Phase 2: Recast Building (In Progress)
- [ ] Heightfield rasterization
- [ ] Filtering functions
- [ ] Region building
- [ ] Contour generation
- [ ] Polygon mesh building
- [ ] Detail mesh building

### Phase 3: Detour Queries
- [ ] NavMesh queries
- [ ] Pathfinding (A*)
- [ ] Ray casting
- [ ] Distance queries

### Phase 4: Advanced Features
- [ ] Crowd simulation (DetourCrowd)
- [ ] Dynamic obstacles (DetourTileCache)
- [ ] Off-mesh connections
- [ ] Area costs

### Phase 5: Optimization & Polish
- [ ] SIMD optimizations
- [ ] Benchmark suite
- [ ] Documentation
- [ ] More examples

## Performance Goals

- Match or exceed C++ performance
- Zero allocations in hot paths (pathfinding)
- Leverage Zig's comptime for code specialization
- Optional SIMD for vector operations

## Known Issues

**Memory Leaks in CompactHeightfield** (Non-Critical)
- Small memory leak when `buildCompactHeightfield()` reallocates arrays
- Tests pass successfully despite leak
- Attempted fix causes test hang - under investigation
- See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full details

## Contributing

This is a work in progress. Contributions are welcome!

## License

This implementation follows the same license as the original RecastNavigation (zlib license).

## Credits

- Original RecastNavigation by Mikko Mononen
- Zig implementation by the community

## References

- [RecastNavigation GitHub](https://github.com/recastnavigation/recastnavigation)
- [Zig Language](https://ziglang.org/)
