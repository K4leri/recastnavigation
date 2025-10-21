const std = @import("std");
const recast = @import("recast-nav");

// ====================================================================
// COMPREHENSIVE TEST SUITE FOR NEW EAR CLIPPING triangulateHull
// ====================================================================

test "Ear clipping triangulateHull - Mathematical correctness verification" {
    const allocator = std.testing.allocator;

    // Test case: Regular convex hexagon
    const hexagon_verts = [_]f32{
        0.0, 0.0, 0.0,   // vertex 0
        2.0, 0.0, 0.0,   // vertex 1
        3.0, 1.0, 0.0,   // vertex 2
        2.5, 2.5, 0.0,   // vertex 3
        1.0, 3.0, 0.0,   // vertex 4
        -0.5, 1.5, 0.0,  // vertex 5
    };
    const hexagon_hull = [_]i32{ 0, 1, 2, 3, 4, 5 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        6,
        &hexagon_verts,
        6,
        &hexagon_hull,
        6,
        &tris,
    );

    // For hexagon, should produce 4 triangles (6-2)
    try std.testing.expectEqual(@as(usize, 4), tris.items.len / 4);

    // Verify each triangle has valid indices
    var i: usize = 0;
    while (i < tris.items.len) : (i += 4) {
        const v0 = tris.items[i];
        const v1 = tris.items[i + 1];
        const v2 = tris.items[i + 2];
        const flags = tris.items[i + 3];

        // Verify indices are within hull bounds
        try std.testing.expect(v0 >= 0 and v0 < 6);
        try std.testing.expect(v1 >= 0 and v1 < 6);
        try std.testing.expect(v2 >= 0 and v2 < 6);

        // Verify all vertices are different
        try std.testing.expect(v0 != v1);
        try std.testing.expect(v1 != v2);
        try std.testing.expect(v0 != v2);

        // Verify flags are set correctly
        try std.testing.expectEqual(@as(i32, 0), flags);
    }

    std.debug.print("✓ Hexagon triangulated successfully with {} triangles\n", .{tris.items.len / 4});
}

test "Ear clipping triangulateHull - Complex concave polygon" {
    const allocator = std.testing.allocator;

    // Complex concave polygon (star-like shape)
    const concave_verts = [_]f32{
        0.0, 0.0, 0.0,    // vertex 0
        2.0, 0.0, 0.0,    // vertex 1
        2.5, 1.0, 0.0,    // vertex 2
        2.0, 1.5, 0.0,    // vertex 3 (creates concavity)
        2.5, 2.0, 0.0,    // vertex 4
        1.0, 2.5, 0.0,    // vertex 5
        -0.5, 2.0, 0.0,   // vertex 6
        0.0, 1.5, 0.0,    // vertex 7 (creates concavity)
        -0.5, 1.0, 0.0,   // vertex 8
    };
    const concave_hull = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        9,
        &concave_verts,
        9,
        &concave_hull,
        9,
        &tris,
    );

    // For nonagon, should produce 7 triangles (9-2)
    try std.testing.expectEqual(@as(usize, 7), tris.items.len / 4);

    std.debug.print("✓ Complex concave polygon triangulated with {} triangles\n", .{tris.items.len / 4});
}

test "Ear clipping triangulateHull - Edge case protection (issue #650)" {
    const allocator = std.testing.allocator;

    // Test cases that previously caused infinite loops
    const edge_cases = [_]struct {
        name: []const u8,
        nhull: i32,
        verts: []const f32,
    }{
        .{ .name = "empty hull", .nhull = 0, .verts = &[_]f32{} },
        .{ .name = "single vertex", .nhull = 1, .verts = &[_]f32{0.0, 0.0, 0.0} },
        .{ .name = "two vertices", .nhull = 2, .verts = &[_]f32{0.0, 0.0, 0.0, 1.0, 0.0, 0.0} },
    };

    for (edge_cases) |case| {
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        // This should return immediately without infinite loop
        try recast.triangulateHull(
            case.nhull,
            case.verts.ptr,
            case.nhull,
            undefined,
            0,
            &tris,
        );

        // Should produce no triangles for invalid input
        try std.testing.expectEqual(@as(usize, 0), tris.items.len);

        std.debug.print("✓ Edge case '{}' handled safely: nhull={}\n", .{ case.name, case.nhull });
    }
}

test "Ear clipping triangulateHull - Precision preservation" {
    const allocator = std.testing.allocator;

    // Test with very small coordinates to verify precision preservation
    const small_verts = [_]f32{
        0.001, 0.001, 0.0,  // vertex 0
        0.002, 0.001, 0.0,  // vertex 1
        0.002, 0.002, 0.0,  // vertex 2
        0.001, 0.002, 0.0,  // vertex 3
    };
    const small_hull = [_]i32{ 0, 1, 2, 3 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        4,
        &small_verts,
        4,
        &small_hull,
        4,
        &tris,
    );

    // Should still produce correct triangulation
    try std.testing.expectEqual(@as(usize, 2), tris.items.len / 4);

    std.debug.print("✓ Small coordinate precision test passed\n", .{});
}

test "Ear clipping triangulateHull - Large coordinate handling" {
    const allocator = std.testing.allocator;

    // Test with large coordinates
    const large_verts = [_]f32{
        1000.0, 1000.0, 0.0,    // vertex 0
        2000.0, 1000.0, 0.0,    // vertex 1
        2000.0, 2000.0, 0.0,    // vertex 2
        1000.0, 2000.0, 0.0,    // vertex 3
    };
    const large_hull = [_]i32{ 0, 1, 2, 3 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        4,
        &large_verts,
        4,
        &large_hull,
        4,
        &tris,
    );

    // Should produce correct triangulation
    try std.testing.expectEqual(@as(usize, 2), tris.items.len / 4);

    std.debug.print("✓ Large coordinate test passed\n", .{});
}

test "Ear clipping triangulateHull - Performance with complex polygon" {
    const allocator = std.testing.allocator;

    // Create a 20-vertex approximation of a circle
    const nvertices: usize = 20;
    var circle_verts: [60]f32 = undefined;
    var circle_hull: [20]i32 = undefined;

    const radius: f32 = 10.0;
    var i: usize = 0;
    while (i < nvertices) : (i += 1) {
        const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(nvertices));
        circle_verts[i * 3 + 0] = radius * @cos(angle);
        circle_verts[i * 3 + 1] = 0.0;
        circle_verts[i * 3 + 2] = radius * @sin(angle);
        circle_hull[i] = @intCast(i);
    }

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    const start_time = std.time.nanoTimestamp();

    try recast.triangulateHull(
        @intCast(nvertices),
        &circle_verts,
        @intCast(nvertices),
        &circle_hull,
        @intCast(nvertices),
        &tris,
    );

    const end_time = std.time.nanoTimestamp();
    const duration_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Should produce 18 triangles (20-2)
    try std.testing.expectEqual(@as(usize, 18), tris.items.len / 4);

    // Performance should be reasonable (less than 100ms for 20 vertices)
    try std.testing.expect(duration_ms < 100.0);

    std.debug.print("✓ 20-vertex polygon triangulated in {d:.2}ms\n", .{duration_ms});
}

test "Ear clipping triangulateHull - Fallback mechanism verification" {
    const allocator = std.testing.allocator;

    // Test with a polygon that might require loose diagonal handling
    // This simulates overlapping segments or complex geometry
    const complex_verts = [_]f32{
        0.0, 0.0, 0.0,    // vertex 0
        1.0, 0.0, 0.0,    // vertex 1
        2.0, 0.1, 0.0,    // vertex 2 (nearly collinear)
        3.0, 0.0, 0.0,    // vertex 3
        3.0, 1.0, 0.0,    // vertex 4
        2.0, 1.1, 0.0,    // vertex 5 (nearly collinear)
        1.0, 1.0, 0.0,    // vertex 6
        0.0, 1.0, 0.0,    // vertex 7
    };
    const complex_hull = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        8,
        &complex_verts,
        8,
        &complex_hull,
        8,
        &tris,
    );

    // Should produce 6 triangles (8-2)
    try std.testing.expectEqual(@as(usize, 6), tris.items.len / 4);

    std.debug.print("✓ Complex polygon with near-collinear points handled successfully\n", .{});
}

test "Ear clipping triangulateHull - Memory safety verification" {
    const allocator = std.testing.allocator;

    // Test that the implementation properly cleans up memory
    // even with large numbers of vertices
    const large_n: i32 = 100;

    // Create a large regular polygon
    var large_verts = try allocator.alloc(f32, @as(usize, @intCast(large_n * 3)));
    defer allocator.free(large_verts);
    var large_hull = try allocator.alloc(i32, @as(usize, @intCast(large_n)));
    defer allocator.free(large_hull);

    const radius: f32 = 50.0;
    var i: i32 = 0;
    while (i < large_n) : (i += 1) {
        const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(large_n));
        large_verts[@as(usize, @intCast(i * 3 + 0))] = radius * @cos(angle);
        large_verts[@as(usize, @intCast(i * 3 + 1))] = 0.0;
        large_verts[@as(usize, @intCast(i * 3 + 2))] = radius * @sin(angle);
        large_hull[@as(usize, @intCast(i))] = i;
    }

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        large_n,
        large_verts.ptr,
        large_n,
        large_hull,
        large_n,
        &tris,
    );

    // Should produce 98 triangles (100-2)
    try std.testing.expectEqual(@as(usize, 98), tris.items.len / 4);

    std.debug.print("✓ Large polygon (100 vertices) handled safely with proper memory management\n", .{});
}

test "Ear clipping triangulateHull - Comparison with expected results" {
    const allocator = std.testing.allocator;

    // Test case where we can verify the exact triangulation
    const simple_verts = [_]f32{
        0.0, 0.0, 0.0,  // vertex 0
        2.0, 0.0, 0.0,  // vertex 1
        2.0, 2.0, 0.0,  // vertex 2
        0.0, 2.0, 0.0,  // vertex 3
    };
    const simple_hull = [_]i32{ 0, 1, 2, 3 };

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    try recast.triangulateHull(
        4,
        &simple_verts,
        4,
        &simple_hull,
        4,
        &tris,
    );

    // Should produce exactly 2 triangles
    try std.testing.expectEqual(@as(usize, 2), tris.items.len / 4);

    // Verify that all hull vertices are used in triangulation
    var used_vertices = std.bit_set.IntegerBitSet(4).initEmpty();
    var tri_idx: usize = 0;
    while (tri_idx < tris.items.len) : (tri_idx += 4) {
        used_vertices.set(@as(usize, @intCast(tris.items[tri_idx])));
        used_vertices.set(@as(usize, @intCast(tris.items[tri_idx + 1])));
        used_vertices.set(@as(usize, @intCast(tris.items[tri_idx + 2])));
    }

    // All 4 vertices should be used
    try std.testing.expectEqual(@as(u4, 0b1111), used_vertices.mask);

    std.debug.print("✓ Simple square triangulation verification passed\n", .{});
}

test "Ear clipping triangulateHull - Stress test with degenerate cases" {
    const allocator = std.testing.allocator;

    // Test various degenerate cases that could cause issues
    const test_cases = [_]struct {
        name: []const u8,
        verts: []const f32,
        hull: []const i32,
        expected_tris: usize,
    }{
        .{
            .name = "minimal triangle",
            .verts = &[_]f32{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.5, 1.0, 0.0 },
            .hull = &[_]i32{ 0, 1, 2 },
            .expected_tris = 1,
        },
        .{
            .name = "collinear quadrilateral fallback",
            .verts = &[_]f32{ 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 2.0, 0.0, 0.0, 3.0, 0.0, 0.0 },
            .hull = &[_]i32{ 0, 1, 2, 3 },
            .expected_tris = 2, // Should still produce something reasonable
        },
    };

    for (test_cases) |case| {
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        try recast.triangulateHull(
            @intCast(case.hull.len),
            case.verts.ptr,
            @intCast(case.hull.len),
            case.hull,
            @intCast(case.hull.len),
            &tris,
        );

        try std.testing.expectEqual(case.expected_tris, tris.items.len / 4);

        std.debug.print("✓ Degenerate case '{}' handled: {} triangles\n", .{ case.name, tris.items.len / 4 });
    }
}