# Quick Start Guide

Создайте свой первый navigation mesh за 5 минут!

---

## Цель

В этом руководстве вы:
1. ✅ Создадите простой triangle mesh
2. ✅ Построите navigation mesh с помощью Recast
3. ✅ Выполните pathfinding запрос с помощью Detour
4. ✅ Убедитесь что нет утечек памяти

**Время выполнения:** ~5-10 минут

---

## Шаг 1: Создание проекта

Создайте новый Zig проект:

```bash
mkdir my-navmesh
cd my-navmesh
```

Создайте `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "my-navmesh",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Добавьте zig-recast как dependency
    const recast_dep = b.dependency("zig-recast", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig-recast", recast_dep.module("zig-recast"));

    b.installArtifact(exe);
}
```

Создайте `build.zig.zon`:

```zig
.{
    .name = "my-navmesh",
    .version = "0.1.0",
    .dependencies = .{
        .@"zig-recast" = .{
            .path = "../zig-recast",  // или Git URL
        },
    },
}
```

---

## Шаг 2: Создание простого mesh

Создайте `src/main.zig`:

```zig
const std = @import("std");
const nav = @import("zig-recast");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Creating navigation mesh...\n", .{});

    // 1. Создаем простой box mesh (пол)
    const vertices = [_]f32{
        // Floor vertices (clockwise from top-left)
        -10.0, 0.0, -10.0,  // 0: top-left
        -10.0, 0.0,  10.0,  // 1: bottom-left
         10.0, 0.0,  10.0,  // 2: bottom-right
         10.0, 0.0, -10.0,  // 3: top-right
    };

    const indices = [_]u32{
        0, 1, 2,  // Triangle 1
        0, 2, 3,  // Triangle 2
    };

    // 2. Настраиваем конфигурацию
    var config = nav.recast.Config{
        .cs = 0.3,           // Cell size
        .ch = 0.2,           // Cell height
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

    // Вычисляем bounds
    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ std.math.floatMin(f32), std.math.floatMin(f32), std.math.floatMin(f32) };

    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        bmin[0] = @min(bmin[0], vertices[i + 0]);
        bmin[1] = @min(bmin[1], vertices[i + 1]);
        bmin[2] = @min(bmin[2], vertices[i + 2]);
        bmax[0] = @max(bmax[0], vertices[i + 0]);
        bmax[1] = @max(bmax[1], vertices[i + 1]);
        bmax[2] = @max(bmax[2], vertices[i + 2]);
    }

    config.bmin = bmin;
    config.bmax = bmax;

    std.debug.print("  Bounds: ({d:.1}, {d:.1}, {d:.1}) to ({d:.1}, {d:.1}, {d:.1})\n", .{
        bmin[0], bmin[1], bmin[2],
        bmax[0], bmax[1], bmax[2],
    });

    // 3. Создаем build context
    var ctx = nav.Context.init(allocator);
    defer ctx.deinit();

    // 4. Вычисляем grid size
    const grid_size = nav.recast.calcGridSize(&config.bmin, &config.bmax, config.cs);
    config.width = grid_size[0];
    config.height = grid_size[1];

    std.debug.print("  Grid size: {}x{}\n", .{ config.width, config.height });

    // 5. Создаем heightfield
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

    std.debug.print("  Heightfield created: {}x{}\n", .{ heightfield.width, heightfield.height });

    // 6. Rasterize triangles
    var areas = try allocator.alloc(u8, indices.len / 3);
    defer allocator.free(areas);

    @memset(areas, 0);
    nav.recast.filter.markWalkableTriangles(
        &ctx,
        config.walkable_slope_angle,
        &vertices,
        &indices,
        areas,
    );

    try nav.recast.rasterizeTriangles(
        &ctx,
        &vertices,
        &indices,
        areas,
        &heightfield,
        config.walkable_climb,
    );

    std.debug.print("  Triangles rasterized\n", .{});

    // 7. Filter heightfield
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, config.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, config.walkable_height, config.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, config.walkable_height, &heightfield);

    std.debug.print("  Heightfield filtered\n", .{});

    // 8. Compact heightfield
    var compact = try nav.recast.buildCompactHeightfield(
        &ctx,
        allocator,
        config.walkable_height,
        config.walkable_climb,
        &heightfield,
    );
    defer compact.deinit(allocator);

    std.debug.print("  Compact heightfield built: {} spans\n", .{compact.span_count});

    // 9. Build distance field & regions
    try nav.recast.buildDistanceField(&ctx, &compact);
    try nav.recast.buildRegions(&ctx, allocator, &compact, config.min_region_area, config.merge_region_area);

    std.debug.print("  Regions built\n", .{});

    // 10. Build contours
    var contour_set = try nav.recast.buildContours(
        &ctx,
        allocator,
        &compact,
        config.max_simplification_error,
        config.max_edge_len,
    );
    defer contour_set.deinit(allocator);

    std.debug.print("  Contours built: {} contours\n", .{contour_set.contours.len});

    // 11. Build polygon mesh
    var poly_mesh = try nav.recast.buildPolyMesh(
        &ctx,
        allocator,
        &contour_set,
        config.max_verts_per_poly,
    );
    defer poly_mesh.deinit(allocator);

    std.debug.print("  PolyMesh built: {} polygons, {} vertices\n", .{
        poly_mesh.poly_count,
        poly_mesh.vert_count,
    });

    // 12. Build detail mesh
    var detail_mesh = try nav.recast.buildPolyMeshDetail(
        &ctx,
        allocator,
        &poly_mesh,
        &compact,
        config.detail_sample_dist,
        config.detail_sample_max_error,
    );
    defer detail_mesh.deinit(allocator);

    std.debug.print("  DetailMesh built: {} meshes\n", .{detail_mesh.mesh_count});

    std.debug.print("\n✅ NavMesh created successfully!\n", .{});
    std.debug.print("   - Polygons: {}\n", .{poly_mesh.poly_count});
    std.debug.print("   - Vertices: {}\n", .{poly_mesh.vert_count});
}
```

---

## Шаг 3: Сборка и запуск

```bash
zig build
./zig-out/bin/my-navmesh
```

Вы должны увидеть:

```
Creating navigation mesh...
  Bounds: (-10.0, 0.0, -10.0) to (10.0, 0.0, 10.0)
  Grid size: 67x67
  Heightfield created: 67x67
  Triangles rasterized
  Heightfield filtered
  Compact heightfield built: 4489 spans
  Regions built
  Contours built: 1 contours
  PolyMesh built: 2 polygons, 4 vertices
  DetailMesh built: 2 meshes

✅ NavMesh created successfully!
   - Polygons: 2
   - Vertices: 4
```

---

## Шаг 4: Добавление pathfinding (опционально)

Добавьте pathfinding в конец `main()`:

```zig
    // ... после создания poly_mesh и detail_mesh ...

    // 13. Создаем NavMesh data
    var nav_data_params = nav.detour.builder.NavMeshCreateParams{
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
        .bmin = &poly_mesh.bmin,
        .bmax = &poly_mesh.bmax,
        .cs = config.cs,
        .ch = config.ch,
        .build_bv_tree = true,
    };

    const nav_data = try nav.detour.builder.createNavMeshData(allocator, &nav_data_params);
    defer allocator.free(nav_data);

    // 14. Инициализируем NavMesh
    var navmesh = try nav.detour.NavMesh.init(allocator);
    defer navmesh.deinit();

    try navmesh.addTile(nav_data, .{});

    std.debug.print("\n✅ NavMesh initialized for pathfinding!\n", .{});

    // 15. Создаем query для pathfinding
    var query = try nav.detour.NavMeshQuery.init(allocator, &navmesh, 2048);
    defer query.deinit();

    // 16. Ищем путь от (-5, 0, -5) до (5, 0, 5)
    const start_pos = [3]f32{ -5.0, 0.0, -5.0 };
    const end_pos = [3]f32{ 5.0, 0.0, 5.0 };
    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    var start_ref: nav.detour.PolyRef = 0;
    var end_ref: nav.detour.PolyRef = 0;
    var start_nearest = [3]f32{ 0, 0, 0 };
    var end_nearest = [3]f32{ 0, 0, 0 };

    _ = try query.findNearestPoly(&start_pos, &extents, &query.filter, &start_ref, &start_nearest);
    _ = try query.findNearestPoly(&end_pos, &extents, &query.filter, &end_ref, &end_nearest);

    var path = try allocator.alloc(nav.detour.PolyRef, 256);
    defer allocator.free(path);

    const path_count = try query.findPath(
        start_ref,
        end_ref,
        &start_pos,
        &end_pos,
        &query.filter,
        path,
    );

    std.debug.print("   - Path found: {} polygons\n", .{path_count});
```

---

## Проверка памяти

Убедитесь что нет утечек памяти:

```bash
zig build -Doptimize=Debug
./zig-out/bin/my-navmesh
```

В конце должно быть:
```
(нет сообщений об утечках)
```

---

## Что дальше?

🎉 **Поздравляем!** Вы создали свой первый NavMesh.

Следующие шаги:

1. 📖 **[Creating NavMesh Guide](../04-guides/creating-navmesh.md)** - более детальное руководство
2. 🔍 **[Pathfinding Guide](../04-guides/pathfinding.md)** - поиск пути и queries
3. 👥 **[Crowd Simulation](../04-guides/crowd-simulation.md)** - multi-agent simulation
4. 🏗️ **[Architecture Overview](../02-architecture/overview.md)** - понимание pipeline

---

## Troubleshooting

### Ошибка: "unable to resolve dependency"

Проверьте `build.zig.zon` - путь к zig-recast должен быть корректным.

### Ошибка: "poly_count = 0"

Проверьте что:
- Triangle vertices правильно упорядочены (counter-clockwise)
- Areas правильно инициализированы через `markWalkableTriangles`

### Утечки памяти

Убедитесь что все структуры вызывают `deinit()`:
```zig
defer heightfield.deinit(allocator);
defer compact.deinit(allocator);
defer contour_set.deinit(allocator);
// и т.д.
```

---

**Помощь:** [GitHub Issues](https://github.com/your-org/zig-recast/issues)
