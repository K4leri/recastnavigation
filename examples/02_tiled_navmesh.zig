const std = @import("std");
const recast = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🗺️  Tiled Navigation Mesh Example\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Create a build context
    var ctx = recast.Context.init(allocator);
    ctx.log(.progress, "Initializing tiled navigation mesh builder", .{});

    // Tiled navmesh configuration
    // Tiles allow for building large worlds by dividing into chunks
    const tile_size: f32 = 32.0; // Size of each tile in world units
    const world_size: f32 = 128.0; // Total world size (4x4 tiles)

    var nav_params = recast.NavMeshParams.init();
    nav_params.orig = recast.Vec3.init(0, 0, 0);
    nav_params.tile_width = tile_size;
    nav_params.tile_height = tile_size;
    nav_params.max_tiles = 64; // Support up to 64 tiles (8x8 grid)
    nav_params.max_polys = 1024; // Max polygons per tile

    std.debug.print("📐 Tile Configuration:\n", .{});
    std.debug.print("   • Tile size: {d:.1} x {d:.1} units\n", .{ tile_size, tile_size });
    std.debug.print("   • World size: {d:.1} x {d:.1} units\n", .{ world_size, world_size });
    std.debug.print("   • Max tiles: {d}\n", .{nav_params.max_tiles});
    std.debug.print("   • Max polys per tile: {d}\n\n", .{nav_params.max_polys});

    // Create navigation mesh
    ctx.log(.progress, "Creating tiled navigation mesh...", .{});
    var navmesh = try recast.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    std.debug.print("✅ Tiled NavMesh created\n", .{});
    std.debug.print("   • Max tiles: {d}\n", .{navmesh.max_tiles});
    std.debug.print("   • Tile width: {d:.1}\n", .{navmesh.params.tile_width});
    std.debug.print("   • Tile height: {d:.1}\n", .{navmesh.params.tile_height});
    std.debug.print("   • Origin: ({d:.1}, {d:.1}, {d:.1})\n\n", .{
        navmesh.params.orig.x,
        navmesh.params.orig.y,
        navmesh.params.orig.z,
    });

    // Example: Calculate tile coordinates for a given position
    std.debug.print("🎯 Tile Coordinate Examples:\n", .{});
    std.debug.print("-" ** 40 ++ "\n", .{});

    const test_positions = [_][3]f32{
        [3]f32{ 16.0, 0.0, 16.0 }, // Center of tile (0, 0)
        [3]f32{ 48.0, 0.0, 16.0 }, // Center of tile (1, 0)
        [3]f32{ 16.0, 0.0, 48.0 }, // Center of tile (0, 1)
        [3]f32{ 80.0, 0.0, 80.0 }, // Center of tile (2, 2)
    };

    for (test_positions) |pos| {
        var tx: i32 = 0;
        var ty: i32 = 0;
        navmesh.calcTileLoc(&pos, &tx, &ty);

        std.debug.print("Position ({d:.1}, {d:.1}, {d:.1}) -> Tile ({d}, {d})\n", .{
            pos[0],
            pos[1],
            pos[2],
            tx,
            ty,
        });
    }

    std.debug.print("\n");

    // Demonstrate tile hash computation
    std.debug.print("🔐 Tile Hash Examples:\n", .{});
    std.debug.print("-" ** 40 ++ "\n", .{});

    const example_tiles = [_][2]i32{
        [2]i32{ 0, 0 },
        [2]i32{ 1, 0 },
        [2]i32{ 0, 1 },
        [2]i32{ 3, 3 },
    };

    for (example_tiles) |tile_coords| {
        const hash = navmesh.computeTileHash(tile_coords[0], tile_coords[1], navmesh.tile_lookup_table_mask);
        std.debug.print("Tile ({d}, {d}) -> Hash: {d}\n", .{ tile_coords[0], tile_coords[1], hash });
    }

    std.debug.print("\n");

    // Benefits of tiled navigation meshes
    std.debug.print("✨ Benefits of Tiled Navigation Meshes:\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("1. 🌍 Large Worlds: Handle huge game worlds efficiently\n", .{});
    std.debug.print("   • Only load/unload tiles as needed\n", .{});
    std.debug.print("   • Memory usage scales with visible area\n\n", .{});

    std.debug.print("2. 🔄 Dynamic Updates: Update individual tiles\n", .{});
    std.debug.print("   • Add/remove tiles without rebuilding entire mesh\n", .{});
    std.debug.print("   • Fast incremental updates for destructible environments\n\n", .{});

    std.debug.print("3. 🧵 Parallel Building: Build multiple tiles concurrently\n", .{});
    std.debug.print("   • Each tile can be built independently\n", .{});
    std.debug.print("   • Distribute work across multiple threads\n\n", .{});

    std.debug.print("4. 💾 Streaming: Stream tiles from disk as needed\n", .{});
    std.debug.print("   • Save memory for open-world games\n", .{});
    std.debug.print("   • Load tiles around player position\n\n", .{});

    // Typical tiled workflow
    std.debug.print("📋 Typical Tiled NavMesh Workflow:\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("Step 1: Divide world into tile grid\n", .{});
    std.debug.print("Step 2: For each tile:\n", .{});
    std.debug.print("  a) Rasterize geometry within tile bounds\n", .{});
    std.debug.print("  b) Build compact heightfield\n", .{});
    std.debug.print("  c) Build regions and contours\n", .{});
    std.debug.print("  d) Build polygon mesh\n", .{});
    std.debug.print("  e) Build detail mesh\n", .{});
    std.debug.print("  f) Create navmesh data\n", .{});
    std.debug.print("  g) Add tile to NavMesh using addTile()\n", .{});
    std.debug.print("Step 3: NavMesh automatically connects adjacent tiles\n", .{});
    std.debug.print("Step 4: Perform queries across tile boundaries seamlessly\n\n", .{});

    // Tile size recommendations
    std.debug.print("💡 Tile Size Recommendations:\n", .{});
    std.debug.print("-" ** 60 ++ "\n", .{});
    std.debug.print("• Small tiles (16-32 units): Fast updates, more tiles\n", .{});
    std.debug.print("• Medium tiles (32-64 units): Balanced approach\n", .{});
    std.debug.print("• Large tiles (64-128 units): Fewer tiles, slower updates\n\n", .{});
    std.debug.print("Choose based on:\n", .{});
    std.debug.print("  - How often geometry changes\n", .{});
    std.debug.print("  - Memory constraints\n", .{});
    std.debug.print("  - Build time requirements\n", .{});
    std.debug.print("  - World complexity\n\n", .{});

    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("✅ Tiled NavMesh example completed!\n", .{});
    std.debug.print("\n📖 Next steps:\n", .{});
    std.debug.print("   • See 03_full_pathfinding.zig for complete tile building\n", .{});
    std.debug.print("   • See dynamic_obstacles.zig for tile updates\n", .{});
    std.debug.print("   • Implement tile streaming for your game\n", .{});
}
