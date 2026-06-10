const std = @import("std");
const recast_nav = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Recast Navigation Zig v{s}\n", .{recast_nav.version()});
    std.debug.print("=====================================\n\n", .{});

    // Create a build context
    var ctx = recast_nav.Context.init(allocator);
    ctx.log(.progress, "Initializing navigation mesh builder", .{});

    // Configure navmesh build parameters
    var config = recast_nav.RecastConfig{
        .width = 0,
        .height = 0,
        .tile_size = 0,
        .border_size = 0,
        .cs = 0.3, // Cell size (xz)
        .ch = 0.2, // Cell height (y)
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

    // Example vertices for a simple triangle mesh
    const vertices = [_]recast_nav.Vec3{
        recast_nav.Vec3.init(0, 0, 0),
        recast_nav.Vec3.init(10, 0, 0),
        recast_nav.Vec3.init(10, 0, 10),
        recast_nav.Vec3.init(0, 0, 10),
    };

    // Calculate bounds
    var bmin = recast_nav.Vec3.zero();
    var bmax = recast_nav.Vec3.zero();
    recast_nav.RecastConfig.calcBounds(&vertices, &bmin, &bmax);

    ctx.log(.progress, "Bounds: min({d:.2}, {d:.2}, {d:.2}) max({d:.2}, {d:.2}, {d:.2})", .{
        bmin.x, bmin.y, bmin.z,
        bmax.x, bmax.y, bmax.z,
    });

    config.bmin = bmin;
    config.bmax = bmax;

    // Calculate grid size
    var size_x: i32 = 0;
    var size_z: i32 = 0;
    recast_nav.RecastConfig.calcGridSize(bmin, bmax, config.cs, &size_x, &size_z);
    config.width = size_x;
    config.height = size_z;

    ctx.log(.progress, "Grid size: {d}x{d} cells", .{ size_x, size_z });

    // Create heightfield
    ctx.log(.progress, "Creating heightfield...", .{});
    var heightfield = try recast_nav.Heightfield.init(
        allocator,
        config.width,
        config.height,
        config.bmin,
        config.bmax,
        config.cs,
        config.ch,
    );
    defer heightfield.deinit();

    ctx.log(.progress, "Heightfield created: {d}x{d}", .{ heightfield.width, heightfield.height });

    // Create navigation mesh parameters
    var nav_params = recast_nav.NavMeshParams.init();
    nav_params.orig = recast_nav.Vec3.init(0, 0, 0);
    nav_params.tile_width = 32.0;
    nav_params.tile_height = 32.0;
    nav_params.max_tiles = 256;
    nav_params.max_polys = 8192;

    ctx.log(.progress, "Creating navigation mesh...", .{});
    var navmesh = try recast_nav.NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    ctx.log(.progress, "Navigation mesh created with {d} tiles", .{navmesh.max_tiles});

    std.debug.print("\n=====================================\n", .{});
    std.debug.print("Simple navmesh example completed!\n", .{});
}
