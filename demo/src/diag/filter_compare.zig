//! Side-by-side filter comparison (cluster A, A4). Run the SAME start/end route
//! query under up to THREE different QueryFilters at once, and report each
//! resulting route (its polygon count + an approximate total cost + whether it
//! reaches the end). The demo renders each route in a distinct colour with a
//! legend — answering "why does the route differ when I change the filter /
//! exclude a flag?".
//!
//! Each Variant is a comparison slot: an include/exclude mask pair + a colour +
//! a short label. To run a variant we COPY the base filter (a value type — area
//! costs and the neutral state are preserved), override its include/exclude
//! flags, then run findPath into that variant's scratch corridor.
//!
//! COST APPROXIMATION (documented, reused from reachability.zig): the faithful
//! getCost needs portal midpoints (heavier). For a debug legend we sum, over the
//! route's consecutive poly pairs, distance(centroid_i, centroid_{i+1}) *
//! areaCost(area_{i+1}) — exactly `reachability.edgeWeight` with poly CENTROIDS.
//! This is the same shape as the heatmap flood weight; good enough to RANK why
//! one filter's route is dearer than another's. (v1 varies only flags — area
//! costs are taken from the base filter for every variant. Varying per-area cost
//! per variant is a documented possible extension.)
//!
//! No core changes: read-only over findPath + tile verts. Recomputed only on
//! recalc / Run (never per frame) — see the tester's wiring.
//!
//! Сравнение фильтров бок-о-бок: один и тот же запрос маршрута под 2-3 разными
//! QueryFilter; каждый маршрут своим цветом + легенда (кол-во поли + стоимость).

const std = @import("std");
const recast = @import("recast-nav");
const reachability = @import("reachability.zig");

const dt = recast.detour;
const PolyRef = dt.PolyRef;
const NavMesh = dt.NavMesh;
const QueryFilter = dt.QueryFilter;

pub const MAX_VARIANTS: usize = 3;
pub const MAX_POLYS: usize = 256; // mirror the tester's corridor cap
const LABEL_CAP: usize = 24;

/// A single comparison slot: a filter defined by its include/exclude masks, the
/// colour its route renders in, and a short label. `enabled` gates whether the
/// variant participates in a Run.
pub const Variant = struct {
    enabled: bool = false,
    include: u16 = 0,
    exclude: u16 = 0,
    color: u32 = 0,
    label_buf: [LABEL_CAP]u8 = [_]u8{0} ** LABEL_CAP,
    label_len: u8 = 0,

    pub fn label(self: *const Variant) []const u8 {
        return self.label_buf[0..self.label_len];
    }
    pub fn setLabel(self: *Variant, s: []const u8) void {
        const n = @min(s.len, LABEL_CAP);
        @memcpy(self.label_buf[0..n], s[0..n]);
        self.label_len = @intCast(n);
    }
};

/// Per-variant result of the last Run.
pub const Result = struct {
    npolys: usize = 0,
    cost: f32 = 0,
    reaches: bool = false,
    valid: bool = false, // a Run produced a corridor for this variant
};

/// Comparison state owned by the tester. `variants` are user-configured slots;
/// `results` + `polys` hold the last Run's per-variant route. Routes live in a
/// fixed scratch (no per-frame allocation).
pub const Compare = struct {
    on: bool = false,
    variants: [MAX_VARIANTS]Variant = undefined,
    results: [MAX_VARIANTS]Result = .{ .{}, .{}, .{} },
    polys: [MAX_VARIANTS][MAX_POLYS]PolyRef = undefined,

    /// Default three distinct colours: magenta / cyan / orange.
    pub fn init() Compare {
        var c = Compare{};
        const dbg = recast.debug;
        const defaults = [MAX_VARIANTS]struct { col: u32, name: []const u8 }{
            .{ .col = dbg.rgba(255, 0, 200, 255), .name = "F1" },
            .{ .col = dbg.rgba(0, 220, 220, 255), .name = "F2" },
            .{ .col = dbg.rgba(255, 150, 0, 255), .name = "F3" },
        };
        for (&c.variants, 0..) |*v, i| {
            v.* = .{ .enabled = false, .include = 0, .exclude = 0, .color = defaults[i].col };
            v.setLabel(defaults[i].name);
        }
        return c;
    }

    /// Number of currently enabled variants.
    pub fn enabledCount(self: *const Compare) usize {
        var n: usize = 0;
        for (&self.variants) |*v| {
            if (v.enabled) n += 1;
        }
        return n;
    }

    /// Run the comparison: for each ENABLED variant, build a filter from `base`
    /// (a value-type copy — keeps the registry area costs) with the variant's
    /// include/exclude, run findPath into that variant's scratch, then store
    /// npolys + the computed total cost + whether it reaches `end_ref`.
    ///
    /// Disabled variants are marked invalid. Called ONLY on recalc / Run.
    ///
    /// Запуск сравнения: для каждого включённого варианта — копия base-фильтра с
    /// его include/exclude, findPath в свой буфер, сумма стоимости + reaches.
    pub fn run(
        self: *Compare,
        query: *dt.NavMeshQuery,
        nav: *const NavMesh,
        start_ref: PolyRef,
        end_ref: PolyRef,
        spos: *const [3]f32,
        epos: *const [3]f32,
        base_filter: *const QueryFilter,
    ) void {
        for (&self.variants, 0..) |*v, i| {
            self.results[i] = .{};
            if (!v.enabled) continue;
            if (start_ref == 0 or end_ref == 0) {
                self.results[i].valid = true; // ran, but no endpoints -> 0 polys
                continue;
            }

            // Value-type copy of the base (preserves area costs) + override flags.
            var f = base_filter.*;
            f.setIncludeFlags(v.include);
            f.setExcludeFlags(v.exclude);

            var n: usize = 0;
            _ = query.findPath(start_ref, end_ref, spos, epos, &f, self.polys[i][0..], &n) catch {};
            self.results[i] = .{
                .npolys = n,
                .cost = routeCost(nav, &f, self.polys[i][0..n]),
                .reaches = n > 0 and self.polys[i][n - 1] == end_ref,
                .valid = true,
            };
        }
    }

    /// Read-only access to a variant's last route (only valid when results[i].valid).
    pub fn route(self: *const Compare, i: usize) []const PolyRef {
        return self.polys[i][0..self.results[i].npolys];
    }
};

/// Centroid (average of the poly's tile.verts). Mirrors reachability.polyCentroid
/// / the tester's getPolyCenter. Returns origin for an empty poly.
fn polyCentroid(tile: *const dt.MeshTile, p: *const dt.Poly) [3]f32 {
    var c = [3]f32{ 0, 0, 0 };
    const nv: usize = p.vert_count;
    if (nv == 0) return c;
    for (0..nv) |i| {
        const vi = @as(usize, p.verts[i]) * 3;
        c[0] += tile.verts[vi];
        c[1] += tile.verts[vi + 1];
        c[2] += tile.verts[vi + 2];
    }
    const s = 1.0 / @as(f32, @floatFromInt(nv));
    c[0] *= s;
    c[1] *= s;
    c[2] *= s;
    return c;
}

/// Pure cost-sum over a centroid sequence: sum over consecutive pairs of
/// `reachability.edgeWeight(centroid_i, centroid_{i+1}, area_cost_{i+1})`.
/// `area_costs[k]` is the per-area movement cost of poly k (the DEST cost is used
/// for edge k-1 -> k, matching the faithful getCost shape). Length must match
/// `centroids`; a 0/1-element sequence costs 0. Unit-tested.
///
/// Чистая сумма стоимости по последовательности центроидов (для юнит-теста).
pub fn costSum(centroids: []const [3]f32, area_costs: []const f32) f32 {
    if (centroids.len < 2) return 0;
    std.debug.assert(centroids.len == area_costs.len);
    var total: f32 = 0;
    var i: usize = 1;
    while (i < centroids.len) : (i += 1) {
        total += reachability.edgeWeight(centroids[i - 1], centroids[i], area_costs[i]);
    }
    return total;
}

/// Total approximate cost of a route (sequence of poly refs) under `filter`:
/// decode each poly's centroid + area cost, then `costSum`. Refs that fail to
/// decode are skipped (the route stays contiguous over the decodable polys —
/// findPath corridors are always valid, so this is just defensive). Returns 0
/// for a 0/1-poly route.
pub fn routeCost(nav: *const NavMesh, filter: *const QueryFilter, polys: []const PolyRef) f32 {
    if (polys.len < 2) return 0;
    var prev_c: [3]f32 = undefined;
    var have_prev = false;
    var total: f32 = 0;
    for (polys) |ref| {
        var t: ?*const dt.MeshTile = null;
        var p: ?*const dt.Poly = null;
        nav.getTileAndPolyByRefUnsafe(ref, &t, &p);
        const tile = t orelse continue;
        const poly = p orelse continue;
        const c = polyCentroid(tile, poly);
        if (have_prev) {
            total += reachability.edgeWeight(prev_c, c, filter.getAreaCost(poly.getArea()));
        }
        prev_c = c;
        have_prev = true;
    }
    return total;
}

// ---------------------------------------------------------------------------
// Unit tests (pure cost-sum). A full findPath / routeCost test needs a real
// NavMesh (heavy) — skipped per the A4 brief; the overlay is owner-verified. We
// test costSum on synthetic centroids, which is the load-bearing accumulation.
// ---------------------------------------------------------------------------

test "costSum: empty / single poly -> 0" {
    try std.testing.expectEqual(@as(f32, 0.0), costSum(&.{}, &.{}));
    try std.testing.expectEqual(@as(f32, 0.0), costSum(&.{.{ 1, 2, 3 }}, &.{1.0}));
}

test "costSum: two polys 3-4-5 triangle, dest cost 2 -> 10" {
    const cs = [_][3]f32{ .{ 0, 0, 0 }, .{ 3, 0, 4 } };
    const ac = [_]f32{ 1.0, 2.0 }; // edge uses DEST (index 1) cost = 2 -> 5*2
    try std.testing.expectEqual(@as(f32, 10.0), costSum(&cs, &ac));
}

test "costSum: three colinear polys accumulate per-edge dest costs" {
    // (0,0,0)->(10,0,0) dist 10 cost 1 = 10; ->(20,0,0) dist 10 cost 3 = 30; total 40.
    const cs = [_][3]f32{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 20, 0, 0 } };
    const ac = [_]f32{ 1.0, 1.0, 3.0 };
    try std.testing.expectEqual(@as(f32, 40.0), costSum(&cs, &ac));
}

test "costSum: differing dest costs change the total (filter divergence)" {
    const cs = [_][3]f32{ .{ 0, 0, 0 }, .{ 5, 0, 0 } };
    const cheap = [_]f32{ 1.0, 1.0 };
    const dear = [_]f32{ 1.0, 4.0 };
    try std.testing.expect(costSum(&cs, &dear) > costSum(&cs, &cheap));
    try std.testing.expectEqual(@as(f32, 5.0), costSum(&cs, &cheap));
    try std.testing.expectEqual(@as(f32, 20.0), costSum(&cs, &dear));
}
