const std = @import("std");
const recast = @import("recast-nav");

// Simple compressor that does no compression (for demonstration)
const NoopCompressor = struct {
    pub fn maxCompressedSize(self: *const NoopCompressor, buffer_size: i32) i32 {
        _ = self;
        return buffer_size;
    }

    pub fn compress(
        self: *const NoopCompressor,
        buffer: []const u8,
        compressed: []u8,
        compressed_size: *i32,
    ) recast.Status {
        _ = self;
        if (compressed.len < buffer.len) {
            return .{ .failure = true, .buffer_too_small = true };
        }
        @memcpy(compressed[0..buffer.len], buffer);
        compressed_size.* = @intCast(buffer.len);
        return .{ .success = true };
    }

    pub fn decompress(
        self: *const NoopCompressor,
        compressed: []const u8,
        buffer: []u8,
        max_buffer_size: i32,
        buffer_size: *i32,
    ) recast.Status {
        _ = self;
        if (max_buffer_size < compressed.len) {
            return .{ .failure = true, .buffer_too_small = true };
        }
        @memcpy(buffer[0..compressed.len], compressed);
        buffer_size.* = @intCast(compressed.len);
        return .{ .success = true };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧱 DetourTileCache - Dynamic Obstacles Demo\n", .{});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    // Setup tile cache parameters
    var tc_params = std.mem.zeroes(recast.TileCacheParams);
    tc_params.orig = [3]f32{ -50.0, 0.0, -50.0 };
    tc_params.cs = 0.3; // Cell size
    tc_params.ch = 0.2; // Cell height
    tc_params.width = 64; // Tile width in cells
    tc_params.height = 64; // Tile height in cells
    tc_params.walkable_height = 2.0; // Agent height
    tc_params.walkable_radius = 0.6; // Agent radius
    tc_params.walkable_climb = 0.9; // Max climb height
    tc_params.max_simplification_error = 1.3;
    tc_params.max_tiles = 128;
    tc_params.max_obstacles = 128;

    std.debug.print("📦 TileCache Configuration:\n", .{});
    std.debug.print("   Origin: ({d:.1}, {d:.1}, {d:.1})\n", .{
        tc_params.orig[0],
        tc_params.orig[1],
        tc_params.orig[2],
    });
    std.debug.print("   Cell size: {d:.2}x{d:.2}\n", .{ tc_params.cs, tc_params.ch });
    std.debug.print("   Tile dimensions: {d}x{d} cells\n", .{ tc_params.width, tc_params.height });
    std.debug.print("   Max tiles: {d}\n", .{tc_params.max_tiles});
    std.debug.print("   Max obstacles: {d}\n\n", .{tc_params.max_obstacles});

    // Create NavMesh
    std.debug.print("🗺️  Creating NavMesh...\n", .{});
    const tile_width = @as(f32, @floatFromInt(tc_params.width)) * tc_params.cs;
    const tile_height = @as(f32, @floatFromInt(tc_params.height)) * tc_params.cs;

    var nav_params = recast.NavMeshParams.init();
    nav_params.orig = recast.Vec3.init(tc_params.orig[0], tc_params.orig[1], tc_params.orig[2]);
    nav_params.tile_width = tile_width;
    nav_params.tile_height = tile_height;
    nav_params.max_tiles = tc_params.max_tiles;
    nav_params.max_polys = 4096;

    var navmesh = try recast.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();
    std.debug.print("   ✅ NavMesh created\n\n", .{});

    // Create TileCache
    std.debug.print("💾 Creating TileCache...\n", .{});
    var compressor = NoopCompressor{};
    var compressor_vtable = recast.TileCacheCompressor{
        .ptr = @ptrCast(&compressor),
        .vtable = &.{
            .maxCompressedSize = @ptrCast(&NoopCompressor.maxCompressedSize),
            .compress = @ptrCast(&NoopCompressor.compress),
            .decompress = @ptrCast(&NoopCompressor.decompress),
        },
    };

    var tilecache = try recast.TileCache.init(
        allocator,
        &tc_params,
        &compressor_vtable,
        null, // mesh_process
    );
    defer tilecache.deinit();
    std.debug.print("   ✅ TileCache created\n\n", .{});

    // Note: In a real application, you would:
    // 1. Build TileCacheLayer for each tile from input geometry
    // 2. Compress and add tiles to TileCache
    // 3. Build initial NavMesh tiles
    //
    // For this demo, we'll show the obstacle management workflow

    std.debug.print("🎯 Dynamic Obstacle Management Demo\n", .{});
    std.debug.print("-" ** 60 ++ "\n\n", .{});

    // Demonstrate adding a cylindrical obstacle
    std.debug.print("➕ Adding cylindrical obstacle (column)...\n", .{});
    const cylinder_pos = [3]f32{ 0.0, 0.0, 0.0 };
    const cylinder_radius: f32 = 2.0;
    const cylinder_height: f32 = 4.0;

    const obstacle_ref = tilecache.addObstacle(
        &cylinder_pos,
        cylinder_radius,
        cylinder_height,
    ) catch 0;
    const status_add: recast.Status = if (obstacle_ref != 0) .{ .success = true } else .{ .failure = true };

    if (status_add.isSuccess()) {
        std.debug.print("   ✅ Cylindrical obstacle added (ref: {d})\n", .{obstacle_ref});
        std.debug.print("      Position: ({d:.1}, {d:.1}, {d:.1})\n", .{
            cylinder_pos[0],
            cylinder_pos[1],
            cylinder_pos[2],
        });
        std.debug.print("      Radius: {d:.1}, Height: {d:.1}\n\n", .{
            cylinder_radius,
            cylinder_height,
        });
    } else {
        std.debug.print("   ❌ Failed to add obstacle\n\n", .{});
    }

    // Demonstrate adding a box obstacle
    std.debug.print("➕ Adding box obstacle (wall)...\n", .{});
    const box_bmin = [3]f32{ 5.0, 0.0, -2.0 };
    const box_bmax = [3]f32{ 6.0, 3.0, 2.0 };

    const box_ref = tilecache.addBoxObstacle(&box_bmin, &box_bmax) catch 0;
    const status_box: recast.Status = if (box_ref != 0) .{ .success = true } else .{ .failure = true };

    if (status_box.isSuccess()) {
        std.debug.print("   ✅ Box obstacle added (ref: {d})\n", .{box_ref});
        std.debug.print("      Min: ({d:.1}, {d:.1}, {d:.1})\n", .{
            box_bmin[0],
            box_bmin[1],
            box_bmin[2],
        });
        std.debug.print("      Max: ({d:.1}, {d:.1}, {d:.1})\n\n", .{
            box_bmax[0],
            box_bmax[1],
            box_bmax[2],
        });
    } else {
        std.debug.print("   ❌ Failed to add box obstacle\n\n", .{});
    }

    // Demonstrate adding an oriented box obstacle
    std.debug.print("➕ Adding oriented box obstacle (rotated barrier)...\n", .{});
    const obb_center = [3]f32{ -5.0, 0.0, 0.0 };
    const obb_half_extents = [3]f32{ 3.0, 2.0, 0.5 };
    const obb_rotation_y: f32 = 45.0 * std.math.pi / 180.0; // 45 degrees

    const obb_ref = tilecache.addOrientedBoxObstacle(
        &obb_center,
        &obb_half_extents,
        obb_rotation_y,
    ) catch 0;
    const status_obb: recast.Status = if (obb_ref != 0) .{ .success = true } else .{ .failure = true };

    if (status_obb.isSuccess()) {
        std.debug.print("   ✅ Oriented box obstacle added (ref: {d})\n", .{obb_ref});
        std.debug.print("      Center: ({d:.1}, {d:.1}, {d:.1})\n", .{
            obb_center[0],
            obb_center[1],
            obb_center[2],
        });
        std.debug.print("      Half extents: ({d:.1}, {d:.1}, {d:.1})\n", .{
            obb_half_extents[0],
            obb_half_extents[1],
            obb_half_extents[2],
        });
        std.debug.print("      Rotation: {d:.1}°\n\n", .{obb_rotation_y * 180.0 / std.math.pi});
    } else {
        std.debug.print("   ❌ Failed to add oriented box obstacle\n\n", .{});
    }

    // Demonstrate update process
    std.debug.print("🔄 Updating NavMesh with obstacles...\n", .{});
    std.debug.print("   (In a real application, this would rebuild affected tiles)\n\n", .{});

    // Update loop - in real application this would be called per frame
    var update_count: u32 = 0;
    const max_updates: u32 = 10;
    var up_to_date: bool = false;

    while (update_count < max_updates and !up_to_date) : (update_count += 1) {
        const dt: f32 = 1.0 / 60.0; // 60 FPS
        const status_update = try tilecache.update(dt, &navmesh, &up_to_date);

        if (status_update.isFailure()) {
            std.debug.print("   ❌ Update failed at iteration {d}\n", .{update_count});
            break;
        }

        if (up_to_date) {
            std.debug.print("   ✅ NavMesh fully updated after {d} iterations\n\n", .{update_count + 1});
            break;
        }
    }

    if (!up_to_date and update_count >= max_updates) {
        std.debug.print("   ⚠️  Reached max updates, more iterations needed\n\n", .{});
    }

    // Demonstrate removing an obstacle
    std.debug.print("➖ Removing cylindrical obstacle...\n", .{});
    tilecache.removeObstacle(obstacle_ref) catch {
        std.debug.print("   ❌ Failed to remove obstacle\n\n", .{});
        return;
    };
    const status_remove: recast.Status = .{ .success = true };

    if (status_remove.isSuccess()) {
        std.debug.print("   ✅ Obstacle removal queued (ref: {d})\n", .{obstacle_ref});
        std.debug.print("   ℹ️  Call update() to rebuild affected tiles\n\n", .{});
    } else {
        std.debug.print("   ❌ Failed to remove obstacle\n\n", .{});
    }

    // Update again to process removal
    std.debug.print("🔄 Updating NavMesh after obstacle removal...\n", .{});
    update_count = 0;
    up_to_date = false;

    while (update_count < max_updates and !up_to_date) : (update_count += 1) {
        const dt: f32 = 1.0 / 60.0;
        const status_update = try tilecache.update(dt, &navmesh, &up_to_date);

        if (status_update.isFailure()) {
            std.debug.print("   ❌ Update failed at iteration {d}\n", .{update_count});
            break;
        }

        if (up_to_date) {
            std.debug.print("   ✅ NavMesh updated after {d} iterations\n\n", .{update_count + 1});
            break;
        }
    }

    // Summary
    std.debug.print("=" ** 60 ++ "\n", .{});
    std.debug.print("✨ Dynamic Obstacles Demo completed successfully!\n\n", .{});

    std.debug.print("📚 Key Features Demonstrated:\n", .{});
    std.debug.print("   ✅ TileCache initialization with custom compressor\n", .{});
    std.debug.print("   ✅ Adding cylindrical obstacles (columns, pillars)\n", .{});
    std.debug.print("   ✅ Adding box obstacles (walls, barriers)\n", .{});
    std.debug.print("   ✅ Adding oriented box obstacles (rotated objects)\n", .{});
    std.debug.print("   ✅ Incremental NavMesh updates (one tile per frame)\n", .{});
    std.debug.print("   ✅ Removing obstacles dynamically\n", .{});
    std.debug.print("   ✅ Update state tracking (up_to_date flag)\n\n", .{});

    std.debug.print("💡 Use Cases:\n", .{});
    std.debug.print("   • Doors opening/closing in real-time\n", .{});
    std.debug.print("   • Moving platforms and elevators\n", .{});
    std.debug.print("   • Destructible environment elements\n", .{});
    std.debug.print("   • Dynamic cover system for AI\n", .{});
    std.debug.print("   • Temporary blockades and barriers\n", .{});
    std.debug.print("   • Vehicles blocking pathways\n\n", .{});

    std.debug.print("⚡ Performance Notes:\n", .{});
    std.debug.print("   • update() processes one tile per call (amortized updates)\n", .{});
    std.debug.print("   • Spread updates over multiple frames for smooth performance\n", .{});
    std.debug.print("   • Use up_to_date flag to check completion\n", .{});
    std.debug.print("   • Obstacles are queued and processed asynchronously\n", .{});
}
