//! Demo-side navmesh fill pass that colours each polygon by the active colour
//! scheme (foundation render layer, §3.c). The faithful core `debugDrawNavMesh`
//! can only colour by area (its sole input is the area_to_col hook), so this
//! replicates the detail-triangle fill of `drawMeshTile` and applies
//! `color_scheme.colorForPoly` per polygon. Boundaries/off-mesh stay with the
//! core draw.

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;
const dbg = recast.debug;
const sample = @import("../sample.zig");
const area_types = @import("../area_types.zig");
const cs = @import("color_scheme.zig");
const components = @import("components.zig");
const isolation = @import("isolation.zig");
const reachability = @import("../diag/reachability.zig");

const NavMesh = dt.NavMesh;

fn polyHeight(tile: *const dt.MeshTile, p: *const dt.Poly) f32 {
    var sum: f32 = 0;
    for (0..p.vert_count) |k| {
        sum += tile.verts[@as(usize, p.verts[k]) * 3 + 1];
    }
    return if (p.vert_count == 0) 0 else sum / @as(f32, @floatFromInt(p.vert_count));
}

const HeightRange = struct { lo: f32, hi: f32 };

fn heightRange(mesh: *const NavMesh) HeightRange {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var found = false;
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        const hdr = tile.header orelse continue;
        for (0..@intCast(hdr.poly_count)) |pi| {
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;
            const h = polyHeight(tile, p);
            lo = @min(lo, h);
            hi = @max(hi, h);
            found = true;
        }
    }
    return if (found) .{ .lo = lo, .hi = hi } else .{ .lo = 0, .hi = 0 };
}

/// Return the area-type cost for a given area id, falling back to 1.0 for
/// unknown/unregistered areas. Pure helper — no NavMesh traversal.
pub fn polyCost(area: u8) f32 {
    return area_types.costFor(@as(usize, area));
}

const CostRange = struct { lo: f32, hi: f32 };

fn costRange(mesh: *const NavMesh) CostRange {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var found = false;
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        const hdr = tile.header orelse continue;
        for (0..@intCast(hdr.poly_count)) |pi| {
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;
            const c = polyCost(p.getArea());
            lo = @min(lo, c);
            hi = @max(hi, c);
            found = true;
        }
    }
    return if (found) .{ .lo = lo, .hi = hi } else .{ .lo = 0, .hi = 0 };
}

/// Precomputed per-scheme ranges + optional connected-components, so the per-poly
/// `PolyColorCtx` build (shared by fillNavMesh and fillNavMeshFiltered) doesn't
/// rescan the whole mesh for every polygon.
const SchemeRanges = struct {
    hr: HeightRange = .{ .lo = 0, .hi = 0 },
    cr: CostRange = .{ .lo = 0, .hi = 0 },
    comps: ?components.Components = null,

    fn compute(mesh: *const NavMesh, scheme: cs.ColorScheme, alloc: std.mem.Allocator) SchemeRanges {
        return .{
            .hr = if (scheme == .height) heightRange(mesh) else .{ .lo = 0, .hi = 0 },
            .cr = if (scheme == .cost) costRange(mesh) else .{ .lo = 0, .hi = 0 },
            .comps = if (scheme == .component) (components.compute(mesh, alloc) catch null) else null,
        };
    }

    fn deinit(self: *SchemeRanges) void {
        if (self.comps) |*c| c.deinit();
    }
};

/// Build the colour-scheme context for one polygon given precomputed ranges.
/// Shared by the plain and filtered fill so the two never drift. `ti`/`i` are the
/// tile/poly indices (used to look up the poly's connected component).
fn buildCtx(ranges: *const SchemeRanges, tile: *const dt.MeshTile, p: *const dt.Poly, ti: usize, i: usize) cs.PolyColorCtx {
    return cs.PolyColorCtx{
        .area_col = sample.sampleAreaToCol(p.getArea()),
        .flags = p.flags,
        .height = polyHeight(tile, p),
        .height_min = ranges.hr.lo,
        .height_max = ranges.hr.hi,
        .component = if (ranges.comps) |*c| @as(i32, c.getByIndex(ti, i)) else 0,
        .cost = polyCost(p.getArea()),
        .cost_min = ranges.cr.lo,
        .cost_max = ranges.cr.hi,
    };
}

/// Numeric range (lo..hi) of the continuous schemes (height / cost) over the
/// whole navmesh, for the legend's gradient min/max labels. For discrete schemes
/// returns {0,0} (the legend uses discreteEntries instead). One full traversal —
/// the legend calls it once per frame, same cost as a single fill's range scan.
pub fn schemeRange(mesh: *const NavMesh, scheme: cs.ColorScheme) struct { lo: f32, hi: f32 } {
    return switch (scheme) {
        .height => blk: {
            const r = heightRange(mesh);
            break :blk .{ .lo = r.lo, .hi = r.hi };
        },
        .cost => blk: {
            const r = costRange(mesh);
            break :blk .{ .lo = r.lo, .hi = r.hi };
        },
        else => .{ .lo = 0, .hi = 0 },
    };
}

/// Wireframe navmesh draw (cluster E, P1-1): ONLY the per-poly outer-ring outline
/// (the `.lines` pass factored out of fillNavMeshFiltered) — no filled triangles.
/// Routes through the SAME filter verdict so wireframe works with a clip/iso
/// filter active OR inactive: an inactive filter (`.{}`) yields `.draw` for every
/// poly, so the whole mesh is outlined; an active one hides/dims exactly as the
/// filled draw would. Colours each ring by the active scheme (so wireframe still
/// reflects the colouring), dimmed polys get the faint ring.
pub fn outlineNavMesh(
    dd: dbg.DebugDraw,
    mesh: *const NavMesh,
    scheme: cs.ColorScheme,
    filter: isolation.Filter,
    alloc: std.mem.Allocator,
) void {
    var ranges = SchemeRanges.compute(mesh, scheme, alloc);
    defer ranges.deinit();

    dd.depthMask(false);
    dd.begin(.lines, 2.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;

            const v = isolation.verdictFor(filter, polyHeight(tile, p), hdr.x, hdr.y, p.getArea(), p.flags);
            if (v == .hide) continue;

            const ctx = buildCtx(&ranges, tile, p, ti, i);
            const base_col = cs.colorForPoly(scheme, ctx);
            const lc = if (v == .dim) dimCol(base_col) else base_col;

            const vc: usize = p.vert_count;
            for (0..vc) |k| {
                const next = (k + 1) % vc;
                const v0 = @as(usize, p.verts[k]) * 3;
                const v1 = @as(usize, p.verts[next]) * 3;
                dd.vertex(@ptrCast(&tile.verts[v0]), lc);
                dd.vertex(@ptrCast(&tile.verts[v1]), lc);
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}

pub fn fillNavMesh(dd: dbg.DebugDraw, mesh: *const NavMesh, scheme: cs.ColorScheme, alloc: std.mem.Allocator) void {
    // Precompute scheme ranges/components once (height/cost ramps + components
    // each need a full mesh traversal); reused for every polygon below.
    var ranges = SchemeRanges.compute(mesh, scheme, alloc);
    defer ranges.deinit();

    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;
            const pd = &tile.detail_meshes[i];

            const ctx = buildCtx(&ranges, tile, p, ti, i);
            const col = cs.colorForPoly(scheme, ctx);

            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];
                for (0..3) |k| {
                    if (t[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[t[k]]) * 3;
                        dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                    } else {
                        const d_idx = (@as(usize, pd.vert_base) + @as(usize, t[k] - p.vert_count)) * 3;
                        dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                    }
                }
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}

/// Colour for an UNREACHABLE poly in the reachability heatmap: dim translucent
/// grey, so regions the source can't reach read as visually distinct (not part of
/// the green->red gradient). Cluster A, A6.
const HEATMAP_UNREACHED: u32 = dbg.rgba(70, 70, 70, 110);

/// Reachability heatmap overlay (cluster A, A6). Mirrors `fillNavMesh`'s
/// detail-triangle fill, but colours each non-offmesh poly by its ACCUMULATED
/// reachability cost from the heatmap's source (not the per-poly area cost):
///   reachable -> cost gradient COST_LO(cheap/near) .. COST_HI(dear/far),
///                normalised over [hm.lo, hm.hi];
///   unreachable / filtered-out -> dim grey (HEATMAP_UNREACHED), so unreachable
///                regions are obviously different from the reachable ramp.
/// Looks each poly up by its ref via `hm.costForRef` (O(1) per poly). Same
/// depthMask(false) + .tris pass as fillNavMesh.
///
/// Хитмап достижимости: заливка каждого поли цветом по накопленной стоимости из
/// источника; недостижимые — тусклый серый.
pub fn fillNavMeshHeatmap(
    dd: dbg.DebugDraw,
    mesh: *const NavMesh,
    hm: *const reachability.Heatmap,
) void {
    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;
        const base = mesh.getPolyRefBase(tile);

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;
            const pd = &tile.detail_meshes[i];

            const ref = base | @as(dt.PolyRef, @intCast(i));
            const col = if (hm.costForRef(mesh, ref)) |cost|
                cs.colorForPoly(.cost, .{ .cost = cost, .cost_min = hm.lo, .cost_max = hm.hi })
            else
                HEATMAP_UNREACHED;

            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];
                for (0..3) |k| {
                    if (t[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[t[k]]) * 3;
                        dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                    } else {
                        const d_idx = (@as(usize, pd.vert_base) + @as(usize, t[k] - p.vert_count)) * 3;
                        dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                    }
                }
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}

/// Darken + fade a colour for the DIM verdict: RGB *= ~0.35, A *= ~0.5.
/// Operates on the packed 0xAABBGGRR u32 (same layout as dbg.rgba).
fn dimCol(col: u32) u32 {
    const r = (col & 0xff) * 90 / 255; // ~0.35
    const g = ((col >> 8) & 0xff) * 90 / 255;
    const b = ((col >> 16) & 0xff) * 90 / 255;
    const a = ((col >> 24) & 0xff) / 2; // ~0.5
    return dbg.rgba(@intCast(r), @intCast(g), @intCast(b), @intCast(a));
}

// Outline colours for the second (.lines) pass — keeps the clipped navmesh
// readable without the faithful boundary draw (which is suppressed when a filter
// is active). Drawn polys get a solid dark-grey ring; dim polys a fainter one.
const OUTLINE_DRAW: u32 = dbg.rgba(0, 0, 0, 160);
const OUTLINE_DIM: u32 = dbg.rgba(0, 0, 0, 60);

/// Filtered navmesh draw (cluster E, P0-2). REPLACES the faithful navmesh draw
/// (debugDrawNavMesh + the plain fillNavMesh overdraw) whenever `filter.active()`:
/// the sample calls THIS instead, so unclipped floors don't show through.
///
/// Per non-offmesh poly: centroid_y = polyHeight; tile identity = header.x/header.y
/// (simpler + cheaper than decoding a poly ref, and MeshTileHeader carries the tile
/// coords directly). verdict = filter.verdictFor(...).
///   hide -> poly skipped entirely (fill AND outline).
///   draw -> fill with the active scheme colour.
///   dim  -> fill with dimCol() (darker RGB + lower alpha).
/// Pass 1: `.tris` detail-tri fill (depthMask(false), like fillNavMesh).
/// Pass 2: `.lines` outer-ring outline of every non-hidden poly (outer ring of
/// p.verts; no inner/outer edge classification — kept simple).
pub fn fillNavMeshFiltered(
    dd: dbg.DebugDraw,
    mesh: *const NavMesh,
    scheme: cs.ColorScheme,
    filter: isolation.Filter,
    alloc: std.mem.Allocator,
) void {
    var ranges = SchemeRanges.compute(mesh, scheme, alloc);
    defer ranges.deinit();

    // --- Pass 1: filled detail triangles ---
    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;

            const v = isolation.verdictFor(filter, polyHeight(tile, p), hdr.x, hdr.y, p.getArea(), p.flags);
            if (v == .hide) continue;

            const ctx = buildCtx(&ranges, tile, p, ti, i);
            const base_col = cs.colorForPoly(scheme, ctx);
            const col = if (v == .dim) dimCol(base_col) else base_col;

            const pd = &tile.detail_meshes[i];
            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];
                for (0..3) |k| {
                    if (t[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[t[k]]) * 3;
                        dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                    } else {
                        const d_idx = (@as(usize, pd.vert_base) + @as(usize, t[k] - p.vert_count)) * 3;
                        dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                    }
                }
            }
        }
    }

    dd.end();

    // --- Pass 2: outer-ring outline of every non-hidden poly ---
    dd.begin(.lines, 2.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;

            const v = isolation.verdictFor(filter, polyHeight(tile, p), hdr.x, hdr.y, p.getArea(), p.flags);
            if (v == .hide) continue;
            const lc = if (v == .dim) OUTLINE_DIM else OUTLINE_DRAW;

            const vc: usize = p.vert_count;
            for (0..vc) |k| {
                const next = (k + 1) % vc;
                const v0 = @as(usize, p.verts[k]) * 3;
                const v1 = @as(usize, p.verts[next]) * 3;
                dd.vertex(@ptrCast(&tile.verts[v0]), lc);
                dd.vertex(@ptrCast(&tile.verts[v1]), lc);
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}

test "dimCol darkens RGB and halves alpha" {
    // Opaque white -> ~35% grey, 50% alpha.
    const out = dimCol(dbg.rgba(255, 255, 255, 200));
    try std.testing.expectEqual(@as(u32, 255 * 90 / 255), out & 0xff);
    try std.testing.expectEqual(@as(u32, 100), (out >> 24) & 0xff);
}

test "polyCost: known area returns registry cost; unknown area -> 1.0" {
    area_types.resetToBuiltins();
    // Ground (id=0): cost 1.0
    try std.testing.expectEqual(@as(f32, 1.0), polyCost(0));
    // Water (id=1): cost 10.0
    try std.testing.expectEqual(@as(f32, 10.0), polyCost(1));
    // Grass (id=4): cost 2.0
    try std.testing.expectEqual(@as(f32, 2.0), polyCost(4));
    // Jump (id=5): cost 1.5
    try std.testing.expectEqual(@as(f32, 1.5), polyCost(5));
    // Unknown area (e.g. id=63, not seeded by builtins) -> 1.0
    try std.testing.expectEqual(@as(f32, 1.0), polyCost(63));
}
