//! Чистый детерминированный SVG-эмиттер топологии навмеша (cluster D / D7).
//!
//! Автономный модуль: импортирует ТОЛЬКО std, тестируется отдельно от остального
//! проекта. Обход навмеша и проекция XZ выполняются снаружи — на вход подаются
//! уже готовые плоские 2D-полигоны.
//!
//! Ориентация координат:
//!   SVG-X = recast-X (горизонталь, направо)
//!   SVG-Y = recast-Z (вертикаль, ВНИЗ в SVG; Z уже «вниз» в top-down проекции)
//!   Таким образом viewBox = "bmin[0] bmin[1] width height" отображает
//!   XZ-плоскость напрямую без дополнительной инверсии.
//!
//! Формат цвета colors[i]:
//!   0x00RRGGBB (нижние 24 бита) → "#rrggbb" (нижний регистр hex).
//!   Верхний байт (alpha) игнорируется; у caller-а не должно быть потребности
//!   передавать прозрачность — stroke и fill задаются фиксированно.
//!
//! Формат float: `{d}` — кратчайшее детерминированное десятичное (как в D3).

const std = @import("std");

/// Записать SVG (вид сверху XZ) в `writer` (anytype; в тестах — ArrayList(u8).writer()).
///
/// Аргументы:
///   writer      — anytype writer
///   polys_flat  — плоские 2D-точки (x, z) всех полигонов подряд: x0,z0,x1,z1,…
///   poly_sizes  — число вершин каждого полигона (>= 3)
///   colors      — 0x00RRGGBB (или 0xAARRGGBB, alpha игнорируется), по одному на полигон
///   bmin        — [xmin, zmin] — левый верхний угол viewBox
///   bmax        — [xmax, zmax] — правый нижний угол viewBox
///
/// Ошибки:
///   error.MalformedPolys — sum(poly_sizes) * 2 != polys_flat.len ИЛИ
///                          colors.len != poly_sizes.len
pub fn writeSvg(
    writer: anytype,
    polys_flat: []const f32,
    poly_sizes: []const u32,
    colors: []const u32,
    bmin: [2]f32,
    bmax: [2]f32,
) !void {
    // Валидация: количество цветов совпадает с количеством полигонов
    if (colors.len != poly_sizes.len) return error.MalformedPolys;

    // Валидация: сумма вершин * 2 == длина плоского массива точек
    var total_verts: usize = 0;
    for (poly_sizes) |sz| total_verts += sz;
    if (total_verts * 2 != polys_flat.len) return error.MalformedPolys;

    const width = bmax[0] - bmin[0];
    const height = bmax[1] - bmin[1];

    // SVG-заголовок: xmlns + viewBox
    try writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="{d} {d} {d} {d}">
        \\
    , .{ bmin[0], bmin[1], width, height });

    // Перебираем полигоны, поддерживая смещение в polys_flat
    var flat_offset: usize = 0;
    for (poly_sizes, 0..) |sz, pi| {
        const rgb = colors[pi] & 0x00FF_FFFF;
        const r: u8 = @intCast((rgb >> 16) & 0xFF);
        const g: u8 = @intCast((rgb >> 8) & 0xFF);
        const b: u8 = @intCast(rgb & 0xFF);

        // <polygon points="x0,z0 x1,z1 ..." fill="#rrggbb" stroke="#333333" stroke-width="0.1"/>
        try writer.writeAll("<polygon points=\"");
        var vi: u32 = 0;
        while (vi < sz) : (vi += 1) {
            const x = polys_flat[flat_offset + vi * 2];
            const z = polys_flat[flat_offset + vi * 2 + 1];
            if (vi != 0) try writer.writeByte(' ');
            try writer.print("{d},{d}", .{ x, z });
        }
        try writer.print("\" fill=\"#{x:0>2}{x:0>2}{x:0>2}\" stroke=\"#333333\" stroke-width=\"0.1\"/>\n", .{ r, g, b });

        flat_offset += sz * 2;
    }

    try writer.writeAll("</svg>\n");
}

// ===========================================================================
// Тесты
// ===========================================================================

test "writeSvg: один треугольник" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Треугольник в XZ: (0,0), (10,0), (5,8)
    const polys_flat = [_]f32{ 0.0, 0.0, 10.0, 0.0, 5.0, 8.0 };
    const poly_sizes = [_]u32{3};
    const colors = [_]u32{0xFF8000}; // оранжевый

    try writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 10.0, 8.0 });

    const out = aw.writer.buffered();

    // Присутствует открывающий тег
    try std.testing.expect(std.mem.indexOf(u8, out, "<svg") != null);

    // viewBox корректен: minx=0 minz=0 width=10 height=8
    try std.testing.expect(std.mem.indexOf(u8, out, "viewBox=\"0 0 10 8\"") != null);

    // Один полигон
    try std.testing.expect(std.mem.indexOf(u8, out, "<polygon") != null);

    // points содержит три пары
    try std.testing.expect(std.mem.indexOf(u8, out, "points=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "10,0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "5,8") != null);

    // fill присутствует
    try std.testing.expect(std.mem.indexOf(u8, out, "fill=\"#") != null);

    // Оранжевый 0xFF8000 → #ff8000
    try std.testing.expect(std.mem.indexOf(u8, out, "fill=\"#ff8000\"") != null);

    // Закрывающий тег
    try std.testing.expect(std.mem.indexOf(u8, out, "</svg>") != null);
}

test "writeSvg: два полигона разных цветов" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Первый: треугольник; второй: квадрат
    const polys_flat = [_]f32{
        0.0, 0.0,  5.0, 0.0,  2.5, 4.0, // треугольник
        6.0, 0.0,  10.0, 0.0, 10.0, 4.0, 6.0, 4.0, // квадрат
    };
    const poly_sizes = [_]u32{ 3, 4 };
    const colors = [_]u32{ 0x00FF00, 0x0000FF };

    try writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 10.0, 4.0 });

    const out = aw.writer.buffered();

    // Два тега polygon
    var count: usize = 0;
    var search = out;
    while (std.mem.indexOf(u8, search, "<polygon")) |pos| {
        count += 1;
        search = search[pos + 1 ..];
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    // Разные fill
    try std.testing.expect(std.mem.indexOf(u8, out, "fill=\"#00ff00\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fill=\"#0000ff\"") != null);
}

test "writeSvg: несоответствие colors.len — error.MalformedPolys" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    const polys_flat = [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.5, 1.0 };
    const poly_sizes = [_]u32{3};
    const colors = [_]u32{ 0xFF0000, 0x00FF00 }; // лишний цвет

    const result = writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 1.0, 1.0 });
    try std.testing.expectError(error.MalformedPolys, result);
}

test "writeSvg: несоответствие polys_flat.len — error.MalformedPolys" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // poly_sizes говорит 3 вершины (= 6 f32), но передано 4 f32 — несоответствие
    const polys_flat = [_]f32{ 0.0, 0.0, 1.0, 0.0 };
    const poly_sizes = [_]u32{3};
    const colors = [_]u32{0xFF0000};

    const result = writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 1.0, 1.0 });
    try std.testing.expectError(error.MalformedPolys, result);
}

test "writeSvg: пустой вход — валидный <svg></svg>" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    const polys_flat = [_]f32{};
    const poly_sizes = [_]u32{};
    const colors = [_]u32{};

    try writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 1.0, 1.0 });

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "<svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "</svg>") != null);
    // Полигонов нет
    try std.testing.expect(std.mem.indexOf(u8, out, "<polygon") == null);
}

test "writeSvg: hex цвет корректен (0xRRGGBB → нижний регистр)" {
    const alloc = std.testing.allocator;
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    // Используем значение с цифрами A-F во всех каналах
    // 0xABCDEF → r=0xAB g=0xCD b=0xEF → "#abcdef"
    const polys_flat = [_]f32{ 0.0, 0.0, 1.0, 0.0, 0.5, 1.0 };
    const poly_sizes = [_]u32{3};
    const colors = [_]u32{0xABCDEF};

    try writeSvg(&aw.writer, &polys_flat, &poly_sizes, &colors, .{ 0.0, 0.0 }, .{ 1.0, 1.0 });

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "fill=\"#abcdef\"") != null);
}
