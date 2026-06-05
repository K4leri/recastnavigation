//! MINIMAP overview + FLY-TO (cluster E, P1-4). A top-down 2D overview of the
//! scene drawn inside a dvui window: the scene XZ bbox, the tile grid (Tile/Temp
//! samples), the camera position+heading marker, and off-mesh / convex-volume
//! markers. Clicking the map — or the tile/poly-ref "Go" entries — flies the 3D
//! camera to that spot.
//!
//! DEMO OVERLAY only — faithful core (src/*) untouched. The load-bearing geometry
//! (tile centre, world<->map pixel mapping, hex parse) is factored into pure,
//! unit-testable helpers here; the dvui draw + UI wiring lives in main.zig.

const std = @import("std");
const dvui = @import("dvui");

/// Live global: whether the Minimap window is shown. Toggled by a Properties
/// checkbox, like show_flags / app.show_log.
pub var show: bool = false;

// ---------------------------------------------------------------------------
// Pure helpers (unit-tested)
// ---------------------------------------------------------------------------

/// World XZ centre of tile (tx,ty) for a tiled navmesh whose tile-space origin is
/// `orig` with tile size (tw,th). 1:1 with NavMesh tile-space:
///   cx = orig.x + (tx + 0.5) * tw ;  cz = orig.z + (ty + 0.5) * th.
/// Returns {cx, cz}. (Y is supplied separately by the caller — usually bbox mid.)
pub fn tileCenter(orig: [3]f32, tw: f32, th: f32, tx: i32, ty: i32) [2]f32 {
    const fx: f32 = @floatFromInt(tx);
    const fy: f32 = @floatFromInt(ty);
    return .{
        orig[0] + (fx + 0.5) * tw,
        orig[2] + (fy + 0.5) * th,
    };
}

/// Map a world XZ point into minimap pixel space. The map rect is the on-screen
/// box (px origin `mx,my`, size `mw,mh`); the world XZ bbox is [bmin_x..bmax_x] x
/// [bmin_z..bmax_z]. X maps left->right; Z maps top->bottom (screen-down = +Z, a
/// conventional top-down map). Degenerate bbox (zero extent) maps to the centre.
pub fn worldToMap(
    wx: f32,
    wz: f32,
    bmin_x: f32,
    bmin_z: f32,
    bmax_x: f32,
    bmax_z: f32,
    mx: f32,
    my: f32,
    mw: f32,
    mh: f32,
) [2]f32 {
    const ex = bmax_x - bmin_x;
    const ez = bmax_z - bmin_z;
    const fx: f32 = if (ex > 0) (wx - bmin_x) / ex else 0.5;
    const fz: f32 = if (ez > 0) (wz - bmin_z) / ez else 0.5;
    return .{ mx + std.math.clamp(fx, 0, 1) * mw, my + std.math.clamp(fz, 0, 1) * mh };
}

/// Inverse of `worldToMap`: a minimap pixel -> world XZ. Used for click-to-fly.
/// Pixels outside the rect are clamped to the bbox edges.
pub fn mapToWorld(
    px: f32,
    py: f32,
    bmin_x: f32,
    bmin_z: f32,
    bmax_x: f32,
    bmax_z: f32,
    mx: f32,
    my: f32,
    mw: f32,
    mh: f32,
) [2]f32 {
    const fx: f32 = if (mw > 0) std.math.clamp((px - mx) / mw, 0, 1) else 0.5;
    const fz: f32 = if (mh > 0) std.math.clamp((py - my) / mh, 0, 1) else 0.5;
    return .{ bmin_x + fx * (bmax_x - bmin_x), bmin_z + fz * (bmax_z - bmin_z) };
}

/// Parse a poly-ref hex string (optionally "0x"-prefixed, case-insensitive) into a
/// u32. Trims surrounding whitespace. Returns null on empty / malformed input.
pub fn parseHexRef(s: []const u8) ?u32 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and (std.mem.eql(u8, t[0..2], "0x") or std.mem.eql(u8, t[0..2], "0X"))) {
        t = t[2..];
    }
    if (t.len == 0) return null;
    return std.fmt.parseInt(u32, t, 16) catch null;
}

// ---------------------------------------------------------------------------
// dvui draw primitives (not unit-tested — GUI; thin wrappers over dvui.Path)
// ---------------------------------------------------------------------------

/// One physical-pixel line segment in the given colour.
pub fn line(x0: f32, y0: f32, x1: f32, y1: f32, col: dvui.Color, thickness: f32) void {
    var b = dvui.Path.Builder.init(dvui.currentWindow().lifo());
    defer b.deinit();
    b.addPoint(.{ .x = x0, .y = y0 });
    b.addPoint(.{ .x = x1, .y = y1 });
    b.build().stroke(.{ .thickness = thickness, .color = col, .closed = false });
}

/// A small filled square (a point marker), centred on (cx,cy), side `s` px.
pub fn dot(cx: f32, cy: f32, s: f32, col: dvui.Color) void {
    const r: dvui.Rect.Physical = .{ .x = cx - s * 0.5, .y = cy - s * 0.5, .w = s, .h = s };
    r.fill(.{}, .{ .color = col });
}

/// An axis-aligned rectangle OUTLINE (4 strokes), in physical pixels.
pub fn rectOutline(x: f32, y: f32, w: f32, h: f32, col: dvui.Color, thickness: f32) void {
    line(x, y, x + w, y, col, thickness);
    line(x + w, y, x + w, y + h, col, thickness);
    line(x + w, y + h, x, y + h, col, thickness);
    line(x, y + h, x, y, col, thickness);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "tileCenter: centre of tile (0,0) is half a tile from origin" {
    const c = tileCenter(.{ 0, 0, 0 }, 10, 10, 0, 0);
    try std.testing.expectEqual(@as(f32, 5), c[0]);
    try std.testing.expectEqual(@as(f32, 5), c[1]);
}

test "tileCenter: offset origin + non-square tiles + tile (2,3)" {
    const c = tileCenter(.{ -100, 0, 50 }, 8, 16, 2, 3);
    try std.testing.expectEqual(@as(f32, -100 + 2.5 * 8), c[0]); // -80
    try std.testing.expectEqual(@as(f32, 50 + 3.5 * 16), c[1]); // 106
}

test "worldToMap: corners + centre" {
    // bbox [0..100]x[0..200] into a 50x50 map at (10,20).
    const tl = worldToMap(0, 0, 0, 0, 100, 200, 10, 20, 50, 50);
    try std.testing.expectEqual(@as(f32, 10), tl[0]);
    try std.testing.expectEqual(@as(f32, 20), tl[1]);
    const br = worldToMap(100, 200, 0, 0, 100, 200, 10, 20, 50, 50);
    try std.testing.expectEqual(@as(f32, 60), br[0]);
    try std.testing.expectEqual(@as(f32, 70), br[1]);
    const mid = worldToMap(50, 100, 0, 0, 100, 200, 10, 20, 50, 50);
    try std.testing.expectEqual(@as(f32, 35), mid[0]);
    try std.testing.expectEqual(@as(f32, 45), mid[1]);
}

test "worldToMap: degenerate bbox -> centre" {
    const c = worldToMap(5, 5, 0, 0, 0, 0, 0, 0, 100, 100);
    try std.testing.expectEqual(@as(f32, 50), c[0]);
    try std.testing.expectEqual(@as(f32, 50), c[1]);
}

test "mapToWorld inverts worldToMap" {
    const w = mapToWorld(35, 45, 0, 0, 100, 200, 10, 20, 50, 50);
    try std.testing.expectApproxEqAbs(@as(f32, 50), w[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), w[1], 1e-3);
}

test "parseHexRef: with and without prefix, case-insensitive, whitespace" {
    try std.testing.expectEqual(@as(?u32, 0x4002A), parseHexRef("0x4002A"));
    try std.testing.expectEqual(@as(?u32, 0x4002A), parseHexRef("4002a"));
    try std.testing.expectEqual(@as(?u32, 0xFF), parseHexRef("  0XfF \n"));
    try std.testing.expectEqual(@as(?u32, 0), parseHexRef("0"));
}

test "parseHexRef: empty / malformed -> null" {
    try std.testing.expectEqual(@as(?u32, null), parseHexRef(""));
    try std.testing.expectEqual(@as(?u32, null), parseHexRef("0x"));
    try std.testing.expectEqual(@as(?u32, null), parseHexRef("xyz"));
    try std.testing.expectEqual(@as(?u32, null), parseHexRef("   "));
}
