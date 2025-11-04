const std = @import("std");
const recast = @import("recast-nav");
const filter = recast.recast.filter;
const Heightfield = recast.Heightfield;
const Context = recast.Context;
const Vec3 = recast.Vec3;

const WALKABLE_AREA: u8 = 63;
const NULL_AREA: u8 = 0;

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
    try std.testing.expectEqual(WALKABLE_AREA, areas[0]);
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
    try std.testing.expectEqual(NULL_AREA, areas[0]);
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
    var areas = [_]u8{WALKABLE_AREA}; // Start as walkable

    const ctx = Context.init(allocator);
    filter.clearUnwalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Steep triangle should be cleared
    try std.testing.expectEqual(NULL_AREA, areas[0]);
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
    var areas = [_]u8{WALKABLE_AREA};

    const ctx = Context.init(allocator);
    filter.clearUnwalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);

    // Flat triangle should remain walkable
    try std.testing.expectEqual(WALKABLE_AREA, areas[0]);
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
    const span1 = try hf.allocSpan();
    span1.smin = 0;
    span1.smax = 10;
    span1.area = WALKABLE_AREA;

    // Create second span (ceiling) - only 3 units above floor
    const span2 = try hf.allocSpan();
    span2.smin = 13; // Only 3 units clearance (13 - 10)
    span2.smax = 20;
    span2.area = NULL_AREA;

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterWalkableLowHeightSpans(&ctx, 5, &hf); // Require 5 units clearance

    // Span should be marked as non-walkable due to low ceiling
    try std.testing.expectEqual(NULL_AREA, span1.area);
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
    const span1 = try hf.allocSpan();
    span1.smin = 0;
    span1.smax = 10;
    span1.area = WALKABLE_AREA;

    // Create second span (ceiling) - 10 units above floor
    const span2 = try hf.allocSpan();
    span2.smin = 20; // 10 units clearance (20 - 10)
    span2.smax = 30;
    span2.area = NULL_AREA;

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterWalkableLowHeightSpans(&ctx, 5, &hf); // Require 5 units clearance

    // Span should remain walkable
    try std.testing.expectEqual(WALKABLE_AREA, span1.area);
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
    const span1 = try hf.allocSpan();
    span1.smin = 0;
    span1.smax = 10;
    span1.area = WALKABLE_AREA;

    // Create non-walkable obstacle span just above
    const span2 = try hf.allocSpan();
    span2.smin = 10;
    span2.smax = 11; // Only 1 unit high
    span2.area = NULL_AREA;

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterLowHangingWalkableObstacles(&ctx, 2, &hf); // Can climb 2 units

    // Small obstacle should be marked as walkable
    try std.testing.expectEqual(WALKABLE_AREA, span2.area);
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
    const span1 = try hf.allocSpan();
    span1.smin = 0;
    span1.smax = 10;
    span1.area = WALKABLE_AREA;

    // Create tall obstacle span
    const span2 = try hf.allocSpan();
    span2.smin = 10;
    span2.smax = 15; // 5 units tall
    span2.area = NULL_AREA;

    span1.next = span2;
    hf.spans[col_idx] = span1;

    const ctx = Context.init(allocator);
    filter.filterLowHangingWalkableObstacles(&ctx, 2, &hf); // Can only climb 2 units

    // Tall obstacle should remain non-walkable
    try std.testing.expectEqual(NULL_AREA, span2.area);
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

    const span = try hf.allocSpan();
    span.smin = 0;
    span.smax = 10;
    span.area = WALKABLE_AREA;

    hf.spans[col_idx] = span;

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, 5, 2, &hf);

    // Edge span should be marked as ledge (unwalkable)
    try std.testing.expectEqual(NULL_AREA, span.area);
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
            const span = try hf.allocSpan();
            span.smin = 0;
            span.smax = 10;
            span.area = WALKABLE_AREA;
            hf.spans[col_idx] = span;
        }
    }

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);

    // Center span should remain walkable (has neighbors on all sides)
    const center_idx = @as(usize, @intCast(5 + 5 * 10));
    const center_span = hf.spans[center_idx];
    try std.testing.expect(center_span != null);
    try std.testing.expectEqual(WALKABLE_AREA, center_span.?.area);
}

// Regression test for GitHub issue #772
// https://github.com/recastnavigation/recastnavigation/issues/729
// https://github.com/recastnavigation/recastnavigation/pull/772
test "filterLedgeSpans - boundary case: gap equals walkableHeight" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        5,
        5,
        Vec3.init(0, 0, 0),
        Vec3.init(5, 20, 5),
        1.0,
        1.0,
    );
    defer hf.deinit();

    const walkable_height: i32 = 10;
    const walkable_climb: i32 = 2;

    // Create test scenario from PR #772
    // Grid layout (smin values):
    //  0   0   0   0   0
    //  0   0  11   0   0
    //  0   6   0  10   0
    //  0   0  11   0   0
    //  0   0   0   0   0

    const smin_values = [_]u16{
        0,  0,  0,  0,  0,
        0,  0, 11,  0,  0,
        0,  6,  0, 10,  0,
        0,  0, 11,  0,  0,
        0,  0,  0,  0,  0,
    };

    const smax_values = [_]u16{
        1,  1,  1,  1,  1,
        1,  1, 12,  1,  1,
        1,  7,  1, 11,  1,
        1,  1, 12,  1,  1,
        1,  1,  1,  1,  1,
    };

    // Create spans
    var idx: usize = 0;
    while (idx < 25) : (idx += 1) {
        const span = try hf.allocSpan();
        span.smin = smin_values[idx];
        span.smax = smax_values[idx];
        span.area = WALKABLE_AREA;
        hf.spans[idx] = span;
    }

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);

    // Expected areas after filtering (from PR #772 test)
    const expected_areas = [_]u8{
        NULL_AREA, NULL_AREA, NULL_AREA, NULL_AREA, NULL_AREA,
        NULL_AREA, WALKABLE_AREA, NULL_AREA, WALKABLE_AREA, NULL_AREA,
        NULL_AREA, NULL_AREA, WALKABLE_AREA, NULL_AREA, NULL_AREA,
        NULL_AREA, WALKABLE_AREA, NULL_AREA, WALKABLE_AREA, NULL_AREA,
        NULL_AREA, NULL_AREA, NULL_AREA, NULL_AREA, NULL_AREA,
    };

    // Verify results
    idx = 0;
    while (idx < 25) : (idx += 1) {
        const span = hf.spans[idx];
        try std.testing.expect(span != null);
        try std.testing.expectEqual(expected_areas[idx], span.?.area);
    }
}

// Additional boundary test: gap is exactly walkableHeight + 1 (should be walkable)
test "filterLedgeSpans - boundary case: gap greater than walkableHeight by 1" {
    const allocator = std.testing.allocator;

    var hf = try Heightfield.init(
        allocator,
        3,
        3,
        Vec3.init(0, 0, 0),
        Vec3.init(3, 20, 3),
        1.0,
        1.0,
    );
    defer hf.deinit();

    const walkable_height: i32 = 10;
    const walkable_climb: i32 = 2;

    // Create a 3x3 grid where center has ceiling at exactly walkableHeight + 1
    var z: i32 = 0;
    while (z < 3) : (z += 1) {
        var x: i32 = 0;
        while (x < 3) : (x += 1) {
            const col_idx = @as(usize, @intCast(x + z * 3));
            const span1 = try hf.allocSpan();
            span1.smin = 0;
            span1.smax = 5;
            span1.area = WALKABLE_AREA;

            if (x == 1 and z == 1) {
                // Center: ceiling at floor + walkableHeight + 1 = 5 + 11 = 16
                const span2 = try hf.allocSpan();
                span2.smin = 16; // gap = 16 - 5 = 11 (walkableHeight + 1)
                span2.smax = 20;
                span2.area = NULL_AREA;
                span1.next = span2;
            }

            hf.spans[col_idx] = span1;
        }
    }

    const ctx = Context.init(allocator);
    filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);

    // Center span should remain walkable (gap > walkableHeight)
    const center_idx = @as(usize, 4); // (1, 1)
    const center_span = hf.spans[center_idx];
    try std.testing.expect(center_span != null);
    try std.testing.expectEqual(WALKABLE_AREA, center_span.?.area);
}
