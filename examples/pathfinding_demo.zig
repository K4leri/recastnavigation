const std = @import("std");
const recast = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🎯 Recast Navigation Pathfinding Demo\n", .{});
    std.debug.print("=" ** 50 ++ "\n\n", .{});

    // Create a simple rectangular room: 20x20 units
    const vertices = [_]f32{
        // Floor vertices (y=0)
        -10.0, 0.0, -10.0, // 0
        10.0,  0.0, -10.0, // 1
        10.0,  0.0, 10.0, // 2
        -10.0, 0.0, 10.0, // 3
    };

    const indices = [_]i32{
        0, 1, 2, // Triangle 1
        0, 2, 3, // Triangle 2
    };

    std.debug.print("📦 Input mesh: {d} vertices, {d} triangles\n", .{ vertices.len / 3, indices.len / 3 });

    // Calculate bounds
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

    std.debug.print("📏 Bounds: ({d:.1}, {d:.1}, {d:.1}) to ({d:.1}, {d:.1}, {d:.1})\n\n", .{
        bmin[0], bmin[1], bmin[2],
        bmax[0], bmax[1], bmax[2],
    });

    // Create navmesh parameters
    var nav_params = recast.NavMeshParams.init();
    nav_params.orig = recast.Vec3.init(bmin[0], bmin[1], bmin[2]);
    nav_params.tile_width = bmax[0] - bmin[0];
    nav_params.tile_height = bmax[2] - bmin[2];
    nav_params.max_tiles = 128; // Must be > 4 for lookup table
    nav_params.max_polys = 256;

    std.debug.print("🗺️  Creating navigation mesh...\n", .{});
    var navmesh = try recast.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    std.debug.print("✅ NavMesh created with {d} max tiles, {d} max polys per tile\n\n", .{
        navmesh.max_tiles,
        nav_params.max_polys,
    });

    // Create a query object
    std.debug.print("🔍 Creating navmesh query...\n", .{});
    var query = try recast.NavMeshQuery.init(allocator);
    defer query.deinit();

    try query.initQuery(&navmesh, 2048);
    std.debug.print("✅ Query initialized with 2048 max nodes\n\n", .{});

    // Demo: Find path between two points
    std.debug.print("🎯 Pathfinding Demo\n", .{});
    std.debug.print("-" ** 30 ++ "\n", .{});

    const start_pos = [3]f32{ -8.0, 0.0, -8.0 };
    const end_pos = [3]f32{ 8.0, 0.0, 8.0 };

    std.debug.print("📍 Start: ({d:.1}, {d:.1}, {d:.1})\n", .{ start_pos[0], start_pos[1], start_pos[2] });
    std.debug.print("📍 End:   ({d:.1}, {d:.1}, {d:.1})\n\n", .{ end_pos[0], end_pos[1], end_pos[2] });

    // Note: In a real scenario, you would:
    // 1. Build the heightfield from the input mesh
    // 2. Build compact heightfield
    // 3. Build regions, contours, and polygon mesh
    // 4. Build detail mesh
    // 5. Create navmesh data and add tiles
    // 6. Then perform queries

    std.debug.print("ℹ️  Note: This is a minimal demo. To perform actual pathfinding:\n", .{});
    std.debug.print("   1. Rasterize input triangles to heightfield\n", .{});
    std.debug.print("   2. Filter walkable surfaces\n", .{});
    std.debug.print("   3. Build compact heightfield\n", .{});
    std.debug.print("   4. Build regions and contours\n", .{});
    std.debug.print("   5. Build polygon mesh\n", .{});
    std.debug.print("   6. Build detail mesh\n", .{});
    std.debug.print("   7. Create navmesh data and add to NavMesh\n", .{});
    std.debug.print("   8. Perform queries (findPath, raycast, etc.)\n\n", .{});

    std.debug.print("=" ** 50 ++ "\n", .{});
    std.debug.print("✨ Demo completed successfully!\n", .{});
    std.debug.print("\n📚 Available query functions:\n", .{});
    std.debug.print("   • findPath() - A* pathfinding\n", .{});
    std.debug.print("   • findStraightPath() - String pulling\n", .{});
    std.debug.print("   • raycast() - Line of sight checks\n", .{});
    std.debug.print("   • findNearestPoly() - Find closest polygon\n", .{});
    std.debug.print("   • moveAlongSurface() - Constrained movement\n", .{});
    std.debug.print("   • findDistanceToWall() - Wall detection\n", .{});
    std.debug.print("   • findPolysAroundCircle() - Area queries\n", .{});
    std.debug.print("   • getPolyHeight() - Height queries\n", .{});
    std.debug.print("   • closestPointOnPoly() - Point projection\n", .{});
}
