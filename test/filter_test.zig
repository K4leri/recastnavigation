const std = @import("std");
const recast = @import("recast-nav");
const filter = recast.recast.filter;
const Heightfield = recast.Heightfield;
const Context = recast.Context;
const Vec3 = recast.Vec3;

test "markWalkableTriangles - flat triangle" {
    const allocator = std.testing.allocator;

    // Counter-clockwise winding when viewed from above (Y-up)
    const verts = [_]f32{
        0, 0, 0,
        1, 0, 0,
        0, 0, -1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{0};

    const ctx = Context.init(allocator);
    filter.markWalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Flat triangle with correct winding should be walkable
    try std.testing.expectEqual(@as(u8, 1), areas[0]);
}

test "markWalkableTriangles - steep slope" {
    const allocator = std.testing.allocator;

    // Steep triangle (almost vertical)
    const verts = [_]f32{
        0, 0,  0,
        1, 10, 0,
        0, 0,  1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{0};

    const ctx = Context.init(allocator);
    filter.markWalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Steep triangle should not be marked walkable
    try std.testing.expectEqual(@as(u8, 0), areas[0]);
}

test "clearUnwalkableTriangles - steep slope" {
    const allocator = std.testing.allocator;

    // Steep triangle (almost vertical)
    const verts = [_]f32{
        0, 0,  0,
        1, 10, 0,
        0, 0,  1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{1}; // Start as walkable

    const ctx = Context.init(allocator);
    filter.clearUnwalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Steep triangle should be cleared
    try std.testing.expectEqual(@as(u8, 0), areas[0]);
}

test "clearUnwalkableTriangles - flat triangle unchanged" {
    const allocator = std.testing.allocator;

    // Counter-clockwise winding
    const verts = [_]f32{
        0, 0, 0,
        1, 0, 0,
        0, 0, -1,
    };

    const tris = [_]i32{ 0, 1, 2 };
    var areas = [_]u8{1};

    const ctx = Context.init(allocator);
    filter.clearUnwalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Flat triangle should remain walkable
    try std.testing.expectEqual(@as(u8, 1), areas[0]);
}

test "filterWalkableLowHeightSpans - removes low ceiling spans" {
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

    // Manually create a span with low clearance
    const x: i32 = 5;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 32));

    // Create first span (floor)
    const span1 = try hf.span_pool.allocator.create(recast.Span);
    span1.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    // Create second span (ceiling) - only 3 units above floor
    const span2 = try hf.span_pool.allocator.create(recast.Span);
    span2.* = .{
        .smin = 13, // Only 3 units clearance (13 - 10)
        .smax = 20,
        .area = 0,
        .next = null,
    };

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterWalkableLowHeightSpans(&ctx, 5, &hf); // Require 5 units clearance

    // Span should be marked as non-walkable due to low ceiling
    try std.testing.expectEqual(@as(u8, 0), span1.area);
}

test "filterWalkableLowHeightSpans - keeps sufficient height spans" {
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

    const x: i32 = 5;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 32));

    // Create first span (floor)
    const span1 = try hf.span_pool.allocator.create(recast.Span);
    span1.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    // Create second span (ceiling) - 10 units above floor
    const span2 = try hf.span_pool.allocator.create(recast.Span);
    span2.* = .{
        .smin = 20, // 10 units clearance (20 - 10)
        .smax = 30,
        .area = 0,
        .next = null,
    };

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterWalkableLowHeightSpans(&ctx, 5, &hf); // Require 5 units clearance

    // Span should remain walkable
    try std.testing.expectEqual(@as(u8, 1), span1.area);
}

test "filterLowHangingWalkableObstacles - marks low obstacles as walkable" {
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

    const x: i32 = 5;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 32));

    // Create walkable span
    const span1 = try hf.span_pool.allocator.create(recast.Span);
    span1.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    // Create non-walkable obstacle span just above
    const span2 = try hf.span_pool.allocator.create(recast.Span);
    span2.* = .{
        .smin = 10,
        .smax = 11, // Only 1 unit high
        .area = 0, // Not walkable
        .next = null,
    };

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterLowHangingWalkableObstacles(&ctx, 2, &hf); // Can climb 2 units

    // Small obstacle should be marked as walkable
    try std.testing.expectEqual(@as(u8, 1), span2.area);
}

test "filterLowHangingWalkableObstacles - ignores tall obstacles" {
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

    const x: i32 = 5;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 32));

    // Create walkable span
    const span1 = try hf.span_pool.allocator.create(recast.Span);
    span1.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    // Create tall obstacle span
    const span2 = try hf.span_pool.allocator.create(recast.Span);
    span2.* = .{
        .smin = 10,
        .smax = 15, // 5 units tall
        .area = 0, // Not walkable
        .next = null,
    };

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterLowHangingWalkableObstacles(&ctx, 2, &hf); // Can only climb 2 units

    // Tall obstacle should remain non-walkable
    try std.testing.expectEqual(@as(u8, 0), span2.area);
}

test "filterLedgeSpans - marks edge ledges as unwalkable" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        10,
        10,
        Vec3.init(0, 0, 0),
        Vec3.init(10, 10, 10),
        1.0,
        0.5,
    );
    defer hf.deinit();

    // Create a walkable span at the edge (x=0, z=5)
    const x: i32 = 0;
    const z: i32 = 5;
    const col_idx = @as(usize, @intCast(x + z * 10));

    const span = try hf.span_pool.allocator.create(recast.Span);
    span.* = .{
        .smin = 0,
        .smax = 10,
        .area = 1, // Walkable
        .next = null,
    };

    hf.spans[col_idx] = span;

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, 5, 2, &hf);

    // Edge span should be marked as ledge (unwalkable)
    try std.testing.expectEqual(@as(u8, 0), span.area);
}

test "filterLedgeSpans - keeps interior spans walkable" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        10,
        10,
        Vec3.init(0, 0, 0),
        Vec3.init(10, 10, 10),
        1.0,
        0.5,
    );
    defer hf.deinit();

    const walkable_height: i32 = 5;
    const walkable_climb: i32 = 2;

    // Create a grid of walkable spans in the middle
    var z: i32 = 2;
    while (z <= 7) : (z += 1) {
        var x: i32 = 2;
        while (x <= 7) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * 10));
            const span = try hf.span_pool.allocator.create(recast.Span);
            span.* = .{
                .smin = 0,
                .smax = 10,
                .area = 1, // Walkable
                .next = null,
            };
            hf.spans[col_idx] = span;
        }
    }

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);

    // Center span should remain walkable (has neighbors on all sides)
    const center_idx = @as(usize, @intCast(5 + 5 * 10));
    const center_span = hf.spans[center_idx];
    try std.testing.expect(center_span != null);
    try std.testing.expectEqual(@as(u8, 1), center_span.?.area);
}
