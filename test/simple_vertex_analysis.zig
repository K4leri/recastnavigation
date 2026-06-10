const std = @import("std");
const recast = @import("recast-nav");
const rasterization = recast.recast.rasterization;

// Анализ дубликатов в 10 вершинах
test "Vertex duplicates analysis" {
    // Наш тестовый полигон, который дает 5+5=10
    const polygon = [_]f32{
        0.0, 0.0, 0.0,   // vertex 0
        2.0, 0.0, 1.0,   // vertex 1
        4.0, 0.0, 0.0,   // vertex 2
        6.0, 0.0, 1.0,   // vertex 3
        8.0, 0.0, 0.0,   // vertex 4
        10.0, 0.0, 1.0,  // vertex 5
    };

    // Увеличенные буферы для анализа
    var out_verts1: [20 * 3]f32 = undefined;
    var out_verts2: [20 * 3]f32 = undefined;

    const result = rasterization.dividePoly(
        &polygon,
        6,
        &out_verts1,
        &out_verts2,
        5.0,  // axis offset X=5
        .x,    // divide along X axis
    );

    std.debug.print("Result: {} + {} = {} vertices\n", .{ result.count1, result.count2, result.count1 + result.count2 });

    // Выводим координаты для анализа
    std.debug.print("Polygon 1:\n", .{});
    for (0..result.count1) |i| {
        const x = out_verts1[i * 3];
        const y = out_verts1[i * 3 + 1];
        const z = out_verts1[i * 3 + 2];
        std.debug.print("V{}: {:.1},{:.1},{:.1}\n", .{ i, x, y, z });
    }

    std.debug.print("Polygon 2:\n", .{});
    for (0..result.count2) |i| {
        const x = out_verts2[i * 3];
        const y = out_verts2[i * 3 + 1];
        const z = out_verts2[i * 3 + 2];
        std.debug.print("V{}: {:.1},{:.1},{:.1}\n", .{ i, x, y, z });
    }

    // Проверка на дубликаты между полигонами
    var duplicates_count: usize = 0;
    for (0..result.count1) |i| {
        for (0..result.count2) |j| {
            const x1 = out_verts1[i * 3];
            const y1 = out_verts1[i * 3 + 1];
            const z1 = out_verts1[i * 3 + 2];

            const x2 = out_verts2[j * 3];
            const y2 = out_verts2[j * 3 + 1];
            const z2 = out_verts2[j * 3 + 2];

            if (@abs(x1 - x2) < 0.001 and @abs(y1 - y2) < 0.001 and @abs(z1 - z2) < 0.001) {
                std.debug.print("DUPLICATE: P1[V{}] = P2[V{}] ({:.1},{:.1},{:.1})\n", .{ i, j, x1, y1, z1 });
                duplicates_count += 1;
            }
        }
    }

    const unique_vertices = result.count1 + result.count2 - duplicates_count;
    std.debug.print("Stats: Total={}, Duplicates={}, Unique={}\n", .{ result.count1 + result.count2, duplicates_count, unique_vertices });

    if (unique_vertices <= 7) {
        std.debug.print("CONCLUSION: GitHub RIGHT! Buffer 7 sufficient!\n", .{});
    } else {
        std.debug.print("CONCLUSION: GitHub WRONG! Problem real!\n", .{});
    }

    try std.testing.expect(unique_vertices <= 7);
}