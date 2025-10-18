# API Reference

Полная справка по API zig-recast.

---

## Содержание

### Основные модули

- **[Recast API](recast-api.md)** - Navigation mesh building
  - Heightfield
  - CompactHeightfield
  - Regions
  - Contours
  - PolyMesh
  - DetailMesh

- **[Detour API](detour-api.md)** - Runtime navigation queries
  - NavMesh
  - NavMeshQuery
  - Pathfinding
  - Raycast
  - QueryFilter

- **[Math API](math-api.md)** - Mathematical utilities
  - Vec3
  - AABB
  - Geometry functions

---

## Quick Reference

### Common Patterns

#### Build NavMesh

```zig
const nav = @import("zig-recast");

// 1. Create heightfield
var heightfield = try nav.recast.Heightfield.init(allocator, width, height, ...);
defer heightfield.deinit(allocator);

// 2. Rasterize
try nav.recast.rasterizeTriangles(ctx, verts, indices, areas, &heightfield, walkable_climb);

// 3. Filter
nav.recast.filter.filterLowHangingWalkableObstacles(ctx, walkable_climb, &heightfield);
nav.recast.filter.filterLedgeSpans(ctx, walkable_height, walkable_climb, &heightfield);
nav.recast.filter.filterWalkableLowHeightSpans(ctx, walkable_height, &heightfield);

// 4. Compact
var compact = try nav.recast.buildCompactHeightfield(ctx, allocator, walkable_height, walkable_climb, &heightfield);
defer compact.deinit(allocator);

// 5. Regions
try nav.recast.buildDistanceField(ctx, &compact);
try nav.recast.buildRegions(ctx, allocator, &compact, min_region_area, merge_region_area);

// 6. Contours
var contours = try nav.recast.buildContours(ctx, allocator, &compact, max_simplification_error, max_edge_len);
defer contours.deinit(allocator);

// 7. PolyMesh
var poly_mesh = try nav.recast.buildPolyMesh(ctx, allocator, &contours, max_verts_per_poly);
defer poly_mesh.deinit(allocator);

// 8. DetailMesh
var detail_mesh = try nav.recast.buildPolyMeshDetail(ctx, allocator, &poly_mesh, &compact, sample_dist, sample_max_error);
defer detail_mesh.deinit(allocator);
```

#### Pathfinding

```zig
// 1. Initialize query
var query = try nav.detour.NavMeshQuery.init(allocator);
defer query.deinit();
try query.initQuery(&navmesh, 2048);

// 2. Find nearest polygons
const filter = nav.detour.QueryFilter.init();
const extents = [3]f32{ 2.0, 4.0, 2.0 };

var start_ref: nav.detour.PolyRef = 0;
var end_ref: nav.detour.PolyRef = 0;

try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);
try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, null);

// 3. Find path
var path: [256]nav.detour.PolyRef = undefined;
const path_count = try query.findPath(start_ref, end_ref, &start_pos, &end_pos, &filter, &path);

// 4. Get waypoints
var waypoints: [256 * 3]f32 = undefined;
var waypoint_count: usize = 0;
_ = try query.findStraightPath(&start_pos, &end_pos, path[0..path_count], &waypoints, null, null, &waypoint_count, 0);
```

#### Raycast

```zig
// 1. Find start polygon
var start_ref: nav.detour.PolyRef = 0;
try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);

// 2. Perform raycast
var hit = nav.detour.RaycastHit{
    .t = 0,
    .hit_normal = .{ 0, 0, 0 },
    .path = undefined,
    .path_count = 0,
    .path_cost = 0,
    .hit_edge_index = 0,
};

_ = try query.raycast(start_ref, &start_pos, &end_pos, &filter, 0, &hit, 0);

// 3. Check result
if (hit.t == std.math.floatMax(f32)) {
    // No hit - clear line of sight
} else {
    // Hit at t
    const hit_pos = [3]f32{
        start_pos[0] + hit.t * (end_pos[0] - start_pos[0]),
        start_pos[1] + hit.t * (end_pos[1] - start_pos[1]),
        start_pos[2] + hit.t * (end_pos[2] - start_pos[2]),
    };
}
```

---

## Error Handling

All functions that can fail return error unions (`!T`):

```zig
// Option 1: Propagate error
const result = try operation();

// Option 2: Handle error
const result = operation() catch |err| {
    std.debug.print("Error: {}\n", .{err});
    return err;
};

// Option 3: Default value
const result = operation() catch default_value;
```

Common errors:
- `error.OutOfMemory` - Allocation failed
- `error.InvalidParam` - Invalid parameter
- `error.NoNavMesh` - NavMesh not initialized
- `error.InvalidInput` - Invalid input data

---

## Memory Management

All structures use **explicit allocators**:

```zig
// Pass allocator to init
var structure = try Structure.init(allocator, ...);

// Must call deinit with same allocator
defer structure.deinit(allocator);
```

**Rules:**
- Caller owns returned memory
- All structures have `deinit()`
- No hidden allocations
- No shared ownership

---

## Type Reference

### Basic Types

```zig
// Polygon reference (64-bit)
pub const PolyRef = u64;

// Tile reference (64-bit)
pub const TileRef = u64;

// 3D vector
pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,
};

// Axis-aligned bounding box
pub const AABB = extern struct {
    min: Vec3,
    max: Vec3,
};

// Status flags
pub const Status = struct {
    failure: bool = false,
    success: bool = false,
    in_progress: bool = false,
    partial_result: bool = false,
    invalid_param: bool = false,
    buffer_too_small: bool = false,
};
```

---

## Constants

### Recast

```zig
// Default area IDs
pub const NULL_AREA: u8 = 0;
pub const WALKABLE_AREA: u8 = 63;

// Null connection
pub const NULL_IDX: u16 = 0xFFFF;

// Span flags
pub const SPAN_FLAGS_LEDGE: u8 = 0x01;
pub const SPAN_FLAGS_WALKABLE: u8 = 0x02;

// Border
pub const BORDER_VERTEX: u16 = 0x8000;

// Max layers
pub const MAX_LAYERS: u8 = 255;
```

### Detour

```zig
// NavMesh
pub const NAVMESH_MAGIC: u32 = 'D' | ('N' << 8) | ('A' << 16) | ('V' << 24);
pub const NAVMESH_VERSION: u32 = 7;

// Polygon
pub const VERTS_PER_POLYGON: usize = 6;
pub const NULL_LINK: u32 = 0xffffffff;
pub const EXT_LINK: u8 = 0x8000;

// Areas
pub const MAX_AREAS: usize = 64;

// Raycast options
pub const RAYCAST_USE_COSTS: u32 = 0x01;

// Straight path flags
pub const STRAIGHTPATH_START: u8 = 0x01;
pub const STRAIGHTPATH_END: u8 = 0x02;
pub const STRAIGHTPATH_OFFMESH_CONNECTION: u8 = 0x04;

// Straight path options
pub const STRAIGHTPATH_ALL_CROSSINGS: u32 = 0x00;
pub const STRAIGHTPATH_AREA_CROSSINGS: u32 = 0x01;
```

---

## Configuration

### Typical Agent Parameters

```zig
// Human-sized character
const agent_height: f32 = 2.0;      // 2 meters
const agent_radius: f32 = 0.6;      // 0.6 meters
const agent_max_climb: f32 = 0.9;   // 0.9 meters

// Cell sizing (rule of thumb: radius / 2)
const cs: f32 = 0.3;  // XZ plane
const ch: f32 = 0.2;  // Y axis

// Convert to cells
const walkable_height = @as(u32, @intFromFloat(@ceil(agent_height / ch)));  // 10
const walkable_climb = @as(u32, @intFromFloat(@floor(agent_max_climb / ch)));  // 4
const walkable_radius = @as(u32, @intFromFloat(@ceil(agent_radius / cs)));  // 2
```

### Recommended Config Values

```zig
pub const Config = struct {
    cs: f32 = 0.3,
    ch: f32 = 0.2,
    walkable_slope_angle: f32 = 45.0,
    walkable_height: u32 = 10,
    walkable_climb: u32 = 4,
    walkable_radius: u32 = 2,
    max_edge_len: u32 = 12,
    max_simplification_error: f32 = 1.3,
    min_region_area: u32 = 8,
    merge_region_area: u32 = 20,
    max_verts_per_poly: u32 = 6,
    detail_sample_dist: f32 = 6.0,
    detail_sample_max_error: f32 = 1.0,
};
```

---

## See Also

- 📖 [Recast API](recast-api.md) - Complete Recast reference
- 📖 [Detour API](detour-api.md) - Complete Detour reference
- 📖 [Math API](math-api.md) - Math utilities reference
- 🏗️ [Architecture](../02-architecture/overview.md) - System architecture
- 📚 [Guides](../04-guides/) - Practical tutorials
