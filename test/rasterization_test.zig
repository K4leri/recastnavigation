const std = @import("std");
const recast = @import("recast-nav");
const rasterization = recast.recast.rasterization;
const Heightfield = recast.Heightfield;
const Context = recast.Context;
const Vec3 = recast.Vec3;

test "rasterizeTriangle - single triangle" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        64,
        64,
        Vec3.init(0, 0, 0),
        Vec3.init(64, 10, 64),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    const v0 = Vec3.init(10, 0, 10);
    const v1 = Vec3.init(20, 2, 10);
    const v2 = Vec3.init(10, 0, 20);

    try rasterization.rasterizeTriangle(&ctx, v0, v1, v2, 1, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterizeTriangle - degenerate triangle" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        32,
        32,
        Vec3.init(0, 0, 0),
        Vec3.init(32, 10, 32),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Degenerate triangle (all points on same line)
    const v0 = Vec3.init(5, 0, 5);
    const v1 = Vec3.init(10, 0, 10);
    const v2 = Vec3.init(15, 0, 15);

    try rasterization.rasterizeTriangle(&ctx, v0, v1, v2, 1, &hf, 1);

    // Should not crash, may or may not create spans
}

test "rasterizeTriangle - outside bounds" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        32,
        32,
        Vec3.init(0, 0, 0),
        Vec3.init(32, 10, 32),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Triangle completely outside heightfield
    const v0 = Vec3.init(100, 0, 100);
    const v1 = Vec3.init(110, 2, 100);
    const v2 = Vec3.init(100, 0, 110);

    try rasterization.rasterizeTriangle(&ctx, v0, v1, v2, 1, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expectEqual(@as(usize, 0), span_count);
}

test "rasterizeTriangles - multiple triangles" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        64,
        64,
        Vec3.init(0, 0, 0),
        Vec3.init(64, 10, 64),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Vertices
    const verts = [_]f32{
        0,  0, 0,
        10, 0, 0,
        10, 0, 10,
        0,  0, 10,
    };

    // Two triangles forming a quad
    const tris = [_]i32{
        0, 1, 2,
        0, 2, 3,
    };

    const areas = [_]u8{ 1, 1 };

    try rasterization.rasterizeTriangles(&ctx, &verts, &tris, &areas, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterizeTrianglesU16 - with u16 indices" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        64,
        64,
        Vec3.init(0, 0, 0),
        Vec3.init(64, 10, 64),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    const verts = [_]f32{
        0,  0, 0,
        10, 0, 0,
        10, 0, 10,
        0,  0, 10,
    };

    const tris = [_]u16{
        0, 1, 2,
        0, 2, 3,
    };

    const areas = [_]u8{ 1, 1 };

    try rasterization.rasterizeTrianglesU16(&ctx, &verts, &tris, &areas, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterizeTrianglesFlat - flat vertex array" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        64,
        64,
        Vec3.init(0, 0, 0),
        Vec3.init(64, 10, 64),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Two triangles in flat array
    const verts = [_]f32{
        // Triangle 1
        0,  0, 0,
        10, 0, 0,
        10, 0, 10,
        // Triangle 2
        0,  0, 0,
        10, 0, 10,
        0,  0, 10,
    };

    const areas = [_]u8{ 1, 1 };

    try rasterization.rasterizeTrianglesFlat(&ctx, &verts, &areas, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterization - area merging" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        32,
        32,
        Vec3.init(0, 0, 0),
        Vec3.init(32, 10, 32),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Two overlapping triangles with different area IDs
    const v0 = Vec3.init(5, 0, 5);
    const v1 = Vec3.init(15, 1, 5);
    const v2 = Vec3.init(5, 0, 15);

    try rasterization.rasterizeTriangle(&ctx, v0, v1, v2, 1, &hf, 1);

    // Slightly higher triangle with different area
    const v3 = Vec3.init(5, 1, 5);
    const v4 = Vec3.init(15, 2, 5);
    const v5 = Vec3.init(5, 1, 15);

    try rasterization.rasterizeTriangle(&ctx, v3, v4, v5, 2, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}

test "rasterization - large mesh performance" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        256,
        256,
        Vec3.init(0, 0, 0),
        Vec3.init(256, 20, 256),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const ctx = Context.init(allocator);

    // Generate a grid of triangles
    var verts = std.array_list.Managed(f32).init(allocator);
    defer verts.deinit();

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    var areas = std.array_list.Managed(u8).init(allocator);
    defer areas.deinit();

    // Create 10x10 grid
    const grid_size = 10;
    const cell_size = 20.0;

    // Generate vertices
    var z: usize = 0;
    while (z <= grid_size) : (z += 1) {
        var x: usize = 0;
        while (x <= grid_size) : (x += 1) {
            try verts.append(@as(f32, @floatFromInt(x)) * cell_size);
            try verts.append(0);
            try verts.append(@as(f32, @floatFromInt(z)) * cell_size);
        }
    }

    // Generate triangles
    z = 0;
    while (z < grid_size) : (z += 1) {
        var x: usize = 0;
        while (x < grid_size) : (x += 1) {
            const idx = @as(i32, @intCast(z * (grid_size + 1) + x));

            // First triangle
            try tris.append(idx);
            try tris.append(idx + @as(i32, @intCast(grid_size)) + 1);
            try tris.append(idx + @as(i32, @intCast(grid_size)) + 2);
            try areas.append(1);

            // Second triangle
            try tris.append(idx);
            try tris.append(idx + @as(i32, @intCast(grid_size)) + 2);
            try tris.append(idx + 1);
            try areas.append(1);
        }
    }

    try rasterization.rasterizeTriangles(&ctx, verts.items, tris.items, areas.items, &hf, 1);

    const span_count = hf.getSpanCount();
    try std.testing.expect(span_count > 0);
}
