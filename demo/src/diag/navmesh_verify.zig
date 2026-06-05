//! NAVMESH INTEGRITY VERIFIER (cluster G feature G2) — a READ-ONLY structural
//! verifier of a built `dt.NavMesh`. Where the linter (G1) checks navmesh
//! SEMANTICS (islands, dangling off-mesh, null regions), THIS verifier checks
//! the low-level DATA-STRUCTURE INVARIANTS that have broken SILENTLY in real
//! history: portal-link leaks on removeTile, 0xff-memset corruption, stale refs
//! after add/remove cycles.
//!
//! Run it as a post-condition after a tilecache update / removeTile / addTile,
//! or as a CI gate (`--verify`, exit code = violation count).
//!
//! INVARIANTS:
//!   - freelist          per tile, (allocated links + free links) ==
//!                       header.max_link_count; freelist has no cycles and stays
//!                       in bounds. Checked by `freelistConsistent` arithmetic
//!                       over the two cycle-guarded brick counts.
//!   - link_refs         every link.ref is either 0 or a valid poly ref
//!                       (isValidPolyRef).
//!   - portal_symmetry   if poly A links to poly B, B has a reciprocal link back
//!                       to A (link reciprocity).
//!   - offmesh_endpoints each off-mesh poly has a matching OffMeshConnection
//!                       record whose poly index is consistent with the ref.
//!   - salt              every live link ref's salt equals its target tile's
//!                       current salt (no stale ref after remove/add).
//!
//! POLICY: faithful src/* is read-only. VerifyReport owns a heap ArrayList of
//! violations -> caller MUST deinit(alloc). All link walks are bounds- AND
//! cycle-guarded (this verifier runs on SUSPECT data — mirror navmesh_lint's
//! `steps > links.len -> break` hardening). Reusable bricks `countFreeLinks` /
//! `countAllocatedLinks` are extracted so the link-leak regression test can
//! adopt them too (kills the duplicated freelist-walk). common.PolyRef typing
//! (not hardcoded u32 — project supports -Dpolyref64).

const std = @import("std");
const recast = @import("recast-nav");

const dt = recast.detour;
const NavMesh = dt.NavMesh;
const MeshTile = dt.MeshTile;
const Poly = dt.Poly;
const common = dt.common;

// ============================================================================
// REPORT TYPES
// ============================================================================

pub const Invariant = enum { freelist, link_refs, portal_symmetry, offmesh_endpoints, salt };

/// One invariant violation: which invariant fired + the tile/poly/link indices
/// that pinpoint it + a short formatted message. Plain value type (no
/// allocations) — safe to copy. `poly`/`link` are 0xffffffff when N/A.
pub const Violation = struct {
    invariant: Invariant,
    tile: u32,
    poly: u32 = NA,
    link: u32 = NA,
    message_buf: [96]u8 = [_]u8{0} ** 96,
    message_len: u8 = 0,

    /// Sentinel for a poly/link index that does not apply to this violation.
    pub const NA: u32 = 0xffffffff;

    pub fn message(self: *const Violation) []const u8 {
        return self.message_buf[0..self.message_len];
    }
};

/// Cap on stored violations — bounds memory. The total `count` keeps tallying
/// past the cap; only the stored `violations` list is capped.
pub const MAX_VIOLATIONS: usize = 256;

/// Verify results. `ok == (count == 0)`. Owns a heap ArrayList of violations ->
/// caller MUST deinit(alloc).
pub const VerifyReport = struct {
    violations: std.ArrayList(Violation) = .empty,
    /// True total of violations found (may exceed `violations.items.len` if the
    /// MAX_VIOLATIONS storage cap was hit).
    count: usize = 0,
    ok: bool = true,

    pub fn deinit(self: *VerifyReport, alloc: std.mem.Allocator) void {
        self.violations.deinit(alloc);
        self.violations = .empty;
    }
};

// ============================================================================
// PURE HELPER — the freelist arithmetic invariant (unit-tested in isolation).
// ============================================================================

/// Freelist consistency: TRUE iff (allocated + free) exactly accounts for every
/// slot in the per-tile link pool (`max`). A leak (links never returned to the
/// freelist) makes free shrink so the sum drops below max; double-counting makes
/// it exceed. No NavMesh dependency -> trivially unit-tested.
pub fn freelistConsistent(allocated: usize, free: usize, max: usize) bool {
    return allocated + free == max;
}

// ============================================================================
// REUSABLE BRICKS — bounds- AND cycle-guarded link counts. Extracted so the
// removeTile link-leak regression test can REUSE them (eliminates the dup
// `countFreeLinks` walk that test currently inlines).
// ============================================================================

/// Count the links on `tile`'s freelist (unallocated slots). Walks
/// `links_free_list` via `.next`. Cycle-guarded: a corrupt within-bounds cycle
/// (e.g. a slot pointing back at itself after a 0xff-memset partial overwrite)
/// is broken once the step count exceeds the pool size.
pub fn countFreeLinks(tile: *const MeshTile) usize {
    var n: usize = 0;
    var j = tile.links_free_list;
    var steps: usize = 0;
    while (j != common.NULL_LINK) : (steps += 1) {
        if (j >= tile.links.len) break; // out of bounds — corrupt index
        if (steps > tile.links.len) break; // within-bounds cycle guard
        n += 1;
        j = tile.links[j].next;
    }
    return n;
}

/// Count the ALLOCATED links in `tile` by walking every poly's `first_link`
/// chain. Cycle-guarded per chain. Sums across all polys; the freelist sum plus
/// this must equal `header.max_link_count`.
pub fn countAllocatedLinks(tile: *const MeshTile) usize {
    const hdr = tile.header orelse return 0;
    const poly_count: usize = @intCast(hdr.poly_count);
    var n: usize = 0;
    for (0..poly_count) |pi| {
        if (pi >= tile.polys.len) break;
        var j = tile.polys[pi].first_link;
        var steps: usize = 0;
        while (j != common.NULL_LINK) : (steps += 1) {
            if (j >= tile.links.len) break;
            if (steps > tile.links.len) break; // within-bounds cycle guard
            n += 1;
            j = tile.links[j].next;
        }
    }
    return n;
}

// ============================================================================
// VERIFY — run every invariant over the navmesh (bounds-safe, read-only).
// ============================================================================

/// Run all integrity invariants over `nav`. Read-only. Caller deinits the
/// returned report (it owns a heap ArrayList).
pub fn verify(nav: *const NavMesh, alloc: std.mem.Allocator) !VerifyReport {
    var report = VerifyReport{};
    errdefer report.deinit(alloc);

    const num_tiles: usize = @intCast(nav.max_tiles);

    for (0..num_tiles) |ti| {
        const tile = &nav.tiles[ti];
        const hdr = tile.header orelse continue; // empty slot
        const tu: u32 = @intCast(ti);
        const max_links: usize = @intCast(hdr.max_link_count);
        const poly_count: usize = @intCast(hdr.poly_count);

        // --- VERIFY_FREELIST: allocated + free == max_link_count. ----------
        // The two brick counts are cycle-guarded; if their sum disagrees with
        // max there is either a leak (free shrank) or corruption.
        {
            const free = countFreeLinks(tile);
            const allocd = countAllocatedLinks(tile);
            if (!freelistConsistent(allocd, free, max_links)) {
                push(&report, alloc, .{ .invariant = .freelist, .tile = tu }, "Freelist: {d} alloc + {d} free != {d} max", .{ allocd, free, max_links });
            }
        }

        // --- Per-poly invariants: walk each poly's link chain once. --------
        for (0..poly_count) |pi| {
            if (pi >= tile.polys.len) break; // corrupt header vs slice
            const p = &tile.polys[pi];
            const pu: u32 = @intCast(pi);

            // VERIFY_OFFMESH_ENDPOINTS: an off-mesh poly must have a matching
            // OffMeshConnection record reachable by its OWN ref (salt/tile/poly
            // consistent). getOffMeshConnectionByRef returns null on any
            // salt/tile/index mismatch, so a null here means the ref no longer
            // resolves to its own connection.
            if (p.getType() == .offmesh_connection) {
                const self_ref: common.PolyRef = nav.getPolyRefBase(tile) | @as(common.PolyRef, pu);
                const con = nav.getOffMeshConnectionByRef(self_ref);
                if (con == null) {
                    push(&report, alloc, .{ .invariant = .offmesh_endpoints, .tile = tu, .poly = pu }, "Off-mesh endpoint mismatch: ref does not resolve to its connection", .{});
                } else if (con.?.poly != @as(u16, @truncate(pu))) {
                    push(&report, alloc, .{ .invariant = .offmesh_endpoints, .tile = tu, .poly = pu }, "Off-mesh endpoint mismatch: con.poly {d} != poly {d}", .{ con.?.poly, pu });
                }
            }

            // Walk the poly's allocated link chain (bounds + cycle guarded).
            var li: u32 = p.first_link;
            var steps: usize = 0;
            while (li != common.NULL_LINK) : (steps += 1) {
                if (li >= tile.links.len) break; // corrupt link index
                if (steps > tile.links.len) break; // within-bounds cycle guard
                const link = &tile.links[li];
                const lu = li;

                if (link.ref != 0) {
                    // VERIFY_LINK_REFS: every non-zero ref must be valid.
                    if (!nav.isValidPolyRef(link.ref)) {
                        push(&report, alloc, .{ .invariant = .link_refs, .tile = tu, .poly = pu, .link = lu }, "Link ref invalid: 0x{X}", .{link.ref});
                    } else {
                        // VERIFY_SALT: the ref's salt must equal its target
                        // tile's CURRENT salt (no stale ref after remove/add).
                        const d = nav.decodePolyId(link.ref);
                        if (d.tile < @as(u32, @intCast(nav.max_tiles))) {
                            const target = &nav.tiles[d.tile];
                            if (target.salt != d.salt) {
                                push(&report, alloc, .{ .invariant = .salt, .tile = tu, .poly = pu, .link = lu }, "Stale salt: ref salt {d} != tile salt {d}", .{ d.salt, target.salt });
                            }
                        }

                        // VERIFY_PORTAL_SYMMETRY: B (= link.ref) must have a
                        // reciprocal link back to A (= self_ref). ONLY for genuine
                        // tile-portal (poly<->poly) links. Off-mesh connections are
                        // INTENTIONALLY directional: a unidirectional off-mesh link
                        // has no reciprocal, so flagging it would cry wolf. Exclude
                        // off-mesh links — the forward link's SOURCE is the off-mesh
                        // poly (getType), and Detour marks off-mesh back-links with
                        // edge==0xff. (Detour: navmesh.zig baseOffMeshLinks /
                        // connectExtOffMeshLinks.)
                        const is_offmesh_link = p.getType() == .offmesh_connection or link.edge == 0xff;
                        if (!is_offmesh_link) {
                            const self_ref: common.PolyRef = nav.getPolyRefBase(tile) | @as(common.PolyRef, pu);
                            if (!hasReciprocalLink(nav, link.ref, self_ref)) {
                                push(&report, alloc, .{ .invariant = .portal_symmetry, .tile = tu, .poly = pu, .link = lu }, "Portal A->B no reciprocal (B=0x{X})", .{link.ref});
                            }
                        }
                    }
                }

                li = link.next;
            }
        }
    }

    report.ok = (report.count == 0);
    return report;
}

/// TRUE if poly `b_ref` has a link back to `a_ref` — the reciprocity half of
/// portal symmetry. Bounds- AND cycle-guarded link walk over B's chain.
fn hasReciprocalLink(nav: *const NavMesh, b_ref: common.PolyRef, a_ref: common.PolyRef) bool {
    var tb: ?*const MeshTile = null;
    var pb: ?*const Poly = null;
    nav.getTileAndPolyByRefUnsafe(b_ref, &tb, &pb);
    const tile = tb orelse return false;
    const poly = pb orelse return false;

    var li: u32 = poly.first_link;
    var steps: usize = 0;
    while (li != common.NULL_LINK) : (steps += 1) {
        if (li >= tile.links.len) break;
        if (steps > tile.links.len) break; // within-bounds cycle guard
        if (tile.links[li].ref == a_ref) return true;
        li = tile.links[li].next;
    }
    return false;
}

// ============================================================================
// VIOLATION APPEND — formats the message + bumps the count (capped).
// ============================================================================

fn push(
    report: *VerifyReport,
    alloc: std.mem.Allocator,
    base: Violation,
    comptime fmt: []const u8,
    args: anytype,
) void {
    report.count += 1; // tally even past the storage cap
    if (report.violations.items.len >= MAX_VIOLATIONS) return;

    var v = base;
    const s = std.fmt.bufPrint(&v.message_buf, fmt, args) catch v.message_buf[0..0];
    v.message_len = @intCast(s.len);
    report.violations.append(alloc, v) catch {}; // OOM -> drop entry (count stands)
}

// ============================================================================
// UNIT TESTS — pure helper + a real built navmesh (the high-value case).
// ============================================================================
const testing = std.testing;

test "freelistConsistent: alloc+free==max -> true" {
    try testing.expect(freelistConsistent(12, 28, 40));
}

test "freelistConsistent: leak (sum below max) -> false" {
    try testing.expect(!freelistConsistent(12, 20, 40));
}

test "freelistConsistent: double-count (sum above max) -> false" {
    try testing.expect(!freelistConsistent(30, 20, 40));
}

test "freelistConsistent: empty pool" {
    try testing.expect(freelistConsistent(0, 0, 0));
}

test "Violation.message round-trips + NA sentinels" {
    var report = VerifyReport{};
    defer report.deinit(testing.allocator);
    push(&report, testing.allocator, .{ .invariant = .freelist, .tile = 3 }, "Freelist: {d} alloc + {d} free != {d} max", .{ 12, 30, 40 });
    try testing.expectEqual(@as(usize, 1), report.count);
    try testing.expectEqual(@as(usize, 1), report.violations.items.len);
    const v = report.violations.items[0];
    try testing.expectEqualStrings("Freelist: 12 alloc + 30 free != 40 max", v.message());
    try testing.expectEqual(@as(u32, 3), v.tile);
    try testing.expectEqual(Violation.NA, v.poly);
    try testing.expectEqual(Violation.NA, v.link);
}

test "VerifyReport.deinit is safe on empty report" {
    var r = VerifyReport{};
    r.deinit(testing.allocator);
}

// Highest-value test: build a REAL two-tile navmesh (same helper the link-leak
// regression test uses) and assert verify() passes it clean, AND that the brick
// counts satisfy the freelist arithmetic on every live tile. Proves the
// verifier accepts a valid mesh (no false positives) on actual Detour data.
const fixture = @import("navmesh_verify_fixture.zig");

test "verify(): freshly-built two-tile navmesh is integrity-OK" {
    const allocator = testing.allocator;

    var fx = try fixture.buildTwoTile(allocator);
    defer fx.deinit();

    var report = try verify(&fx.navmesh, allocator);
    defer report.deinit(allocator);

    if (!report.ok) {
        for (report.violations.items) |*v| {
            std.debug.print("[verify] {s} tile={d} poly={d} link={d}: {s}\n", .{ @tagName(v.invariant), v.tile, v.poly, v.link, v.message() });
        }
    }
    try testing.expect(report.ok);
    try testing.expectEqual(@as(usize, 0), report.count);
}

test "bricks: countFreeLinks + countAllocatedLinks == max_link_count per live tile" {
    const allocator = testing.allocator;

    var fx = try fixture.buildTwoTile(allocator);
    defer fx.deinit();

    const num_tiles: usize = @intCast(fx.navmesh.max_tiles);
    var live: usize = 0;
    for (0..num_tiles) |ti| {
        const tile = &fx.navmesh.tiles[ti];
        const hdr = tile.header orelse continue;
        live += 1;
        const max: usize = @intCast(hdr.max_link_count);
        try testing.expect(freelistConsistent(countAllocatedLinks(tile), countFreeLinks(tile), max));
    }
    try testing.expect(live >= 2); // both tiles added
}
