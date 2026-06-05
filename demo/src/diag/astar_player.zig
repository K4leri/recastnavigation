//! A* sliced-pathfinding playback helpers — pure (no GL/UI) bits factored out
//! of the NavMeshTester sliced visualizer so they can be unit-tested.
//!
//! Чистые помощники для пошаговой визуализации A* (sliced findPath): формат
//! подписи g/h/f узла. Рендер и состояние поиска живут в tool_navmesh_tester.zig;
//! здесь — только детерминированное форматирование (тестируемое).

const std = @import("std");

/// Formats the three A* search values into a compact "g.. h.. f.." label.
/// `g` — cost from start (Node.cost), `f` — total f-cost (Node.total),
/// `h` — heuristic, passed in by the caller as `f - g`. Returns a slice into
/// `buf` (caller-owned). One decimal place keeps labels readable at the density
/// cap. На переполнении буфера возвращает пустую строку (рисовать нечего).
///
/// Форматирует g/h/f узла A* в короткую строку. h передаётся вызывающим как f-g.
pub fn formatNodeLabel(buf: []u8, g: f32, h: f32, f: f32) []const u8 {
    return std.fmt.bufPrint(buf, "g{d:.1} h{d:.1} f{d:.1}", .{ g, h, f }) catch "";
}

test "formatNodeLabel — deterministic g/h/f output" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("g0.0 h10.0 f10.0", formatNodeLabel(&buf, 0.0, 10.0, 10.0));
    try std.testing.expectEqualStrings("g3.5 h2.0 f5.5", formatNodeLabel(&buf, 3.5, 2.0, 5.5));
    // h is f-g by the caller's convention; we just format what we're given.
    try std.testing.expectEqualStrings("g12.3 h7.7 f20.0", formatNodeLabel(&buf, 12.3, 7.7, 20.0));
}

test "formatNodeLabel — rounds to one decimal" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("g1.2 h3.5 f4.6", formatNodeLabel(&buf, 1.24, 3.46, 4.55));
}

test "formatNodeLabel — tiny buffer yields empty string" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", formatNodeLabel(&buf, 1.0, 2.0, 3.0));
}
