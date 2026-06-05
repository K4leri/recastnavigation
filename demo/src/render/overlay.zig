//! Worldspace POLY OVERLAY LABELS (cluster E, P1-2). A short text label drawn over
//! polygons identifying each one: poly-ref (hex), centroid (x,y,z), area name and
//! movement cost. Helps "what poly is this / how expensive is it" navigation.
//!
//! DEMO OVERLAY only — the faithful core (src/*) is untouched. The pure label
//! formatter lives here so it is deterministic + unit-testable; the actual
//! worldToScreen + screenText draw lives in main.zig's worldspace-text block
//! (it needs the live Camera/viewport), gated under view_state.groups.labels.

const std = @import("std");

/// What gets labelled this frame.
///   none    — no overlay labels (default; keeps the scene clean).
///   hovered — one label, on the poly under the cursor.
///   all     — a label on every visible poly (auto-downgrades to `hovered` when
///             the would-be label count exceeds `MAX_ALL_LABELS`, a perf guard).
pub const LabelMode = enum { none, hovered, all };

/// Live global, mirroring scheme_state/filter_state: the Properties UI sets it,
/// the render block reads it. Defaults to `none`.
pub var mode: LabelMode = .none;

/// Perf cap for `all` mode: if more than this many polys would be labelled in one
/// frame, the render path downgrades to `hovered` for that frame (drawing hundreds
/// of overlapping worldspace strings is both unreadable and slow).
pub const MAX_ALL_LABELS: usize = 200;

/// Format one poly's label into `buf`, returning the written slice. Pure — no GL,
/// no NavMesh traversal; the caller supplies the already-decoded values.
///
/// Layout: "0x<REF> | (<x>, <y>, <z>) | <area_name> c<cost>"
/// e.g. "0x4002A | (12.3, 0.5, -7.1) | Ground c1.0".
///
/// Buffer-cap safe: on overflow falls back to the bare ref (which always fits in a
/// reasonable buffer); if even that overflows, returns an empty slice.
pub fn formatLabel(
    buf: []u8,
    ref: u32,
    cx: f32,
    cy: f32,
    cz: f32,
    area: u8,
    area_name: []const u8,
    cost: f32,
) []const u8 {
    _ = area; // area id is encoded via its name/cost; kept in the signature so
    // callers don't have to look the id up twice and a future format can show it.
    return std.fmt.bufPrint(
        buf,
        "0x{X} | ({d:.1}, {d:.1}, {d:.1}) | {s} c{d:.1}",
        .{ ref, cx, cy, cz, area_name, cost },
    ) catch std.fmt.bufPrint(buf, "0x{X}", .{ref}) catch "";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "formatLabel: deterministic string for known inputs" {
    var buf: [128]u8 = undefined;
    const s = formatLabel(&buf, 0x4002A, 12.34, 0.5, -7.1, 0, "Ground", 1.0);
    try std.testing.expectEqualStrings("0x4002A | (12.3, 0.5, -7.1) | Ground c1.0", s);
}

test "formatLabel: negative coords + multi-char area + non-integer cost" {
    var buf: [128]u8 = undefined;
    const s = formatLabel(&buf, 1, -0.04, 100.0, -250.55, 1, "Water", 10.0);
    try std.testing.expectEqualStrings("0x1 | (-0.0, 100.0, -250.6) | Water c10.0", s);
}

test "formatLabel: overflow falls back to bare ref" {
    // Buffer too small for the full label but big enough for "0x<REF>".
    var buf: [12]u8 = undefined;
    const s = formatLabel(&buf, 0xABCDE, 1.0, 2.0, 3.0, 0, "VeryLongAreaName", 1.0);
    try std.testing.expectEqualStrings("0xABCDE", s);
}

test "formatLabel: buffer too small even for ref -> empty" {
    var buf: [2]u8 = undefined; // can't hold "0x1"
    const s = formatLabel(&buf, 1, 1, 2, 3, 0, "X", 1.0);
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "MAX_ALL_LABELS is a sane positive cap" {
    try std.testing.expect(MAX_ALL_LABELS > 0 and MAX_ALL_LABELS <= 1000);
}
