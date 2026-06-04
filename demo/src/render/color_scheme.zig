//! Colour schemes for navmesh visualisation (foundation render layer, §3.c).
//! Pure mapping from one polygon's properties to an RGBA colour, so every debug
//! visualiser (cluster E and others) recolours the navmesh by area / region /
//! flags / height / connected-component / movement-cost through ONE place,
//! instead of hardcoding palettes. This module only computes a colour; applying
//! it during a navmesh traversal is a separate module (step 3b).

const std = @import("std");
const recast = @import("recast-nav");
const dbg = recast.debug; // rgba / intToCol / lerpCol — faithful core helpers

pub const ColorScheme = enum { area, region, flags, height, component, cost };

/// Per-polygon inputs a scheme may use. The caller fills the fields relevant to
/// the active scheme; the rest may stay at their defaults.
pub const PolyColorCtx = struct {
    /// Precomputed area colour (from the area-type registry) — used by `.area`.
    area_col: u32 = 0,
    region: i32 = 0,
    component: i32 = 0,
    flags: u16 = 0,
    height: f32 = 0,
    height_min: f32 = 0,
    height_max: f32 = 0,
    cost: f32 = 0,
    cost_min: f32 = 0, // Detour area costs are non-negative, so default min is 0
    cost_max: f32 = 0,
};

const ALPHA: i32 = 192; // ~75% opaque — standard navmesh overlay alpha

// Gradient endpoints (dbg.rgba is an inline fn, so these fold at comptime).
const HEIGHT_LO: u32 = dbg.rgba(40, 90, 200, 192); // low  = blue
const HEIGHT_HI: u32 = dbg.rgba(220, 70, 40, 192); // high = red
const COST_LO: u32 = dbg.rgba(60, 180, 70, 192); // cheap = green
const COST_HI: u32 = dbg.rgba(200, 50, 40, 192); // dear  = red

/// Clamp (v - lo) / (hi - lo) to [0,1]; returns 0 when the range is empty.
fn norm(v: f32, lo: f32, hi: f32) f32 {
    if (hi <= lo) return 0;
    return std.math.clamp((v - lo) / (hi - lo), 0.0, 1.0);
}

/// Blend colours a->b by t in [0,1]; t is truncated (not rounded) to [0,255].
fn gradient(a: u32, b: u32, t: f32) u32 {
    const u: u32 = @intFromFloat(std.math.clamp(t, 0.0, 1.0) * 255.0);
    return dbg.lerpCol(a, b, u);
}

/// RGBA colour for one polygon under the given scheme.
pub fn colorForPoly(scheme: ColorScheme, ctx: PolyColorCtx) u32 {
    return switch (scheme) {
        .area => ctx.area_col,
        .region => dbg.intToCol(ctx.region, ALPHA),
        .component => dbg.intToCol(ctx.component, ALPHA),
        .flags => dbg.intToCol(@as(i32, ctx.flags), ALPHA),
        .height => gradient(HEIGHT_LO, HEIGHT_HI, norm(ctx.height, ctx.height_min, ctx.height_max)),
        .cost => gradient(COST_LO, COST_HI, norm(ctx.cost, ctx.cost_min, ctx.cost_max)),
    };
}

test "area scheme returns the precomputed area colour verbatim" {
    const col: u32 = 0x8011_2233;
    try std.testing.expectEqual(col, colorForPoly(.area, .{ .area_col = col }));
}

test "region/component/flags are deterministic and match intToCol" {
    try std.testing.expectEqual(dbg.intToCol(5, ALPHA), colorForPoly(.region, .{ .region = 5 }));
    try std.testing.expectEqual(dbg.intToCol(7, ALPHA), colorForPoly(.component, .{ .component = 7 }));
    try std.testing.expectEqual(dbg.intToCol(@as(i32, 0x0A), ALPHA), colorForPoly(.flags, .{ .flags = 0x0A }));
    // distinct region -> distinct deterministic colour
    try std.testing.expectEqual(dbg.intToCol(0, ALPHA), colorForPoly(.region, .{ .region = 0 }));
}

test "height gradient hits endpoints; empty range -> low" {
    const lo = colorForPoly(.height, .{ .height = 0, .height_min = 0, .height_max = 10 });
    const hi = colorForPoly(.height, .{ .height = 10, .height_min = 0, .height_max = 10 });
    try std.testing.expectEqual(HEIGHT_LO, lo);
    try std.testing.expectEqual(HEIGHT_HI, hi);
    const empty = colorForPoly(.height, .{ .height = 5, .height_min = 3, .height_max = 3 });
    try std.testing.expectEqual(HEIGHT_LO, empty);
}

test "cost gradient hits endpoints" {
    try std.testing.expectEqual(COST_LO, colorForPoly(.cost, .{ .cost = 0, .cost_max = 4 }));
    try std.testing.expectEqual(COST_HI, colorForPoly(.cost, .{ .cost = 4, .cost_max = 4 }));
    // degenerate range: cost_max == cost_min -> low endpoint, no divide-by-zero
    try std.testing.expectEqual(COST_LO, colorForPoly(.cost, .{ .cost = 1, .cost_max = 0 }));
}
