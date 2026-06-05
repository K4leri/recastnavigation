//! Reachability heatmap (cluster A, A6). From a chosen SOURCE polygon, run a
//! Dijkstra-style expansion over the navmesh poly links — honouring the active
//! `QueryFilter.passFilter` — to accumulate each reachable polygon's travel COST
//! from the source. The demo colours the navmesh by that cost (green=cheap/near,
//! red=dear/far): "how far / how expensive is everything from here" at a glance.
//!
//! Read-only graph traversal over the faithful core (links + filter + area cost):
//! NO core changes. Storage mirrors components.zig (per-tile slice of per-poly
//! values) for O(1) ref->cost lookup.
//!
//! EDGE WEIGHT (approximation, documented): the real pathfinder's getCost needs
//! the portal points between two polys (heavier to compute). For a debug overlay
//! we use distance(centroid(a), centroid(b)) * areaCost(dest) — the same shape as
//! the faithful `getCost` (Euclidean dist * dest area cost) but using poly
//! CENTROIDS instead of portal midpoints. Good enough to rank "near vs far".
//!
//! COMPLEXITY: O((polys + links) * log polys) per flood (binary-heap Dijkstra).
//! Floods are RARE (only when the source/filter changes — the caller caches the
//! result), so this is not a per-frame cost.
//!
//! Хитмап достижимости: Dijkstra по линкам навмеша от исходного полигона с учётом
//! фильтра; вес ребра = расстояние между центроидами * стоимость области-приёмника.

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;

const NavMesh = dt.NavMesh;
const PolyRef = dt.PolyRef;
const QueryFilter = dt.QueryFilter;

/// Pure edge-weight helper: Euclidean distance between two poly centroids times
/// the destination poly's area cost. Unit-tested. `area_cost` is the dest poly's
/// per-area movement cost (>= 0); zero distance -> zero weight regardless of cost.
///
/// Вес ребра: расстояние между центроидами * стоимость области-приёмника.
pub fn edgeWeight(a: [3]f32, b: [3]f32, area_cost: f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    const dist = @sqrt(dx * dx + dy * dy + dz * dz);
    return dist * area_cost;
}

/// Centroid (average of the poly's tile.verts) — mirrors poly_visit.polyHeight /
/// the tester's getPolyCenter, but returns all three coords.
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

/// Per-poly accumulated reachability cost from a source polygon, stored in the
/// components.zig per-tile layout (a `?[]f32` per tile: cost per poly; an
/// unreachable / unvisited poly stays at INF). `lo`/`hi` bracket the reachable
/// costs (lo = 0 at the source, hi = the costliest reachable poly) for the
/// colour-gradient normalisation.
pub const Heatmap = struct {
    alloc: std.mem.Allocator,
    tile_cost: []?[]f32 = &.{}, // per tile: cost per poly (INF = unreachable), or null for empty tile
    reached: usize = 0,
    lo: f32 = 0,
    hi: f32 = 0,

    /// Sentinel for "not reached": +inf so it never wins a min-reduction.
    pub const UNREACHED: f32 = std.math.inf(f32);

    pub fn deinit(self: *Heatmap) void {
        for (self.tile_cost) |maybe| {
            if (maybe) |s| self.alloc.free(s);
        }
        if (self.tile_cost.len > 0) self.alloc.free(self.tile_cost);
        self.tile_cost = &.{};
    }

    /// Accumulated cost for a poly REF (decodes + bounds-checks). Returns null for
    /// ref==0, an out-of-range ref, an empty tile, or an UNREACHED poly.
    ///
    /// Стоимость по REF полигона; null для плохого ref или недостижимого поли.
    pub fn costForRef(self: *const Heatmap, nav: *const NavMesh, ref: PolyRef) ?f32 {
        if (ref == 0) return null;
        const d = nav.decodePolyId(ref);
        if (d.tile >= self.tile_cost.len) return null;
        const slot = self.tile_cost[d.tile] orelse return null;
        if (d.poly >= slot.len) return null;
        const c = slot[d.poly];
        if (c == UNREACHED) return null;
        return c;
    }
};

/// Dijkstra expansion from `src_ref` over poly links, honouring `filter.passFilter`.
/// Edge weight = distance(centroid(a), centroid(b)) * areaCost(dest) (see module
/// note — centroid-distance approximation of the faithful getCost). Returns a
/// Heatmap with each reachable poly's accumulated cost + the reachable min/max
/// (lo = 0 at source, hi = costliest reachable poly). Unreachable / filtered-out
/// polys stay at Heatmap.UNREACHED (costForRef -> null).
///
/// A std.PriorityQueue (binary heap) keeps the open set; O((V+E) log V).
pub fn flood(nav: *const NavMesh, src_ref: PolyRef, filter: *const QueryFilter, alloc: std.mem.Allocator) !Heatmap {
    var hm = Heatmap{ .alloc = alloc };
    const num_tiles: usize = @intCast(nav.max_tiles);
    if (num_tiles == 0 or src_ref == 0) return hm;

    // Allocate the per-tile cost slices (INF = unreached), mirroring components.zig.
    hm.tile_cost = try alloc.alloc(?[]f32, num_tiles);
    for (hm.tile_cost) |*slot| slot.* = null;
    errdefer hm.deinit();

    for (0..num_tiles) |i| {
        const tile = &nav.tiles[i];
        const header = tile.header orelse continue;
        const pc: usize = @intCast(header.poly_count);
        const s = try alloc.alloc(f32, pc);
        @memset(s, Heatmap.UNREACHED);
        hm.tile_cost[i] = s;
    }

    // Validate the source ref and that it passes the filter; otherwise nothing is
    // reachable (empty heatmap — every costForRef returns null).
    var st: ?*const dt.MeshTile = null;
    var sp: ?*const dt.Poly = null;
    nav.getTileAndPolyByRefUnsafe(src_ref, &st, &sp);
    const stile = st orelse return hm;
    const spoly = sp orelse return hm;
    if (!filter.passFilter(src_ref, stile, spoly)) return hm;

    const sd = nav.decodePolyId(src_ref);
    if (sd.tile >= hm.tile_cost.len) return hm;
    const sslot = hm.tile_cost[sd.tile] orelse return hm;
    if (sd.poly >= sslot.len) return hm;

    const QEntry = struct {
        cost: f32,
        ref: PolyRef,
        fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
            return std.math.order(a.cost, b.cost);
        }
    };
    var open = std.PriorityQueue(QEntry, void, QEntry.lessThan).init(alloc, {});
    defer open.deinit();

    sslot[sd.poly] = 0;
    try open.add(.{ .cost = 0, .ref = src_ref });

    var hi: f32 = 0;
    var reached: usize = 1;

    while (open.removeOrNull()) |cur| {
        // Stale-entry skip: a poly may sit in the heap with an outdated (higher)
        // cost after a relaxation; the slot holds the settled value.
        const cd = nav.decodePolyId(cur.ref);
        const cur_slot = hm.tile_cost[cd.tile] orelse continue;
        if (cur.cost > cur_slot[cd.poly]) continue;

        var ct: ?*const dt.MeshTile = null;
        var cp: ?*const dt.Poly = null;
        nav.getTileAndPolyByRefUnsafe(cur.ref, &ct, &cp);
        const ctile = ct orelse continue;
        const cpoly = cp orelse continue;
        const c_centroid = polyCentroid(ctile, cpoly);

        var li: u32 = cpoly.first_link;
        while (li != dt.NULL_LINK) : (li = ctile.links[li].next) {
            const nref = ctile.links[li].ref;
            if (nref == 0) continue;

            var nt: ?*const dt.MeshTile = null;
            var np: ?*const dt.Poly = null;
            nav.getTileAndPolyByRefUnsafe(nref, &nt, &np);
            const ntile = nt orelse continue;
            const npoly = np orelse continue;
            if (!filter.passFilter(nref, ntile, npoly)) continue;

            const nd = nav.decodePolyId(nref);
            const nslot = hm.tile_cost[nd.tile] orelse continue;
            if (nd.poly >= nslot.len) continue;

            const n_centroid = polyCentroid(ntile, npoly);
            const w = edgeWeight(c_centroid, n_centroid, filter.getAreaCost(npoly.getArea()));
            const new_cost = cur.cost + w;
            if (new_cost < nslot[nd.poly]) {
                if (nslot[nd.poly] == Heatmap.UNREACHED) reached += 1;
                nslot[nd.poly] = new_cost;
                hi = @max(hi, new_cost);
                try open.add(.{ .cost = new_cost, .ref = nref });
            }
        }
    }

    hm.reached = reached;
    hm.lo = 0;
    hm.hi = hi;
    return hm;
}

// ---------------------------------------------------------------------------
// Unit tests (pure parts: edgeWeight + costForRef bounds). A full flood needs a
// real NavMesh (heavy) — skipped per the A6 brief; the overlay is owner-verified.
// ---------------------------------------------------------------------------

test "edgeWeight: distance * area cost" {
    // 3-4-5 triangle in XZ -> dist 5; cost 2 -> 10.
    try std.testing.expectEqual(@as(f32, 10.0), edgeWeight(.{ 0, 0, 0 }, .{ 3, 0, 4 }, 2.0));
}

test "edgeWeight: includes the Y axis" {
    // Pure vertical 3 units; cost 1 -> 3.
    try std.testing.expectEqual(@as(f32, 3.0), edgeWeight(.{ 0, 0, 0 }, .{ 0, 3, 0 }, 1.0));
}

test "edgeWeight: zero distance -> zero weight regardless of cost" {
    try std.testing.expectEqual(@as(f32, 0.0), edgeWeight(.{ 1, 2, 3 }, .{ 1, 2, 3 }, 99.0));
}

test "edgeWeight: zero area cost -> zero weight" {
    try std.testing.expectEqual(@as(f32, 0.0), edgeWeight(.{ 0, 0, 0 }, .{ 10, 0, 0 }, 0.0));
}

test "Heatmap.costForRef: ref==0 -> null; empty heatmap -> null" {
    // An empty/zeroed Heatmap (no tiles) must safely return null for any ref —
    // we can pass an undefined nav* because ref==0 short-circuits before decode.
    var hm = Heatmap{ .alloc = std.testing.allocator };
    defer hm.deinit();
    const nav: *const NavMesh = undefined;
    try std.testing.expectEqual(@as(?f32, null), hm.costForRef(nav, 0));
}
