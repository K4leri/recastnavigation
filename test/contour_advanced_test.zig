const std = @import("std");
const testing = std.testing;
const recast = @import("recast-nav");
const contour = recast.recast.contour;

// ==============================================================================
// DISTANCE POINT TO SEGMENT TESTS
// ==============================================================================

test "distancePtSeg - point on segment" {
    // Segment from (0,0) to (10,0)
    // Point at (5,0) - exactly on the segment
    const d = contour.distancePtSeg(5, 0, 0, 0, 10, 0);

    // Distance should be 0 (or very close to 0)
    try testing.expect(d < 0.001);
}

test "distancePtSeg - point perpendicular to segment" {
    // Segment from (0,0) to (10,0)
    // Point at (5,5) - perpendicular distance = 5
    const d = contour.distancePtSeg(5, 5, 0, 0, 10, 0);

    // Distance squared should be 25 (5^2)
    try testing.expectApproxEqAbs(@as(f32, 25.0), d, 0.001);
}

test "distancePtSeg - point before segment start" {
    // Segment from (5,0) to (10,0)
    // Point at (0,0) - before segment start
    const d = contour.distancePtSeg(0, 0, 5, 0, 10, 0);

    // Distance should be to closest endpoint (5,0)
    // Distance squared = 5^2 = 25
    try testing.expectApproxEqAbs(@as(f32, 25.0), d, 0.001);
}

test "distancePtSeg - point after segment end" {
    // Segment from (0,0) to (5,0)
    // Point at (10,0) - after segment end
    const d = contour.distancePtSeg(10, 0, 0, 0, 5, 0);

    // Distance should be to closest endpoint (5,0)
    // Distance squared = 5^2 = 25
    try testing.expectApproxEqAbs(@as(f32, 25.0), d, 0.001);
}

test "distancePtSeg - diagonal segment" {
    // Segment from (0,0) to (10,10)
    // Point at (5,0) - perpendicular to diagonal
    const d = contour.distancePtSeg(5, 0, 0, 0, 10, 10);

    // Distance from (5,0) to closest point on line y=x
    // Closest point is (2.5, 2.5)
    // Distance squared = (5-2.5)^2 + (0-2.5)^2 = 6.25 + 6.25 = 12.5
    try testing.expectApproxEqAbs(@as(f32, 12.5), d, 0.1);
}

test "distancePtSeg - vertical segment" {
    // Segment from (5,0) to (5,10)
    // Point at (0,5) - perpendicular distance = 5
    const d = contour.distancePtSeg(0, 5, 5, 0, 5, 10);

    // Distance squared should be 25 (5^2)
    try testing.expectApproxEqAbs(@as(f32, 25.0), d, 0.001);
}

test "distancePtSeg - same start and end point (degenerate segment)" {
    // Degenerate segment: both endpoints at (5,5)
    // Point at (10,10)
    const d = contour.distancePtSeg(10, 10, 5, 5, 5, 5);

    // Distance should be to the single point (5,5)
    // Distance squared = (10-5)^2 + (10-5)^2 = 25 + 25 = 50
    try testing.expectApproxEqAbs(@as(f32, 50.0), d, 0.001);
}

test "distancePtSeg - point coincides with segment start" {
    // Segment from (0,0) to (10,0)
    // Point at (0,0) - coincides with start
    const d = contour.distancePtSeg(0, 0, 0, 0, 10, 0);

    // Distance should be 0
    try testing.expect(d < 0.001);
}

test "distancePtSeg - point coincides with segment end" {
    // Segment from (0,0) to (10,0)
    // Point at (10,0) - coincides with end
    const d = contour.distancePtSeg(10, 0, 0, 0, 10, 0);

    // Distance should be 0
    try testing.expect(d < 0.001);
}

test "distancePtSeg - negative coordinates" {
    // Segment from (-10,-10) to (0,0)
    // Point at (-5,-5) - on the segment
    const d = contour.distancePtSeg(-5, -5, -10, -10, 0, 0);

    // Distance should be ~0 (on line)
    try testing.expect(d < 0.1);
}

// ==============================================================================
// SIMPLIFYCONTOUR TESTS (Basic)
// ==============================================================================

test "simplifyContour - simple square contour" {
    const allocator = testing.allocator;

    // Create a simple square contour: (0,0), (10,0), (10,10), (0,10)
    // Each point is stored as [x, y, z, flags] (4 i32 values)
    var points = std.array_list.Managed(i32).init(allocator);
    defer points.deinit();

    // Bottom-left (0, 0, 0)
    try points.append(0);
    try points.append(0);
    try points.append(0);
    try points.append(0); // flags

    // Bottom-right (10, 0, 0)
    try points.append(10);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    // Top-right (10, 0, 10)
    try points.append(10);
    try points.append(0);
    try points.append(10);
    try points.append(0);

    // Top-left (0, 0, 10)
    try points.append(0);
    try points.append(0);
    try points.append(10);
    try points.append(0);

    var simplified = std.array_list.Managed(i32).init(allocator);
    defer simplified.deinit();

    // Simplify with max_error=1.0, no edge splitting
    try contour.simplifyContour(&points, &simplified, 1.0, 0, 0, allocator);

    // Should have at least 2 points (lower-left and upper-right corners)
    // for a square without region connections
    const num_points = @divTrunc(simplified.items.len, 4);
    try testing.expect(num_points >= 2);
    try testing.expect(num_points <= 4); // At most the original 4 corners
}

test "simplifyContour - collinear points with low threshold" {
    const allocator = testing.allocator;

    // Create contour with collinear points: (0,0), (5,0), (10,0)
    var points = std.array_list.Managed(i32).init(allocator);
    defer points.deinit();

    try points.append(0);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    try points.append(5);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    try points.append(10);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    var simplified = std.array_list.Managed(i32).init(allocator);
    defer simplified.deinit();

    // With low error threshold, should keep only endpoints
    try contour.simplifyContour(&points, &simplified, 0.1, 0, 0, allocator);

    const num_points = @divTrunc(simplified.items.len, 4);

    // Should have 2 points (start and end, since middle is collinear)
    try testing.expectEqual(@as(usize, 2), num_points);
}

test "simplifyContour - high threshold removes details" {
    const allocator = testing.allocator;

    // Create contour with slight deviation: (0,0), (5,1), (10,0)
    var points = std.array_list.Managed(i32).init(allocator);
    defer points.deinit();

    try points.append(0);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    try points.append(5);
    try points.append(0);
    try points.append(1);
    try points.append(0);

    try points.append(10);
    try points.append(0);
    try points.append(0);
    try points.append(0);

    var simplified = std.array_list.Managed(i32).init(allocator);
    defer simplified.deinit();

    // With high error threshold (10.0), should remove middle point
    try contour.simplifyContour(&points, &simplified, 10.0, 0, 0, allocator);

    const num_points = @divTrunc(simplified.items.len, 4);

    // Should have 2 points (deviation 1 is < max_error 10)
    try testing.expectEqual(@as(usize, 2), num_points);
}
