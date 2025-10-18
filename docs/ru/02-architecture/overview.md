# Architecture Overview

Полный обзор архитектуры zig-recast navigation library.

---

## Содержание

- [System Architecture](#system-architecture)
- [Core Modules](#core-modules)
- [Data Flow](#data-flow)
- [Memory Model](#memory-model)
- [Design Principles](#design-principles)

---

## System Architecture

zig-recast состоит из 4 основных модулей:

```
┌─────────────────────────────────────────────────┐
│                    User Code                     │
└─────────────────────────────────────────────────┘
                         │
          ┌──────────────┴──────────────┐
          │                             │
┌─────────▼─────────┐         ┌────────▼──────────┐
│  Recast Module    │         │  Detour Module    │
│                   │         │                   │
│ • Heightfield     │         │ • NavMesh         │
│ • Compact HF      │────────▶│ • NavMeshQuery    │
│ • Regions         │         │ • Pathfinding     │
│ • Contours        │         │                   │
│ • PolyMesh        │         │                   │
│ • DetailMesh      │         │                   │
└───────────────────┘         └───────────────────┘
          │                             │
          │                   ┌─────────▼─────────┐
          │                   │ DetourCrowd       │
          │                   │                   │
          │                   │ • Crowd Manager   │
          │                   │ • Agents          │
          │                   │ • Local Steering  │
          │                   └───────────────────┘
          │                             │
┌─────────▼─────────────────────────────▼─────────┐
│              TileCache Module                    │
│                                                   │
│  • Dynamic Obstacles                             │
│  • NavMesh Rebuilding                            │
│  • Tile Management                               │
└──────────────────────────────────────────────────┘
          │
┌─────────▼─────────┐
│   Math & Utils    │
│                   │
│ • Vec3, AABB      │
│ • Geometry Utils  │
│ • Context         │
└───────────────────┘
```

---

## Core Modules

### 1. Recast (NavMesh Building)

**Назначение:** Преобразование triangle mesh в navigation mesh

**Компоненты:**
- **Heightfield** - voxel representation входной геометрии
- **Compact Heightfield** - compressed representation для обработки
- **Regions** - watershed partitioning в walkable regions
- **Contours** - извлечение контуров regions
- **PolyMesh** - simplified polygon mesh
- **DetailMesh** - detailed triangulation для height queries

**Pipeline:**
```
Triangle Mesh → Heightfield → Compact HF → Regions →
Contours → PolyMesh → DetailMesh → NavMesh Data
```

**Файлы:**
- `src/recast/` - основной код
- `src/recast/*.zig` - отдельные модули

### 2. Detour (Pathfinding)

**Назначение:** Runtime navigation и pathfinding queries

**Компоненты:**
- **NavMesh** - runtime navigation mesh structure
- **NavMeshQuery** - spatial queries и pathfinding
- **A* Pathfinding** - оптимальный поиск пути
- **Raycast** - visibility checks
- **PolyRef** - polygon references (tile + poly index)

**Queries:**
```
findPath()          → A* pathfinding
findNearestPoly()   → closest polygon search
raycast()           → line-of-sight check
findStraightPath()  → straight line path
```

**Файлы:**
- `src/detour/` - основной код
- `src/detour/query.zig` - query engine

### 3. DetourCrowd (Multi-Agent)

**Назначение:** Управление множеством агентов с collision avoidance

**Компоненты:**
- **Crowd Manager** - управление агентами
- **Agents** - индивидуальные агенты
- **Local Steering** - локальное управление
- **Obstacle Avoidance** - избежание препятствий
- **Path Corridor** - dynamic path следование

**Features:**
```
• Multi-agent simulation
• Collision avoidance (RVO)
• Dynamic path following
• Local steering
• Neighbor detection
```

**Файлы:**
- `src/detour_crowd/` - основной код

### 4. TileCache (Dynamic Obstacles)

**Назначение:** Dynamic obstacle support и NavMesh rebuilding

**Компоненты:**
- **TileCache** - tile-based navmesh management
- **Obstacles** - cylinder, box, oriented box
- **Compression** - tile data compression
- **Rebuilding** - инкрементальное обновление NavMesh

**Workflow:**
```
Add Obstacle → Mark Affected Tiles → Rebuild Tiles → Update NavMesh
```

**Файлы:**
- `src/tile_cache/` - основной код

### 5. Math & Utils

**Назначение:** Базовые математические типы и утилиты

**Компоненты:**
- **Vec3** - 3D вектор
- **AABB** - axis-aligned bounding box
- **Geometry Utils** - intersection, distance, etc.
- **Context** - build context и logging

**Файлы:**
- `src/math.zig` - математические функции
- `src/context.zig` - build context

---

## Data Flow

### NavMesh Creation Flow

```
1. Input Triangle Mesh
   ↓
2. Rasterization
   • Voxelize geometry → Heightfield
   • Mark walkable areas
   ↓
3. Filtering
   • Filter obstacles
   • Filter ledges
   • Filter low ceilings
   ↓
4. Compaction
   • Compact heightfield
   • Build neighbor connectivity
   ↓
5. Region Building
   • Distance field calculation
   • Watershed partitioning
   • Region merging
   ↓
6. Contour Extraction
   • Walk contours
   • Simplify contours
   • Remove degenerate segments
   ↓
7. Polygon Mesh
   • Triangulate contours
   • Merge triangles
   • Create polygon mesh
   ↓
8. Detail Mesh
   • Sample heights
   • Delaunay triangulation
   ↓
9. NavMesh Data
   • Create NavMesh data structure
   • Build BVH tree
   ↓
10. Runtime NavMesh
    • Initialize NavMesh
    • Add tiles
    • Ready for pathfinding!
```

### Pathfinding Query Flow

```
1. User Query
   • Start position
   • End position
   ↓
2. Find Nearest Polygons
   • Search BVH tree
   • Find closest polys
   ↓
3. A* Pathfinding
   • Open list (priority queue)
   • Closed list (visited)
   • Node pool
   ↓
4. Path Smoothing
   • String pulling
   • Straight line segments
   ↓
5. Result
   • Array of positions
   • Path corridor
```

---

## Memory Model

### Explicit Allocators

Все аллокации используют explicit allocators (no hidden allocations):

```zig
// User provides allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

// All structures take allocator
var heightfield = try Heightfield.init(allocator, ...);
defer heightfield.deinit(allocator);
```

### Memory Ownership

**Правила:**
1. **Caller owns** - вызывающий владеет памятью
2. **Explicit deinit** - все структуры имеют `deinit()`
3. **No shared ownership** - нет reference counting

**Пример:**
```zig
// Caller owns all structures
var compact = try buildCompactHeightfield(ctx, allocator, ...);
defer compact.deinit(allocator);  // Caller must free

var contours = try buildContours(ctx, allocator, &compact, ...);
defer contours.deinit(allocator);  // Caller must free
```

### Arena Allocators

Для temporary data используйте arena:

```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();  // Free all at once

const temp_allocator = arena.allocator();
// Use temp_allocator for temporary data
```

---

## Design Principles

### 1. Memory Safety

✅ **Explicit allocators** - no hidden allocations
✅ **RAII pattern** - init/deinit pairs
✅ **No memory leaks** - verified with tests
✅ **Bounds checking** - debug mode checks

### 2. Error Handling

```zig
// Error unions instead of bool returns
pub fn buildNavMesh(allocator: Allocator, config: Config) !NavMesh {
    return error.OutOfMemory;  // Explicit error
}

// Usage
const navmesh = try buildNavMesh(allocator, config);
// or handle error
const navmesh = buildNavMesh(allocator, config) catch |err| {
    // Handle error
};
```

### 3. Type Safety

✅ **Strong typing** - no void pointers
✅ **Enums** - type-safe constants
✅ **Comptime** - compile-time validation

**Пример:**
```zig
// Type-safe area ID
const AreaId = enum(u8) {
    NULL_AREA = 0,
    WALKABLE_AREA = 63,
    _,
};

// Not just raw u8
areas[i] = AreaId.WALKABLE_AREA;
```

### 4. Performance

✅ **Inline functions** - zero-cost abstractions
✅ **Comptime** - code generation
✅ **SIMD ready** - vector operations prepared
✅ **Zero allocations** - в hot paths (pathfinding loop)

### 5. API Design

**Zig idioms:**
```zig
// Named parameters
const config = Config{
    .cs = 0.3,
    .ch = 0.2,
    .walkable_height = 20,
};

// Error unions
const result = try operation();

// Optional values
const value: ?u32 = null;
```

**C++ compatibility:**
- Same algorithm logic
- Same parameter names
- Byte-for-byte identical output

---

## Module Dependencies

```
root.zig
 ├─ math.zig (no deps)
 ├─ context.zig (depends: math)
 ├─ recast.zig
 │   ├─ heightfield.zig
 │   ├─ compact.zig
 │   ├─ region.zig
 │   ├─ contour.zig
 │   ├─ mesh.zig
 │   └─ detail.zig
 ├─ detour.zig
 │   ├─ navmesh.zig
 │   ├─ builder.zig
 │   └─ query.zig
 ├─ detour_crowd.zig
 │   ├─ crowd.zig
 │   ├─ agent.zig
 │   └─ avoidance.zig
 └─ tile_cache.zig
     ├─ tilecache.zig
     └─ obstacle.zig
```

**Dependency Rules:**
- `math.zig` - no dependencies (pure functions)
- `recast/` - depends only on math, context
- `detour/` - depends on recast (NavMesh data)
- `detour_crowd/` - depends on detour
- `tile_cache/` - depends on recast, detour

---

## Threading Model

**Current:** Single-threaded
**Future:** Thread-safe queries planned

**Thread Safety:**
- ✅ Multiple NavMeshQuery on same NavMesh (read-only)
- ❌ Concurrent NavMesh modifications
- ❌ Concurrent TileCache updates

---

## Next Steps

Для более детального понимания:

1. 📖 [Recast Pipeline](recast-pipeline.md) - подробный разбор Recast
2. 🔍 [Detour Pipeline](detour-pipeline.md) - подробный разбор Detour
3. 💾 [Memory Model](memory-model.md) - управление памятью
4. ⚠️ [Error Handling](error-handling.md) - обработка ошибок

---

## References

- [C++ RecastNavigation](https://github.com/recastnavigation/recastnavigation)
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Navigation Mesh Paper](http://digestingduck.blogspot.com/2009/03/recast-navigation-mesh-generation.html)
