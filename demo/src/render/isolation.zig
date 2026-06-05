//! Demo-side navmesh CLIPPING + ISOLATION filter (cluster E, P0-2). Pure predicate
//! logic: given one polygon's centroid height and identity (tile coords / area /
//! flags), decide whether to DRAW, DIM, or HIDE it. This lets overlapping floors
//! (parking decks, multi-storey buildings) that currently Z-fight into one blob be
//! read floor-by-floor.
//!
//! NAVMESH-ONLY: this filters the navmesh debug draw only; the input geometry mesh
//! is NOT clipped (a GL clip-plane is a noted future enhancement).
//!
//! No NavMesh traversal, no GL — just a verdict function so the load-bearing logic
//! is unit-testable. The actual draw lives in poly_visit.fillNavMeshFiltered.

const std = @import("std");

/// Height clipping mode. `off` disables clipping; the others test a poly's
/// centroid height against `clip_y` (and `slab_thickness` for the band).
pub const ClipMode = enum { off, above, below, slab };

/// Isolation mode applied to polys that SURVIVE the clip test.
pub const IsoMode = enum { none, show_only, dim_others };

/// Which identity key isolation matches on.
pub const IsoKey = enum { tile, area, flags };

/// Combined clip + isolation parameters. Shared global lives in filter_state.zig.
pub const Filter = struct {
    clip_mode: ClipMode = .off,
    clip_y: f32 = 0,
    slab_thickness: f32 = 1.0, // half-thickness for slab band [clip_y - t, clip_y + t]
    iso_mode: IsoMode = .none,
    iso_key: IsoKey = .tile,
    iso_tile_x: i32 = 0,
    iso_tile_y: i32 = 0, // for IsoKey.tile
    iso_area: u8 = 0, // for IsoKey.area
    iso_flags: u16 = 0, // for IsoKey.flags (match = any bit overlaps)

    /// True if any clipping or isolation is active (caller uses this to pick the
    /// filtered draw path vs the faithful unfiltered one).
    pub fn active(self: Filter) bool {
        return self.clip_mode != .off or self.iso_mode != .none;
    }
};

/// Per-poly verdict for the filtered draw.
pub const Verdict = enum { draw, dim, hide };

/// Decide how to render a poly given its centroid height and identity.
///
/// CLIP first: `above` -> keep polys with y >= clip_y; `below` -> y <= clip_y;
/// `slab` -> |y - clip_y| <= slab_thickness. A poly failing the clip test is
/// HIDDEN outright (clip-hide BEATS any isolation match).
///
/// Then ISOLATION on the survivors: `none` -> draw; `show_only` -> draw if it
/// MATCHES the key/value else hide; `dim_others` -> draw if match else DIM.
/// Match: `tile` -> (tx,ty) equal; `area` -> area == iso_area; `flags` ->
/// (poly_flags & iso_flags) != 0.
pub fn verdictFor(f: Filter, centroid_y: f32, tile_x: i32, tile_y: i32, area: u8, poly_flags: u16) Verdict {
    // --- CLIP (boundaries inclusive) ---
    const clipped_out = switch (f.clip_mode) {
        .off => false,
        .above => centroid_y < f.clip_y, // keep y >= clip_y
        .below => centroid_y > f.clip_y, // keep y <= clip_y
        .slab => @abs(centroid_y - f.clip_y) > f.slab_thickness, // keep within +-t
    };
    if (clipped_out) return .hide;

    // --- ISOLATION (only on clip survivors) ---
    if (f.iso_mode == .none) return .draw;

    const match = switch (f.iso_key) {
        .tile => tile_x == f.iso_tile_x and tile_y == f.iso_tile_y,
        .area => area == f.iso_area,
        .flags => (poly_flags & f.iso_flags) != 0,
    };

    return switch (f.iso_mode) {
        .none => .draw, // unreachable (handled above), kept exhaustive
        .show_only => if (match) .draw else .hide,
        .dim_others => if (match) .draw else .dim,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "active(): off+none -> false; any clip or iso -> true" {
    try std.testing.expect(!(Filter{}).active());
    try std.testing.expect((Filter{ .clip_mode = .above }).active());
    try std.testing.expect((Filter{ .iso_mode = .show_only }).active());
}

test "clip off + iso none -> draw" {
    const f = Filter{};
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 5.0, 0, 0, 0, 0));
}

test "clip above: keep y >= clip_y, boundary inclusive" {
    const f = Filter{ .clip_mode = .above, .clip_y = 10.0 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 10.0, 0, 0, 0, 0)); // exactly at plane: kept
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 12.0, 0, 0, 0, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 9.99, 0, 0, 0, 0));
}

test "clip below: keep y <= clip_y, boundary inclusive" {
    const f = Filter{ .clip_mode = .below, .clip_y = 10.0 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 10.0, 0, 0, 0, 0)); // exactly at plane: kept
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 8.0, 0, 0, 0, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 10.01, 0, 0, 0, 0));
}

test "clip slab: include within +-t, exclude outside; boundaries inclusive" {
    const f = Filter{ .clip_mode = .slab, .clip_y = 10.0, .slab_thickness = 2.0 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 10.0, 0, 0, 0, 0)); // centre
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 12.0, 0, 0, 0, 0)); // +t boundary
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 8.0, 0, 0, 0, 0)); // -t boundary
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 12.01, 0, 0, 0, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 7.99, 0, 0, 0, 0));
}

test "show_only by tile: matching draws, non-matching hides" {
    const f = Filter{ .iso_mode = .show_only, .iso_key = .tile, .iso_tile_x = 3, .iso_tile_y = 4 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 0, 3, 4, 0, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 0, 3, 5, 0, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 0, 2, 4, 0, 0));
}

test "show_only by area" {
    const f = Filter{ .iso_mode = .show_only, .iso_key = .area, .iso_area = 7 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 0, 0, 0, 7, 0));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 0, 0, 0, 8, 0));
}

test "show_only by flags: any overlapping bit matches" {
    const f = Filter{ .iso_mode = .show_only, .iso_key = .flags, .iso_flags = 0b0110 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 0, 0, 0, 0, 0b0100)); // one bit overlaps
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 0, 0, 0, 0, 0b0010));
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 0, 0, 0, 0, 0b1001)); // no overlap
}

test "dim_others: matching draws, non-matching dims (not hidden)" {
    const f = Filter{ .iso_mode = .dim_others, .iso_key = .area, .iso_area = 1 };
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 0, 0, 0, 1, 0));
    try std.testing.expectEqual(Verdict.dim, verdictFor(f, 0, 0, 0, 2, 0));
}

test "combined clip + iso: clipped-out poly is hide regardless of iso match" {
    // Poly matches the iso key (area==5) but fails the clip-above test -> HIDE.
    const f = Filter{
        .clip_mode = .above,
        .clip_y = 10.0,
        .iso_mode = .show_only,
        .iso_key = .area,
        .iso_area = 5,
    };
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 5.0, 0, 0, 5, 0)); // below plane: hide despite match
    try std.testing.expectEqual(Verdict.draw, verdictFor(f, 11.0, 0, 0, 5, 0)); // above plane + match: draw
    try std.testing.expectEqual(Verdict.hide, verdictFor(f, 11.0, 0, 0, 6, 0)); // above plane but no match: hide
}
