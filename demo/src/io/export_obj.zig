//! export_obj — Wavefront .obj эмиттер геометрии навмеша (cluster D / D2).
//! Чистый, автономный модуль: зависит только от std.
//! Полигоны произвольной арности (3, 4, 5+ вершин) — .obj поддерживает грани `f`
//! с любым числом индексов.

const std = @import("std");

/// Ошибки эмиттера.
pub const ObjError = error{
    /// Сумма face_sizes не совпадает с faces_flat.len.
    MalformedFaces,
};

/// Записать геометрию как Wavefront .obj в `writer` (std.Io.Writer).
///
/// - `verts`      — плоские тройки x,y,z (f32), длина должна быть кратна 3.
/// - `faces_flat` — индексы вершин подряд (0-based), сгруппированы по face_sizes.
/// - `face_sizes` — число вершин в каждой грани (>= 3).
///
/// Индексы в выводе — 1-based (как требует спека .obj).
/// Возвращает ObjError.MalformedFaces, если сумма face_sizes != faces_flat.len.
pub fn writeObj(
    writer: *std.Io.Writer,
    verts: []const f32,
    faces_flat: []const u32,
    face_sizes: []const u32,
) !void {
    // Проверяем согласованность faces_flat / face_sizes
    var total_indices: usize = 0;
    for (face_sizes) |s| total_indices += s;
    if (total_indices != faces_flat.len) return ObjError.MalformedFaces;

    // Шапка
    try writer.writeAll("# zig-recast navmesh export\n");

    // Вершины: v x y z
    const n_verts = verts.len / 3;
    var vi: usize = 0;
    while (vi < n_verts) : (vi += 1) {
        const x = verts[vi * 3 + 0];
        const y = verts[vi * 3 + 1];
        const z = verts[vi * 3 + 2];
        try writer.print("v {d} {d} {d}\n", .{ x, y, z });
    }

    // Грани: f i1 i2 i3 ... (1-based)
    var fi: usize = 0; // курсор в faces_flat
    for (face_sizes) |sz| {
        try writer.writeAll("f");
        for (0..sz) |k| {
            const idx0 = faces_flat[fi + k]; // 0-based
            try writer.print(" {d}", .{idx0 + 1}); // 1-based
        }
        try writer.writeAll("\n");
        fi += sz;
    }
}

// ---------------------------------------------------------------------------
// Тесты
// ---------------------------------------------------------------------------

test "quad: 4 вершины, одна четырёхугольная грань" {
    const alloc = std.testing.allocator;

    // Единичный квадрат в плоскости XZ (y=0)
    const verts = [_]f32{
        0.0, 0.0, 0.0, // 0
        1.0, 0.0, 0.0, // 1
        1.0, 0.0, 1.0, // 2
        0.0, 0.0, 1.0, // 3
    };
    const faces_flat = [_]u32{ 0, 1, 2, 3 };
    const face_sizes = [_]u32{4};

    var aw = std.Io.Writer.Allocating.init(alloc);
    try writeObj(&aw.writer, &verts, &faces_flat, &face_sizes);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);

    const expected =
        "# zig-recast navmesh export\n" ++
        "v 0 0 0\n" ++
        "v 1 0 0\n" ++
        "v 1 0 1\n" ++
        "v 0 0 1\n" ++
        "f 1 2 3 4\n";

    try std.testing.expectEqualStrings(expected, out);
}

test "два треугольника" {
    const alloc = std.testing.allocator;

    const verts = [_]f32{
        0.0, 0.0, 0.0, // 0
        1.0, 0.0, 0.0, // 1
        0.5, 0.0, 1.0, // 2
        2.0, 0.0, 0.0, // 3
        3.0, 0.0, 0.0, // 4
        2.5, 0.0, 1.0, // 5
    };
    const faces_flat = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const face_sizes = [_]u32{ 3, 3 };

    var aw = std.Io.Writer.Allocating.init(alloc);
    try writeObj(&aw.writer, &verts, &faces_flat, &face_sizes);
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);

    const expected =
        "# zig-recast navmesh export\n" ++
        "v 0 0 0\n" ++
        "v 1 0 0\n" ++
        "v 0.5 0 1\n" ++
        "v 2 0 0\n" ++
        "v 3 0 0\n" ++
        "v 2.5 0 1\n" ++
        "f 1 2 3\n" ++
        "f 4 5 6\n";

    try std.testing.expectEqualStrings(expected, out);
}

test "несоответствие face_sizes/faces_flat → MalformedFaces" {
    const alloc = std.testing.allocator;

    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const faces_flat = [_]u32{ 0, 1, 2 }; // 3 индекса
    const face_sizes = [_]u32{4}; // говорим что 4, но их 3 → ошибка

    var aw = std.Io.Writer.Allocating.init(alloc);
    const result = writeObj(&aw.writer, &verts, &faces_flat, &face_sizes);
    // Нужно освободить буфер даже при ошибке (toOwnedSlice не вызываем — aw.deinit)
    aw.deinit();

    try std.testing.expectError(ObjError.MalformedFaces, result);
}

test "пустой меш — только шапка, без паники" {
    const alloc = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(alloc);
    try writeObj(&aw.writer, &[_]f32{}, &[_]u32{}, &[_]u32{});
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);

    try std.testing.expectEqualStrings("# zig-recast navmesh export\n", out);
}
