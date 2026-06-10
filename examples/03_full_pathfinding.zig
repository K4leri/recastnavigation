const std = @import("std");
const recast = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎯 Full Navigation Mesh Building & Pathfinding\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // Create a build context
    var ctx = recast.Context.init(allocator);

    // ========================================================================
    // STEP 1: Define input geometry
    // ========================================================================
    ctx.log(.progress, "STEP 1: Defining input geometry", .{});

    // Create a simple L-shaped room
    const vertices = [_]f32{
        // Main room floor (20x20)
        0.0,  0.0,  0.0, // 0
        20.0, 0.0,  0.0, // 1
        20.0, 0.0,  20.0, // 2
        0.0,  0.0,  20.0, // 3

        // Extension room (10x10)
        20.0, 0.0,  0.0, // 4 (shared with main)
        30.0, 0.0,  0.0, // 5
        30.0, 0.0,  10.0, // 6
        20.0, 0.0,  10.0, // 7
    };

    const indices = [_]i32{
        // Main room (2 triangles)
        0, 1, 2,
        0, 2, 3,

        // Extension room (2 triangles)
        4, 5, 6,
        4, 6, 7,
    };

    const num_verts = vertices.len / 3;
    const num_tris = indices.len / 3;

    std.debug.print("📦 Input mesh:\n", .{});
    std.debug.print("   • Vertices: {d}\n", .{num_verts});
    std.debug.print("   • Triangles: {d}\n\n", .{num_tris});

    // ========================================================================
    // STEP 2: Calculate bounds
    // ========================================================================
    ctx.log(.progress, "STEP 2: Calculating bounds", .{});

    var bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var bmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

    var i: usize = 0;
    while (i < vertices.len) : (i += 3) {
        bmin[0] = @min(bmin[0], vertices[i + 0]);
        bmin[1] = @min(bmin[1], vertices[i + 1]);
        bmin[2] = @min(bmin[2], vertices[i + 2]);
        bmax[0] = @max(bmax[0], vertices[i + 0]);
        bmax[1] = @max(bmax[1], vertices[i + 1]);
        bmax[2] = @max(bmax[2], vertices[i + 2]);
    }

    std.debug.print("📏 Bounds:\n", .{});
    std.debug.print("   • Min: ({d:.1}, {d:.1}, {d:.1})\n", .{ bmin[0], bmin[1], bmin[2] });
    std.debug.print("   • Max: ({d:.1}, {d:.1}, {d:.1})\n\n", .{ bmax[0], bmax[1], bmax[2] });

    // ========================================================================
    // STEP 3: Configure build parameters
    // ========================================================================
    ctx.log(.progress, "STEP 3: Configuring build parameters", .{});

    const cs: f32 = 0.3; // Cell size (XZ plane)
    const ch: f32 = 0.2; // Cell height (Y axis)

    // Calculate grid size
    var width: i32 = 0;
    var height: i32 = 0;
    recast.RecastConfig.calcGridSize(
        recast.Vec3.init(bmin[0], bmin[1], bmin[2]),
        recast.Vec3.init(bmax[0], bmax[1], bmax[2]),
        cs,
        &width,
        &height,
    );

    std.debug.print("⚙️  Build configuration:\n", .{});
    std.debug.print("   • Cell size (XZ): {d:.2}\n", .{cs});
    std.debug.print("   • Cell height (Y): {d:.2}\n", .{ch});
    std.debug.print("   • Grid size: {d} x {d} cells\n", .{ width, height });
    std.debug.print("   • Walkable slope: 45.0°\n", .{});
    std.debug.print("   • Walkable height: 20 cells (4.0 units)\n", .{});
    std.debug.print("   • Walkable climb: 9 cells (1.8 units)\n", .{});
    std.debug.print("   • Walkable radius: 2 cells (0.6 units)\n\n", .{});

    // ========================================================================
    // STEP 4: Build heightfield
    // ========================================================================
    ctx.log(.progress, "STEP 4: Creating heightfield and rasterizing triangles", .{});

    var heightfield = try recast.Heightfield.init(
        allocator,
        width,
        height,
        recast.Vec3.init(bmin[0], bmin[1], bmin[2]),
        recast.Vec3.init(bmax[0], bmax[1], bmax[2]),
        cs,
        ch,
    );
    defer heightfield.deinit();

    std.debug.print("✅ Heightfield created: {d} x {d}\n", .{ width, height });

    // Rasterize triangles
    const areas = try allocator.alloc(u8, num_tris);
    defer allocator.free(areas);

    // Mark all triangles as walkable
    for (areas) |*area| {
        area.* = 1; // WALKABLE
    }

    try recast.rasterizeTriangles(
        &ctx,
        &vertices,
        &indices,
        areas,
        &heightfield,
        1, // walkableClimb
    );

    const span_count = heightfield.getSpanCount();
    std.debug.print("✅ Rasterized {d} triangles -> {d} spans\n\n", .{ num_tris, span_count });

    // ========================================================================
    // STEP 5: Filter walkable surfaces
    // ========================================================================
    ctx.log(.progress, "STEP 5: Filtering walkable surfaces", .{});

    const walkableHeight: i32 = 20; // 20 cells = 4.0 units
    const walkableClimb: i32 = 9; // 9 cells = 1.8 units

    try recast.filterLowHangingWalkableObstacles(&ctx, walkableClimb, &heightfield);
    try recast.filterLedgeSpans(&ctx, walkableHeight, walkableClimb, &heightfield);
    try recast.filterWalkableLowHeightSpans(&ctx, walkableHeight, &heightfield);

    std.debug.print("✅ Filtered walkable surfaces\n\n", .{});

    // ========================================================================
    // STEP 6: Build compact heightfield
    // ========================================================================
    ctx.log(.progress, "STEP 6: Building compact heightfield", .{});

    var chf = try recast.buildCompactHeightfield(
        &ctx,
        allocator,
        walkableHeight,
        walkableClimb,
        &heightfield,
    );
    defer chf.deinit();

    std.debug.print("✅ Compact heightfield: {d} spans\n\n", .{chf.span_count});

    // ========================================================================
    // STEP 7: Build distance field and regions
    // ========================================================================
    ctx.log(.progress, "STEP 7: Building distance field and regions", .{});

    try recast.buildDistanceField(&ctx, &chf);
    std.debug.print("✅ Distance field built (max distance: {d})\n", .{chf.max_distance});

    try recast.buildRegions(&ctx, allocator, &chf, 0, 8, 20);
    std.debug.print("✅ Regions built ({d} regions)\n\n", .{chf.max_regions});

    // ========================================================================
    // STEP 8: Build contours
    // ========================================================================
    ctx.log(.progress, "STEP 8: Building contours", .{});

    var cset = try recast.buildContours(
        &ctx,
        allocator,
        &chf,
        1.3, // maxError
        12, // maxEdgeLen
        recast.CONTOUR_TESS_WALL_EDGES,
    );
    defer cset.deinit();

    std.debug.print("✅ Contours built: {d} contours\n\n", .{cset.conts.len});

    // ========================================================================
    // STEP 9: Build polygon mesh
    // ========================================================================
    ctx.log(.progress, "STEP 9: Building polygon mesh", .{});

    var pmesh = try recast.buildPolyMesh(
        &ctx,
        allocator,
        &cset,
        6, // maxVertsPerPoly
    );
    defer pmesh.deinit();

    std.debug.print("✅ Polygon mesh built:\n", .{});
    std.debug.print("   • Vertices: {d}\n", .{pmesh.nverts});
    std.debug.print("   • Polygons: {d}\n", .{pmesh.npolys});
    std.debug.print("   • Max verts per poly: {d}\n\n", .{pmesh.nvp});

    // ========================================================================
    // STEP 10: Build detail mesh
    // ========================================================================
    ctx.log(.progress, "STEP 10: Building detail mesh", .{});

    var dmesh = try recast.buildPolyMeshDetail(
        &ctx,
        allocator,
        &pmesh,
        &chf,
        6.0, // sampleDist
        1.0, // sampleMaxError
    );
    defer dmesh.deinit();

    std.debug.print("✅ Detail mesh built:\n", .{});
    std.debug.print("   • Vertices: {d}\n", .{dmesh.nverts});
    std.debug.print("   • Triangles: {d}\n", .{dmesh.ntris});
    std.debug.print("   • Meshes: {d}\n\n", .{dmesh.nmeshes});

    // ========================================================================
    // STEP 11: Create NavMesh data
    // ========================================================================
    ctx.log(.progress, "STEP 11: Creating NavMesh data", .{});

    var create_params = recast.NavMeshCreateParams.init(allocator);
    create_params.verts = pmesh.verts;
    create_params.vert_count = pmesh.nverts;
    create_params.polys = pmesh.polys;
    create_params.poly_areas = pmesh.areas;
    create_params.poly_flags = pmesh.flags;
    create_params.poly_count = pmesh.npolys;
    create_params.nvp = pmesh.nvp;
    create_params.detail_meshes = dmesh.meshes;
    create_params.detail_verts = dmesh.verts;
    create_params.detail_verts_count = dmesh.nverts;
    create_params.detail_tris = dmesh.tris;
    create_params.detail_tri_count = dmesh.ntris;
    create_params.walkable_height = 2.0;
    create_params.walkable_radius = 0.6;
    create_params.walkable_climb = 0.9;
    create_params.bmin = pmesh.bmin;
    create_params.bmax = pmesh.bmax;
    create_params.cs = cs;
    create_params.ch = ch;
    create_params.build_bv_tree = true;

    const navmesh_data = try recast.createNavMeshData(&create_params);
    defer allocator.free(navmesh_data);

    std.debug.print("✅ NavMesh data created: {d} bytes\n\n", .{navmesh_data.len});

    // ========================================================================
    // STEP 12: Initialize NavMesh and add tile
    // ========================================================================
    ctx.log(.progress, "STEP 12: Initializing NavMesh and adding tile", .{});

    var nav_params = recast.NavMeshParams.init();
    nav_params.orig = recast.Vec3.init(bmin[0], bmin[1], bmin[2]);
    nav_params.tile_width = bmax[0] - bmin[0];
    nav_params.tile_height = bmax[2] - bmin[2];
    nav_params.max_tiles = 128;
    nav_params.max_polys = 512;

    var navmesh = try recast.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    // Add the tile
    _ = try navmesh.addTile(
        navmesh_data,
        0, // flags (0 = take ownership)
        0, // lastRef
    );

    std.debug.print("✅ NavMesh initialized and tile added\n\n", .{});

    // ========================================================================
    // STEP 13: Create query and find path
    // ========================================================================
    ctx.log(.progress, "STEP 13: Setting up pathfinding query", .{});

    var query = try recast.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&navmesh, 2048);

    std.debug.print("✅ Query initialized with 2048 max nodes\n\n", .{});

    // ========================================================================
    // STEP 14: Find path
    // ========================================================================
    std.debug.print("🎯 PATHFINDING DEMO\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    const start_pos = [3]f32{ 2.0, 0.0, 2.0 };
    const end_pos = [3]f32{ 28.0, 0.0, 8.0 };
    const extent = [3]f32{ 2.0, 4.0, 2.0 };

    std.debug.print("📍 Start: ({d:.1}, {d:.1}, {d:.1})\n", .{ start_pos[0], start_pos[1], start_pos[2] });
    std.debug.print("📍 End:   ({d:.1}, {d:.1}, {d:.1})\n", .{ end_pos[0], end_pos[1], end_pos[2] });
    std.debug.print("📏 Search extent: ({d:.1}, {d:.1}, {d:.1})\n\n", .{ extent[0], extent[1], extent[2] });

    // Find start polygon
    var start_ref: recast.PolyRef = 0;
    var start_nearest = [3]f32{ 0, 0, 0 };

    const filter = recast.QueryFilter.init();

    start_ref = try query.findNearestPoly(&start_pos, &extent, &filter, &start_nearest);

    if (start_ref != 0) {
        std.debug.print("✅ Start polygon found (ref: {d})\n", .{start_ref});
        std.debug.print("   Nearest point: ({d:.2}, {d:.2}, {d:.2})\n", .{
            start_nearest[0],
            start_nearest[1],
            start_nearest[2],
        });
    } else {
        std.debug.print("❌ Start polygon not found!\n", .{});
        return;
    }

    // Find end polygon
    var end_ref: recast.PolyRef = 0;
    var end_nearest = [3]f32{ 0, 0, 0 };

    end_ref = try query.findNearestPoly(&end_pos, &extent, &filter, &end_nearest);

    if (end_ref != 0) {
        std.debug.print("✅ End polygon found (ref: {d})\n", .{end_ref});
        std.debug.print("   Nearest point: ({d:.2}, {d:.2}, {d:.2})\n\n", .{
            end_nearest[0],
            end_nearest[1],
            end_nearest[2],
        });
    } else {
        std.debug.print("❌ End polygon not found!\n", .{});
        return;
    }

    // Find path
    var path = try allocator.alloc(recast.PolyRef, 256);
    defer allocator.free(path);

    const path_count = try query.findPath(
        start_ref,
        end_ref,
        &start_nearest,
        &end_nearest,
        &filter,
        path,
    );

    if (path_count > 0) {
        std.debug.print("✅ Path found! ({d} polygons)\n", .{path_count});

        // Find straight path
        var straight_path = try allocator.alloc([3]f32, 256);
        defer allocator.free(straight_path);

        const straight_count = try query.findStraightPath(
            &start_nearest,
            &end_nearest,
            path[0..path_count],
            straight_path,
            null,
            null,
            256,
            0,
        );

        if (straight_count > 0) {
            std.debug.print("✅ Straight path computed ({d} waypoints):\n", .{straight_count});
            for (straight_path[0..straight_count], 0..) |point, idx| {
                std.debug.print("   {d}. ({d:.2}, {d:.2}, {d:.2})\n", .{
                    idx + 1,
                    point[0],
                    point[1],
                    point[2],
                });
            }
        }
    } else {
        std.debug.print("❌ No path found!\n", .{});
    }

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("✨ Full pathfinding example completed successfully!\n", .{});
    std.debug.print("\n📚 Complete pipeline demonstrated:\n", .{});
    std.debug.print("   ✅ Heightfield rasterization\n", .{});
    std.debug.print("   ✅ Walkable surface filtering\n", .{});
    std.debug.print("   ✅ Compact heightfield\n", .{});
    std.debug.print("   ✅ Distance field & regions\n", .{});
    std.debug.print("   ✅ Contour building\n", .{});
    std.debug.print("   ✅ Polygon mesh\n", .{});
    std.debug.print("   ✅ Detail mesh\n", .{});
    std.debug.print("   ✅ NavMesh data creation\n", .{});
    std.debug.print("   ✅ Pathfinding (A* + string pulling)\n", .{});
}
