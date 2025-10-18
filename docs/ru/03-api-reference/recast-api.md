# Recast API Reference

API для построения Navigation Mesh.

---

## Config

Конфигурация для построения NavMesh.

```zig
pub const Config = struct {
    // Grid resolution
    width: u32,                      // Grid width (cells)
    height: u32,                     // Grid height (cells)
    cs: f32,                         // Cell size (XZ plane)
    ch: f32,                         // Cell height (Y axis)

    // Bounds
    bmin: [3]f32,                    // Min bounds
    bmax: [3]f32,                    // Max bounds

    // Agent parameters
    walkable_slope_angle: f32,       // Max slope angle (degrees)
    walkable_height: u32,            // Min ceiling height (cells)
    walkable_climb: u32,             // Max step height (cells)
    walkable_radius: u32,            // Agent radius (cells)

    // Region parameters
    min_region_area: u32,            // Min region size (cells²)
    merge_region_area: u32,          // Merge threshold (cells²)

    // Polygon parameters
    max_edge_len: u32,               // Max edge length (cells)
    max_simplification_error: f32,   // Simplification tolerance
    max_verts_per_poly: u32,         // Max vertices per polygon

    // Detail mesh parameters
    detail_sample_dist: f32,         // Sample spacing
    detail_sample_max_error: f32,    // Max height error
};
```

### Helper Functions

```zig
// Calculate grid size from bounds and cell size
pub fn calcGridSize(bmin: *const [3]f32, bmax: *const [3]f32, cs: f32) [2]u32
```

---

## Heightfield

Voxel representation of input geometry.

### Structure

```zig
pub const Heightfield = struct {
    width: u32,                  // Grid width
    height: u32,                 // Grid height
    bmin: [3]f32,                // Bounds min
    bmax: [3]f32,                // Bounds max
    cs: f32,                     // Cell size
    ch: f32,                     // Cell height
    spans: []?*Span,             // Span lists for each cell

    pub fn init(
        allocator: Allocator,
        width: u32,
        height: u32,
        bmin: *const [3]f32,
        bmax: *const [3]f32,
        cs: f32,
        ch: f32,
    ) !Heightfield

    pub fn deinit(self: *Heightfield, allocator: Allocator) void
};

pub const Span = struct {
    smin: u32,                   // Min height
    smax: u32,                   // Max height
    area: u8,                    // Area type
    next: ?*Span,                // Next span in column
};
```

---

## Rasterization

Преобразование triangles в voxels.

```zig
// Mark walkable triangles based on slope
pub fn markWalkableTriangles(
    ctx: *Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    tris: []const u32,
    areas: []u8,
) void

// Rasterize triangles into heightfield
pub fn rasterizeTriangles(
    ctx: *Context,
    verts: []const f32,
    tris: []const u32,
    areas: []const u8,
    heightfield: *Heightfield,
    walkable_climb: u32,
) !void

// Rasterize single triangle
pub fn rasterizeTriangle(
    ctx: *Context,
    v0: *const [3]f32,
    v1: *const [3]f32,
    v2: *const [3]f32,
    area: u8,
    heightfield: *Heightfield,
    bbox_min_y: u32,
    bbox_max_y: u32,
) !void
```

---

## Filtering

Фильтрация non-walkable spans.

```zig
// Filter low hanging obstacles
pub fn filterLowHangingWalkableObstacles(
    ctx: *Context,
    walkable_climb: u32,
    heightfield: *Heightfield,
) void

// Filter ledge spans
pub fn filterLedgeSpans(
    ctx: *Context,
    walkable_height: u32,
    walkable_climb: u32,
    heightfield: *Heightfield,
) void

// Filter low height spans
pub fn filterWalkableLowHeightSpans(
    ctx: *Context,
    walkable_height: u32,
    heightfield: *Heightfield,
) void
```

---

## CompactHeightfield

Compressed heightfield с connectivity.

### Structure

```zig
pub const CompactHeightfield = struct {
    width: u32,
    height: u32,
    span_count: u32,
    walkable_height: u32,
    walkable_climb: u32,
    max_distance: u32,
    max_regions: u32,
    bmin: [3]f32,
    bmax: [3]f32,
    cs: f32,
    ch: f32,
    cells: []CompactCell,        // Grid cells
    spans: []CompactSpan,        // All spans (linear)
    areas: []u8,                 // Area IDs

    pub fn deinit(self: *CompactHeightfield, allocator: Allocator) void
};

pub const CompactCell = struct {
    index: u32,                  // Index to first span
    count: u32,                  // Span count
};

pub const CompactSpan = struct {
    y: u16,                      // Height
    reg: u16,                    // Region ID
    con: u32,                    // Connections (4 directions)
    h: u8,                       // Height above floor
};
```

### Functions

```zig
// Build compact heightfield from heightfield
pub fn buildCompactHeightfield(
    ctx: *Context,
    allocator: Allocator,
    walkable_height: u32,
    walkable_climb: u32,
    heightfield: *Heightfield,
) !CompactHeightfield
```

---

## Distance Field & Regions

Разделение walkable area на regions.

```zig
// Build distance field
pub fn buildDistanceField(
    ctx: *Context,
    chf: *CompactHeightfield,
) !void

// Build regions using watershed
pub fn buildRegions(
    ctx: *Context,
    allocator: Allocator,
    chf: *CompactHeightfield,
    min_region_area: u32,
    merge_region_area: u32,
) !void

// Erode walkable area
pub fn erodeWalkableArea(
    ctx: *Context,
    allocator: Allocator,
    radius: u32,
    chf: *CompactHeightfield,
) !void
```

---

## Contours

Извлечение контуров regions.

### Structure

```zig
pub const ContourSet = struct {
    contours: []Contour,
    bmin: [3]f32,
    bmax: [3]f32,
    cs: f32,
    ch: f32,
    width: u32,
    height: u32,
    border_size: u32,
    max_error: f32,

    pub fn deinit(self: *ContourSet, allocator: Allocator) void
};

pub const Contour = struct {
    verts: [][4]i32,             // Vertices (x, y, z, region_connection)
    rverts: [][4]i32,            // Raw vertices (before simplification)
    reg: u16,                    // Region ID
    area: u8,                    // Area type
};
```

### Functions

```zig
// Build contours from compact heightfield
pub fn buildContours(
    ctx: *Context,
    allocator: Allocator,
    chf: *CompactHeightfield,
    max_error: f32,
    max_edge_len: u32,
) !ContourSet
```

---

## PolyMesh

Simplified polygon mesh.

### Structure

```zig
pub const PolyMesh = struct {
    verts: []u16,                // Vertices (x,y,z interleaved)
    polys: []u16,                // Polygons (vertex indices)
    regs: []u16,                 // Region IDs
    flags: []u16,                // Flags
    areas: []u8,                 // Area types
    vert_count: u32,
    poly_count: u32,
    nvp: u32,                    // Max verts per poly
    bmin: [3]f32,
    bmax: [3]f32,
    cs: f32,
    ch: f32,
    border_size: u32,
    max_edge_error: f32,

    pub fn deinit(self: *PolyMesh, allocator: Allocator) void
};
```

### Functions

```zig
// Build polygon mesh from contours
pub fn buildPolyMesh(
    ctx: *Context,
    allocator: Allocator,
    cset: *ContourSet,
    nvp: u32,
) !PolyMesh

// Merge polygon meshes
pub fn mergePolyMeshes(
    ctx: *Context,
    allocator: Allocator,
    meshes: []*PolyMesh,
    nvp: u32,
) !PolyMesh
```

---

## DetailMesh

Детальная triangulation для height queries.

### Structure

```zig
pub const PolyMeshDetail = struct {
    meshes: []u32,               // [base_vert, vert_count, base_tri, tri_count] per poly
    verts: []f32,                // Vertices (x,y,z)
    tris: []u8,                  // Triangles (indices + flags)
    mesh_count: u32,
    vert_count: u32,
    tri_count: u32,

    pub fn deinit(self: *PolyMeshDetail, allocator: Allocator) void
};
```

### Functions

```zig
// Build detail mesh
pub fn buildPolyMeshDetail(
    ctx: *Context,
    allocator: Allocator,
    mesh: *PolyMesh,
    chf: *CompactHeightfield,
    sample_dist: f32,
    sample_max_error: f32,
) !PolyMeshDetail

// Merge detail meshes
pub fn mergePolyMeshDetails(
    ctx: *Context,
    allocator: Allocator,
    meshes: []*PolyMeshDetail,
) !PolyMeshDetail
```

---

## Area Modification

Изменение area types.

```zig
// Mark box area
pub fn markBoxArea(
    ctx: *Context,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void

// Mark convex polygon area
pub fn markConvexPolyArea(
    ctx: *Context,
    verts: []const f32,
    nverts: usize,
    hmin: f32,
    hmax: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void

// Mark cylinder area
pub fn markCylinderArea(
    ctx: *Context,
    pos: *const [3]f32,
    radius: f32,
    height: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void
```

---

## Constants

```zig
// Area IDs
pub const NULL_AREA: u8 = 0;
pub const WALKABLE_AREA: u8 = 63;

// Null indices
pub const NULL_IDX: u16 = 0xFFFF;
pub const MESH_NULL_IDX: u16 = 0xFFFF;

// Border
pub const BORDER_REG: u16 = 0x8000;
pub const BORDER_VERTEX: u16 = 0x8000;

// Connection
pub const NOT_CONNECTED: u8 = 0x3F;

// Max values
pub const MAX_LAYERS: u8 = 255;
pub const MAX_NEIS: usize = 16;
```

---

## Complete Example

```zig
const std = @import("std");
const nav = @import("zig-recast");

pub fn buildNavMesh(allocator: Allocator, mesh: Mesh) !void {
    var ctx = nav.Context.init(allocator);
    defer ctx.deinit();

    // Calculate bounds
    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    // ... calculate bounds from mesh ...

    // Configure
    var config = nav.recast.Config{
        .cs = 0.3,
        .ch = 0.2,
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
        .bmin = bmin,
        .bmax = bmax,
        .width = 0,
        .height = 0,
    };

    const grid_size = nav.recast.calcGridSize(&config.bmin, &config.bmax, config.cs);
    config.width = grid_size[0];
    config.height = grid_size[1];

    // 1. Heightfield
    var heightfield = try nav.recast.Heightfield.init(
        allocator,
        config.width,
        config.height,
        &config.bmin,
        &config.bmax,
        config.cs,
        config.ch,
    );
    defer heightfield.deinit(allocator);

    // 2. Rasterize
    var areas = try allocator.alloc(u8, mesh.tri_count);
    defer allocator.free(areas);

    @memset(areas, 0);
    nav.recast.filter.markWalkableTriangles(&ctx, config.walkable_slope_angle, mesh.verts, mesh.indices, areas);
    try nav.recast.rasterizeTriangles(&ctx, mesh.verts, mesh.indices, areas, &heightfield, config.walkable_climb);

    // 3. Filter
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    // 4. Compact
    var compact = try nav.recast.buildCompactHeightfield(&ctx, allocator, config.walkable_height, config.walkable_climb, &heightfield);
    defer compact.deinit(allocator);

    // 5. Regions
    try nav.recast.buildDistanceField(&ctx, &compact);
    try nav.recast.buildRegions(&ctx, allocator, &compact, config.min_region_area, config.merge_region_area);

    // 6. Contours
    var contours = try nav.recast.buildContours(&ctx, allocator, &compact, config.max_simplification_error, config.max_edge_len);
    defer contours.deinit(allocator);

    // 7. PolyMesh
    var poly_mesh = try nav.recast.buildPolyMesh(&ctx, allocator, &contours, config.max_verts_per_poly);
    defer poly_mesh.deinit(allocator);

    // 8. DetailMesh
    var detail_mesh = try nav.recast.buildPolyMeshDetail(&ctx, allocator, &poly_mesh, &compact, config.detail_sample_dist, config.detail_sample_max_error);
    defer detail_mesh.deinit(allocator);

    std.debug.print("NavMesh built: {d} polygons\n", .{poly_mesh.poly_count});
}
```

---

## See Also

- 📖 [Detour API](detour-api.md)
- 📖 [Math API](math-api.md)
- 🏗️ [Recast Pipeline](../02-architecture/recast-pipeline.md)
- 📚 [Creating NavMesh Guide](../04-guides/creating-navmesh.md)
