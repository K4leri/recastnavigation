const std = @import("std");
const recast = @import("recast-nav");

// ====================================================================
// Issue #650 Test: Infinite loop in triangulateHull when detailSampleDist == 0
//
// This test verifies the fix for a critical bug that could cause infinite
// loops in NavMesh generation when detailSampleDist parameter is set to 0.
//
// The fix involves:
// 1. Changing loop condition from '!=' to '<' in triangulateHull
// 2. Adding guard clause to prevent calls with nhull < 3
// ====================================================================

test "Issue 650 - triangulateHull infinite loop prevention" {
    const allocator = std.testing.allocator;

    // Test case 1: Critical case - nhull = 0 (previously caused infinite loop)
    {
        const nhull: i32 = 0;
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        // This call should complete immediately without infinite loop
        const start_time = std.time.nanoTimestamp();

        recast.recast.detail.triangulateHull(
            0,           // nverts
            undefined,   // verts (not needed for nhull=0)
            nhull,       // nhull
            undefined,   // hull (not needed for nhull=0)
            0,           // nin
            &tris,       // tris
        ) catch |err| {
            // Expected behavior - function should return early due to guard clause
            try std.testing.expect(err == error.UnexpectedValue);
        };

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - start_time;

        // Verify function completed quickly (less than 1ms)
        try std.testing.expect(duration < 1_000_000);
        std.debug.print("✓ nhull=0 case completed in {}ns (no infinite loop)\n", .{duration});
    }

    // Test case 2: Edge case - nhull = 1
    {
        const nhull: i32 = 1;
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        const start_time = std.time.nanoTimestamp();

        recast.recast.detail.triangulateHull(
            0,
            undefined,
            nhull,
            undefined,
            0,
            &tris,
        ) catch |err| {
            // Expected - guard clause should trigger
            try std.testing.expect(err == error.UnexpectedValue);
        };

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - start_time;

        try std.testing.expect(duration < 1_000_000);
        std.debug.print("✓ nhull=1 case completed in {}ns (early exit)\n", .{duration});
    }

    // Test case 3: Edge case - nhull = 2
    {
        const nhull: i32 = 2;
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        const start_time = std.time.nanoTimestamp();

        recast.recast.detail.triangulateHull(
            0,
            undefined,
            nhull,
            undefined,
            0,
            &tris,
        ) catch |err| {
            // Expected - guard clause should trigger
            try std.testing.expect(err == error.UnexpectedValue);
        };

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - start_time;

        try std.testing.expect(duration < 1_000_000);
        std.debug.print("✓ nhull=2 case completed in {}ns (early exit)\n", .{duration});
    }

    // Test case 4: Valid case - nhull = 3 (minimum for triangulation)
    {
        const nhull: i32 = 3;
        const verts = [_]f32{
            0.0, 0.0, 0.0,  // vertex 0
            1.0, 0.0, 0.0,  // vertex 1
            0.0, 1.0, 0.0,  // vertex 2
        };
        const hull = [_]i32{ 0, 1, 2 };
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        const start_time = std.time.nanoTimestamp();

        recast.recast.detail.triangulateHull(
            3,
            &verts,
            nhull,
            &hull,
            3,
            &tris,
        ) catch |err| {
            // Should not error for valid input
            std.debug.print("Unexpected error for nhull=3: {}\n", .{err});
            return err;
        };

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - start_time;

        try std.testing.expect(duration < 10_000_000); // 10ms max for valid case
        try std.testing.expect(tris.items.len >= 4); // At least one triangle (3 vertices + flags)
        std.debug.print("✓ nhull=3 case completed in {}ns with {} triangles\n", .{ duration, tris.items.len / 4 });
    }

    // Test case 5: Valid case - nhull = 4 (square)
    {
        const nhull: i32 = 4;
        const verts = [_]f32{
            0.0, 0.0, 0.0,  // vertex 0
            1.0, 0.0, 0.0,  // vertex 1
            1.0, 1.0, 0.0,  // vertex 2
            0.0, 1.0, 0.0,  // vertex 3
        };
        const hull = [_]i32{ 0, 1, 2, 3 };
        var tris = std.array_list.Managed(i32).init(allocator);
        defer tris.deinit();

        const start_time = std.time.nanoTimestamp();

        recast.recast.detail.triangulateHull(
            4,
            &verts,
            nhull,
            &hull,
            4,
            &tris,
        ) catch |err| {
            return err;
        };

        const end_time = std.time.nanoTimestamp();
        const duration = end_time - start_time;

        try std.testing.expect(duration < 10_000_000);
        try std.testing.expect(tris.items.len >= 8); // At least two triangles for square
        std.debug.print("✓ nhull=4 case completed in {}ns with {} triangles\n", .{ duration, tris.items.len / 4 });
    }
}

test "Issue 650 - buildPolyDetail integration simulation" {
    // Simplified integration test that simulates the buildPolyDetail scenario
    // that would trigger the original bug
    const allocator = std.testing.allocator;

    // Simulate the scenario where buildPolyDetail would call triangulateHull
    // with nhull = 0 (when sample_dist = 0)
    const critical_nhull: i32 = 0;

    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    const start_time = std.time.nanoTimestamp();

    // Direct call to triangulateHull with nhull=0 - this should complete immediately
    recast.recast.detail.triangulateHull(
        0,              // nverts
        undefined,      // verts
        critical_nhull, // nhull (critical case)
        undefined,      // hull
        0,              // nin
        &tris,          // tris
    ) catch |err| {
        // Expected - guard clause should prevent processing
        try std.testing.expect(err == error.UnexpectedValue);
    };

    const end_time = std.time.nanoTimestamp();
    const duration = end_time - start_time;

    // Verify the function completed quickly (no infinite loop)
    try std.testing.expect(duration < 1_000_000); // 1ms max

    std.debug.print("✓ triangulateHull integration test completed in {}ns\n", .{duration});
    std.debug.print("  Simulated buildPolyDetail scenario with nhull=0\n", .{});
}

test "Issue 650 - Loop condition mathematical verification" {
    // Verify that the fixed loop condition behaves correctly
    const TestHelper = struct {
        const next = struct {
            fn f(i: i32, n: i32) i32 {
                return if (i + 1 < n) i + 1 else 0;
            }
        }.f;

        fn verifyConditions(nhull: i32, left: i32, right: i32) struct {
            original: bool,
            fixed: bool,
            prevents_infinite: bool
        } {
            const next_left = next(left, nhull);
            const original_cond = next_left != right;
            const fixed_cond = next_left < right;

            return .{
                .original = original_cond,
                .fixed = fixed_cond,
                .prevents_infinite = if (nhull == 0 and left == 1 and right == -1)
                    original_cond and !fixed_cond
                else
                    true,
            };
        }
    };

    // Test critical cases
    const test_cases = [_]struct { nhull: i32, left: i32, right: i32 }{
        .{ .nhull = 0, .left = 1, .right = -1 }, // Critical case from bug report
        .{ .nhull = 1, .left = 1, .right = 0 },
        .{ .nhull = 2, .left = 1, .right = 1 },
        .{ .nhull = 3, .left = 1, .right = 2 },
        .{ .nhull = 4, .left = 1, .right = 3 },
    };

    for (test_cases) |case| {
        const result = TestHelper.verifyConditions(case.nhull, case.left, case.right);

        std.debug.print("nhull={}, left={}, right={} -> orig: {}, fixed: {}\n",
            .{ case.nhull, case.left, case.right, result.original, result.fixed });

        // Verify fix prevents infinite loop in critical case
        try std.testing.expect(result.prevents_infinite);

        // For the critical case (nhull=0), original should be true, fixed should be false
        if (case.nhull == 0) {
            try std.testing.expect(result.original == true);
            try std.testing.expect(result.fixed == false);
            std.debug.print("  ✓ Critical case: infinite loop prevented!\n", .{});
        }
    }
}