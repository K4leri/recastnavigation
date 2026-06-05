//! Colour-scheme LEGEND (cluster E, P1-3). A 2D corner overlay that explains the
//! active ColorScheme's colour->meaning mapping, so a navmesh recoloured by
//! area/flags/component/height/cost is readable without guessing the palette.
//!
//! Two shapes of legend, chosen by scheme:
//!   - DISCRETE (area/flags/component): a list of {swatch, label} entries pulled
//!     from the live registries (area_types/poly_flags) or synthesised
//!     (component). Built by `discreteEntries`.
//!   - GRADIENT (height/cost): a green/blue->red ramp bar with numeric min/max
//!     labels. Endpoints come from color_scheme's published gradient consts (so
//!     the bar matches the fill exactly); the numeric range is passed in by the
//!     caller (poly_visit.schemeRange). Described by `gradientInfo`.
//!
//! The pure entry/gradient logic is unit-tested; `draw` is GUI (not tested).

const std = @import("std");
const recast = @import("recast-nav");
const dbg = recast.debug;

const cs = @import("color_scheme.zig");
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");

// NOTE: dvui / ui.zig are imported LAZILY inside `draw` (and its helpers) — they
// pull in dvui/GL, which the `demo-test` aggregator (recast-nav only) does not
// provide. Keeping them out of module scope lets the pure entry/gradient logic
// (and its unit tests) compile under demo-test; `draw` is GUI-only and is never
// referenced there, so its lazy imports are never analysed.

const ColorScheme = cs.ColorScheme;

/// One discrete legend row: a swatch colour (packed 0xAABBGGRR, like dbg.rgba)
/// and a human label. `label` borrows from a caller-provided `name_buf` (for the
/// synthesised "comp N" rows) or from a registry (stable for the frame).
pub const Entry = struct { color: u32, label: []const u8 };

/// Illustrative component-swatch count for the legend (real component count
/// varies per mesh; we just show the first K islands' colours).
pub const COMPONENT_SWATCHES: usize = 8;

/// Fill `out` with up to `out.len` discrete swatch entries for `scheme`; returns
/// the count written. Continuous schemes (height/cost) return 0 — the caller uses
/// `gradientInfo` instead. `name_buf` backs the synthesised component labels
/// ("comp N"); it must outlive the returned entries' use (same frame).
pub fn discreteEntries(scheme: ColorScheme, out: []Entry, name_buf: []u8) usize {
    return switch (scheme) {
        .area => blk: {
            var n: usize = 0;
            var id: usize = 0;
            while (id < area_types.MAX_AREA_TYPES and n < out.len) : (id += 1) {
                const t = area_types.get(id) orelse continue;
                out[n] = .{ .color = t.color(), .label = t.name() };
                n += 1;
            }
            break :blk n;
        },
        .flags => blk: {
            var n: usize = 0;
            var i: usize = 0;
            while (i < poly_flags.MAX_FLAGS and n < out.len) : (i += 1) {
                const bit = poly_flags.bitOf(i) orelse continue;
                const f = poly_flags.get(i) orelse continue;
                // Colour per bit value — same intToCol the .flags fill uses for a
                // single-bit poly, so the legend swatch matches a poly carrying
                // exactly that flag.
                out[n] = .{ .color = dbg.intToCol(@as(i32, bit), cs.ALPHA), .label = f.name() };
                n += 1;
            }
            break :blk n;
        },
        .component => blk: {
            // Synthesise "comp 1..K" (component ids are 1-based; see components.zig).
            var n: usize = 0;
            var off: usize = 0;
            var c: usize = 1;
            while (c <= COMPONENT_SWATCHES and n < out.len) : (c += 1) {
                const rest = name_buf[off..];
                const txt = std.fmt.bufPrint(rest, "comp {d}", .{c}) catch break;
                out[n] = .{ .color = dbg.intToCol(@as(i32, @intCast(c)), cs.ALPHA), .label = txt };
                off += txt.len;
                n += 1;
            }
            break :blk n;
        },
        .height, .cost, .region => 0,
    };
}

/// Gradient descriptor for the legend bar. For discrete schemes `is_gradient` is
/// false and the colour/label fields are unspecified (caller ignores them).
pub const Gradient = struct {
    lo_col: u32,
    hi_col: u32,
    lo_label: f32,
    hi_label: f32,
    is_gradient: bool,
};

/// Gradient endpoints + numeric min/max labels for height/cost; `is_gradient`
/// false for every discrete scheme. `lo`/`hi` are the navmesh's value range
/// (from poly_visit.schemeRange) used as the bar's end labels.
pub fn gradientInfo(scheme: ColorScheme, lo: f32, hi: f32) Gradient {
    return switch (scheme) {
        .height => .{ .lo_col = cs.HEIGHT_LO, .hi_col = cs.HEIGHT_HI, .lo_label = lo, .hi_label = hi, .is_gradient = true },
        .cost => .{ .lo_col = cs.COST_LO, .hi_col = cs.COST_HI, .lo_label = lo, .hi_label = hi, .is_gradient = true },
        else => .{ .lo_col = 0, .hi_col = 0, .lo_label = 0, .hi_label = 0, .is_gradient = false },
    };
}

// Legend layout (top-right corner, screen pixels). Mirrors the hint-overlay
// style (plain screenText, no panel chrome).
const MARGIN: f32 = 12.0;
const ROW_H: f32 = 18.0;
const SWATCH_W: f32 = 26.0;
const SWATCH_GAP: f32 = 8.0;
const BAR_W: f32 = 120.0;

/// Draw the legend for `scheme` in the top-right corner. `lo`/`hi` are the
/// height/cost numeric range (ignored for discrete schemes). Call inside the
/// dvui frame, in the worldspace-overlay block. GUI-only (not unit-tested).
/// dvui/ui are imported here (lazily) — see the module-scope note.
pub fn draw(scheme: ColorScheme, screen_w: f32, screen_h: f32, lo: f32, hi: f32) void {
    _ = screen_h;
    const dvui = @import("dvui");
    const ui = @import("../ui.zig");

    // Unpack packed 0xAABBGGRR (dbg.rgba layout) -> dvui.Color.
    const toDvui = struct {
        fn f(col: u32) dvui.Color {
            return .{
                .r = @intCast(col & 0xff),
                .g = @intCast((col >> 8) & 0xff),
                .b = @intCast((col >> 16) & 0xff),
                .a = @intCast((col >> 24) & 0xff),
            };
        }
    }.f;

    const white = dvui.Color{ .r = 235, .g = 235, .b = 235, .a = 255 };

    const grad = gradientInfo(scheme, lo, hi);
    if (grad.is_gradient) {
        // Gradient bar: short ramp of coloured glyph cells lo->hi + end labels.
        const label = switch (scheme) {
            .height => "Height",
            .cost => "Cost",
            else => "",
        };
        const x = screen_w - MARGIN - BAR_W;
        var y = MARGIN;
        ui.screenText(x, y, label, white);
        y += ROW_H;
        // Ramp: N coloured blocks interpolating lo_col..hi_col.
        const cells: usize = 12;
        const cell_w: f32 = BAR_W / @as(f32, @floatFromInt(cells));
        for (0..cells) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(cells - 1));
            const u: u32 = @intFromFloat(std.math.clamp(t, 0, 1) * 255.0);
            const col = dbg.lerpCol(grad.lo_col, grad.hi_col, u);
            ui.screenText(x + @as(f32, @floatFromInt(i)) * cell_w, y, "\u{2588}", toDvui(col));
        }
        y += ROW_H;
        var buf: [64]u8 = undefined;
        const lbl = std.fmt.bufPrint(&buf, "{d:.2}  ..  {d:.2}", .{ grad.lo_label, grad.hi_label }) catch return;
        ui.screenText(x, y, lbl, white);
        return;
    }

    // Discrete: swatch + label per entry.
    var entries: [area_types.MAX_AREA_TYPES]Entry = undefined;
    var name_buf: [COMPONENT_SWATCHES * 16]u8 = undefined;
    const n = discreteEntries(scheme, &entries, &name_buf);
    if (n == 0) return;

    const title = switch (scheme) {
        .area => "Area",
        .flags => "Flags",
        .component => "Component",
        else => "",
    };
    // Width estimate: swatch + gap + a generous label column.
    const col_w: f32 = SWATCH_W + SWATCH_GAP + 120.0;
    const x = screen_w - MARGIN - col_w;
    var y = MARGIN;
    ui.screenText(x, y, title, white);
    y += ROW_H;
    for (entries[0..n]) |e| {
        // Filled swatch as a coloured block-glyph run (no bare filled-rect screen
        // helper here; same primitive the rest of the overlay uses).
        ui.screenText(x, y, "\u{2588}\u{2588}", toDvui(e.color));
        ui.screenText(x + SWATCH_W + SWATCH_GAP, y, e.label, white);
        y += ROW_H;
    }
}

// ---------------------------------------------------------------------------
// Unit tests (pure parts only — draw is GUI).
// ---------------------------------------------------------------------------

test "discreteEntries: area yields used types' names + colours" {
    area_types.resetToBuiltins();
    var out: [area_types.MAX_AREA_TYPES]Entry = undefined;
    var nb: [128]u8 = undefined;
    const n = discreteEntries(.area, &out, &nb);
    // Six builtins seeded.
    try std.testing.expectEqual(area_types.count(), n);
    try std.testing.expect(n >= 6);
    // First entry == Ground with its registry colour.
    const g = area_types.get(0).?;
    try std.testing.expectEqualStrings("Ground", out[0].label);
    try std.testing.expectEqual(g.color(), out[0].color);
}

test "discreteEntries: area respects out.len cap" {
    area_types.resetToBuiltins();
    var out: [3]Entry = undefined;
    var nb: [128]u8 = undefined;
    const n = discreteEntries(.area, &out, &nb);
    try std.testing.expectEqual(@as(usize, 3), n);
}

test "discreteEntries: flags yields registered flags with per-bit colour" {
    poly_flags.resetToBuiltins();
    var out: [poly_flags.MAX_FLAGS]Entry = undefined;
    var nb: [128]u8 = undefined;
    const n = discreteEntries(.flags, &out, &nb);
    try std.testing.expectEqual(poly_flags.count(), n);
    try std.testing.expect(n >= 4); // walk/swim/door/jump
    // First registered flag = walk (bit 0x01), coloured via intToCol(bit).
    try std.testing.expectEqualStrings("walk", out[0].label);
    try std.testing.expectEqual(dbg.intToCol(@as(i32, poly_flags.bitOf(0).?), cs.ALPHA), out[0].color);
}

test "discreteEntries: component yields K synthesised comp rows" {
    var out: [COMPONENT_SWATCHES]Entry = undefined;
    var nb: [COMPONENT_SWATCHES * 16]u8 = undefined;
    const n = discreteEntries(.component, &out, &nb);
    try std.testing.expectEqual(COMPONENT_SWATCHES, n);
    try std.testing.expectEqualStrings("comp 1", out[0].label);
    try std.testing.expectEqualStrings("comp 8", out[COMPONENT_SWATCHES - 1].label);
    // Colour matches the fill's intToCol(component_id).
    try std.testing.expectEqual(dbg.intToCol(1, cs.ALPHA), out[0].color);
}

test "discreteEntries: continuous schemes return 0" {
    var out: [4]Entry = undefined;
    var nb: [128]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), discreteEntries(.height, &out, &nb));
    try std.testing.expectEqual(@as(usize, 0), discreteEntries(.cost, &out, &nb));
}

test "gradientInfo: height/cost are gradients with the right endpoints + labels" {
    const h = gradientInfo(.height, -3.5, 12.0);
    try std.testing.expect(h.is_gradient);
    try std.testing.expectEqual(cs.HEIGHT_LO, h.lo_col);
    try std.testing.expectEqual(cs.HEIGHT_HI, h.hi_col);
    try std.testing.expectEqual(@as(f32, -3.5), h.lo_label);
    try std.testing.expectEqual(@as(f32, 12.0), h.hi_label);

    const c = gradientInfo(.cost, 1.0, 10.0);
    try std.testing.expect(c.is_gradient);
    try std.testing.expectEqual(cs.COST_LO, c.lo_col);
    try std.testing.expectEqual(cs.COST_HI, c.hi_col);
}

test "gradientInfo: discrete schemes are not gradients" {
    try std.testing.expect(!gradientInfo(.area, 0, 1).is_gradient);
    try std.testing.expect(!gradientInfo(.flags, 0, 1).is_gradient);
    try std.testing.expect(!gradientInfo(.component, 0, 1).is_gradient);
}
