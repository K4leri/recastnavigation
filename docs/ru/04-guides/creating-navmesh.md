# Creating NavMesh Guide

Практическое руководство по созданию Navigation Mesh.

---

## Overview

Этот guide проведет вас через полный процесс создания NavMesh от triangle mesh до готового NavMesh для pathfinding.

**Что вы изучите:**
- ✅ Подготовка input mesh
- ✅ Настройка конфигурации
- ✅ Выполнение Recast pipeline
- ✅ Создание Detour NavMesh
- ✅ Оптимизация параметров
- ✅ Отладка проблем

**Время:** 30-60 минут

---

## Prerequisites

```zig
const std = @import("std");
const nav = @import("zig-recast");

// Базовые импорты
const Allocator = std.mem.Allocator;
const Context = nav.Context;
const Config = nav.recast.Config;
```

---

## Step 1: Prepare Input Mesh

### Load Mesh Data

```zig
pub fn loadMesh(allocator: Allocator, path: []const u8) !Mesh {
    // Load .obj file or other format
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    return parseMesh(allocator, content);
}

pub const Mesh = struct {
    vertices: []f32,   // x, y, z triplets
    indices: []u32,    // triangle indices
    tri_count: usize,

    pub fn deinit(self: *Mesh, allocator: Allocator) void {
        allocator.free(self.vertices);
        allocator.free(self.indices);
    }
};
```

### Validate Mesh

```zig
pub fn validateMesh(mesh: *const Mesh) !void {
    // Check vertex count
    if (mesh.vertices.len % 3 != 0) {
        return error.InvalidVertexData;
    }

    // Check index count
    if (mesh.indices.len % 3 != 0) {
        return error.InvalidIndexData;
    }

    // Check indices are valid
    const vert_count = mesh.vertices.len / 3;
    for (mesh.indices) |idx| {
        if (idx >= vert_count) {
            std.debug.print("Invalid index: {d} (max: {d})\n", .{ idx, vert_count });
            return error.IndexOutOfBounds;
        }
    }

    // Check for NaN/Inf
    for (mesh.vertices) |v| {
        if (!std.math.isFinite(v)) {
            return error.InvalidVertexValue;
        }
    }

    std.debug.print("✅ Mesh validation passed\n", .{});
    std.debug.print("   Vertices: {d}\n", .{mesh.vertices.len / 3});
    std.debug.print("   Triangles: {d}\n", .{mesh.tri_count});
}
```

---

## Step 2: Configure Parameters

### Basic Configuration

```zig
pub fn createDefaultConfig(mesh: *const Mesh) Config {
    // Calculate bounds
    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) };

    var i: usize = 0;
    while (i < mesh.vertices.len) : (i += 3) {
        bmin[0] = @min(bmin[0], mesh.vertices[i + 0]);
        bmin[1] = @min(bmin[1], mesh.vertices[i + 1]);
        bmin[2] = @min(bmin[2], mesh.vertices[i + 2]);
        bmax[0] = @max(bmax[0], mesh.vertices[i + 0]);
        bmax[1] = @max(bmax[1], mesh.vertices[i + 1]);
        bmax[2] = @max(bmax[2], mesh.vertices[i + 2]);
    }

    // Agent parameters (for human-sized character)
    const agent_height: f32 = 2.0;     // 2 meters tall
    const agent_radius: f32 = 0.6;     // 0.6 meter radius
    const agent_max_climb: f32 = 0.9;  // Can climb 0.9m steps

    // Cell size (rule of thumb: radius / 2)
    const cs: f32 = agent_radius / 2.0;  // 0.3
    const ch: f32 = cs / 1.5;            // 0.2

    // Convert to cells
    const walkable_height = @as(u32, @intFromFloat(@ceil(agent_height / ch)));
    const walkable_climb = @as(u32, @intFromFloat(@floor(agent_max_climb / ch)));
    const walkable_radius = @as(u32, @intFromFloat(@ceil(agent_radius / cs)));

    var config = Config{
        .cs = cs,
        .ch = ch,
        .walkable_slope_angle = 45.0,
        .walkable_height = walkable_height,
        .walkable_climb = walkable_climb,
        .walkable_radius = walkable_radius,
        .max_edge_len = @as(u32, @intFromFloat(agent_radius / cs)) * 8,
        .max_simplification_error = 1.3,
        .min_region_area = 8,
        .merge_region_area = 20,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6.0,
        .detail_sample_max_error = 1.0,
        .bmin = bmin,
        .bmax = bmax,
        .width = 0,   // Will calculate
        .height = 0,  // Will calculate
    };

    // Calculate grid size
    const grid_size = nav.recast.calcGridSize(&config.bmin, &config.bmax, config.cs);
    config.width = grid_size[0];
    config.height = grid_size[1];

    return config;
}
```

### Custom Configuration

```zig
pub fn createCustomConfig(
    agent_height: f32,
    agent_radius: f32,
    agent_max_climb: f32,
    mesh: *const Mesh,
) Config {
    var config = createDefaultConfig(mesh);

    // Adjust for custom agent
    const cs = agent_radius / 2.0;
    const ch = cs / 1.5;

    config.cs = cs;
    config.ch = ch;
    config.walkable_height = @intFromFloat(@ceil(agent_height / ch));
    config.walkable_climb = @intFromFloat(@floor(agent_max_climb / ch));
    config.walkable_radius = @intFromFloat(@ceil(agent_radius / cs));

    // Recalculate grid
    const grid_size = nav.recast.calcGridSize(&config.bmin, &config.bmax, config.cs);
    config.width = grid_size[0];
    config.height = grid_size[1];

    return config;
}
```

---

## Step 3: Build Heightfield

```zig
pub fn buildHeightfield(
    allocator: Allocator,
    ctx: *Context,
    mesh: *const Mesh,
    config: *const Config,
) !nav.recast.Heightfield {
    std.debug.print("=== Building Heightfield ===\n", .{});

    // 1. Create heightfield
    var heightfield = try nav.recast.Heightfield.init(
        allocator,
        config.width,
        config.height,
        &config.bmin,
        &config.bmax,
        config.cs,
        config.ch,
    );
    errdefer heightfield.deinit(allocator);

    std.debug.print("Grid: {d}x{d}\n", .{ config.width, config.height });

    // 2. Mark walkable triangles
    var areas = try allocator.alloc(u8, mesh.tri_count);
    defer allocator.free(areas);

    @memset(areas, 0);
    nav.recast.filter.markWalkableTriangles(
        ctx,
        config.walkable_slope_angle,
        mesh.vertices,
        mesh.indices,
        areas,
    );

    var walkable_count: usize = 0;
    for (areas) |area| {
        if (area != 0) walkable_count += 1;
    }
    std.debug.print("Walkable triangles: {d}/{d}\n", .{ walkable_count, mesh.tri_count });

    // 3. Rasterize triangles
    try nav.recast.rasterizeTriangles(
        ctx,
        mesh.vertices,
        mesh.indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

    // Count spans
    var span_count: usize = 0;
    for (heightfield.spans) |span_opt| {
        var span = span_opt;
        while (span) |s| : (span = s.next) {
            span_count += 1;
        }
    }
    std.debug.print("Spans created: {d}\n", .{span_count});

    return heightfield;
}
```

---

## Step 4: Filter Heightfield

```zig
pub fn filterHeightfield(
    ctx: *Context,
    heightfield: *nav.recast.Heightfield,
    config: *const Config,
) void {
    std.debug.print("=== Filtering Heightfield ===\n", .{});

    // 1. Filter low hanging obstacles
    nav.recast.filter.filterLowHangingWalkableObstacles(
        ctx,
        config.walkable_climb,
        heightfield,
    );
    std.debug.print("✅ Low hanging obstacles filtered\n", .{});

    // 2. Filter ledges
    nav.recast.filter.filterLedgeSpans(
        ctx,
        config.walkable_height,
        config.walkable_climb,
        heightfield,
    );
    std.debug.print("✅ Ledge spans filtered\n", .{});

    // 3. Filter low height spans
    nav.recast.filter.filterWalkableLowHeightSpans(
        ctx,
        config.walkable_height,
        heightfield,
    );
    std.debug.print("✅ Low height spans filtered\n", .{});
}
```

---

## Step 5: Build Compact Heightfield

```zig
pub fn buildCompact(
    allocator: Allocator,
    ctx: *Context,
    heightfield: *nav.recast.Heightfield,
    config: *const Config,
) !nav.recast.CompactHeightfield {
    std.debug.print("=== Building Compact Heightfield ===\n", .{});

    var compact = try nav.recast.buildCompactHeightfield(
        ctx,
        allocator,
        config.walkable_height,
        config.walkable_climb,
        heightfield,
    );

    std.debug.print("Compact spans: {d}\n", .{compact.span_count});
    std.debug.print("Memory saved: ~{d} KB → ~{d} KB\n", .{
        estimateHeightfieldMemory(heightfield) / 1024,
        estimateCompactMemory(&compact) / 1024,
    });

    return compact;
}

fn estimateHeightfieldMemory(hf: *nav.recast.Heightfield) usize {
    var span_count: usize = 0;
    for (hf.spans) |span_opt| {
        var span = span_opt;
        while (span) |s| : (span = s.next) {
            span_count += 1;
        }
    }
    return span_count * @sizeOf(nav.recast.Span);
}

fn estimateCompactMemory(chf: *nav.recast.CompactHeightfield) usize {
    return chf.span_count * @sizeOf(nav.recast.CompactSpan) +
        chf.width * chf.height * @sizeOf(nav.recast.CompactCell);
}
```

---

## Step 6: Build Regions

```zig
pub fn buildRegionsStep(
    allocator: Allocator,
    ctx: *Context,
    compact: *nav.recast.CompactHeightfield,
    config: *const Config,
) !void {
    std.debug.print("=== Building Regions ===\n", .{});

    // 1. Build distance field
    try nav.recast.buildDistanceField(ctx, compact);
    std.debug.print("Max distance: {d}\n", .{compact.max_distance});

    // 2. Build regions (watershed)
    try nav.recast.buildRegions(
        ctx,
        allocator,
        compact,
        config.min_region_area,
        config.merge_region_area,
    );

    // Count regions
    var max_region: u16 = 0;
    for (compact.spans) |span| {
        if (span.reg > max_region) {
            max_region = span.reg;
        }
    }
    std.debug.print("Regions created: {d}\n", .{max_region});
}
```

---

## Step 7: Build Contours

```zig
pub fn buildContoursStep(
    allocator: Allocator,
    ctx: *Context,
    compact: *nav.recast.CompactHeightfield,
    config: *const Config,
) !nav.recast.ContourSet {
    std.debug.print("=== Building Contours ===\n", .{});

    var contour_set = try nav.recast.buildContours(
        ctx,
        allocator,
        compact,
        config.max_simplification_error,
        config.max_edge_len,
    );

    std.debug.print("Contours: {d}\n", .{contour_set.contours.len});

    // Statistics
    var total_verts: usize = 0;
    for (contour_set.contours) |contour| {
        total_verts += contour.verts.len / 4;
    }
    std.debug.print("Total vertices: {d}\n", .{total_verts});

    return contour_set;
}
```

---

## Step 8: Build Polygon Mesh

```zig
pub fn buildPolyMeshStep(
    allocator: Allocator,
    ctx: *Context,
    contour_set: *nav.recast.ContourSet,
    config: *const Config,
) !nav.recast.PolyMesh {
    std.debug.print("=== Building Polygon Mesh ===\n", .{});

    var poly_mesh = try nav.recast.buildPolyMesh(
        ctx,
        allocator,
        contour_set,
        config.max_verts_per_poly,
    );

    std.debug.print("Polygons: {d}\n", .{poly_mesh.poly_count});
    std.debug.print("Vertices: {d}\n", .{poly_mesh.vert_count});
    std.debug.print("Max verts per poly: {d}\n", .{poly_mesh.nvp});

    return poly_mesh;
}
```

---

## Step 9: Build Detail Mesh

```zig
pub fn buildDetailMeshStep(
    allocator: Allocator,
    ctx: *Context,
    poly_mesh: *nav.recast.PolyMesh,
    compact: *nav.recast.CompactHeightfield,
    config: *const Config,
) !nav.recast.PolyMeshDetail {
    std.debug.print("=== Building Detail Mesh ===\n", .{});

    var detail_mesh = try nav.recast.buildPolyMeshDetail(
        ctx,
        allocator,
        poly_mesh,
        compact,
        config.detail_sample_dist,
        config.detail_sample_max_error,
    );

    std.debug.print("Detail meshes: {d}\n", .{detail_mesh.mesh_count});
    std.debug.print("Detail vertices: {d}\n", .{detail_mesh.vert_count});
    std.debug.print("Detail triangles: {d}\n", .{detail_mesh.tri_count});

    return detail_mesh;
}
```

---

## Step 10: Create NavMesh

```zig
pub fn createNavMesh(
    allocator: Allocator,
    poly_mesh: *nav.recast.PolyMesh,
    detail_mesh: *nav.recast.PolyMeshDetail,
    config: *const Config,
) !nav.detour.NavMesh {
    std.debug.print("=== Creating NavMesh ===\n", .{});

    // 1. Setup creation parameters
    var params = nav.detour.builder.NavMeshCreateParams{
        .verts = poly_mesh.verts,
        .vert_count = poly_mesh.vert_count,
        .polys = poly_mesh.polys,
        .poly_flags = poly_mesh.flags,
        .poly_areas = poly_mesh.areas,
        .poly_count = poly_mesh.poly_count,
        .nvp = poly_mesh.nvp,

        .detail_meshes = detail_mesh.meshes,
        .detail_verts = detail_mesh.verts,
        .detail_vert_count = detail_mesh.vert_count,
        .detail_tris = detail_mesh.tris,
        .detail_tri_count = detail_mesh.tri_count,

        .walk_height = @as(f32, @floatFromInt(config.walkable_height)) * config.ch,
        .walk_radius = @as(f32, @floatFromInt(config.walkable_radius)) * config.cs,
        .walk_climb = @as(f32, @floatFromInt(config.walkable_climb)) * config.ch,

        .bmin = poly_mesh.bmin,
        .bmax = poly_mesh.bmax,
        .cs = config.cs,
        .ch = config.ch,

        .build_bv_tree = true,
    };

    // 2. Create NavMesh data
    const nav_data = try nav.detour.builder.createNavMeshData(allocator, &params);
    defer allocator.free(nav_data);

    std.debug.print("NavMesh data size: {d} KB\n", .{nav_data.len / 1024});

    // 3. Initialize NavMesh
    var navmesh = try nav.detour.NavMesh.init(allocator);
    errdefer navmesh.deinit();

    // 4. Add tile
    try navmesh.addTile(nav_data, .{});

    std.debug.print("✅ NavMesh created successfully!\n", .{});

    return navmesh;
}
```

---

## Complete Example

```zig
pub fn buildCompleteNavMesh(
    allocator: Allocator,
    mesh_path: []const u8,
) !nav.detour.NavMesh {
    std.debug.print("========================================\n", .{});
    std.debug.print("   Building NavMesh\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Step 1: Load mesh
    var mesh = try loadMesh(allocator, mesh_path);
    defer mesh.deinit(allocator);

    try validateMesh(&mesh);

    // Step 2: Configure
    const config = createDefaultConfig(&mesh);
    std.debug.print("\nConfiguration:\n", .{});
    std.debug.print("  Cell size: {d:.3} x {d:.3}\n", .{ config.cs, config.ch });
    std.debug.print("  Agent: h={d} r={d} climb={d}\n", .{
        config.walkable_height,
        config.walkable_radius,
        config.walkable_climb,
    });
    std.debug.print("  Grid: {d}x{d}\n\n", .{ config.width, config.height });

    // Step 3: Create context
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    // Step 4: Build heightfield
    var heightfield = try buildHeightfield(allocator, &ctx, &mesh, &config);
    defer heightfield.deinit(allocator);

    // Step 5: Filter
    filterHeightfield(&ctx, &heightfield, &config);

    // Step 6: Compact
    var compact = try buildCompact(allocator, &ctx, &heightfield, &config);
    defer compact.deinit(allocator);

    // Step 7: Regions
    try buildRegionsStep(allocator, &ctx, &compact, &config);

    // Step 8: Contours
    var contour_set = try buildContoursStep(allocator, &ctx, &compact, &config);
    defer contour_set.deinit(allocator);

    // Step 9: Poly mesh
    var poly_mesh = try buildPolyMeshStep(allocator, &ctx, &contour_set, &config);
    defer poly_mesh.deinit(allocator);

    // Step 10: Detail mesh
    var detail_mesh = try buildDetailMeshStep(allocator, &ctx, &poly_mesh, &compact, &config);
    defer detail_mesh.deinit(allocator);

    // Step 11: NavMesh
    const navmesh = try createNavMesh(allocator, &poly_mesh, &detail_mesh, &config);

    std.debug.print("\n========================================\n", .{});
    std.debug.print("   ✅ Complete!\n", .{});
    std.debug.print("========================================\n", .{});

    return navmesh;
}
```

---

## Optimization Tips

### 1. Adjust Cell Size

```zig
// Fine detail (slow, accurate)
config.cs = 0.1;
config.ch = 0.05;

// Balanced (recommended)
config.cs = 0.3;
config.ch = 0.2;

// Coarse (fast, less accurate)
config.cs = 0.5;
config.ch = 0.4;
```

### 2. Region Parameters

```zig
// Small islands - smaller threshold
config.min_region_area = 4;
config.merge_region_area = 10;

// Large open areas - larger threshold
config.min_region_area = 64;
config.merge_region_area = 200;
```

### 3. Polygon Simplification

```zig
// More detail
config.max_simplification_error = 1.0;

// Balanced
config.max_simplification_error = 1.3;

// Simplified
config.max_simplification_error = 2.0;
```

---

## Troubleshooting

### Problem: No polygons generated

**Причины:**
- Все triangles marked as unwalkable (slope too steep)
- Mesh completely filtered out

**Решение:**
```zig
// Increase slope angle
config.walkable_slope_angle = 60.0;

// Check walkable triangle count
var walkable_count: usize = 0;
for (areas) |area| {
    if (area != 0) walkable_count += 1;
}
if (walkable_count == 0) {
    std.debug.print("⚠️ No walkable triangles!\n", .{});
}
```

### Problem: Too many regions

**Решение:**
```zig
// Increase merge threshold
config.merge_region_area = 200;

// Increase min region size
config.min_region_area = 64;
```

### Problem: Jagged contours

**Решение:**
```zig
// Increase simplification
config.max_simplification_error = 2.0;

// Increase max edge length
config.max_edge_len = 24;
```

---

## Next Steps

- 📖 [Pathfinding Guide](pathfinding.md) - использование NavMesh
- 🎯 [Raycast Guide](raycast.md) - line-of-sight
- 🏗️ [Performance Guide](performance.md) - optimization

---

**Поздравляем!** Вы создали свой NavMesh. 🎉
