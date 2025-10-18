# Detour API Reference

API для runtime navigation и pathfinding.

---

## NavMesh

Runtime navigation mesh structure.

### Structure

```zig
pub const NavMesh = struct {
    allocator: Allocator,
    params: NavMeshParams,
    orig: [3]f32,
    tile_width: f32,
    tile_height: f32,
    max_tiles: u32,
    tiles: []MeshTile,

    pub fn init(allocator: Allocator) !*NavMesh
    pub fn deinit(self: *NavMesh) void

    // Tile management
    pub fn addTile(
        self: *NavMesh,
        data: []const u8,
        options: AddTileOptions,
    ) !void

    pub fn removeTile(self: *NavMesh, ref: TileRef) ![]const u8

    // Queries
    pub fn getTileAndPolyByRef(
        self: *const NavMesh,
        ref: PolyRef,
    ) !TileAndPoly

    pub fn closestPointOnPoly(
        self: *const NavMesh,
        ref: PolyRef,
        pos: *const [3]f32,
        closest: *[3]f32,
        pos_over_poly: *bool,
    ) !void

    pub fn getPolyHeight(
        self: *const NavMesh,
        ref: PolyRef,
        pos: *const [3]f32,
        height: *f32,
    ) !void
};

pub const MeshTile = struct {
    salt: u32,
    link_free_list: u32,
    header: ?*MeshHeader,
    polys: []Poly,
    verts: []f32,
    links: []Link,
    detail_meshes: []PolyDetail,
    detail_verts: []f32,
    detail_tris: []u8,
    bv_tree: []BVNode,
    off_mesh_cons: []OffMeshConnection,
    data: []const u8,
    data_size: usize,
    flags: u32,
    next: ?*MeshTile,
};
```

### Types

```zig
// Polygon reference (64-bit)
pub const PolyRef = u64;

// Tile reference (64-bit)
pub const TileRef = u64;

pub const Poly = struct {
    first_link: u32,
    verts: [VERTS_PER_POLYGON]u16,
    neis: [VERTS_PER_POLYGON]u16,
    flags: u16,
    vert_count: u8,
    area_and_type: u8,

    pub fn setArea(self: *Poly, area: u8) void
    pub fn getArea(self: *const Poly) u8
    pub fn setType(self: *Poly, poly_type: PolyType) void
    pub fn getType(self: *const Poly) PolyType
};

pub const Link = struct {
    ref: PolyRef,
    next: u32,
    edge: u8,
    side: u8,
    bmin: u8,
    bmax: u8,
};

pub const BVNode = struct {
    bmin: [3]u16,
    bmax: [3]u16,
    i: i32,
};
```

---

## NavMeshQuery

Query engine для pathfinding и spatial queries.

### Structure

```zig
pub const NavMeshQuery = struct {
    allocator: Allocator,
    nav: ?*const NavMesh,
    node_pool: ?*NodePool,
    tiny_node_pool: ?*NodePool,
    open_list: ?*NodeQueue,
    filter: QueryFilter,

    pub fn init(allocator: Allocator) !*NavMeshQuery
    pub fn deinit(self: *NavMeshQuery) void

    pub fn initQuery(
        self: *NavMeshQuery,
        nav: *const NavMesh,
        max_nodes: usize,
    ) !void
};
```

### Spatial Queries

```zig
// Find nearest polygon
pub fn findNearestPoly(
    self: *const NavMeshQuery,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    filter: *const QueryFilter,
    nearest_ref: *PolyRef,
    nearest_pt: ?*[3]f32,
) !void

// Query polygons in area
pub fn queryPolygons(
    self: *const NavMeshQuery,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    filter: *const QueryFilter,
    polys: []PolyRef,
    poly_count: *usize,
) !void

// Find polygons in circle
pub fn findPolysAroundCircle(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    center_pos: *const [3]f32,
    radius: f32,
    filter: *const QueryFilter,
    result_ref: []PolyRef,
    result_parent: []PolyRef,
    result_cost: []f32,
    result_count: *usize,
) !Status
```

### Pathfinding

```zig
// Find path (A*)
pub fn findPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    path: []PolyRef,
) !usize

// Find straight path (string pulling)
pub fn findStraightPath(
    self: *const NavMeshQuery,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    path: []const PolyRef,
    straight_path: []f32,
    straight_path_flags: ?[]u8,
    straight_path_refs: ?[]PolyRef,
    straight_path_count: *usize,
    options: u32,
) !Status

// Sliced pathfinding (for long paths)
pub fn initSlicedFindPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    options: u32,
) !Status

pub fn updateSlicedFindPath(
    self: *NavMeshQuery,
    max_iter: usize,
    done_iters: *usize,
) !Status

pub fn finalizeSlicedFindPath(
    self: *NavMeshQuery,
    path: []PolyRef,
) !usize
```

### Raycast

```zig
pub const RaycastHit = struct {
    t: f32,                      // Hit parameter [0, 1] or floatMax
    hit_normal: [3]f32,          // Hit surface normal
    path: [256]PolyRef,          // Visited polygons
    path_count: usize,
    path_cost: f32,
    hit_edge_index: i32,
};

// Raycast
pub fn raycast(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    options: u32,
    hit: *RaycastHit,
    prev_ref: PolyRef,
) !Status
```

### Movement

```zig
// Move along surface
pub fn moveAlongSurface(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    result_pos: *[3]f32,
    visited: []PolyRef,
    visited_count: *usize,
) !Status

// Find distance to wall
pub fn findDistanceToWall(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    center_pos: *const [3]f32,
    max_radius: f32,
    filter: *const QueryFilter,
    hit_dist: *f32,
    hit_pos: *[3]f32,
    hit_normal: *[3]f32,
) !Status
```

### Portal & Walls

```zig
// Get portal points
pub fn getPortalPoints(
    self: *const NavMeshQuery,
    from: PolyRef,
    to: PolyRef,
    left: *[3]f32,
    right: *[3]f32,
    from_type: *u8,
    to_type: *u8,
) !void

// Find local neighbourhood
pub fn findLocalNeighbourhood(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    center_pos: *const [3]f32,
    radius: f32,
    filter: *const QueryFilter,
    result_ref: []PolyRef,
    result_parent: []PolyRef,
    result_count: *usize,
) !Status

// Get edge midpoint
pub fn getEdgeMidPoint(
    self: *const NavMeshQuery,
    from: PolyRef,
    to: PolyRef,
    mid: *[3]f32,
) !Status
```

---

## QueryFilter

Фильтрация и cost modification.

```zig
pub const QueryFilter = struct {
    area_cost: [MAX_AREAS]f32,   // Cost multiplier per area
    include_flags: u16,           // Include polygons with these flags
    exclude_flags: u16,           // Exclude polygons with these flags

    pub fn init() QueryFilter

    // Filter
    pub fn passFilter(
        self: *const QueryFilter,
        ref: PolyRef,
        tile: *const MeshTile,
        poly: *const Poly,
    ) bool

    // Cost calculation
    pub fn getCost(
        self: *const QueryFilter,
        pa: *const [3]f32,
        pb: *const [3]f32,
        prev_ref: PolyRef,
        prev_tile: ?*const MeshTile,
        prev_poly: ?*const Poly,
        cur_ref: PolyRef,
        cur_tile: *const MeshTile,
        cur_poly: *const Poly,
        next_ref: PolyRef,
        next_tile: ?*const MeshTile,
        next_poly: ?*const Poly,
    ) f32

    // Area cost
    pub fn getAreaCost(self: *const QueryFilter, area: usize) f32
    pub fn setAreaCost(self: *QueryFilter, area: usize, cost: f32) void

    // Flags
    pub fn getIncludeFlags(self: *const QueryFilter) u16
    pub fn setIncludeFlags(self: *QueryFilter, flags: u16) void
    pub fn getExcludeFlags(self: *const QueryFilter) u16
    pub fn setExcludeFlags(self: *QueryFilter, flags: u16) void
};
```

---

## NavMesh Builder

Создание NavMesh data из Recast output.

```zig
pub const NavMeshCreateParams = struct {
    // Polygon mesh data
    verts: []const u16,
    vert_count: usize,
    polys: []const u16,
    poly_flags: []const u16,
    poly_areas: []const u8,
    poly_count: usize,
    nvp: usize,

    // Detail mesh data
    detail_meshes: ?[]const u32 = null,
    detail_verts: ?[]const f32 = null,
    detail_vert_count: usize = 0,
    detail_tris: ?[]const u8 = null,
    detail_tri_count: usize = 0,

    // Off-mesh connections
    off_mesh_con_verts: ?[]const f32 = null,
    off_mesh_con_rad: ?[]const f32 = null,
    off_mesh_con_flags: ?[]const u16 = null,
    off_mesh_con_areas: ?[]const u8 = null,
    off_mesh_con_dir: ?[]const u8 = null,
    off_mesh_con_user_id: ?[]const u32 = null,
    off_mesh_con_count: usize = 0,

    // Tile location
    tile_x: i32 = 0,
    tile_y: i32 = 0,
    tile_layer: i32 = 0,

    // Bounds
    bmin: [3]f32,
    bmax: [3]f32,

    // Agent parameters
    walkable_height: f32,
    walkable_radius: f32,
    walkable_climb: f32,

    // Cell size
    cs: f32,
    ch: f32,

    // Build flags
    build_bv_tree: bool = true,

    // User data
    user_id: u32 = 0,
};

// Create NavMesh data
pub fn createNavMeshData(
    allocator: Allocator,
    params: *NavMeshCreateParams,
) ![]u8
```

---

## Status

Статус операций (C++ compatibility).

```zig
pub const Status = struct {
    failure: bool = false,
    success: bool = false,
    in_progress: bool = false,
    partial_result: bool = false,
    invalid_param: bool = false,
    buffer_too_small: bool = false,

    pub fn ok() Status
    pub fn failed() Status
    pub fn isSuccess(self: Status) bool
    pub fn isFailure(self: Status) bool
};
```

---

## Constants

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

// Find path options
pub const FINDPATH_ANY_ANGLE: u32 = 0x02;

// Raycast options
pub const RAYCAST_USE_COSTS: u32 = 0x01;
```

---

## Complete Example

```zig
const std = @import("std");
const nav = @import("zig-recast");

pub fn pathfindingExample(
    allocator: Allocator,
    navmesh: *const nav.detour.NavMesh,
) !void {
    // 1. Create query
    var query = try nav.detour.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(navmesh, 2048);

    // 2. Setup filter
    const filter = nav.detour.QueryFilter.init();

    // 3. Find start/end polygons
    const start_pos = [3]f32{ -5.0, 0.0, -5.0 };
    const end_pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: nav.detour.PolyRef = 0;
    var end_ref: nav.detour.PolyRef = 0;

    try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, null);

    // 4. Find polygon path
    var poly_path: [256]nav.detour.PolyRef = undefined;
    const poly_count = try query.findPath(
        start_ref,
        end_ref,
        &start_pos,
        &end_pos,
        &filter,
        &poly_path,
    );

    std.debug.print("Path found: {d} polygons\n", .{poly_count});

    // 5. Get waypoints
    var waypoints: [256 * 3]f32 = undefined;
    var waypoint_count: usize = 0;

    _ = try query.findStraightPath(
        &start_pos,
        &end_pos,
        poly_path[0..poly_count],
        &waypoints,
        null,
        null,
        &waypoint_count,
        0,
    );

    std.debug.print("Waypoints: {d}\n", .{waypoint_count});

    // 6. Raycast
    var hit = nav.detour.RaycastHit{
        .t = 0,
        .hit_normal = .{ 0, 0, 0 },
        .path = undefined,
        .path_count = 0,
        .path_cost = 0,
        .hit_edge_index = 0,
    };

    _ = try query.raycast(start_ref, &start_pos, &end_pos, &filter, 0, &hit, 0);

    if (hit.t == std.math.floatMax(f32)) {
        std.debug.print("Clear line of sight\n", .{});
    } else {
        std.debug.print("Hit at t={d:.3}\n", .{hit.t});
    }
}
```

---

## See Also

- 📖 [Recast API](recast-api.md)
- 📖 [Math API](math-api.md)
- 🏗️ [Detour Pipeline](../02-architecture/detour-pipeline.md)
- 📚 [Pathfinding Guide](../04-guides/pathfinding.md)
- 📚 [Raycast Guide](../04-guides/raycast.md)
