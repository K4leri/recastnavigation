const std = @import("std");
const recast = @import("recast-nav");
const rasterization = recast.recast.rasterization;

// Simple test to verify dividePoly behavior and potential overflow
test "dividePoly simple overflow test" {
    // Create a 6-vertex polygon that might cause overflow
    const polygon = [_]f32{
        0.0, 0.0, 0.0,   // vertex 0
        2.0, 0.0, 1.0,   // vertex 1
        4.0, 0.0, 0.0,   // vertex 2
        6.0, 0.0, 1.0,   // vertex 3
        8.0, 0.0, 0.0,   // vertex 4
        10.0, 0.0, 1.0,  // vertex 5
    };

    var out_verts1: [7 * 3]f32 = undefined;
    var out_verts2: [7 * 3]f32 = undefined;

    // Test division that might create many vertices
    const result = rasterization.dividePoly(
        &polygon,
        6,
        &out_verts1,
        &out_verts2,
        5.0,  // axis offset through middle
        .x,    // divide along X axis
    );

    std.debug.print("Division result: count1={}, count2={}\n", .{ result.count1, result.count2 });

    // Check if we're approaching dangerous territory
    const total_vertices = result.count1 + result.count2;
    std.debug.print("Total vertices: {} (buffer limit: 7)\n", .{total_vertices});

    // These should pass with current buffer - BUT THEY DON'T!
    // This reveals the REAL problem!
    try std.testing.expect(result.count1 <= 7);
    try std.testing.expect(result.count2 <= 7);
}