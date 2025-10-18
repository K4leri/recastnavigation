# Architecture Overview

[Русская версия](../../ru/02-architecture/overview.md) | **English**

Complete overview of the zig-recast navigation library architecture.

---

## System Architecture

zig-recast consists of 4 main modules:

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

**Purpose:** Convert triangle mesh to navigation mesh

**Components:**
- **Heightfield** - voxel representation of input geometry
- **Compact Heightfield** - compressed representation for processing
- **Regions** - watershed partitioning into walkable regions
- **Contours** - contour extraction from regions
- **PolyMesh** - simplified polygon mesh
- **DetailMesh** - detailed triangulation for height queries

**Pipeline:**
```
Triangle Mesh → Heightfield → Compact HF → Regions →
Contours → PolyMesh → DetailMesh → NavMesh Data
```

### 2. Detour (Pathfinding)

**Purpose:** Runtime navigation and pathfinding queries

**Components:**
- **NavMesh** - runtime navigation mesh structure
- **NavMeshQuery** - spatial queries and pathfinding
- **A* Pathfinding** - optimal path finding
- **Raycast** - visibility checks

**Queries:**
```
findPath()          → A* pathfinding
findNearestPoly()   → closest polygon search
raycast()           → line-of-sight check
findStraightPath()  → straight line path
```

### 3. DetourCrowd (Multi-Agent)

**Purpose:** Manage multiple agents with collision avoidance

**Features:**
- Multi-agent simulation
- Collision avoidance (RVO)
- Dynamic path following
- Local steering
- Neighbor detection

### 4. TileCache (Dynamic Obstacles)

**Purpose:** Dynamic obstacle support and NavMesh rebuilding

**Components:**
- **TileCache** - tile-based navmesh management
- **Obstacles** - cylinder, box, oriented box
- **Compression** - tile data compression
- **Rebuilding** - incremental NavMesh updates

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
```

### 3. Type Safety

✅ **Strong typing** - no void pointers
✅ **Enums** - type-safe constants
✅ **Comptime** - compile-time validation

---

## Performance

- ✅ Matches or exceeds C++ version
- ✅ Spatial hash structures for O(1) lookups
- ✅ BV tree for spatial queries
- ✅ Memory pooling for frequent allocations
- ✅ Inline critical functions

---

## Next Steps

For more detailed understanding:

1. 📖 [Recast Pipeline](recast-pipeline.md) - detailed Recast breakdown
2. 🔍 [Detour Pipeline](detour-pipeline.md) - detailed Detour breakdown
3. 💾 [Memory Model](memory-model.md) - memory management
4. ⚠️ [Error Handling](error-handling.md) - error handling strategies
