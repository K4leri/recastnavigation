//! BUILD ARTIFACT DETECTORS (cluster B feature B-3) — diagnostic-only passes over
//! the BUILT navmesh that flag likely-problematic geometry. DIAGNOSIS ONLY: never
//! mutates the mesh (fixing is cluster F). Three detectors:
//!
//!   1. DEGENERATE DETAIL TRIANGLES — detail-mesh triangles with near-zero XZ area
//!      (collinear / zero-area), which cause render/raycast glitches.
//!   2. TINY POLYGONS — navmesh polys whose XZ (shoelace) area is below a small
//!      threshold (slivers / dust that survived region merging).
//!   3. DEAD-END / SINGLE-LINK POLYGONS — polys with exactly ONE non-zero-ref link
//!      (chokepoints / isolated stubs) — a cheap proxy for thin isthmuses.
//!
//! The pure geometry helpers (triArea2 / polyAreaXZ) are the load-bearing tested
//! bits; analyze() needs a real NavMesh (heavy) and is owner-verified.
//!
//! Все детекторы — ЧИСТОЕ ЧТЕНИЕ (никаких мутаций), bounds-safe (зеркалят guard'ы
//! poly_inspect.zig). Используется настраиваемый common.PolyRef (не хардкод u32 —
//! проект поддерживает -Dpolyref64).

const std = @import("std");
const recast = @import("recast-nav");

const dt = recast.detour;
const NavMesh = dt.NavMesh;
const common = dt.common;

// ============================================================================
// PURE GEOMETRY HELPERS — no NavMesh deps; unit-tested.
// Чистые геометрические помощники — нет зависимостей на NavMesh; покрыты тестами.
// ============================================================================

/// Twice the signed XZ area of triangle (a,b,c) — the standard cross-product
/// "2*area" form. Sign encodes winding; callers take @abs for an unsigned area.
/// Collinear points -> ~0.
///
/// Удвоенная знаковая площадь треугольника в плоскости XZ (cross-product). Знак —
/// направление обхода; вызывающий берёт @abs. Коллинеарные точки -> ~0.
pub fn triArea2(ax: f32, az: f32, bx: f32, bz: f32, cx: f32, cz: f32) f32 {
    return (bx - ax) * (cz - az) - (cx - ax) * (bz - az);
}

/// Absolute XZ area of a polygon given its vertices' XZ coords (flat: x0,z0,x1,z1,
/// ...), via the shoelace formula. < 3 vertices -> 0.
///
/// Абсолютная площадь полигона в XZ по формуле шнурков (вершины плоско: x0,z0,...).
pub fn polyAreaXZ(verts_xz: []const f32) f32 {
    const n = verts_xz.len / 2;
    if (n < 3) return 0;
    var acc: f32 = 0;
    var i: usize = 0;
    var j: usize = n - 1; // previous vertex (wraps to last)
    while (i < n) : (i += 1) {
        const xi = verts_xz[i * 2 + 0];
        const zi = verts_xz[i * 2 + 1];
        const xj = verts_xz[j * 2 + 0];
        const zj = verts_xz[j * 2 + 1];
        acc += (xj + xi) * (zj - zi);
        j = i;
    }
    return @abs(acc) * 0.5;
}

// ============================================================================
// REPORT TYPES
// ============================================================================

/// One flagged polygon + which detector flagged it. A poly may appear more than
/// once if it trips several detectors (each is a separate culprit entry).
///
/// Один помеченный полигон + кто его пометил. Поли может встретиться несколько раз.
pub const Culprit = struct {
    ref: common.PolyRef,
    kind: enum { degenerate_tri, tiny_poly, dead_end },
};

/// Cap on stored culprits. Counts beyond the cap are still tallied in the
/// per-kind totals; only the highlight list is capped (keeps the overdraw cheap).
pub const MAX_CULPRITS: usize = 256;

/// Detector results. Owns a heap ArrayList of culprits -> caller MUST deinit().
///
/// Результаты детекторов. Владеет heap-списком culprits -> вызывающий обязан
/// вызвать deinit().
pub const ArtifactReport = struct {
    degenerate_tris: usize = 0,
    tiny_polys: usize = 0,
    dead_end_polys: usize = 0,
    /// Capped highlight list ({ref, kind}); see MAX_CULPRITS.
    culprits: std.ArrayList(Culprit) = .empty,

    pub fn deinit(self: *ArtifactReport, alloc: std.mem.Allocator) void {
        self.culprits.deinit(alloc);
        self.culprits = .empty;
    }
};

// ============================================================================
// ANALYZE — run all detectors over the built navmesh (bounds-safe, read-only).
// ============================================================================

/// Run all detectors over `nav`. Returns counts + a capped culprit list for the
/// highlight overlay. Thresholds:
///   - degenerate tri: @abs(triArea2)/2 < DEGEN_TRI_EPS (absolute small area);
///   - tiny poly: polyAreaXZ < `tiny_threshold` (param);
///   - dead-end: exactly ONE link with a non-zero ref.
///
/// Bounds-safe over tiles/polys/detail-tris/links (mirrors poly_inspect.zig guards
/// — corrupt indices stop a tile's walk early rather than panicking). Uses the
/// configured common.PolyRef for refs.
///
/// Caller deinits the returned report (it owns a heap ArrayList).
pub fn analyze(nav: *const NavMesh, tiny_threshold: f32, alloc: std.mem.Allocator) !ArtifactReport {
    var report = ArtifactReport{};
    errdefer report.deinit(alloc);

    const num_tiles: usize = @intCast(nav.max_tiles);

    // Scratch buffer for a poly's XZ vertex coords (shoelace input). VERTS_PER_POLYGON
    // pairs (x,z) — fixed cap, no per-poly alloc.
    var xz_buf: [common.VERTS_PER_POLYGON * 2]f32 = undefined;

    for (0..num_tiles) |ti| {
        const tile = &nav.tiles[ti];
        const hdr = tile.header orelse continue;
        const poly_count: usize = @intCast(hdr.poly_count);
        const base = nav.getPolyRefBase(tile);

        for (0..poly_count) |pi| {
            if (pi >= tile.polys.len) break; // corrupt header vs slice — stop tile
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;

            const ref: common.PolyRef = base | @as(common.PolyRef, @intCast(pi));

            // --- TINY POLYGON: shoelace XZ area below threshold ---
            const vc: usize = p.vert_count;
            if (vc >= 3) {
                var ok = true;
                for (0..vc) |k| {
                    const vi: usize = @as(usize, p.verts[k]) * 3;
                    if (vi + 2 >= tile.verts.len) { // corrupt vert index
                        ok = false;
                        break;
                    }
                    xz_buf[k * 2 + 0] = tile.verts[vi + 0];
                    xz_buf[k * 2 + 1] = tile.verts[vi + 2];
                }
                if (ok) {
                    const area = polyAreaXZ(xz_buf[0 .. vc * 2]);
                    if (area < tiny_threshold) {
                        report.tiny_polys += 1;
                        pushCulprit(&report, alloc, .{ .ref = ref, .kind = .tiny_poly });
                    }
                }
            }

            // --- DEAD-END: exactly ONE non-zero-ref link ---
            var nonzero_links: usize = 0;
            var li: u32 = p.first_link;
            while (li != common.NULL_LINK) {
                if (li >= tile.links.len) break; // corrupt link index
                const link = &tile.links[li];
                if (link.ref != 0) nonzero_links += 1;
                li = link.next;
            }
            if (nonzero_links == 1) {
                report.dead_end_polys += 1;
                pushCulprit(&report, alloc, .{ .ref = ref, .kind = .dead_end });
            }

            // --- DEGENERATE DETAIL TRIANGLES: near-zero XZ area ---
            if (pi >= tile.detail_meshes.len) continue;
            const pd = &tile.detail_meshes[pi];
            var poly_has_degen = false;
            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (@as(usize, pd.tri_base) + j) * 4;
                if (t_idx + 3 >= tile.detail_tris.len) break; // corrupt tri range
                const t = tile.detail_tris[t_idx .. t_idx + 4];

                var vx: [3]f32 = undefined;
                var vz: [3]f32 = undefined;
                var tri_ok = true;
                for (0..3) |k| {
                    // Mirror poly_visit.fillNavMesh's split: index < poly.vert_count
                    // is a poly outer vert (tile.verts); else a detail vert
                    // (tile.detail_verts), offset by (t[k] - poly.vert_count).
                    if (t[k] < p.vert_count) {
                        const v_idx: usize = @as(usize, p.verts[t[k]]) * 3;
                        if (v_idx + 2 >= tile.verts.len) {
                            tri_ok = false;
                            break;
                        }
                        vx[k] = tile.verts[v_idx + 0];
                        vz[k] = tile.verts[v_idx + 2];
                    } else {
                        const d_idx: usize = (@as(usize, pd.vert_base) + @as(usize, t[k] - p.vert_count)) * 3;
                        if (d_idx + 2 >= tile.detail_verts.len) {
                            tri_ok = false;
                            break;
                        }
                        vx[k] = tile.detail_verts[d_idx + 0];
                        vz[k] = tile.detail_verts[d_idx + 2];
                    }
                }
                if (!tri_ok) continue;

                const area2 = triArea2(vx[0], vz[0], vx[1], vz[1], vx[2], vz[2]);
                if (@abs(area2) * 0.5 < DEGEN_TRI_EPS) {
                    report.degenerate_tris += 1;
                    poly_has_degen = true;
                }
            }
            // One culprit entry per poly (not per triangle) so the highlight list
            // stays poly-granular; degenerate_tris count is still per-triangle.
            if (poly_has_degen) {
                pushCulprit(&report, alloc, .{ .ref = ref, .kind = .degenerate_tri });
            }
        }
    }

    return report;
}

/// Absolute area below which a detail triangle is "degenerate" (collinear /
/// zero-area). World units squared — small enough to flag only truly-flat tris.
pub const DEGEN_TRI_EPS: f32 = 1e-4;

/// Append a culprit, silently dropping it past MAX_CULPRITS (the per-kind count
/// still reflects the true total — only the highlight list is capped).
fn pushCulprit(report: *ArtifactReport, alloc: std.mem.Allocator, c: Culprit) void {
    if (report.culprits.items.len >= MAX_CULPRITS) return;
    report.culprits.append(alloc, c) catch {}; // OOM -> just skip the highlight entry
}

// ============================================================================
// UNIT TESTS — pure geometry helpers (the load-bearing tested bits).
// A full analyze() test needs a real NavMesh (heavy) -> skipped; owner-verified.
// ============================================================================
const testing = std.testing;

test "triArea2: right triangle (legs 3,4) -> 2*area = 12" {
    // (0,0),(3,0),(0,4): area 6, so 2*area = 12.
    const a2 = triArea2(0, 0, 3, 0, 0, 4);
    try testing.expectApproxEqAbs(@as(f32, 12.0), @abs(a2), 1e-5);
}

test "triArea2: collinear points -> ~0" {
    const a2 = triArea2(0, 0, 1, 1, 2, 2);
    try testing.expectApproxEqAbs(@as(f32, 0.0), a2, 1e-5);
}

test "triArea2: winding sign flips with vertex order" {
    const cw = triArea2(0, 0, 3, 0, 0, 4);
    const ccw = triArea2(0, 0, 0, 4, 3, 0);
    try testing.expect(cw * ccw < 0); // opposite signs
}

test "polyAreaXZ: unit square -> 1" {
    const sq = [_]f32{ 0, 0, 1, 0, 1, 1, 0, 1 };
    try testing.expectApproxEqAbs(@as(f32, 1.0), polyAreaXZ(&sq), 1e-5);
}

test "polyAreaXZ: right triangle (legs 1,1) -> 0.5" {
    const tri = [_]f32{ 0, 0, 1, 0, 0, 1 };
    try testing.expectApproxEqAbs(@as(f32, 0.5), polyAreaXZ(&tri), 1e-5);
}

test "polyAreaXZ: degenerate (<3 verts) -> 0" {
    const two = [_]f32{ 0, 0, 1, 1 };
    try testing.expectEqual(@as(f32, 0.0), polyAreaXZ(&two));
}

test "polyAreaXZ: collinear poly -> ~0" {
    const line = [_]f32{ 0, 0, 1, 0, 2, 0 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), polyAreaXZ(&line), 1e-5);
}

test "ArtifactReport: deinit is safe on empty report" {
    var r = ArtifactReport{};
    r.deinit(testing.allocator);
}
