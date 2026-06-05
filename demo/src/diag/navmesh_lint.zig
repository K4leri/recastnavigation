//! NAVMESH LINTER (cluster G feature G1) — a READ-ONLY pass over a built
//! `dt.NavMesh` that emits a list of Findings (severity + rule + culprit refs +
//! message). Turns "why doesn't the agent reach / off-mesh didn't fire / area
//! not painted" into a machine-readable report for the GUI panel and the
//! `--lint` CLI (exit code = error-count).
//!
//! RULES:
//!   - islands         (warn):  connected components below `min_share` of the
//!                              total poly count — small isolated islands
//!                              unreachable from the main mass. The LARGEST
//!                              component is never flagged. Reuses
//!                              render/components.zig flood-fill.
//!   - null_region     (warn):  polygons with area == RC_NULL_AREA (0) AND no
//!                              walkable flags — a genuine null leak. The flags
//!                              guard avoids flagging samples that legitimately
//!                              use area id 0 for walkable ground (e.g. this
//!                              demo's SamplePolyAreas.ground, which carries walk
//!                              flags).
//!   - degenerate_poly (warn):  polygons with a duplicate vertex index OR a
//!                              ~zero XZ (shoelace) area. Reuses
//!                              diag/artifacts.zig polyAreaXZ.
//!   - offmesh_dangling(error): an off-mesh connection poly with no link to a
//!                              normal (ground) polygon — the endpoint never
//!                              attached to land, so the connection is dead.
//!   - orphan_tile     (info):  a tile that has polygons but no external portal
//!                              link to any OTHER tile (multi-tile only; for a
//!                              single-tile navmesh this never fires).
//!
//! POLICY: faithful src/* is read-only here. LintReport owns a heap ArrayList of
//! findings -> caller MUST deinit(alloc). The pure rule PREDICATES
//! (isDegeneratePoly / islandShareFlagged / orphanTilePredicate) are the
//! load-bearing unit-tested bits; a full lint() over a real NavMesh is heavy and
//! is owner-verified.
//!
//! Линтер навмеша — ЧИСТОЕ ЧТЕНИЕ (никаких мутаций), bounds-safe (зеркалит
//! guard'ы artifacts.zig / poly_inspect.zig). Использует настраиваемый
//! common.PolyRef (не хардкод u32 — проект поддерживает -Dpolyref64).

const std = @import("std");
const recast = @import("recast-nav");
const components = @import("../render/components.zig");
const artifacts = @import("artifacts.zig");

const dt = recast.detour;
const NavMesh = dt.NavMesh;
const common = dt.common;

// RC_NULL_AREA == 0 (config.AreaId.NULL_AREA) — a polygon with area id 0 is the
// "null" (unwalkable) area; it should not survive into the navmesh.
const RC_NULL_AREA: u8 = 0;

// ============================================================================
// REPORT TYPES
// ============================================================================

pub const Severity = enum { info, warn, err };

pub const Rule = enum { islands, null_region, degenerate_poly, offmesh_dangling, orphan_tile };

/// One lint finding: severity + which rule fired + up to 4 culprit refs + a
/// short formatted message. Plain value type (no allocations) — safe to copy.
///
/// Одно срабатывание линтера: severity + правило + до 4 ref'ов виновников +
/// короткое сообщение. Чистый value-тип (без аллокаций).
pub const Finding = struct {
    severity: Severity,
    rule: Rule,
    refs: [4]common.PolyRef = [_]common.PolyRef{0} ** 4,
    ref_count: u8 = 0,
    message_buf: [96]u8 = [_]u8{0} ** 96,
    message_len: u8 = 0,

    pub fn message(self: *const Finding) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

/// Cap on stored findings — bounds memory. Counts (error/warn/info) keep tallying
/// past the cap; only the stored `findings` list is capped.
pub const MAX_FINDINGS: usize = 256;

/// Lint results. Owns a heap ArrayList of findings -> caller MUST deinit(alloc).
///
/// Результаты линтера. Владеет heap-списком findings -> вызывающий обязан
/// вызвать deinit(alloc).
pub const LintReport = struct {
    findings: std.ArrayList(Finding) = .empty,
    error_count: usize = 0,
    warn_count: usize = 0,
    info_count: usize = 0,

    pub fn deinit(self: *LintReport, alloc: std.mem.Allocator) void {
        self.findings.deinit(alloc);
        self.findings = .empty;
    }
};

// ============================================================================
// PURE RULE PREDICATES — no NavMesh deps; unit-tested (the load-bearing bits).
// Чистые предикаты правил — нет зависимостей на NavMesh; покрыты тестами.
// ============================================================================

/// Degenerate-polygon predicate: TRUE if the poly has a duplicate vertex index
/// (`dup_vert`) OR a ~zero XZ area (slivers / collinear). `verts_xz` is the flat
/// [x0,z0,x1,z1,...] of the FIRST `nverts` vertices.
///
/// Предикат вырожденного полигона: дублирующийся индекс вершины ИЛИ ~нулевая
/// площадь в XZ.
pub fn isDegeneratePoly(verts_xz: []const f32, nverts: usize, dup_vert: bool) bool {
    if (dup_vert) return true;
    if (nverts < 3) return true; // <3 verts can never bound an area
    const area = artifacts.polyAreaXZ(verts_xz[0 .. nverts * 2]);
    return area < DEGEN_POLY_EPS;
}

/// Absolute XZ area below which a navmesh polygon is "degenerate" (zero-area /
/// collinear sliver). World units squared.
pub const DEGEN_POLY_EPS: f32 = 1e-4;

/// Island-share decision: should a component of `comp_polys` polys (out of
/// `total_polys`) be FLAGGED as a small isolated island? Flagged when its share
/// is strictly below `min_share` AND it is not the largest component
/// (`is_largest` guards the main mass from ever being flagged).
///
/// Решение по доле острова: компонента флагуется, если её доля < min_share и она
/// НЕ самая большая компонента.
pub fn islandShareFlagged(comp_polys: usize, total_polys: usize, is_largest: bool, min_share: f32) bool {
    if (is_largest) return false; // the main mass is never an "island"
    if (total_polys == 0) return false;
    const share = @as(f32, @floatFromInt(comp_polys)) / @as(f32, @floatFromInt(total_polys));
    return share < min_share;
}

/// Orphan-tile predicate: a tile with polygons but ZERO external portal links is
/// an orphan. `has_polys` = the tile has at least one poly; `ext_link_count` =
/// number of links whose ref decodes to a DIFFERENT tile. Multi-tile only —
/// callers gate this on tile_count > 1 so single-tile meshes never fire.
///
/// Предикат острова-тайла: есть полигоны, но 0 внешних портал-линков.
pub fn orphanTilePredicate(has_polys: bool, ext_link_count: usize) bool {
    return has_polys and ext_link_count == 0;
}

// ============================================================================
// LINT — run all rules over the built navmesh (bounds-safe, read-only).
// ============================================================================

/// Run all lint rules over `nav`. `min_share` is the island threshold (e.g.
/// 0.02 = components under 2% of total polys are flagged; the largest is never
/// flagged). Caller deinits the returned report (it owns a heap ArrayList).
pub fn lint(nav: *const NavMesh, min_share: f32, alloc: std.mem.Allocator) !LintReport {
    var report = LintReport{};
    errdefer report.deinit(alloc);

    const num_tiles: usize = @intCast(nav.max_tiles);

    // Count how many tiles actually hold a header (for the single-tile gate on
    // orphan_tile) and the global poly total (for the island-share rule).
    var live_tiles: usize = 0;
    var total_polys: usize = 0;
    for (0..num_tiles) |ti| {
        const tile = &nav.tiles[ti];
        const hdr = tile.header orelse continue;
        live_tiles += 1;
        total_polys += @as(usize, @intCast(hdr.poly_count));
    }

    // --- LINT_ISLANDS: flood-fill components, tally sizes, flag small ones. ---
    try lintIslands(nav, num_tiles, total_polys, min_share, &report, alloc);

    // --- Per-poly + per-tile rules in one tile/poly walk. ---
    // Scratch for a poly's XZ coords (shoelace input): VERTS_PER_POLYGON pairs.
    var xz_buf: [common.VERTS_PER_POLYGON * 2]f32 = undefined;

    for (0..num_tiles) |ti| {
        const tile = &nav.tiles[ti];
        const hdr = tile.header orelse continue;
        const poly_count: usize = @intCast(hdr.poly_count);
        const base = nav.getPolyRefBase(tile);

        var tile_ext_links: usize = 0; // external portal links for orphan_tile

        for (0..poly_count) |pi| {
            if (pi >= tile.polys.len) break; // corrupt header vs slice — stop tile
            const p = &tile.polys[pi];
            const ref: common.PolyRef = base | @as(common.PolyRef, @intCast(pi));

            // Count this poly's external links (links into a DIFFERENT tile) for
            // the orphan-tile rule, regardless of poly type.
            tile_ext_links += countExtLinks(nav, tile, p, ti);

            if (p.getType() == .offmesh_connection) {
                // --- LINT_OFFMESH_DANGLING: off-mesh poly with no link to a
                // normal (ground) poly means the endpoint never attached. ---
                if (!offMeshLinkedToLand(nav, tile, p)) {
                    pushFinding(&report, alloc, .err, .offmesh_dangling, &.{ref}, "Off-mesh connection endpoint not linked", .{});
                }
                continue; // off-mesh polys have no real XZ area / area id to lint
            }

            // --- LINT_NULL_REGION: poly with area == RC_NULL_AREA (0) AND no
            // walkable flags. The flags==0 guard is required because some samples
            // (this demo's SamplePolyAreas.ground) legitimately use area id 0 for
            // walkable ground — those carry walk flags. A genuine null leak is
            // both area 0 AND flagless (unreachable by any filter). ---
            if (p.getArea() == RC_NULL_AREA and p.flags == 0) {
                pushFinding(&report, alloc, .warn, .null_region, &.{ref}, "Null-area polygon (no flags)", .{});
            }

            // --- LINT_DEGENERATE_POLY: dup vertex index OR ~zero XZ area. ---
            const vc: usize = p.vert_count;
            var dup_vert = false;
            var coords_ok = true;
            if (vc >= 1) {
                // Duplicate-vertex scan over verts[0..vc].
                for (0..vc) |a| {
                    for (a + 1..vc) |b| {
                        if (p.verts[a] == p.verts[b]) {
                            dup_vert = true;
                            break;
                        }
                    }
                    if (dup_vert) break;
                }
                // Gather XZ coords (bounds-safe) for the area test.
                for (0..vc) |k| {
                    const vi: usize = @as(usize, p.verts[k]) * 3;
                    if (vi + 2 >= tile.verts.len) {
                        coords_ok = false;
                        break;
                    }
                    xz_buf[k * 2 + 0] = tile.verts[vi + 0];
                    xz_buf[k * 2 + 1] = tile.verts[vi + 2];
                }
            }
            if (coords_ok and isDegeneratePoly(xz_buf[0 .. vc * 2], vc, dup_vert)) {
                pushFinding(&report, alloc, .warn, .degenerate_poly, &.{ref}, "Degenerate polygon (zero area / dup vert)", .{});
            }
        }

        // --- LINT_ORPHAN_TILE: multi-tile only; tile has polys but 0 ext links. ---
        if (live_tiles > 1 and orphanTilePredicate(poly_count > 0, tile_ext_links)) {
            pushFinding(&report, alloc, .info, .orphan_tile, &.{}, "Orphan tile ({d},{d}): no external portals", .{ hdr.x, hdr.y });
        }
    }

    return report;
}

/// LINT_ISLANDS body: compute connected components, tally per-component poly
/// counts, find the largest, and flag every component below `min_share`.
fn lintIslands(
    nav: *const NavMesh,
    num_tiles: usize,
    total_polys: usize,
    min_share: f32,
    report: *LintReport,
    alloc: std.mem.Allocator,
) !void {
    if (total_polys == 0) return;

    var comps = try components.compute(nav, alloc);
    defer comps.deinit();
    if (comps.count == 0) return;

    // Tally poly count + a representative ref per component (1-based ids).
    const n: usize = comps.count;
    const sizes = try alloc.alloc(usize, n + 1); // index by component id
    defer alloc.free(sizes);
    @memset(sizes, 0);
    const rep_ref = try alloc.alloc(common.PolyRef, n + 1);
    defer alloc.free(rep_ref);
    @memset(rep_ref, 0);

    for (0..num_tiles) |ti| {
        const tile = &nav.tiles[ti];
        const hdr = tile.header orelse continue;
        const poly_count: usize = @intCast(hdr.poly_count);
        const base = nav.getPolyRefBase(tile);
        for (0..poly_count) |pi| {
            const cid = comps.getByIndex(ti, pi);
            if (cid == 0 or cid > n) continue;
            sizes[cid] += 1;
            if (rep_ref[cid] == 0) rep_ref[cid] = base | @as(common.PolyRef, @intCast(pi));
        }
    }

    // Largest component id (the main mass) — never flagged.
    var largest_id: usize = 0;
    var largest_sz: usize = 0;
    for (1..n + 1) |cid| {
        if (sizes[cid] > largest_sz) {
            largest_sz = sizes[cid];
            largest_id = cid;
        }
    }

    for (1..n + 1) |cid| {
        if (sizes[cid] == 0) continue;
        const is_largest = (cid == largest_id);
        if (islandShareFlagged(sizes[cid], total_polys, is_largest, min_share)) {
            const pct = 100.0 * @as(f32, @floatFromInt(sizes[cid])) / @as(f32, @floatFromInt(total_polys));
            pushFinding(report, alloc, .warn, .islands, &.{rep_ref[cid]}, "Island: {d} polys ({d:.1}% of mesh)", .{ sizes[cid], pct });
        }
    }
}

// ============================================================================
// NAVMESH HELPERS — bounds-safe link walks for the offmesh/orphan rules.
// ============================================================================

/// Count `poly`'s links whose ref decodes to a tile index DIFFERENT from
/// `tile_idx` (external portal links). Bounds-safe link walk.
fn countExtLinks(nav: *const NavMesh, tile: *const dt.MeshTile, poly: *const dt.Poly, tile_idx: usize) usize {
    var count: usize = 0;
    var li: u32 = poly.first_link;
    while (li != common.NULL_LINK) {
        if (li >= tile.links.len) break; // corrupt link index
        const link = &tile.links[li];
        if (link.ref != 0) {
            const d = nav.decodePolyId(link.ref);
            if (d.tile != @as(u32, @intCast(tile_idx))) count += 1;
        }
        li = link.next;
    }
    return count;
}

/// TRUE if the off-mesh `poly` has at least one link to a NORMAL (ground)
/// polygon — i.e. the connection endpoint attached to land. Bounds-safe.
///
/// An off-mesh poly's links point at the land polys it bridges; if none decode
/// to a ground-type poly, the connection is dangling.
fn offMeshLinkedToLand(nav: *const NavMesh, tile: *const dt.MeshTile, poly: *const dt.Poly) bool {
    var li: u32 = poly.first_link;
    while (li != common.NULL_LINK) {
        if (li >= tile.links.len) break;
        const link = &tile.links[li];
        if (link.ref != 0) {
            var t2: ?*const dt.MeshTile = null;
            var p2: ?*const dt.Poly = null;
            nav.getTileAndPolyByRefUnsafe(link.ref, &t2, &p2);
            if (p2) |pp| {
                if (pp.getType() == .ground) return true;
            }
        }
        li = link.next;
    }
    return false;
}

// ============================================================================
// FINDING APPEND — formats the message + bumps counts (capped at MAX_FINDINGS).
// ============================================================================

fn pushFinding(
    report: *LintReport,
    alloc: std.mem.Allocator,
    severity: Severity,
    rule: Rule,
    refs: []const common.PolyRef,
    comptime fmt: []const u8,
    args: anytype,
) void {
    // Tally counts even past the storage cap (the GUI shows true totals).
    switch (severity) {
        .err => report.error_count += 1,
        .warn => report.warn_count += 1,
        .info => report.info_count += 1,
    }
    if (report.findings.items.len >= MAX_FINDINGS) return;

    var f = Finding{ .severity = severity, .rule = rule };
    const rc: u8 = @intCast(@min(refs.len, f.refs.len));
    for (0..rc) |i| f.refs[i] = refs[i];
    f.ref_count = rc;

    const s = std.fmt.bufPrint(&f.message_buf, fmt, args) catch f.message_buf[0..0];
    f.message_len = @intCast(s.len);

    report.findings.append(alloc, f) catch {}; // OOM -> drop the stored entry (count stands)
}

// ============================================================================
// UNIT TESTS — pure rule predicates (the load-bearing tested bits).
// A full lint() needs a real NavMesh (heavy) -> owner-verified.
// Юнит-тесты только чистых предикатов правил.
// ============================================================================
const testing = std.testing;

test "isDegeneratePoly: real triangle -> false" {
    // (0,0),(1,0),(0,1): area 0.5 -> not degenerate.
    const tri = [_]f32{ 0, 0, 1, 0, 0, 1 };
    try testing.expect(!isDegeneratePoly(&tri, 3, false));
}

test "isDegeneratePoly: collinear / zero-area -> true" {
    const line = [_]f32{ 0, 0, 1, 0, 2, 0 };
    try testing.expect(isDegeneratePoly(&line, 3, false));
}

test "isDegeneratePoly: duplicate vertex index -> true (area ignored)" {
    // A geometrically fine triangle, but the dup_vert flag forces degenerate.
    const tri = [_]f32{ 0, 0, 1, 0, 0, 1 };
    try testing.expect(isDegeneratePoly(&tri, 3, true));
}

test "isDegeneratePoly: <3 verts -> true" {
    const two = [_]f32{ 0, 0, 1, 1 };
    try testing.expect(isDegeneratePoly(&two, 2, false));
}

test "islandShareFlagged: below threshold -> flagged" {
    // 3 of 200 polys = 1.5% < 2% -> flagged.
    try testing.expect(islandShareFlagged(3, 200, false, 0.02));
}

test "islandShareFlagged: above threshold -> not flagged" {
    // 10 of 200 = 5% > 2% -> not flagged.
    try testing.expect(!islandShareFlagged(10, 200, false, 0.02));
}

test "islandShareFlagged: largest component never flagged" {
    // Even a 1-poly component is spared if it is THE largest (degenerate mesh).
    try testing.expect(!islandShareFlagged(1, 200, true, 0.02));
}

test "islandShareFlagged: zero total -> not flagged (no div-by-zero)" {
    try testing.expect(!islandShareFlagged(0, 0, false, 0.02));
}

test "orphanTilePredicate: polys + no ext links -> orphan" {
    try testing.expect(orphanTilePredicate(true, 0));
}

test "orphanTilePredicate: polys + ext links -> not orphan" {
    try testing.expect(!orphanTilePredicate(true, 3));
}

test "orphanTilePredicate: no polys -> not orphan" {
    try testing.expect(!orphanTilePredicate(false, 0));
}

test "Finding.message: round-trips the formatted slice" {
    var report = LintReport{};
    defer report.deinit(testing.allocator);
    pushFinding(&report, testing.allocator, .warn, .islands, &.{42}, "Island: {d} polys", .{3});
    try testing.expectEqual(@as(usize, 1), report.findings.items.len);
    try testing.expectEqual(@as(usize, 1), report.warn_count);
    try testing.expectEqualStrings("Island: 3 polys", report.findings.items[0].message());
    try testing.expectEqual(@as(u8, 1), report.findings.items[0].ref_count);
    try testing.expectEqual(@as(common.PolyRef, 42), report.findings.items[0].refs[0]);
}

test "LintReport: deinit is safe on empty report" {
    var r = LintReport{};
    r.deinit(testing.allocator);
}
