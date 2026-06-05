//! Funnel / portal debug-overlay helpers — pure (no GL/UI) bits factored out of
//! the NavMeshTester funnel visualizer so they can be unit-tested.
//!
//! Чистые помощники для оверлея «воронки» (funnel / string-pulling): предикаты
//! по флагам straight-path вершин (START/END/OFFMESH) и середина портала. Рендер
//! и буферы живут в tool_navmesh_tester.zig; здесь — только детерминированная
//! логика (тестируемая).

const std = @import("std");

// Straight-path vertex flag bits (1-в-1 с detour common.zig STRAIGHTPATH_*).
// Дублируем как u8-константы, чтобы модуль оставался GL/UI-free и тестируемым.
pub const SP_START: u8 = 0x01; // DT_STRAIGHTPATH_START
pub const SP_END: u8 = 0x02; // DT_STRAIGHTPATH_END
pub const SP_OFFMESH: u8 = 0x04; // DT_STRAIGHTPATH_OFFMESH_CONNECTION

// findStraightPath `options` mask (1-в-1 с detour common.zig STRAIGHTPATH_*).
pub const OPT_ALL_CROSSINGS: u32 = 0x02; // DT_STRAIGHTPATH_ALL_CROSSINGS

/// True if the waypoint flags mark the start vertex of the straight path.
pub fn isStart(flags: u8) bool {
    return (flags & SP_START) != 0;
}

/// True if the waypoint flags mark the end vertex of the straight path.
pub fn isEnd(flags: u8) bool {
    return (flags & SP_END) != 0;
}

/// True if the waypoint flags mark an off-mesh-connection start vertex.
pub fn isOffMesh(flags: u8) bool {
    return (flags & SP_OFFMESH) != 0;
}

/// True if the waypoint is a funnel "turn" (apex) point: a corner produced by
/// string-pulling that is NOT the start, end, or an off-mesh connection. With
/// ALL_CROSSINGS the path also contains plain portal-crossing vertices (flags==0
/// AND a portal ref); without ALL_CROSSINGS every interior vertex IS a turn — so
/// this predicate is precise only for the no-crossings buffer, where any interior
/// (non-start/end/offmesh) vertex is a genuine funnel apex.
///
/// True — вершина является поворотом воронки (apex): интерьерный угол string-
/// pulling, не start/end/offmesh. Точна для буфера БЕЗ ALL_CROSSINGS.
pub fn isTurn(flags: u8) bool {
    return !isStart(flags) and !isEnd(flags) and !isOffMesh(flags);
}

/// Midpoint of a portal segment (left/right endpoints) — где рисуется подпись
/// "P{i}". Pure averaging; y included so the label floats at the portal height.
pub fn portalMid(left: [3]f32, right: [3]f32) [3]f32 {
    return .{
        (left[0] + right[0]) * 0.5,
        (left[1] + right[1]) * 0.5,
        (left[2] + right[2]) * 0.5,
    };
}

test "isStart/isEnd/isOffMesh — flag bit predicates" {
    try std.testing.expect(isStart(SP_START));
    try std.testing.expect(!isStart(SP_END));
    try std.testing.expect(isEnd(SP_END));
    try std.testing.expect(!isEnd(SP_START));
    try std.testing.expect(isOffMesh(SP_OFFMESH));
    try std.testing.expect(!isOffMesh(SP_START));
    // combined bits
    try std.testing.expect(isStart(SP_START | SP_OFFMESH));
    try std.testing.expect(isOffMesh(SP_START | SP_OFFMESH));
}

test "isTurn — interior vertices are turns, endpoints/offmesh are not" {
    try std.testing.expect(isTurn(0)); // plain interior vertex
    try std.testing.expect(!isTurn(SP_START));
    try std.testing.expect(!isTurn(SP_END));
    try std.testing.expect(!isTurn(SP_OFFMESH));
    try std.testing.expect(!isTurn(SP_START | SP_END));
}

test "portalMid — averages left/right endpoints" {
    const m = portalMid(.{ 0, 2, 0 }, .{ 4, 6, 8 });
    try std.testing.expectEqual(@as(f32, 2), m[0]);
    try std.testing.expectEqual(@as(f32, 4), m[1]);
    try std.testing.expectEqual(@as(f32, 4), m[2]);
}
