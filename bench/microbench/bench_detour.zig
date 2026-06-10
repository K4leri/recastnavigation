//! Bench group: detour.common + detour.builder leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;

var node_pool_4096: ?*nav.detour.query.NodePool = null;

fn setupNodePool4096() void {
    if (node_pool_4096 == null) {
        node_pool_4096 = nav.detour.query.NodePool.init(std.heap.smp_allocator, 4096, 1024) catch @panic("NodePool.init failed");
    } else {
        node_pool_4096.?.clear();
    }
}

// ---------------------------------------------------------------------------
// triArea2D  (detour.common)
// ---------------------------------------------------------------------------

fn runTriArea2D(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 4 + f, 0, 1.3 };
    const c = [3]f32{ 2, 0, 5.7 };
    dna(nav.detour.common.triArea2D(&a, &b, &c));
}
fn checkTriArea2D() bool {
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 1, 0, 0 };
    const c = [3]f32{ 0, 0, 1 };
    // acx*abz - abx*acz = 0*0 - 1*1 = -1, nonzero is the sane check
    return nav.detour.common.triArea2D(&a, &b, &c) != 0.0;
}

// Analog: replace the two-multiply subtraction with a single @mulAdd (fma).
// Expected verdict: REJECT — f32 fma and two-op sub differ for a subset of inputs
// due to the absence of intermediate rounding, so the exact == gate will fire.
fn triArea2D_fma(a: *const [3]f32, b: *const [3]f32, c: *const [3]f32) f32 {
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const abx = b[0] - a[0];
    const acz = c[2] - a[2];
    return @mulAdd(f32, acx, abz, -(abx * acz));
}
fn runTriArea2DFma(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    const a = [3]f32{ 0, 0, 0 };
    const b = [3]f32{ 4 + f, 0, 1.3 };
    const c = [3]f32{ 2, 0, 5.7 };
    dna(triArea2D_fma(&a, &b, &c));
}
fn checkTriArea2DFma() bool {
    var i: usize = 1;
    while (i < 5000) : (i += 1) {
        const fa: f32 = @floatFromInt(i);
        const a = [3]f32{ 0, 0, 0 };
        const b = [3]f32{ fa * 0.7, 0, 1.3 };
        const c = [3]f32{ 2.1, 0, fa * 0.3 };
        if (triArea2D_fma(&a, &b, &c) != nav.detour.common.triArea2D(&a, &b, &c)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// calcExtends  (detour.builder)
// Input: a slice of BVItems (imin=0, imax=len), two *[3]u16 out-params.
// ---------------------------------------------------------------------------

// Build a fixed-size input array varied by i.
fn makeItems(i: usize) [4]nav.detour.builder.BVItem {
    const base: u16 = @intCast(i & 0xFF);
    return [4]nav.detour.builder.BVItem{
        .{ .bmin = [3]u16{ base, 0, 0 }, .bmax = [3]u16{ base + 10, 5, 5 }, .i = 0 },
        .{ .bmin = [3]u16{ 3, base, 2 }, .bmax = [3]u16{ 12, base + 8, 9 }, .i = 1 },
        .{ .bmin = [3]u16{ 1, 1, base }, .bmax = [3]u16{ 7, 7, base + 15 }, .i = 2 },
        .{ .bmin = [3]u16{ 5, 5, 5 }, .bmax = [3]u16{ 20, 20, 20 }, .i = 3 },
    };
}

fn runCalcExtends(i: usize) void {
    const items = makeItems(i);
    var bmin: [3]u16 = undefined;
    var bmax: [3]u16 = undefined;
    nav.detour.builder.calcExtends(&items, 0, items.len, &bmin, &bmax);
    dna(bmin[0]);
}
fn checkCalcExtends() bool {
    // Known-correct result for i=0 (base=0):
    // items[0]: bmin={0,0,0} bmax={10,5,5}
    // items[1]: bmin={3,0,2} bmax={12,8,9}
    // items[2]: bmin={1,1,0} bmax={7,7,15}
    // items[3]: bmin={5,5,5} bmax={20,20,20}
    // overall bmin = {0,0,0}, bmax = {20,20,20}
    const items = makeItems(0);
    var bmin: [3]u16 = undefined;
    var bmax: [3]u16 = undefined;
    nav.detour.builder.calcExtends(&items, 0, items.len, &bmin, &bmax);
    return bmin[0] == 0 and bmin[1] == 0 and bmin[2] == 0 and
        bmax[0] == 20 and bmax[1] == 20 and bmax[2] == 20;
}

// Analog: loop unrolled/restructured to process all 3 axes in a single pass
// using explicit temps instead of direct array writes (same @min/@max logic).
// Expected verdict: TIE (bit-identical) — pure min/max reduction, no
// floating-point arithmetic; restructuring cannot change the result.
fn calcExtends_unrolled(items: []const nav.detour.builder.BVItem, imin: usize, imax: usize, bmin: *[3]u16, bmax: *[3]u16) void {
    var mn0 = items[imin].bmin[0];
    var mn1 = items[imin].bmin[1];
    var mn2 = items[imin].bmin[2];
    var mx0 = items[imin].bmax[0];
    var mx1 = items[imin].bmax[1];
    var mx2 = items[imin].bmax[2];
    for (items[imin + 1 .. imax]) |it| {
        if (it.bmin[0] < mn0) mn0 = it.bmin[0];
        if (it.bmin[1] < mn1) mn1 = it.bmin[1];
        if (it.bmin[2] < mn2) mn2 = it.bmin[2];
        if (it.bmax[0] > mx0) mx0 = it.bmax[0];
        if (it.bmax[1] > mx1) mx1 = it.bmax[1];
        if (it.bmax[2] > mx2) mx2 = it.bmax[2];
    }
    bmin.* = [3]u16{ mn0, mn1, mn2 };
    bmax.* = [3]u16{ mx0, mx1, mx2 };
}
fn runCalcExtendsUnrolled(i: usize) void {
    const items = makeItems(i);
    var bmin: [3]u16 = undefined;
    var bmax: [3]u16 = undefined;
    calcExtends_unrolled(&items, 0, items.len, &bmin, &bmax);
    dna(bmin[0]);
}
fn checkCalcExtendsUnrolled() bool {
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const items = makeItems(i);
        var bmin_orig: [3]u16 = undefined;
        var bmax_orig: [3]u16 = undefined;
        var bmin_alt: [3]u16 = undefined;
        var bmax_alt: [3]u16 = undefined;
        nav.detour.builder.calcExtends(&items, 0, items.len, &bmin_orig, &bmax_orig);
        calcExtends_unrolled(&items, 0, items.len, &bmin_alt, &bmax_alt);
        if (bmin_alt[0] != bmin_orig[0] or bmin_alt[1] != bmin_orig[1] or bmin_alt[2] != bmin_orig[2]) return false;
        if (bmax_alt[0] != bmax_orig[0] or bmax_alt[1] != bmax_orig[1] or bmax_alt[2] != bmax_orig[2]) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// NodePool sliced-path fixed costs  (detour.query)
// ---------------------------------------------------------------------------

fn runNodePoolClear4096(_: usize) void {
    const pool = node_pool_4096.?;
    pool.clear();
    dna(pool.node_count);
}
fn checkNodePoolClear4096() bool {
    const pool = node_pool_4096.?;
    _ = pool.getNode(42, 0) orelse return false;
    pool.clear();
    return pool.node_count == 0 and pool.findNode(42, 0) == null;
}

fn runNodePoolClearGetNode4096(i: usize) void {
    const pool = node_pool_4096.?;
    pool.clear();
    const id: nav.detour.common.PolyRef = @intCast((i & 0xffff) + 1);
    const node = pool.getNode(id, 0) orelse return;
    dna(node.id);
}
fn checkNodePoolClearGetNode4096() bool {
    const pool = node_pool_4096.?;
    pool.clear();
    const node = pool.getNode(1234, 0) orelse return false;
    return node.id == 1234 and node.state == 0 and node.flags.open == false and pool.node_count == 1;
}

// ---------------------------------------------------------------------------
// Navmesh-backed query leaves: isValidPolyRef + getPolyHeight  (detour.query)
// Both are below the System-B QPC floor (~45-194 ns scenario means), so they are
// measured here in isolation on a real (synthetic) navmesh fixture. The fixture
// is a flat 60x60 ground plane run through the full recast pipeline once in an
// UNTIMED setup hook, then a center point is snapped via findNearestPoly to get a
// valid (ref, point-on-poly). Reusable for any future Detour query-leaf bench.
// ---------------------------------------------------------------------------

const QueryFixture = struct {
    navmesh: *nav.NavMesh,
    query: *nav.NavMeshQuery,
    filter: nav.QueryFilter,
    ref: nav.detour.common.PolyRef,
    pt: [3]f32,
};
var query_fixture: ?QueryFixture = null;

fn buildQueryFixture() void {
    if (query_fixture != null) return;
    const allocator = std.heap.smp_allocator;
    var ctx = nav.Context.init(allocator);
    ctx.enableLog(false);
    ctx.enableTimer(false);

    // Flat ground plane (2 triangles) spanning [0,60] x [0,60] at y=0.
    const verts = [_]f32{
        0,  0, 0,
        60, 0, 0,
        60, 0, 60,
        0,  0, 60,
    };
    const tris = [_]i32{ 0, 1, 2, 0, 2, 3 };

    const cs: f32 = 0.3;
    const ch: f32 = 0.2;
    const walkable_height: i32 = 10;
    const walkable_climb: i32 = 4;
    const walkable_radius: i32 = 2;

    const bmin = nav.Vec3.init(0, -1, 0);
    const bmax = nav.Vec3.init(60, 1, 60);
    var width: i32 = 0;
    var height: i32 = 0;
    nav.RecastConfig.calcGridSize(bmin, bmax, cs, &width, &height);

    var hf = nav.Heightfield.init(allocator, width, height, bmin, bmax, cs, ch) catch @panic("hf");
    const areas = allocator.alloc(u8, 2) catch @panic("areas");
    @memset(areas, 1);
    nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &tris, areas, &hf, walkable_climb) catch @panic("raster");
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, walkable_climb, &hf);
    nav.recast.filter.filterLedgeSpans(&ctx, walkable_height, walkable_climb, &hf);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, walkable_height, &hf);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    var chf = nav.CompactHeightfield.init(allocator, width, height, @intCast(span_count), walkable_height, walkable_climb, bmin, bmax, cs, ch, 0) catch @panic("chf");
    nav.recast.compact.buildCompactHeightfield(&ctx, walkable_height, walkable_climb, &hf, &chf) catch @panic("bchf");
    nav.recast.area.erodeWalkableArea(&ctx, walkable_radius, &chf, allocator) catch @panic("erode");
    nav.recast.region.buildDistanceField(&ctx, &chf, allocator) catch @panic("df");
    nav.recast.region.buildRegions(&ctx, &chf, 0, 8, 20, allocator) catch @panic("regions");

    var cset = nav.ContourSet.init(allocator);
    nav.recast.contour.buildContours(&ctx, &chf, 1.3, 12, &cset, 0, allocator) catch @panic("contours");
    var pmesh = nav.PolyMesh.init(allocator);
    nav.recast.mesh.buildPolyMesh(&ctx, &cset, 6, &pmesh, allocator) catch @panic("pmesh");
    var dmesh = nav.PolyMeshDetail.init(allocator);
    nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, 6.0, 1.0, &dmesh, allocator) catch @panic("dmesh");
    if (pmesh.npolys == 0) @panic("fixture navmesh empty");

    const poly_flags = allocator.alloc(u16, @intCast(pmesh.npolys)) catch @panic("flags");
    @memset(poly_flags, 0x01);
    const params = nav.detour.NavMeshCreateParams{
        .verts = pmesh.verts,
        .vert_count = @intCast(pmesh.nverts),
        .polys = pmesh.polys,
        .poly_flags = poly_flags,
        .poly_areas = pmesh.areas,
        .poly_count = @intCast(pmesh.npolys),
        .nvp = @intCast(pmesh.nvp),
        .detail_meshes = dmesh.meshes,
        .detail_verts = dmesh.verts,
        .detail_verts_count = @intCast(dmesh.nverts),
        .detail_tris = dmesh.tris,
        .detail_tri_count = @intCast(dmesh.ntris),
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(walkable_climb)) * ch,
        .cs = cs,
        .ch = ch,
        .build_bv_tree = true,
    };
    const data = nav.detour.createNavMeshData(&params, allocator) catch @panic("createNavMeshData");

    const navmesh = allocator.create(nav.NavMesh) catch @panic("alloc navmesh");
    navmesh.* = nav.NavMesh.init(allocator, .{
        .orig = bmin,
        .tile_width = @as(f32, @floatFromInt(width)) * cs,
        .tile_height = @as(f32, @floatFromInt(height)) * cs,
        .max_tiles = 1,
        .max_polys = @intCast(nav.math.nextPow2(@as(u32, @intCast(pmesh.npolys)))),
    }) catch @panic("navmesh.init");
    _ = navmesh.addTile(data, .{ .free_data = true }, 0) catch @panic("addTile");

    const query = nav.NavMeshQuery.init(allocator) catch @panic("query.init");
    query.initQuery(navmesh, 2048) catch @panic("initQuery");
    const filter = nav.QueryFilter.init();

    const center = [3]f32{ 30, 0, 30 };
    const half = [3]f32{ 8, 2000, 8 };
    var ref: nav.detour.common.PolyRef = 0;
    var pt: [3]f32 = undefined;
    query.findNearestPoly(&center, &half, &filter, &ref, &pt) catch @panic("snap");
    if (ref == 0) @panic("fixture snap failed (ref=0)");

    // Free the recast intermediates; the navmesh owns its own tile copy.
    hf.deinit();
    chf.deinit();
    cset.deinit();
    pmesh.deinit();
    dmesh.deinit();
    allocator.free(areas);
    allocator.free(poly_flags);

    query_fixture = .{ .navmesh = navmesh, .query = query, .filter = filter, .ref = ref, .pt = pt };
}

fn runIsValidPolyRef(i: usize) void {
    const fx = query_fixture.?;
    // Alternate valid/invalid ref by i so the branch is not fully predictable and
    // the result cannot be hoisted out of the batch loop.
    const ref = if (i & 1 == 0) fx.ref else fx.ref ^ 0x1;
    dna(fx.query.isValidPolyRef(ref, &fx.filter));
}
fn checkIsValidPolyRef() bool {
    const fx = query_fixture.?;
    return fx.query.isValidPolyRef(fx.ref, &fx.filter);
}

fn runGetPolyHeight(i: usize) void {
    const fx = query_fixture.?;
    // Jitter the query point within the poly so getPolyHeight isn't loop-invariant.
    const j: f32 = @floatFromInt(i & 7);
    const pos = [3]f32{ fx.pt[0] + j * 0.01, fx.pt[1], fx.pt[2] + j * 0.01 };
    var h: f32 = 0;
    _ = fx.query.getPolyHeight(fx.ref, &pos, &h) catch {};
    dna(h);
}
fn checkGetPolyHeight() bool {
    const fx = query_fixture.?;
    var h: f32 = -1;
    const st = fx.query.getPolyHeight(fx.ref, &fx.pt, &h) catch return false;
    return st.isSuccess();
}

// ---------------------------------------------------------------------------
// Bench table
// ---------------------------------------------------------------------------

pub const benches = [_]core.Bench{
    .{ .name = "triArea2D", .module = "detour.common", .isolation = "A", .run = runTriArea2D, .check = checkTriArea2D },
    .{ .name = "triArea2D", .module = "detour.common", .impl = "fma", .isolation = "A", .run = runTriArea2DFma, .check = checkTriArea2DFma },
    .{ .name = "calcExtends", .module = "detour.builder", .isolation = "A", .run = runCalcExtends, .check = checkCalcExtends },
    .{ .name = "calcExtends", .module = "detour.builder", .impl = "unrolled", .isolation = "A", .run = runCalcExtendsUnrolled, .check = checkCalcExtendsUnrolled },
    .{ .name = "NodePool.clear_4096x1024", .module = "detour.query", .isolation = "A", .setup = setupNodePool4096, .run = runNodePoolClear4096, .check = checkNodePoolClear4096 },
    .{ .name = "NodePool.clear_getNode_4096x1024", .module = "detour.query", .isolation = "A", .setup = setupNodePool4096, .run = runNodePoolClearGetNode4096, .check = checkNodePoolClearGetNode4096 },
    .{ .name = "isValidPolyRef", .module = "detour.query", .isolation = "A", .setup = buildQueryFixture, .run = runIsValidPolyRef, .check = checkIsValidPolyRef },
    .{ .name = "getPolyHeight", .module = "detour.query", .isolation = "A", .setup = buildQueryFixture, .run = runGetPolyHeight, .check = checkGetPolyHeight },
};
