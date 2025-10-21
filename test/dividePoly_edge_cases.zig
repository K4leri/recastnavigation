const std = @import("std");
const recast = @import("recast-nav");
const rasterization = recast.recast.rasterization;

// Edge case testing for dividePoly algorithm fixes
test "dividePoly edge cases - delta near zero" {
    const epsilon = 0.0001;

    // Test case 1: Vertex extremely close to dividing line
    const near_zero_polygon = [_]f32{
        0.0,    0.0, 0.0,   // vertex 0
        5.0-epsilon, 0.0, 1.0,   // vertex 1 - VERY close to line
        10.0,   0.0, 0.0,   // vertex 2
    };

    var out1: [8 * 3]f32 = undefined;
    var out2: [8 * 3]f32 = undefined;

    const result1 = rasterization.dividePoly(
        &near_zero_polygon,
        3,
        &out1,
        &out2,
        5.0,  // axis offset
        .x,
    );

    std.debug.print("Near-zero delta test: {} + {} = {} vertices\n", .{
        result1.count1, result1.count2, result1.count1 + result1.count2
    });

    // Should handle gracefully without creating excessive vertices
    try std.testing.expect(result1.count1 + result1.count2 <= 8);
}

test "dividePoly edge cases - all vertices on line" {
    // Test case 2: All vertices exactly on dividing line (delta=0 for all)
    const on_line_polygon = [_]f32{
        5.0, 0.0, 0.0,   // vertex 0 - exactly on line
        5.0, 0.0, 1.0,   // vertex 1 - exactly on line
        5.0, 0.0, 2.0,   // vertex 2 - exactly on line
    };

    var out1: [8 * 3]f32 = undefined;
    var out2: [8 * 3]f32 = undefined;

    const result2 = rasterization.dividePoly(
        &on_line_polygon,
        3,
        &out1,
        &out2,
        5.0,  // axis offset - same as all vertex X coordinates
        .x,
    );

    std.debug.print("All-on-line test: {} + {} = {} vertices\n", .{
        result2.count1, result2.count2, result2.count1 + result2.count2
    });

    // All vertices should be added to both polygons
    try std.testing.expect(result2.count1 == 3);
    try std.testing.expect(result2.count2 == 3);
}

test "dividePoly edge cases - repeated calls accumulation" {
    // Test case 3: Simulate multiple dividePoly calls like in rasterization pipeline
    const triangle = [_]f32{
        0.0, 0.0, 0.0,   // vertex 0
        10.0, 0.0, 0.0,  // vertex 1
        5.0, 0.0, 10.0,  // vertex 2
    };

    var temp1: [8 * 3]f32 = undefined;
    var temp2: [8 * 3]f32 = undefined;

    // First division (simulate Z-axis clipping)
    const result1 = rasterization.dividePoly(
        &triangle,
        3,
        &temp1,
        &temp2,
        5.0,  // axis offset
        .z,
    );

    std.debug.print("First division: {} + {} vertices\n", .{ result1.count1, result1.count2 });

    // Second division (simulate X-axis clipping on result)
    if (result1.count1 > 0) {
        var final1: [8 * 3]f32 = undefined;
        var final2: [8 * 3]f32 = undefined;

        const result2 = rasterization.dividePoly(
            temp1[0..result1.count1 * 3],
            result1.count1,
            &final1,
            &final2,
            5.0,  // axis offset
            .x,
        );

        std.debug.print("Second division: {} + {} vertices\n", .{ result2.count1, result2.count2 });

        // Should not exceed buffer limits even after multiple calls
        try std.testing.expect(result2.count1 <= 8);
        try std.testing.expect(result2.count2 <= 8);
    }
}

test "dividePoly edge cases - maximum vertices scenario" {
    // Test case 4: Create scenario that could produce maximum vertices
    const max_polygon = [_]f32{
        0.0,   0.0, 0.0,   // vertex 0
        2.0,   0.0, 5.0,   // vertex 1
        4.0,   0.0, 0.0,   // vertex 2
        6.0,   0.0, 5.0,   // vertex 3
        8.0,   0.0, 0.0,   // vertex 4
        10.0,  0.0, 5.0,   // vertex 5
    };

    var out1: [8 * 3]f32 = undefined;
    var out2: [8 * 3]f32 = undefined;

    const result = rasterization.dividePoly(
        &max_polygon,
        6,
        &out1,
        &out2,
        5.0,  // axis offset through middle
        .x,
    );

    std.debug.print("Max vertices test: {} + {} = {} vertices\n", .{
        result.count1, result.count2, result.count1 + result.count2
    });

    // Should handle the complex case without overflow
    try std.testing.expect(result.count1 <= 8);
    try std.testing.expect(result.count2 <= 8);

    // Analyze for duplicates
    var duplicates: usize = 0;
    for (0..result.count1) |i| {
        for (0..result.count2) |j| {
            const x1 = out1[i * 3];
            const y1 = out1[i * 3 + 1];
            const z1 = out1[i * 3 + 2];

            const x2 = out2[j * 3];
            const y2 = out2[j * 3 + 1];
            const z2 = out2[j * 3 + 2];

            if (@abs(x1 - x2) < 0.001 and @abs(y1 - y2) < 0.001 and @abs(z1 - z2) < 0.001) {
                duplicates += 1;
            }
        }
    }

    const unique = result.count1 + result.count2 - duplicates;
    std.debug.print("Unique vertices: {} (duplicates: {})\n", .{ unique, duplicates });

    // Should have reasonable number of unique vertices
    try std.testing.expect(unique <= 8);
}

test "dividePoly edge cases - floating point precision" {
    // Test case 5: Floating point edge cases
    const fp_polygon = [_]f32{
        0.1, 0.2, 0.3,   // vertex 0
        5.0000001, 0.0, 1.0,   // vertex 1 - very close to 5.0
        9.9, 0.8, 1.7,   // vertex 2
    };

    var out1: [8 * 3]f32 = undefined;
    var out2: [8 * 3]f32 = undefined;

    const result = rasterization.dividePoly(
        &fp_polygon,
        3,
        &out1,
        &out2,
        5.0,  // axis offset
        .x,
    );

    std.debug.print("FP precision test: {} + {} = {} vertices\n", .{
        result.count1, result.count2, result.count1 + result.count2
    });

    // Should handle floating point precision gracefully
    try std.testing.expect(result.count1 <= 8);
    try std.testing.expect(result.count2 <= 8);
}