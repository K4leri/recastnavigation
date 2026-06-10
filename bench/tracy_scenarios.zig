//! Zig benchmark runner FRAMEWORK + the 14 BUILD scenarios (Task 3.2a, v2).
//!
//! Implements the BUILD layer (§3) of `dev/research/performance_analysis/scenarios.md`
//! — the SINGLE SOURCE OF TRUTH for scenario ids / configs / the global LCG / the
//! DERIVED-CS rule (§2.2) / the 64M cell-budget guard (§2.3) / the tiled-region rule
//! (§2.5). The runner drives the instrumented Recast pipeline (Tracy zones live INSIDE
//! the core; they RECORD when the binary is built with `-Dbench=true` or `-Dtracy=true`), aggregates
//! per-zone self/inclusive times in the in-process `tracy_registry`, and dumps a CSV
//! that the C++ runner (`Bench/tracy_scenarios.cpp`) must match byte-for-byte.
//!
//! CLI: `tracy_scenarios <scenario_id|id1,id2,...|all> <geom_dir> <out_csv>`
//!   geom_dir = dir containing the dense BVH world meshes `<map>_bvh.obj`
//!   (i.e. test_data/bench_geom). scenario_id = one BUILD id, a comma-separated
//!   subset, or 'all'.
//!
//! QUERY/CROWD layers are a SEPARATE later task (§4/§5). The dispatch table + the
//! layer-agnostic `runAndDump`/registry-dump loop make adding them a matter of
//! appending rows + a new per-scenario run fn — the framework already isolates
//! geometry caching, registry reset, derived-cs, the budget guard and CSV emission.

const std = @import("std");
const nav = @import("zig-recast");
const registry = @import("tracy_registry");
const obj = @import("obj_loader.zig");

// Bench-local alias for the navmesh ref type. Defaults to u32; under
// `-Dpolyref64=true` the whole library switches PolyRef -> u64, so all ref-typed
// locals/buffers in this runner follow suit and the same scenario suite builds
// and runs under both ref widths. (LCG/hash u32 are unrelated and stay u32.)
const PolyRef = nav.PolyRef;

// ===========================================================================
// §2.1 Deterministic RNG (LCG) — Numerical Recipes.
//   state_{n+1} = state_n * 1664525 + 1013904223 (mod 2^32)
//   CONTRACT: advance FIRST, then use the new state. f = state / 2^32.
// Included now for §3.2b (QUERY/CROWD) reuse + any tiled region jitter. BUILD
// scenarios are deterministic from geometry and do NOT draw from it, so its
// presence here is dead-but-contracted for the later layers.
// ===========================================================================
pub const Lcg = struct {
    state: u32 = 12345,

    pub fn init(seed: u32) Lcg {
        return .{ .state = seed };
    }

    /// Advance the stream and return the new 32-bit state (overflow wraps mod 2^32).
    pub fn next(self: *Lcg) u32 {
        self.state = self.state *% 1664525 +% 1013904223;
        return self.state;
    }

    /// Advance, then map the new state to a float in [0,1): f = state / 2^32.
    pub fn nextFloat(self: *Lcg) f64 {
        const s = self.next();
        return @as(f64, @floatFromInt(s)) / 4294967296.0;
    }
};

const LcgRandom = struct {
    rng: Lcg,

    fn init(seed: u32) LcgRandom {
        return .{ .rng = Lcg.init(seed) };
    }

    fn random(self: *LcgRandom) std.Random {
        return std.Random.init(self, fill);
    }

    fn fill(self: *LcgRandom, buf: []u8) void {
        var offset: usize = 0;
        while (offset < buf.len) {
            const value = self.rng.next();
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, value, .little);
            const n = @min(4, buf.len - offset);
            @memcpy(buf[offset .. offset + n], bytes[0..n]);
            offset += n;
        }
    }
};

// ===========================================================================
// §2.3 HARD CELL BUDGET GUARD — the safety net. NEVER build a grid this big.
// ===========================================================================
const cell_budget: i64 = 64_000_000;

var enable_core_log = false;
var trace_crowd_ticks = false;

// ===========================================================================
// Scenario configuration
// ===========================================================================

/// Region-partition algorithm. Drives the prerequisite call sequence:
///   watershed -> buildDistanceField THEN buildRegions(min, merge)
///   monotone  -> buildRegionsMonotone(min, merge)        [NO distance field]
///   layers    -> buildLayerRegions(min)                  [NO distance field, NO merge]
const Partition = enum { watershed, monotone, layers };

/// Resolved per-scenario BUILD config (concrete numbers from scenarios.md §2/§3).
/// `cs`/`ch`/`width`/`height` are NOT stored here — they are DERIVED at build time
/// from the loaded mesh's XZ bbox (solo, §2.2) or FIXED to 0.3/0.15 (tiled, §2.5).
const BuildCfg = struct {
    geometry: []const u8, // obj file basename (the dense BVH world mesh)
    partition: Partition,

    /// SOLO derived-cs budget (§2.2). Ignored when `tiled` (tiled uses fixed cs=0.3).
    target_cells: f64,

    walkable_slope_angle: f32 = 45.0,
    walkable_height: i32 = 10,
    walkable_climb: i32 = 4,
    walkable_radius: i32 = 2, // fat-agent probe overrides to 8
    max_edge_len: i32 = 12,
    max_simplification_error: f32 = 1.3,
    min_region_area: i32 = 8,
    merge_region_area: i32 = 20, // unused by the layers partition
    max_verts_per_poly: i32 = 6,
    detail_sample_dist: f32 = 6.0, // dense-detail probe overrides to 1.5
    detail_sample_max_error: f32 = 1.0, // dense-detail probe overrides to 0.5

    tiled: bool = false,
    tile_size: i32 = 0, // VOXELS, tiled only (128 per §3)

    // Off-mesh-connection build coverage: when > 0, buildOne feeds N deterministic
    // off-mesh connections into createNavMeshData, exercising the off-mesh build
    // path (overlap classification + off-mesh poly/link storage) that the plain
    // build never touches. Solo only.
    offmesh_cons: usize = 0,

    iters: usize,
};

const Scenario = struct {
    id: []const u8,
    cfg: BuildCfg,
};

// ---------------------------------------------------------------------------
// §3 BUILD scenario table — all 14. Concrete values copied from scenarios.md §3.
//   - 6 per-map solo watershed @8M
//   - monotone_map_1 @8M, layers_map_1 @8M
//   - coarse @2M, fine @24M, fat_agent (radius=8), dense_detail (dist=1.5/err=0.5)
//   - 2 tiled-region (inferno watershed, overpass layers): cs=0.3, tile_size=128
// border_size is NOT a field: solo => 0, tiled => walkable_radius+3 (computed in
// buildOne) — exactly the recast convention rcConfig.borderSize = walkableRadius+3.
// ---------------------------------------------------------------------------
const build_scenarios = [_]Scenario{
    // ---- 6 per-map SOLO watershed @ target_cells = 8M ----
    .{ .id = "build_solo_watershed_map_6", .cfg = .{
        .geometry = "map_6_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 5,
    } },
    .{ .id = "build_solo_watershed_map_5", .cfg = .{
        .geometry = "map_5_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 5,
    } },
    .{ .id = "build_solo_watershed_map_2", .cfg = .{
        .geometry = "map_2_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 5,
    } },
    .{ .id = "build_solo_watershed_map_4", .cfg = .{
        .geometry = "map_4_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 4,
    } },
    .{ .id = "build_solo_watershed_map_1", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 4,
    } },
    .{ .id = "build_solo_watershed_map_3", .cfg = .{
        .geometry = "map_3_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .iters = 3,
    } },

    // ---- partition variants on map_1 @ 8M ----
    .{ .id = "build_solo_monotone_map_1", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .monotone,
        .target_cells = 8_000_000, .iters = 4,
    } },
    .{ .id = "build_solo_layers_map_1", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .layers,
        .target_cells = 8_000_000, .iters = 4,
    } },

    // ---- cs-sensitivity sweep on map_1 ----
    .{ .id = "build_solo_watershed_map_1_coarse", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 2_000_000, .iters = 6,
    } },
    .{ .id = "build_solo_watershed_map_1_fine", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 24_000_000, .iters = 2,
    } },

    // ---- agent/detail probes on map_1 @ 8M ----
    .{ .id = "build_solo_watershed_map_1_fat_agent", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .walkable_radius = 8, .iters = 4,
    } },
    .{ .id = "build_solo_watershed_map_1_dense_detail", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000,
        .detail_sample_dist = 1.5, .detail_sample_max_error = 0.5, .iters = 3,
    } },

    // ---- 2 TILED-region (fixed cs=0.3, central 600-unit half-extent, tile_size=128) ----
    .{ .id = "build_tiled_watershed_map_3_region", .cfg = .{
        .geometry = "map_3_bvh.obj", .partition = .watershed,
        .target_cells = 0, .tiled = true, .tile_size = 128, .iters = 2,
    } },
    .{ .id = "build_tiled_layers_map_4_region", .cfg = .{
        .geometry = "map_4_bvh.obj", .partition = .layers,
        .target_cells = 0, .tiled = true, .tile_size = 128, .iters = 2,
    } },
    // Multi-map tiled coverage (watershed tiled on two more maps).
    .{ .id = "build_tiled_watershed_map_2_region", .cfg = .{
        .geometry = "map_2_bvh.obj", .partition = .watershed,
        .target_cells = 0, .tiled = true, .tile_size = 128, .iters = 2,
    } },
    .{ .id = "build_tiled_watershed_map_1_region", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 0, .tiled = true, .tile_size = 128, .iters = 2,
    } },
    // Off-mesh-connection build coverage (solo watershed + 32 off-mesh cons).
    .{ .id = "build_solo_offmesh_map_1", .cfg = .{
        .geometry = "map_1_bvh.obj", .partition = .watershed,
        .target_cells = 8_000_000, .offmesh_cons = 32, .iters = 4,
    } },
};

// ===========================================================================
// §2.5 Tiled region constants.
// ===========================================================================
const tiled_cs: f32 = 0.3;
const tiled_ch: f32 = 0.15;
const tiled_region_half_extent: f32 = 600.0;

// ===========================================================================
// Resolved grid (cs/ch/width/height) for a single SOLO build, plus the bbox.
// ===========================================================================
const Grid = struct {
    cs: f32,
    ch: f32,
    width: i32,
    height: i32,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
};

/// §2.2 DERIVED CELL SIZE. Compute IDENTICALLY to the C++ port:
///   cs     = sqrt((dx*dz)/target_cells)   // dx,dz from loaded XZ bbox, full f32
///   ch     = cs * 0.5
///   width  = ceil(dx/cs)  (integer ceil of the f32 division)
///   height = ceil(dz/cs)
fn deriveSoloGrid(geom: Geom, target_cells: f64) Grid {
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    calcBoundsFlat(geom.verts, &bmin, &bmax);

    const dx: f64 = @floatCast(bmax.x - bmin.x);
    const dz: f64 = @floatCast(bmax.z - bmin.z);
    // cs kept in full f32 precision — the raw sqrt result, NOT rounded/snapped.
    const cs: f32 = @floatCast(@sqrt((dx * dz) / target_cells));
    const ch: f32 = cs * 0.5;
    const width: i32 = @intFromFloat(@ceil((bmax.x - bmin.x) / cs));
    const height: i32 = @intFromFloat(@ceil((bmax.z - bmin.z) / cs));
    return .{ .cs = cs, .ch = ch, .width = width, .height = height, .bmin = bmin, .bmax = bmax };
}

// ===========================================================================
// Recast pipeline — one full rebuild over a triangle soup within given bounds.
// Mirrors bench/recast_bench.zig's call sequence (signatures verified against the
// current core); the timing harness is the in-core Tracy zones, NOT a Timer.
// ===========================================================================

/// Input geometry already split into flat f32 verts + i32 (0-indexed) tris.
const Geom = struct {
    verts: []const f32,
    tris: []const i32,

    fn triCount(self: Geom) usize {
        return self.tris.len / 3;
    }
};

/// Build a single navmesh tile/mesh from `geom` over [bmin,bmax] with `cfg` at the
/// given `cs`/`ch`/`width`/`height`/`border_size`. Every Recast/Detour zone in the
/// chain fires exactly once per call → a solo build records count=1/zone/iter and a
/// tiled build records count=tiles/zone/iter.
fn buildOne(
    allocator: std.mem.Allocator,
    geom: Geom,
    cfg: BuildCfg,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
    cs: f32,
    ch: f32,
    width: i32,
    height: i32,
    border_size: i32,
    tile_x: i32,
    tile_z: i32,
) !void {
    if (width <= 0 or height <= 0) return; // degenerate / empty tile

    var ctx = nav.Context.init(allocator);
    // C1: kill ALL core log output + the internal timer for the duration of the
    // measured pipeline. Without this, the core's `ctx.log(.progress, …)` fires
    // std.debug.print to stderr from INSIDE the timed Tracy zones (e.g. the merge
    // loop in rcBuildRegions prints hundreds of lines/iter), inflating
    // rcBuildRegions/rcBuildContours self_ns and making the run unfair vs C++.
    ctx.enableLog(enable_core_log);
    ctx.enableTimer(false);

    var heightfield = try nav.Heightfield.init(
        allocator,
        width,
        height,
        bmin,
        bmax,
        cs,
        ch,
    );
    defer heightfield.deinit();

    // Per-triangle area ids by slope (rcMarkWalkableTriangles, honoring
    // walkable_slope_angle). NULL_AREA (0) for non-walkable, WALKABLE_AREA for
    // walkable — the upstream Sample_SoloMesh pattern (memset 0 then mark). The
    // geom is winding-normalized at load (GeomCache.get) so floor normals point +Y
    // and the slope test is meaningful.
    const tri_count = geom.triCount();
    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, nav.recast.config.AreaId.NULL_AREA);
    nav.recast.filter.markWalkableTriangles(
        &ctx,
        cfg.walkable_slope_angle,
        geom.verts,
        geom.tris,
        areas,
    );

    try nav.recast.rasterization.rasterizeTriangles(
        &ctx,
        geom.verts,
        geom.tris,
        areas,
        &heightfield,
        cfg.walkable_climb,
    );

    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &heightfield);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    // NB: do NOT early-return on a zero-span tile — the C++ reference runs the full
    // build pipeline on empty tiles too, so the tiled-build zone counts match
    // (count = all width>0 tiles). CompactHeightfield.init tolerates span_count==0.
    var chf = try nav.CompactHeightfield.init(
        allocator,
        width,
        height,
        @intCast(span_count),
        cfg.walkable_height,
        cfg.walkable_climb,
        bmin,
        bmax,
        cs,
        ch,
        border_size,
    );
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);

    // Partition prerequisite rules (scenarios.md §2.4 / §3):
    //   watershed: buildDistanceField BEFORE buildRegions(min, merge)
    //   monotone : buildRegionsMonotone(min, merge)        — NO distance field
    //   layers   : buildLayerRegions(min)                  — NO distance field, NO merge
    switch (cfg.partition) {
        .watershed => {
            try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
            try nav.recast.region.buildRegions(&ctx, &chf, border_size, cfg.min_region_area, cfg.merge_region_area, allocator);
        },
        .monotone => {
            try nav.recast.region.buildRegionsMonotone(&ctx, &chf, border_size, cfg.min_region_area, cfg.merge_region_area, allocator);
        },
        .layers => {
            try nav.recast.region.buildLayerRegions(&ctx, &chf, border_size, cfg.min_region_area, allocator);
        },
    }

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, nav.recast.config.CONTOUR_TESS_WALL_EDGES, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    // dtCreateNavMeshData — empty meshes can't serialize; skip if degenerate.
    if (pmesh.npolys == 0 or pmesh.nverts == 0) return;

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // default walkable flag

    // Off-mesh-connection build coverage: synthesize N deterministic connections
    // spread along the mesh AABB diagonal at ground height. createNavMeshData runs
    // its full off-mesh classification/storage path over these regardless of exact
    // endpoint snap (link wiring itself is an addTile concern, not measured here).
    const om_n = cfg.offmesh_cons;
    const om_verts = try allocator.alloc(f32, om_n * 2 * 3);
    defer allocator.free(om_verts);
    const om_rad = try allocator.alloc(f32, om_n);
    defer allocator.free(om_rad);
    const om_flags = try allocator.alloc(u16, om_n);
    defer allocator.free(om_flags);
    const om_areas = try allocator.alloc(u8, om_n);
    defer allocator.free(om_areas);
    const om_dir = try allocator.alloc(u8, om_n);
    defer allocator.free(om_dir);
    const om_uid = try allocator.alloc(u32, om_n);
    defer allocator.free(om_uid);
    if (om_n > 0) {
        const span_x = bmax.x - bmin.x;
        const span_z = bmax.z - bmin.z;
        for (0..om_n) |i| {
            const t0 = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(om_n));
            const t1 = t0 + 0.01;
            const ax = bmin.x + span_x * t0;
            const az = bmin.z + span_z * t0;
            const bx = bmin.x + span_x * @min(t1, 1.0);
            const bz = bmin.z + span_z * @min(t1, 1.0);
            const y = (bmin.y + bmax.y) * 0.5;
            om_verts[(i * 2 + 0) * 3 + 0] = ax;
            om_verts[(i * 2 + 0) * 3 + 1] = y;
            om_verts[(i * 2 + 0) * 3 + 2] = az;
            om_verts[(i * 2 + 1) * 3 + 0] = bx;
            om_verts[(i * 2 + 1) * 3 + 1] = y;
            om_verts[(i * 2 + 1) * 3 + 2] = bz;
            om_rad[i] = 2.0;
            om_flags[i] = 0x01;
            om_areas[i] = 1;
            om_dir[i] = 1; // bidirectional
            om_uid[i] = @intCast(1000 + i);
        }
    }

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
        .off_mesh_con_verts = if (om_n > 0) om_verts else null,
        .off_mesh_con_rad = if (om_n > 0) om_rad else null,
        .off_mesh_con_flags = if (om_n > 0) om_flags else null,
        .off_mesh_con_areas = if (om_n > 0) om_areas else null,
        .off_mesh_con_dir = if (om_n > 0) om_dir else null,
        .off_mesh_con_user_id = if (om_n > 0) om_uid else null,
        .off_mesh_con_count = om_n,
        .tile_x = tile_x,
        .tile_y = tile_z,
        .tile_layer = 0,
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * ch,
        .cs = cs,
        .ch = ch,
        .build_bv_tree = true,
    };

    const navmesh_data = nav.detour.createNavMeshData(&params, allocator) catch {
        // A degenerate tile can fail serialization (e.g. NoPolys); the build zones
        // we care about already fired. Tolerate it — tile connection is not
        // required for BUILD timing.
        return;
    };
    allocator.free(navmesh_data);
}

/// A fully-built SOLO navmesh kept alive for the QUERY/CROWD measured loops. The
/// build itself is NOT measured (the caller `registry.reset()`s AFTER this returns,
/// just before the timed loop). `npolys`/`nverts` are the recast PolyMesh counts of
/// the single tile (reported in the run log for cross-language sanity-checking).
const BuiltNavMesh = struct {
    navmesh: *nav.NavMesh,
    grid: Grid,
    npolys: i32,
    nverts: i32,
};

/// Build the single SOLO navmesh that all QUERY scenarios (map_1_bvh) or all
/// CROWD scenarios (map_2_bvh) share. Mirrors `buildOne`'s recast pipeline 1:1
/// (same derived-cs grid, same defaults, same winding-normalized geom) but, instead
/// of freeing the serialized tile, wires it into a live `dtNavMesh` via
/// `NavMesh.init` + `addTile` (build_bv_tree=true → findNearestPoly/queryPolygons BV
/// descent per §2.4). Caller owns the returned navmesh (`allocator.destroy` + deinit).
///
/// `max_polys` for the NavMesh is sized to the actual tile poly count rounded up to a
/// power of two (poly_bits caps at 20 in dtNavMesh.init) — the detour_bench's hardcoded
/// 512 is far too small for an 8M-cell map (tens of thousands of polys) and would make
/// addTile reject the tile.
fn buildNavMesh(allocator: std.mem.Allocator, geom: Geom, cfg: BuildCfg, grid: Grid) !BuiltNavMesh {
    var ctx = nav.Context.init(allocator);
    ctx.enableLog(enable_core_log);
    ctx.enableTimer(false);

    const bmin = grid.bmin;
    const bmax = grid.bmax;
    const cs = grid.cs;
    const ch = grid.ch;

    var heightfield = try nav.Heightfield.init(allocator, grid.width, grid.height, bmin, bmax, cs, ch);
    defer heightfield.deinit();

    const tri_count = geom.triCount();
    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, nav.recast.config.AreaId.NULL_AREA);
    nav.recast.filter.markWalkableTriangles(&ctx, cfg.walkable_slope_angle, geom.verts, geom.tris, areas);

    try nav.recast.rasterization.rasterizeTriangles(&ctx, geom.verts, geom.tris, areas, &heightfield, cfg.walkable_climb);
    const spans_after_raster = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &heightfield);
    const spans_after_low = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield);
    const spans_after_ledge = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &heightfield);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    if (span_count == 0) return error.EmptyNavMesh;
    var chf = try nav.CompactHeightfield.init(allocator, grid.width, grid.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, bmin, bmax, cs, ch, 0);
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);
    const compact_span_count = chf.span_count;

    // QUERY/CROWD navmeshes are watershed solo (scenarios.md §4/§5).
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, 0, cfg.min_region_area, cfg.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, nav.recast.config.CONTOUR_TESS_WALL_EDGES, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    std.debug.print(
        "[tracy_scenarios] buildNavMesh stages: raster_spans={d} low_spans={d} ledge_spans={d} raw_spans={d} compact_spans={d} contours={d} pmesh=({d} verts,{d} polys) dmesh=({d} verts,{d} tris)\n",
        .{ spans_after_raster, spans_after_low, spans_after_ledge, span_count, compact_span_count, cset.nconts, pmesh.nverts, pmesh.npolys, dmesh.nverts, dmesh.ntris },
    );

    if (pmesh.npolys == 0 or pmesh.nverts == 0) return error.EmptyNavMesh;

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
    @memset(poly_flags, 0x01); // default walkable flag → matches QueryFilter include 0xffff

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
        .tile_x = 0,
        .tile_y = 0,
        .tile_layer = 0,
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * ch,
        .cs = cs,
        .ch = ch,
        .build_bv_tree = true,
    };

    const navmesh_data = try nav.detour.createNavMeshData(&params, allocator);
    errdefer allocator.free(navmesh_data);

    const nm_params = nav.NavMeshParams{
        .orig = bmin,
        .tile_width = @as(f32, @floatFromInt(grid.width)) * cs,
        .tile_height = @as(f32, @floatFromInt(grid.height)) * cs,
        .max_tiles = 1,
        .max_polys = @intCast(nav.math.nextPow2(@as(u32, @intCast(pmesh.npolys)))),
    };
    const navmesh = try allocator.create(nav.NavMesh);
    errdefer allocator.destroy(navmesh);
    navmesh.* = try nav.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    _ = try navmesh.addTile(navmesh_data, .{ .free_data = true }, 0);

    return .{ .navmesh = navmesh, .grid = grid, .npolys = pmesh.npolys, .nverts = pmesh.nverts };
}

/// Build ONE tile of a connected tiled navmesh and return its serialized detour
/// tile blob (caller passes it to `addTile` with `free_data=true`). Mirrors
/// `buildOne`'s recast pipeline 1:1 (same border_size/region handling) but, instead
/// of discarding the result, serializes it via `createNavMeshData`. Returns null for
/// a degenerate/empty tile (no polys) — those tiles are simply not added, exactly as
/// the C++ tiled mirror skips them. NOT a measured path (build is excluded from the
/// QUERY timing).
fn buildTileData(
    allocator: std.mem.Allocator,
    geom: Geom,
    cfg: BuildCfg,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
    cs: f32,
    ch: f32,
    width: i32,
    height: i32,
    border_size: i32,
    tile_x: i32,
    tile_z: i32,
) !?[]u8 {
    if (width <= 0 or height <= 0) return null;

    var ctx = nav.Context.init(allocator);
    ctx.enableLog(enable_core_log);
    ctx.enableTimer(false);

    var heightfield = try nav.Heightfield.init(allocator, width, height, bmin, bmax, cs, ch);
    defer heightfield.deinit();

    const tri_count = geom.triCount();
    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);
    @memset(areas, nav.recast.config.AreaId.NULL_AREA);
    nav.recast.filter.markWalkableTriangles(&ctx, cfg.walkable_slope_angle, geom.verts, geom.tris, areas);

    try nav.recast.rasterization.rasterizeTriangles(&ctx, geom.verts, geom.tris, areas, &heightfield, cfg.walkable_climb);
    nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &heightfield);
    nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield);
    nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &heightfield);

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &heightfield);
    if (span_count == 0) return null;
    var chf = try nav.CompactHeightfield.init(allocator, width, height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, bmin, bmax, cs, ch, border_size);
    defer chf.deinit();

    try nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &heightfield, &chf);
    try nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator);

    // Tiled QUERY navmesh is watershed (matches the BUILD tiled-watershed flow).
    try nav.recast.region.buildDistanceField(&ctx, &chf, allocator);
    try nav.recast.region.buildRegions(&ctx, &chf, border_size, cfg.min_region_area, cfg.merge_region_area, allocator);

    var cset = nav.ContourSet.init(allocator);
    defer cset.deinit();
    try nav.recast.contour.buildContours(&ctx, &chf, cfg.max_simplification_error, cfg.max_edge_len, &cset, nav.recast.config.CONTOUR_TESS_WALL_EDGES, allocator);

    var pmesh = nav.PolyMesh.init(allocator);
    defer pmesh.deinit();
    try nav.recast.mesh.buildPolyMesh(&ctx, &cset, @intCast(cfg.max_verts_per_poly), &pmesh, allocator);

    var dmesh = nav.PolyMeshDetail.init(allocator);
    defer dmesh.deinit();
    try nav.recast.detail.buildPolyMeshDetail(&ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, allocator);

    if (pmesh.npolys == 0 or pmesh.nverts == 0) return null;

    const poly_flags = try allocator.alloc(u16, @intCast(pmesh.npolys));
    defer allocator.free(poly_flags);
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
        .tile_x = tile_x,
        .tile_y = tile_z,
        .tile_layer = 0,
        .bmin = [3]f32{ pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z },
        .bmax = [3]f32{ pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z },
        .walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * ch,
        .walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cs,
        .walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * ch,
        .cs = cs,
        .ch = ch,
        .build_bv_tree = true,
    };

    const navmesh_data = nav.detour.createNavMeshData(&params, allocator) catch return null;
    return navmesh_data;
}

/// Build the CONNECTED tiled navmesh shared by the multi-tile QUERY scenarios.
/// Tiling mirrors `runTiled` (central region of `query_tiled_geom`, fixed cs=0.3,
/// `query_tiled_tile_size` voxels/tile, border = walkable_radius+3) but each tile is
/// serialized and `addTile`d into ONE dtNavMesh, so detour wires the external links
/// and findPath/raycast/straightPath cross tile boundaries. The returned `grid` holds
/// the region interior bounds (the draw AABB for the measured loops).
fn buildTiledNavMesh(allocator: std.mem.Allocator, geom: Geom, cfg: BuildCfg) !BuiltNavMesh {
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    calcBoundsFlat(geom.verts, &bmin, &bmax);

    const center_x = (bmin.x + bmax.x) * 0.5;
    const center_z = (bmin.z + bmax.z) * 0.5;
    const rxmin = @max(bmin.x, center_x - query_tiled_half_extent);
    const rxmax = @min(bmax.x, center_x + query_tiled_half_extent);
    const rzmin = @max(bmin.z, center_z - query_tiled_half_extent);
    const rzmax = @min(bmax.z, center_z + query_tiled_half_extent);

    const border_size: i32 = cfg.walkable_radius + 3;
    const tile_world: f32 = @as(f32, @floatFromInt(cfg.tile_size)) * tiled_cs;
    const border_world: f32 = @as(f32, @floatFromInt(border_size)) * tiled_cs;

    const tiles_x: i32 = @intFromFloat(@ceil((rxmax - rxmin) / tile_world));
    const tiles_z: i32 = @intFromFloat(@ceil((rzmax - rzmin) / tile_world));
    const tile_count: u32 = @intCast(@max(1, tiles_x * tiles_z));

    const nm_params = nav.NavMeshParams{
        .orig = nav.Vec3.init(rxmin, bmin.y, rzmin),
        .tile_width = tile_world,
        .tile_height = tile_world,
        .max_tiles = @intCast(nav.math.nextPow2(tile_count)),
        .max_polys = query_tiled_max_polys_per_tile,
    };
    const navmesh = try allocator.create(nav.NavMesh);
    errdefer allocator.destroy(navmesh);
    navmesh.* = try nav.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    var total_polys: i32 = 0;
    var total_verts: i32 = 0;
    var added_tiles: u32 = 0;

    const tw = cfg.tile_size + border_size * 2;
    const th = cfg.tile_size + border_size * 2;

    var tz: i32 = 0;
    while (tz < tiles_z) : (tz += 1) {
        var tx: i32 = 0;
        while (tx < tiles_x) : (tx += 1) {
            const ix_min = rxmin + @as(f32, @floatFromInt(tx)) * tile_world;
            const iz_min = rzmin + @as(f32, @floatFromInt(tz)) * tile_world;
            const ix_max = rxmin + @as(f32, @floatFromInt(tx + 1)) * tile_world;
            const iz_max = rzmin + @as(f32, @floatFromInt(tz + 1)) * tile_world;
            const tbmin = nav.Vec3.init(ix_min - border_world, bmin.y, iz_min - border_world);
            const tbmax = nav.Vec3.init(ix_max + border_world, bmax.y, iz_max + border_world);

            const data = try buildTileData(allocator, geom, cfg, tbmin, tbmax, tiled_cs, tiled_ch, tw, th, border_size, tx, tz);
            if (data) |d| {
                _ = navmesh.addTile(d, .{ .free_data = true }, 0) catch continue;
                added_tiles += 1;
            }
        }
    }

    if (added_tiles == 0) return error.EmptyNavMesh;

    // Count total polys/verts across the connected tiles for the run log + parity.
    var ti: i32 = 0;
    while (ti < navmesh.max_tiles) : (ti += 1) {
        const tile = &navmesh.tiles[@intCast(ti)];
        if (tile.header) |h| {
            total_polys += h.poly_count;
            total_verts += h.vert_count;
        }
    }

    const region_grid = Grid{
        .cs = tiled_cs,
        .ch = tiled_ch,
        .width = tiles_x * cfg.tile_size,
        .height = tiles_z * cfg.tile_size,
        .bmin = nav.Vec3.init(rxmin, bmin.y, rzmin),
        .bmax = nav.Vec3.init(rxmax, bmax.y, rzmax),
    };
    std.debug.print(
        "[tracy_scenarios] tiled navmesh: tiles={d}x{d} added={d} npolys={d} nverts={d}\n",
        .{ tiles_x, tiles_z, added_tiles, total_polys, total_verts },
    );
    return .{ .navmesh = navmesh, .grid = region_grid, .npolys = total_polys, .nverts = total_verts };
}

/// Run one full SOLO build over the whole mesh (single tile, border_size=0) at the
/// already-DERIVED grid (§2.2).
fn runSolo(allocator: std.mem.Allocator, geom: Geom, cfg: BuildCfg, grid: Grid) !void {
    try buildOne(
        allocator,
        geom,
        cfg,
        grid.bmin,
        grid.bmax,
        grid.cs,
        grid.ch,
        grid.width,
        grid.height,
        0, // solo border_size
        0,
        0,
    );
}

/// §2.5 Run one full TILED build over the BOUNDED CENTRAL REGION (not the whole
/// map): a `1200×1200` (clamped) world-unit region about the XZ center, at fixed
/// `cs=0.3`, split into `tile_size`-voxel tiles. Each tile is built independently
/// over its bounds expanded by `border_size = walkable_radius + 3` voxels. Zones
/// aggregate across all tiles. Tile CONNECTION is NOT required for BUILD timing.
fn runTiled(allocator: std.mem.Allocator, geom: Geom, cfg: BuildCfg) !void {
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    calcBoundsFlat(geom.verts, &bmin, &bmax);

    const center_x = (bmin.x + bmax.x) * 0.5;
    const center_z = (bmin.z + bmax.z) * 0.5;
    const rxmin = @max(bmin.x, center_x - tiled_region_half_extent);
    const rxmax = @min(bmax.x, center_x + tiled_region_half_extent);
    const rzmin = @max(bmin.z, center_z - tiled_region_half_extent);
    const rzmax = @min(bmax.z, center_z + tiled_region_half_extent);

    const border_size: i32 = cfg.walkable_radius + 3; // recast convention

    // One tile spans `tile_size` voxels in world units (per-tile interior, before
    // the border ring). The number of tiles per side is ceil(region/tile_world).
    const tile_world: f32 = @as(f32, @floatFromInt(cfg.tile_size)) * tiled_cs;
    const border_world: f32 = @as(f32, @floatFromInt(border_size)) * tiled_cs;

    const region_dx = rxmax - rxmin;
    const region_dz = rzmax - rzmin;
    const tiles_x: i32 = @intFromFloat(@ceil(region_dx / tile_world));
    const tiles_z: i32 = @intFromFloat(@ceil(region_dz / tile_world));

    var tz: i32 = 0;
    while (tz < tiles_z) : (tz += 1) {
        var tx: i32 = 0;
        while (tx < tiles_x) : (tx += 1) {
            // Tile interior world bounds within the region (XZ), then expanded by
            // the border ring. Y spans the full mesh so all walkable surfaces in
            // the tile are captured; recast clips triangles to these bounds during
            // rasterization.
            const ix_min = rxmin + @as(f32, @floatFromInt(tx)) * tile_world;
            const iz_min = rzmin + @as(f32, @floatFromInt(tz)) * tile_world;
            const ix_max = rxmin + @as(f32, @floatFromInt(tx + 1)) * tile_world;
            const iz_max = rzmin + @as(f32, @floatFromInt(tz + 1)) * tile_world;

            const tbmin = nav.Vec3.init(ix_min - border_world, bmin.y, iz_min - border_world);
            const tbmax = nav.Vec3.init(ix_max + border_world, bmax.y, iz_max + border_world);

            // Grid for the bordered tile (interior tile_size + 2*border voxels).
            const tw = cfg.tile_size + border_size * 2;
            const th = cfg.tile_size + border_size * 2;
            try buildOne(allocator, geom, cfg, tbmin, tbmax, tiled_cs, tiled_ch, tw, th, border_size, tx, tz);
        }
    }
}

/// Total region grid cells for the budget guard (§2.3, tiled = full region grid).
fn tiledRegionCells(geom: Geom) i64 {
    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    calcBoundsFlat(geom.verts, &bmin, &bmax);
    const center_x = (bmin.x + bmax.x) * 0.5;
    const center_z = (bmin.z + bmax.z) * 0.5;
    const rxmin = @max(bmin.x, center_x - tiled_region_half_extent);
    const rxmax = @min(bmax.x, center_x + tiled_region_half_extent);
    const rzmin = @max(bmin.z, center_z - tiled_region_half_extent);
    const rzmax = @min(bmax.z, center_z + tiled_region_half_extent);
    const rw: i64 = @intFromFloat(@ceil((rxmax - rxmin) / tiled_cs));
    const rh: i64 = @intFromFloat(@ceil((rzmax - rzmin) / tiled_cs));
    return rw * rh;
}

/// Bounds over a flat x,y,z vertex buffer (mirror of RecastConfig.calcBounds which
/// works on []Vec3; here the geom is already flat f32). Vec3 has no min/max helper.
fn calcBoundsFlat(verts: []const f32, bmin: *nav.Vec3, bmax: *nav.Vec3) void {
    if (verts.len < 3) return;
    bmin.* = nav.Vec3.init(verts[0], verts[1], verts[2]);
    bmax.* = bmin.*;
    var i: usize = 3;
    while (i + 2 < verts.len) : (i += 3) {
        const x = verts[i];
        const y = verts[i + 1];
        const z = verts[i + 2];
        bmin.x = @min(bmin.x, x);
        bmin.y = @min(bmin.y, y);
        bmin.z = @min(bmin.z, z);
        bmax.x = @max(bmax.x, x);
        bmax.y = @max(bmax.y, y);
        bmax.z = @max(bmax.z, z);
    }
}

// ===========================================================================
// Geometry loading (cached per obj basename so `all` loads each file once).
// ===========================================================================

const GeomCache = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,
    entries: std.StringHashMap(obj.Mesh),

    fn init(allocator: std.mem.Allocator, dir: []const u8) GeomCache {
        return .{ .allocator = allocator, .dir = dir, .entries = std.StringHashMap(obj.Mesh).init(allocator) };
    }

    fn deinit(self: *GeomCache) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.entries.deinit();
    }

    // Geometry is referenced by the scenario's map token, which IS the on-disk
    // filename: supply your own meshes as map_1_bvh.obj … map_6_bvh.obj (any
    // complex level works — see the reproduce section of the perf report).
    fn resolveGeomFile(basename: []const u8) []const u8 {
        return basename;
    }

    fn get(self: *GeomCache, basename: []const u8) !Geom {
        if (self.entries.getPtr(basename)) |m| {
            return .{ .verts = m.verts, .tris = m.tris };
        }
        const path = try std.fs.path.join(self.allocator, &.{ self.dir, resolveGeomFile(basename) });
        defer self.allocator.free(path);
        var mesh = try obj.load(self.allocator, path);
        normalizeWinding(&mesh);
        const key = try self.allocator.dupe(u8, basename);
        try self.entries.put(key, mesh);
        const m = self.entries.getPtr(basename).?;
        return .{ .verts = m.verts, .tris = m.tris };
    }
};

/// The dense BVH bench geometry is exported in Recast Y-up space, but its triangle
/// winding may be CLOCKWISE relative to Recast's CCW/+Y-up convention: computed face
/// normals then point DOWN, so rcMarkWalkableTriangles marks ZERO walkable floors →
/// empty navmesh on BOTH runners. We deterministically detect the majority face
/// orientation and, when the mesh is predominantly down-facing, flip every triangle's
/// winding (swap the 2nd/3rd index) so floor normals point +Y and the slope test is
/// meaningful. Identical and reproducible cross-language; the C++ runner must apply
/// the same normalization for matching navmeshes.
fn normalizeWinding(mesh: *obj.Mesh) void {
    const verts = mesh.verts;
    const tris = mesh.tris;
    const ntri = tris.len / 3;
    if (ntri == 0) return;

    var up: i64 = 0;
    var down: i64 = 0;
    var t: usize = 0;
    while (t < ntri) : (t += 1) {
        const a: usize = @intCast(tris[t * 3 + 0]);
        const b: usize = @intCast(tris[t * 3 + 1]);
        const c: usize = @intCast(tris[t * 3 + 2]);
        // normal.y = (e0.z * e1.x - e0.x * e1.z) with e0=v1-v0, e1=v2-v0.
        const e0x = verts[b * 3 + 0] - verts[a * 3 + 0];
        const e0z = verts[b * 3 + 2] - verts[a * 3 + 2];
        const e1x = verts[c * 3 + 0] - verts[a * 3 + 0];
        const e1z = verts[c * 3 + 2] - verts[a * 3 + 2];
        const ny = e0z * e1x - e0x * e1z;
        if (ny > 0) up += 1 else if (ny < 0) down += 1;
    }
    if (down <= up) return; // already +Y-majority — leave as-is.

    // Flip winding: swap each triangle's 2nd and 3rd vertex index.
    t = 0;
    while (t < ntri) : (t += 1) {
        const tmp = tris[t * 3 + 1];
        tris[t * 3 + 1] = tris[t * 3 + 2];
        tris[t * 3 + 2] = tmp;
    }
}

// ===========================================================================
// §4 QUERY LAYER + §5 CROWD LAYER (Task 3.2b)
//
// Both layers build the navmesh ONCE (map_1_bvh @8M for QUERY, map_2_bvh
// @8M for CROWD) via `buildNavMesh` (NOT measured), then `registry.reset()` and
// run the measured query/tick loop. The in-core dt*/crowd_* Tracy zones fire
// automatically under -Dbench=true / -Dtracy=true; this layer only DRIVES the workload.
//
// The LCG draw SEQUENCE (warmup draws, accept/reject re-rolls) is part of the
// cross-language contract (§2.1): advance-then-use, f = state/2^32. Every helper
// below consumes the stream in the exact order scenarios.md fixes so the C++
// mirror produces the same N valid inputs draw-for-draw.
// ===========================================================================

/// Shared QUERY default filter (§2.6): include=0xffff, exclude=0, area_cost[*]=1.0.
/// QueryFilter.init() already encodes exactly this default → reuse it.
// §2.6 every findNearestPoly snap. SNAP-FIX (mirrors C++ kHalfExtentsDefault):
// query points are drawn at the AABB y-center, and map_1 is very tall
// (y∈[-212,1178]), so a small y-extent never reaches the floor → ref=0 → trivial
// findPath. The tall y-extent {8,2000,8} lets every XZ draw over walkable surface
// snap to its floor regardless of elevation → query scenarios exercise REAL work.
const half_extents_default = [3]f32{ 8.0, 2000.0, 8.0 };

/// Draw a uniform XZ point inside the navmesh AABB, y = AABB-center (§4
/// `query_findnearestpoly_flood`: "x,z uniform; y=AABB center"). Consumes EXACTLY
/// two LCG draws (x then z) per the contract order.
fn drawPointInAabb(rng: *Lcg, bmin: nav.Vec3, bmax: nav.Vec3) [3]f32 {
    const fx = rng.nextFloat();
    const fz = rng.nextFloat();
    const x = bmin.x + @as(f32, @floatCast(fx)) * (bmax.x - bmin.x);
    const z = bmin.z + @as(f32, @floatCast(fz)) * (bmax.z - bmin.z);
    const y = (bmin.y + bmax.y) * 0.5;
    return .{ x, y, z };
}

/// Draw a unit XZ direction from the next two LCG draws: dir = normalize(rx-0.5,
/// rz-0.5) (§4 raycast / moveAlongSurface). Degenerate (near-zero) draws fall back
/// to +X so the call still does work.
fn drawDir(rng: *Lcg) [2]f32 {
    const rx = @as(f32, @floatCast(rng.nextFloat())) - 0.5;
    const rz = @as(f32, @floatCast(rng.nextFloat())) - 0.5;
    const len = @sqrt(rx * rx + rz * rz);
    if (len < 1e-6) return .{ 1.0, 0.0 };
    return .{ rx / len, rz / len };
}

// ---------------------------------------------------------------------------
// QUERY scenario table (§4) — all 16. The navmesh is byte-identical across them
// (map_1_bvh @8M watershed solo); only node_pool + the function-under-test
// + the LCG recipe vary.
// ---------------------------------------------------------------------------

const QueryKind = enum {
    findnearestpoly,
    findpath,
    findpath_long,
    findstraightpath,
    findstraightpath_crossings,
    raycast,
    movealongsurface,
    findpolysaroundcircle,
    findpolysaroundshape,
    findlocalneighbourhood,
    findrandompoint,
    findrandompointaroundcircle,
    finddistancetowall,
    getpolyheight,
    isvalidpolyref,
    getpolywallsegments,
    slicedpath,
};

const QueryCfg = struct {
    id: []const u8,
    kind: QueryKind,
    node_pool: usize, // main NavMeshQuery node pool (moveAlongSurface ignores it: tiny pool)
    n: usize = 2000, // §4 N=2000 measured inputs
    warmup: usize, // §4 warmup draws/pairs (consume the SAME stream before the loop)
    // Multi-tile query graph: when true, the navmesh is built as a CONNECTED
    // tiled mesh (map_3 central region, fixed cs=0.3, tile_size=128) instead
    // of the single solo map_1 tile, so findPath/straightPath/raycast cross
    // tile boundaries (dtNavMesh external-link traversal). `geom` overrides the
    // source map for these scenarios.
    tiled: bool = false,
    geom: []const u8 = query_navmesh_geom,
};

const query_navmesh_geom = "map_1_bvh.obj"; // §4 source map
const query_target_cells: f64 = 8_000_000; // §4 @8M

// Multi-tile QUERY navmesh region (map_3). Smaller half-extent than the
// BUILD tiled region keeps tile count modest while staying genuinely multi-tile
// (~16x16 tiles at tile_size=128, cs=0.3). Zig and C++ MUST use identical values.
const query_tiled_geom = "map_3_bvh.obj";
const query_tiled_half_extent: f32 = 300.0;
const query_tiled_tile_size: i32 = 128; // voxels (interior, before border ring)
const query_tiled_max_polys_per_tile: u32 = 1 << 14; // detour per-tile poly cap

const query_scenarios = [_]QueryCfg{
    .{ .id = "query_findnearestpoly_flood", .kind = .findnearestpoly, .node_pool = 2048, .warmup = 200 },
    .{ .id = "query_findpath_flood", .kind = .findpath, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findpath_long_diagonal", .kind = .findpath_long, .node_pool = 4096, .warmup = 50 },
    .{ .id = "query_findstraightpath_flood", .kind = .findstraightpath, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findstraightpath_crossings", .kind = .findstraightpath_crossings, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_raycast_flood", .kind = .raycast, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_movealongsurface_flood", .kind = .movealongsurface, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findpolysaroundcircle_radius_sweep", .kind = .findpolysaroundcircle, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findpolysaroundshape_convex_sweep", .kind = .findpolysaroundshape, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findlocalneighbourhood_radius_sweep", .kind = .findlocalneighbourhood, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findrandompoint_area_weighted", .kind = .findrandompoint, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_findrandompointaroundcircle_radius_sweep", .kind = .findrandompointaroundcircle, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_finddistancetowall_radius_sweep", .kind = .finddistancetowall, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_getpolyheight_snapped", .kind = .getpolyheight, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_isvalidpolyref_snapped", .kind = .isvalidpolyref, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_getpolywallsegments_portals", .kind = .getpolywallsegments, .node_pool = 2048, .warmup = 50 },
    .{ .id = "query_slicedpath_budget32", .kind = .slicedpath, .node_pool = 4096, .warmup = 20 },
    // Multi-tile / large-world query graph (cross-tile traversal on a connected
    // tiled map_3 navmesh). Same per-kind measured loops as the solo arms.
    .{ .id = "query_multitile_findpath", .kind = .findpath, .node_pool = 4096, .warmup = 50, .tiled = true, .geom = query_tiled_geom },
    .{ .id = "query_multitile_straightpath", .kind = .findstraightpath, .node_pool = 4096, .warmup = 50, .tiled = true, .geom = query_tiled_geom },
    .{ .id = "query_multitile_raycast", .kind = .raycast, .node_pool = 4096, .warmup = 50, .tiled = true, .geom = query_tiled_geom },
};

fn findQueryScenario(id: []const u8) ?*const QueryCfg {
    for (&query_scenarios) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// Run one QUERY scenario: build the map_1 navmesh once (NOT measured), reset
/// the registry, generate N inputs via the contract's LCG recipe (warmup draws +
/// accept/reject re-rolls), run the measured calls, then `dumpCsv`. Returns the
/// poly/vert counts of the navmesh for the run log.
fn runQuery(allocator: std.mem.Allocator, geom: Geom, qcfg: *const QueryCfg) !struct { npolys: i32, nverts: i32 } {
    // The QUERY recast cfg = standard derived-cs build, walkable_radius=2 (§4).
    // Multi-tile scenarios build a connected tiled navmesh instead (cs=0.3).
    var built = if (qcfg.tiled) blk: {
        const bcfg = BuildCfg{
            .geometry = qcfg.geom,
            .partition = .watershed,
            .target_cells = 0,
            .tiled = true,
            .tile_size = query_tiled_tile_size,
            .iters = 1,
        };
        break :blk try buildTiledNavMesh(allocator, geom, bcfg);
    } else blk: {
        const bcfg = BuildCfg{
            .geometry = qcfg.geom,
            .partition = .watershed,
            .target_cells = query_target_cells,
            .iters = 1,
        };
        const grid = deriveSoloGrid(geom, query_target_cells);
        break :blk try buildNavMesh(allocator, geom, bcfg, grid);
    };
    defer {
        built.navmesh.deinit();
        allocator.destroy(built.navmesh);
    }

    const query = try nav.NavMeshQuery.init(allocator);
    defer query.deinit();
    try query.initQuery(built.navmesh, qcfg.node_pool);

    const filter = nav.QueryFilter.init();
    const bmin = built.grid.bmin;
    const bmax = built.grid.bmax;

    // §2.1: a single LCG stream per scenario run (seed 12345). Warmup draws consume
    // from this SAME stream BEFORE the measured loop, exactly as the C++ mirror does.
    var rng = Lcg.init(12345);

    // §4 contract: the snap/precompute prerequisites run OUTSIDE the measured zone.
    // Each arm therefore generates ALL its inputs first (snapping fires
    // dtFindNearestPoly), then `registry.reset()`s immediately before the measured
    // loop so ONLY the function-under-test's zones land in the CSV. (findnearestpoly
    // is the exception: the function under test IS the snap, so there is no separate
    // input-snap step — its inputs are raw AABB draws and reset precedes the loop.)
    switch (qcfg.kind) {
        .findnearestpoly => {
            // §4 query_findnearestpoly_flood: N points uniform in AABB; warmup=200
            // points consume the same stream; findNearestPoly per point, NO snap
            // re-roll (the function under test IS the snap).
            var i: usize = 0;
            while (i < qcfg.warmup) : (i += 1) _ = drawPointInAabb(&rng, bmin, bmax);
            registry.reset(); // measured loop = findNearestPoly only
            i = 0;
            while (i < qcfg.n) : (i += 1) {
                const p = drawPointInAabb(&rng, bmin, bmax);
                var ref: PolyRef = 0;
                var pt: [3]f32 = undefined;
                query.findNearestPoly(&p, &half_extents_default, &filter, &ref, &pt) catch {};
            }
        },
        .findpath, .findpath_long => {
            // §4 findpath_flood / findpath_long_diagonal: N (start,goal) pairs; snap
            // both via findNearestPoly; if EITHER ref==0 re-roll from the same stream
            // until both valid. The snap is the prerequisite (run, but the measured
            // zone is dtFindPath — snap fires dtFindNearestPoly too, which is fine:
            // both langs do it identically). path cap = 512 (flood) / 1024 (long).
            const long = qcfg.kind == .findpath_long;
            const Pair = struct { sref: PolyRef, gref: PolyRef, spos: [3]f32, gpos: [3]f32 };
            const pairs = try allocator.alloc(Pair, qcfg.n);
            defer allocator.free(pairs);

            // Warmup pairs consume the stream (each warmup pair = the draws of one
            // accepted pair: re-rolling here keeps the stream position identical to
            // a real accepted pair for the C++ mirror).
            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidPair(query, &filter, &rng, bmin, bmax, long);

            for (pairs) |*pr| {
                const vp = drawValidPair(query, &filter, &rng, bmin, bmax, long);
                pr.* = .{ .sref = vp.sref, .gref = vp.gref, .spos = vp.spos, .gpos = vp.gpos };
            }

            // Drop snap (dtFindNearestPoly) noise — measured zone is dtFindPath ONLY.
            registry.reset();

            // Measured loop: findPath only.
            var path_buf: [1024]PolyRef = undefined;
            const cap: usize = if (long) 1024 else 512;
            for (pairs) |pr| {
                var pc: usize = 0;
                query.findPath(pr.sref, pr.gref, &pr.spos, &pr.gpos, &filter, path_buf[0..cap], &pc) catch {};
            }
        },
        .findstraightpath, .findstraightpath_crossings => {
            // §4 query_findstraightpath_flood / _crossings: identical stream to
            // findpath_flood (medium AABB pairs, node_pool=2048). Precompute findPath
            // corridors ONCE (EXCLUDED from measurement), store corridors+endpoints,
            // then the measured loop runs findStraightPath per corridor.
            //   _flood:     options=0,                   cap=256 (corner verts only).
            //   _crossings: ALL_CROSSINGS (vertex per polygon edge), cap=512 (one
            //               vertex per corridor portal → up to plen verts).
            const all_cross = qcfg.kind == .findstraightpath_crossings;
            const opts: u32 = if (all_cross) nav.detour.common.STRAIGHTPATH_ALL_CROSSINGS else 0;
            const sp_cap: usize = if (all_cross) 512 else 256;
            const Corr = struct { spos: [3]f32, gpos: [3]f32, path: [512]PolyRef, plen: usize };
            const corrs = try allocator.alloc(Corr, qcfg.n);
            defer allocator.free(corrs);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidPair(query, &filter, &rng, bmin, bmax, false);

            // Corridor precompute is OUTSIDE the measured zone → build it BEFORE the
            // registry reset point. But the reset already happened above; findPath
            // here would pollute dtFindPath. So we reset AGAIN after precompute.
            for (corrs) |*c| {
                const vp = drawValidPair(query, &filter, &rng, bmin, bmax, false);
                c.spos = vp.spos;
                c.gpos = vp.gpos;
                var pc: usize = 0;
                query.findPath(vp.sref, vp.gref, &vp.spos, &vp.gpos, &filter, c.path[0..], &pc) catch {
                    pc = 0;
                };
                c.plen = pc;
            }

            // Drop the dtFindPath/dtFindNearestPoly noise from the precompute: the
            // measured zone is dtFindStraightPath ONLY (§4).
            registry.reset();

            var sp: [512 * 3]f32 = undefined;
            var sp_flags: [512]u8 = undefined;
            var sp_refs: [512]PolyRef = undefined;
            for (corrs) |c| {
                if (c.plen == 0) continue;
                var spc: usize = 0;
                _ = query.findStraightPath(&c.spos, &c.gpos, c.path[0..c.plen], sp[0 .. sp_cap * 3], sp_flags[0..sp_cap], sp_refs[0..sp_cap], &spc, opts) catch {};
            }
        },
        .raycast => {
            // §4 query_raycast_flood: draw start in AABB, snap → start_ref (re-roll
            // invalid from the same stream); end = start_pos + unit_dir*35.0 (dir from
            // the NEXT 2 LCG draws). RaycastHit path cap=256, options=0, prev_ref=0.
            const Ray = struct { sref: PolyRef, spos: [3]f32, epos: [3]f32 };
            const rays = try allocator.alloc(Ray, qcfg.n);
            defer allocator.free(rays);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStartDir(query, &filter, &rng, bmin, bmax, 35.0);

            for (rays) |*r| {
                const v = drawValidStartDir(query, &filter, &rng, bmin, bmax, 35.0);
                r.* = .{ .sref = v.sref, .spos = v.spos, .epos = v.epos };
            }

            // Drop snap noise — measured zone is dtRaycast ONLY.
            registry.reset();

            var path_buf: [256]PolyRef = undefined;
            for (rays) |r| {
                var hit = nav.detour.RaycastHit.init(&path_buf);
                _ = query.raycast(r.sref, &r.spos, &r.epos, &filter, 0, &hit, 0) catch {};
            }
        },
        .movealongsurface => {
            // §4 query_movealongsurface_flood: tiny node pool (default); draw start,
            // snap → start_ref (re-roll invalid); end = start_pos + dir*5.0 (dir from
            // 2 LCG draws). visited cap=16.
            const Mv = struct { sref: PolyRef, spos: [3]f32, epos: [3]f32 };
            const mvs = try allocator.alloc(Mv, qcfg.n);
            defer allocator.free(mvs);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStartDir(query, &filter, &rng, bmin, bmax, 5.0);

            for (mvs) |*m| {
                const v = drawValidStartDir(query, &filter, &rng, bmin, bmax, 5.0);
                m.* = .{ .sref = v.sref, .spos = v.spos, .epos = v.epos };
            }

            // Drop snap noise — measured zone is dtMoveAlongSurface ONLY.
            registry.reset();

            var visited: [16]PolyRef = undefined;
            for (mvs) |m| {
                var result_pos: [3]f32 = undefined;
                var vc: usize = 0;
                _ = query.moveAlongSurface(m.sref, &m.spos, &m.epos, &filter, &result_pos, &visited, &vc) catch {};
            }
        },
        .findpolysaroundcircle => {
            // §4 query_findpolysaroundcircle_radius_sweep: draw center, snap →
            // start_ref (re-roll invalid); radius = [8,24,64][i%3]. result caps=512.
            const Circ = struct { sref: PolyRef, cpos: [3]f32 };
            const circs = try allocator.alloc(Circ, qcfg.n);
            defer allocator.free(circs);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (circs) |*c| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                c.* = .{ .sref = v.sref, .cpos = v.spos };
            }

            // Drop snap noise — measured zone is dtFindPolysAroundCircle ONLY.
            registry.reset();

            const radii = [3]f32{ 8.0, 24.0, 64.0 };
            var result_ref: [512]PolyRef = undefined;
            var result_parent: [512]PolyRef = undefined;
            var result_cost: [512]f32 = undefined;
            for (circs, 0..) |c, i| {
                const radius = radii[i % 3];
                var rc: usize = 0;
                _ = query.findPolysAroundCircle(c.sref, &c.cpos, radius, &filter, &result_ref, &result_parent, &result_cost, &rc) catch {};
            }
        },
        .findpolysaroundshape => {
            // query_findpolysaroundshape_convex_sweep: same snapped centers and
            // radius sweep as circle, but the measured Dijkstra frontier is gated
            // by a 4-vertex convex diamond in XZ.
            const Shape = struct { sref: PolyRef, cpos: [3]f32 };
            const shapes = try allocator.alloc(Shape, qcfg.n);
            defer allocator.free(shapes);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (shapes) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .sref = v.sref, .cpos = v.spos };
            }

            registry.reset();

            const radii = [3]f32{ 8.0, 24.0, 64.0 };
            var result_ref: [512]PolyRef = undefined;
            var result_parent: [512]PolyRef = undefined;
            var result_cost: [512]f32 = undefined;
            var verts: [4 * 3]f32 = undefined;
            for (shapes, 0..) |s, i| {
                const radius = radii[i % 3];
                verts = .{
                    s.cpos[0],          s.cpos[1], s.cpos[2] - radius,
                    s.cpos[0] + radius, s.cpos[1], s.cpos[2],
                    s.cpos[0],          s.cpos[1], s.cpos[2] + radius,
                    s.cpos[0] - radius, s.cpos[1], s.cpos[2],
                };
                var rc: usize = 0;
                _ = query.findPolysAroundShape(s.sref, &verts, 4, &filter, &result_ref, &result_parent, &result_cost, &rc) catch {};
            }
        },
        .findlocalneighbourhood => {
            // query_findlocalneighbourhood_radius_sweep: draw center, snap →
            // start_ref (re-roll invalid); radius = [8,24,64][i%3]. This uses
            // the tiny node pool and the non-overlap local cluster filter.
            const Start = struct { sref: PolyRef, spos: [3]f32 };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .sref = v.sref, .spos = v.spos };
            }

            registry.reset();

            const radii = [3]f32{ 8.0, 24.0, 64.0 };
            var result_ref: [64]PolyRef = undefined;
            var result_parent: [64]PolyRef = undefined;
            for (starts, 0..) |s, i| {
                const radius = radii[i % 3];
                var rc: usize = 0;
                _ = query.findLocalNeighbourhood(s.sref, &s.spos, radius, &filter, &result_ref, &result_parent, &rc) catch {};
            }
        },
        .findrandompoint => {
            // query_findrandompoint_area_weighted: no snapped input; the call
            // scans tiles/polys and uses the supplied RNG for area-weighted
            // reservoir sampling plus the final convex-poly point draw.
            var func_rng = LcgRandom.init(67890);
            const frand = func_rng.random();
            var random_ref: PolyRef = 0;
            var random_pt: [3]f32 = undefined;

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) {
                query.findRandomPoint(&filter, frand, &random_ref, &random_pt) catch {};
            }

            registry.reset();

            var i: usize = 0;
            while (i < qcfg.n) : (i += 1) {
                query.findRandomPoint(&filter, frand, &random_ref, &random_pt) catch {};
            }
        },
        .findrandompointaroundcircle => {
            // query_findrandompointaroundcircle_radius_sweep: same snapped
            // centers/radius sweep as circle; the function's own RNG is a
            // separate deterministic stream used only by the measured API.
            const Start = struct { sref: PolyRef, spos: [3]f32 };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .sref = v.sref, .spos = v.spos };
            }

            registry.reset();

            var func_rng = LcgRandom.init(67890);
            const frand = func_rng.random();
            const radii = [3]f32{ 8.0, 24.0, 64.0 };
            var random_ref: PolyRef = 0;
            var random_pt: [3]f32 = undefined;
            for (starts, 0..) |s, i| {
                const radius = radii[i % 3];
                query.findRandomPointAroundCircle(s.sref, &s.spos, radius, &filter, frand, &random_ref, &random_pt) catch {};
            }
        },
        .finddistancetowall => {
            // query_finddistancetowall_radius_sweep: draw center, snap → start_ref
            // (re-roll invalid); radius = [8,24,64][i%3]. The snap is excluded so
            // the measured zone is dtFindDistanceToWall only.
            const Start = struct { sref: PolyRef, spos: [3]f32 };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .sref = v.sref, .spos = v.spos };
            }

            registry.reset();

            const radii = [3]f32{ 8.0, 24.0, 64.0 };
            for (starts, 0..) |s, i| {
                const radius = radii[i % 3];
                var hit_dist: f32 = 0.0;
                var hit_pos: [3]f32 = undefined;
                var hit_normal: [3]f32 = undefined;
                _ = query.findDistanceToWall(s.sref, &s.spos, radius, &filter, &hit_dist, &hit_pos, &hit_normal) catch {};
            }
        },
        .getpolywallsegments => {
            // query_getpolywallsegments_portals: draw start, snap → poly ref
            // (re-roll invalid). `segment_refs` is present, so the call returns
            // portals and walls and exercises the interval insertion path.
            const Start = struct { ref: PolyRef };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .ref = v.sref };
            }

            registry.reset();

            var segment_verts: [64 * 6]f32 = undefined;
            var segment_refs: [64]PolyRef = undefined;
            for (starts) |s| {
                var segment_count: usize = 0;
                _ = nav.detour.query.getPolyWallSegments(query, s.ref, &filter, &segment_verts, &segment_refs, &segment_count, segment_refs.len) catch {};
            }
        },
        .getpolyheight => {
            // query_getpolyheight_snapped: draw start, snap → poly ref/point
            // (re-roll invalid). Snap is excluded, so the measured zone is the
            // query-layer getPolyHeight wrapper plus navmesh detail-height lookup.
            const Start = struct { ref: PolyRef, pos: [3]f32 };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .ref = v.sref, .pos = v.spos };
            }

            registry.reset();

            for (starts) |s| {
                var height: f32 = undefined;
                _ = query.getPolyHeight(s.ref, &s.pos, &height) catch {};
            }
        },
        .isvalidpolyref => {
            // query_isvalidpolyref_snapped: draw start, snap → poly ref
            // (re-roll invalid). Snap is excluded, so this measures the public
            // query-level validation path plus filter check on valid refs.
            const Start = struct { ref: PolyRef };
            const starts = try allocator.alloc(Start, qcfg.n);
            defer allocator.free(starts);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidStart(query, &filter, &rng, bmin, bmax);

            for (starts) |*s| {
                const v = drawValidStart(query, &filter, &rng, bmin, bmax);
                s.* = .{ .ref = v.sref };
            }

            registry.reset();

            var valid_count: usize = 0;
            for (starts) |s| {
                if (query.isValidPolyRef(s.ref, &filter)) valid_count += 1;
            }
            std.mem.doNotOptimizeAway(valid_count);
        },
        .slicedpath => {
            // §4 query_slicedpath_budget32: long-diagonal corner-band pairs (identical
            // stream to findpath_long_diagonal), snap both; options=0; per pair:
            // initSlicedFindPath, loop updateSlicedFindPath(max_iter=32) until status
            // != in_progress, finalizeSlicedFindPath(path cap=1024). warmup=20 pairs.
            const Pair = struct { sref: PolyRef, gref: PolyRef, spos: [3]f32, gpos: [3]f32 };
            const pairs = try allocator.alloc(Pair, qcfg.n);
            defer allocator.free(pairs);

            var w: usize = 0;
            while (w < qcfg.warmup) : (w += 1) _ = drawValidPair(query, &filter, &rng, bmin, bmax, true);

            for (pairs) |*pr| {
                const vp = drawValidPair(query, &filter, &rng, bmin, bmax, true);
                pr.* = .{ .sref = vp.sref, .gref = vp.gref, .spos = vp.spos, .gpos = vp.gpos };
            }

            // Drop snap noise — measured zones are dtInitSlicedFindPath /
            // dtUpdateSlicedFindPath / finalize ONLY.
            registry.reset();

            var path_buf: [1024]PolyRef = undefined;
            for (pairs) |pr| {
                _ = query.initSlicedFindPath(pr.sref, pr.gref, &pr.spos, &pr.gpos, &filter, 0);
                var status = nav.Status{ .in_progress = true };
                while (status.in_progress) {
                    var done: u32 = 0;
                    status = query.updateSlicedFindPath(32, &done);
                }
                var pc: usize = 0;
                _ = query.finalizeSlicedFindPath(path_buf[0..1024], &pc);
            }
        },
    }

    return .{ .npolys = built.npolys, .nverts = built.nverts };
}

/// Draw a (start,goal) pair, snapping both, re-rolling from the SAME stream until
/// BOTH refs are valid (§4 findpath). `long=true` uses the opposite corner-bands.
fn drawValidPair(
    query: *const nav.NavMeshQuery,
    filter: *const nav.QueryFilter,
    rng: *Lcg,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
    long: bool,
) struct { sref: PolyRef, gref: PolyRef, spos: [3]f32, gpos: [3]f32 } {
    // SNAP-FIX (mirrors C++ `(void)long_pair;`): the long/short distinction is
    // retired — BOTH endpoints are uniform-AABB draws (drawPointInaAbb, 2 LCG
    // draws each: x then z, y = AABB center). drawPointInCorner consumed the SAME
    // 2 draws, so the LCG stream parity with C++ is preserved draw-for-draw.
    _ = long;
    var guard: usize = 0;
    while (guard < 10000) : (guard += 1) {
        const sp = drawPointInAabb(rng, bmin, bmax);
        const gp = drawPointInAabb(rng, bmin, bmax);
        const ss = snapConst(query, filter, sp);
        const gg = snapConst(query, filter, gp);
        if (ss.ref != 0 and gg.ref != 0) {
            return .{ .sref = ss.ref, .gref = gg.ref, .spos = ss.pt, .gpos = gg.pt };
        }
    }
    return .{ .sref = 0, .gref = 0, .spos = .{ 0, 0, 0 }, .gpos = .{ 0, 0, 0 } };
}

/// Draw a start point, snap, re-roll until valid (§4 findpolysaroundcircle).
fn drawValidStart(
    query: *const nav.NavMeshQuery,
    filter: *const nav.QueryFilter,
    rng: *Lcg,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
) struct { sref: PolyRef, spos: [3]f32 } {
    var guard: usize = 0;
    while (guard < 10000) : (guard += 1) {
        const sp = drawPointInAabb(rng, bmin, bmax);
        const ss = snapConst(query, filter, sp);
        if (ss.ref != 0) return .{ .sref = ss.ref, .spos = ss.pt };
    }
    return .{ .sref = 0, .spos = .{ 0, 0, 0 } };
}

/// Draw a valid start (re-roll), then consume the NEXT 2 draws for the direction and
/// place end = start_pos + dir*dist (§4 raycast/moveAlongSurface). The direction
/// draws happen AFTER the accepted start so the stream order matches the contract.
fn drawValidStartDir(
    query: *const nav.NavMeshQuery,
    filter: *const nav.QueryFilter,
    rng: *Lcg,
    bmin: nav.Vec3,
    bmax: nav.Vec3,
    dist: f32,
) struct { sref: PolyRef, spos: [3]f32, epos: [3]f32 } {
    const v = drawValidStart(query, filter, rng, bmin, bmax);
    const dir = drawDir(rng);
    const epos = [3]f32{ v.spos[0] + dir[0] * dist, v.spos[1], v.spos[2] + dir[1] * dist };
    return .{ .sref = v.sref, .spos = v.spos, .epos = epos };
}

/// Const-self variant of `snap` (findNearestPoly is `*const Self`).
fn snapConst(query: *const nav.NavMeshQuery, filter: *const nav.QueryFilter, pos: [3]f32) struct { ref: PolyRef, pt: [3]f32 } {
    var ref: PolyRef = 0;
    var pt: [3]f32 = pos;
    query.findNearestPoly(&pos, &half_extents_default, filter, &ref, &pt) catch {
        return .{ .ref = 0, .pt = pos };
    };
    return .{ .ref = ref, .pt = pt };
}

fn zoneCount(name: []const u8) u64 {
    if (registry.get(name)) |s| return s.count;
    return 0;
}

fn hashBytes(hash: u64, bytes: []const u8) u64 {
    var h = hash;
    for (bytes) |b| {
        h ^= b;
        h *%= 1099511628211;
    }
    return h;
}

fn hashU64(hash: u64, value: u64) u64 {
    return hashBytes(hash, std.mem.asBytes(&value));
}

fn hashU32(hash: u64, value: u32) u64 {
    return hashBytes(hash, std.mem.asBytes(&value));
}

fn hashF32(hash: u64, value: f32) u64 {
    return hashU32(hash, @bitCast(value));
}

const CrowdHashParts = struct {
    state: u64 = 14695981039346656037,
    target: u64 = 14695981039346656037,
    npos: u64 = 14695981039346656037,
    vel: u64 = 14695981039346656037,
    path: u64 = 14695981039346656037,

    fn combined(self: CrowdHashParts) u64 {
        var h: u64 = 14695981039346656037;
        h = hashU64(h, self.state);
        h = hashU64(h, self.target);
        h = hashU64(h, self.npos);
        h = hashU64(h, self.vel);
        h = hashU64(h, self.path);
        return h;
    }
};

fn crowdHashParts(crowd: *const nav.Crowd) CrowdHashParts {
    var parts = CrowdHashParts{};
    var i: usize = 0;
    while (i < crowd.getAgentCount()) : (i += 1) {
        const ag = crowd.getAgent(@intCast(i)) orelse {
            parts.state = hashU64(parts.state, 0);
            parts.target = hashU64(parts.target, 0);
            parts.npos = hashU64(parts.npos, 0);
            parts.vel = hashU64(parts.vel, 0);
            parts.path = hashU64(parts.path, 0);
            continue;
        };
        parts.state = hashU64(parts.state, 1);
        parts.state = hashU64(parts.state, if (ag.active) 1 else 0);
        parts.state = hashU64(parts.state, @intCast(@intFromEnum(ag.state)));
        parts.target = hashU64(parts.target, @intCast(@intFromEnum(ag.target_state)));
        parts.target = hashU64(parts.target, @intCast(ag.target_ref));
        parts.npos = hashF32(parts.npos, ag.npos[0]);
        parts.npos = hashF32(parts.npos, ag.npos[1]);
        parts.npos = hashF32(parts.npos, ag.npos[2]);
        parts.vel = hashF32(parts.vel, ag.vel[0]);
        parts.vel = hashF32(parts.vel, ag.vel[1]);
        parts.vel = hashF32(parts.vel, ag.vel[2]);
        parts.path = hashU64(parts.path, ag.corridor.getPathCount());
    }
    return parts;
}

fn traceCrowdTick(id: []const u8, tick: i32, crowd: *const nav.Crowd) void {
    const parts = crowdHashParts(crowd);
    std.debug.print(
        "[crowd_tick] {s} tick={d} hash={x:0>16} state={x:0>16} target={x:0>16} npos={x:0>16} vel={x:0>16} path={x:0>16} dtRaycast={d} dtInitSlicedFindPath={d} dtUpdateSlicedFindPath={d} crowd_path_queue_update={d} crowd_topology_opt={d}\n",
        .{
            id,
            tick,
            parts.combined(),
            parts.state,
            parts.target,
            parts.npos,
            parts.vel,
            parts.path,
            zoneCount("dtRaycast"),
            zoneCount("dtInitSlicedFindPath"),
            zoneCount("dtUpdateSlicedFindPath"),
            zoneCount("crowd_path_queue_update"),
            zoneCount("crowd_topology_opt"),
        },
    );
}

fn tracePolyRef(id: []const u8, tag: []const u8, navmesh: *const nav.NavMesh, ref: nav.PolyRef) void {
    const decoded = navmesh.decodePolyId(ref);
    if (decoded.tile >= @as(u32, @intCast(navmesh.max_tiles))) return;
    const tile = &navmesh.tiles[decoded.tile];
    if (tile.header == null or decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return;
    const poly = &tile.polys[decoded.poly];
    const pd = &tile.detail_meshes[decoded.poly];
    std.debug.print(
        "[crowd_poly] {s} {s} ref={d} tile={d} poly={d} nv={d} pd=({d},{d},{d},{d})\n",
        .{ id, tag, ref, decoded.tile, decoded.poly, poly.vert_count, pd.vert_base, pd.tri_base, pd.vert_count, pd.tri_count },
    );
    for (0..poly.vert_count) |vi| {
        const base = @as(usize, poly.verts[vi]) * 3;
        std.debug.print(
            "[crowd_poly_vert] {s} {s} ref={d} i={d} vidx={d} v=({d:.9},{d:.9},{d:.9})\n",
            .{ id, tag, ref, vi, poly.verts[vi], tile.verts[base], tile.verts[base + 1], tile.verts[base + 2] },
        );
    }
}

// ---------------------------------------------------------------------------
// §5 CROWD scenario table — all 7. Navmesh = map_2_bvh @8M watershed solo.
// OA presets (§2.6) + update_flags (§2.6) + 256-agent hard cap.
// ---------------------------------------------------------------------------

const crowd_navmesh_geom = "map_2_bvh.obj";
const crowd_target_cells: f64 = 8_000_000;

/// Crowd behavior modes (drives spawn layout + goal handling).
const CrowdBehavior = enum {
    cross_goals, // per-agent fixed cross-map goal at add (LCG-placed)
    choke_shared_goal, // all spawned one side of a funnel band, single shared far goal
    moving_shared_goal, // single shared goal that MOVES every repath_period ticks
    cluster_no_goal, // tight cluster, NO move target (separation-only)
};

const CrowdCfg = struct {
    id: []const u8,
    n: usize, // agent count (<= 256 hard cap, §2.6)
    ticks: usize, // crowd.update(dt) iterations
    max_agents: usize, // Crowd.init capacity
    oa_type: u8, // 0 LOW / 1 MED / 2 HIGH / 3 ULTRA (§2.6 preset table)
    update_flags: u8, // ALL=31, no-avoidance=29 (§2.6)
    collision_query_range: f32,
    separation_weight: f32,
    behavior: CrowdBehavior,
    repath_period: usize = 0, // moving_shared_goal: ticks between mass repaths (120)
};

const crowd_scenarios = [_]CrowdCfg{
    .{ .id = "crowd_baseline_25_oa_low", .n = 25, .ticks = 600, .max_agents = 50, .oa_type = 0, .update_flags = 31, .collision_query_range = 2.5, .separation_weight = 2.0, .behavior = .cross_goals },
    .{ .id = "crowd_100_oa_high", .n = 100, .ticks = 600, .max_agents = 200, .oa_type = 2, .update_flags = 31, .collision_query_range = 2.5, .separation_weight = 2.0, .behavior = .cross_goals },
    .{ .id = "crowd_100_no_avoidance", .n = 100, .ticks = 600, .max_agents = 200, .oa_type = 2, .update_flags = 29, .collision_query_range = 2.5, .separation_weight = 2.0, .behavior = .cross_goals },
    .{ .id = "crowd_choke_funnel_60_oa_high", .n = 60, .ticks = 900, .max_agents = 128, .oa_type = 3, .update_flags = 31, .collision_query_range = 3.0, .separation_weight = 4.0, .behavior = .choke_shared_goal },
    .{ .id = "crowd_mass_repath_100_shared_moving_goal", .n = 100, .ticks = 1200, .max_agents = 200, .oa_type = 2, .update_flags = 31, .collision_query_range = 2.5, .separation_weight = 2.0, .behavior = .moving_shared_goal, .repath_period = 120 },
    .{ .id = "crowd_separation_spread_120_no_goal", .n = 120, .ticks = 600, .max_agents = 200, .oa_type = 1, .update_flags = 31, .collision_query_range = 4.0, .separation_weight = 4.0, .behavior = .cluster_no_goal },
    .{ .id = "crowd_scale_250_oa_med", .n = 250, .ticks = 600, .max_agents = 256, .oa_type = 1, .update_flags = 31, .collision_query_range = 2.5, .separation_weight = 2.0, .behavior = .cross_goals },
};

fn findCrowdScenario(id: []const u8) ?*const CrowdCfg {
    for (&crowd_scenarios) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// §2.6 OA preset: set the common params + the adaptive triple for `oa_type` onto
/// crowd config slot `oa_type` (selected per-agent via params.obstacle_avoidance_type).
fn applyOaPreset(crowd: *nav.Crowd, oa_type: u8) void {
    // adaptive triple per §2.6: 0=LOW(5,2,1) 1=MED(5,2,2) 2=HIGH(7,2,3) 3=ULTRA(7,3,3)
    const triple: [3]u8 = switch (oa_type) {
        0 => .{ 5, 2, 1 },
        1 => .{ 5, 2, 2 },
        2 => .{ 7, 2, 3 },
        else => .{ 7, 3, 3 },
    };
    const params = nav.ObstacleAvoidanceParams{
        .grid_size = 33,
        .vel_bias = 0.5,
        .weight_des_vel = 2.0,
        .weight_cur_vel = 0.75,
        .weight_side = 0.75,
        .weight_toi = 2.5,
        .horiz_time = 2.5,
        .adaptive_divs = triple[0],
        .adaptive_rings = triple[1],
        .adaptive_depth = triple[2],
    };
    crowd.setObstacleAvoidanceParams(oa_type, &params);
}

/// Run one CROWD scenario: build the map_2 navmesh once (NOT measured), set the
/// OA preset, spawn agents per the behavior (LCG-placed, snapped to the mesh), set
/// goals, reset the registry, run M ticks of crowd.update(dt=1/60). The crowd_*
/// phase zones fire from the core. Returns poly/vert counts for the run log.
fn runCrowd(allocator: std.mem.Allocator, geom: Geom, ccfg: *const CrowdCfg) !struct { npolys: i32, nverts: i32 } {
    const bcfg = BuildCfg{
        .geometry = crowd_navmesh_geom,
        .partition = .watershed,
        .target_cells = crowd_target_cells,
        .iters = 1,
    };
    const grid = deriveSoloGrid(geom, crowd_target_cells);

    var built = try buildNavMesh(allocator, geom, bcfg, grid);
    defer {
        built.navmesh.deinit();
        allocator.destroy(built.navmesh);
    }

    const crowd = try allocator.create(nav.Crowd);
    defer allocator.destroy(crowd);
    crowd.* = try nav.Crowd.init(allocator, ccfg.max_agents, 0.6, built.navmesh);
    defer crowd.deinit();

    // Set the scenario's OA preset on its slot (and slot 0 as a safe default).
    applyOaPreset(crowd, ccfg.oa_type);
    if (ccfg.oa_type != 0) applyOaPreset(crowd, 0);

    const filter = crowd.getFilter(0).?;
    const bmin = grid.bmin;
    const bmax = grid.bmax;

    var rng = Lcg.init(12345); // §5 LCG seed=12345 for spawns/goals

    // Base agent params (§5). update_flags / oa_type / separation / coll-range vary.
    var params = nav.CrowdAgentParams.init();
    params.radius = 0.6;
    params.height = 2.0;
    params.max_acceleration = 8.0;
    params.max_speed = 3.5;
    params.collision_query_range = ccfg.collision_query_range;
    params.path_optimization_range = 30.0;
    params.separation_weight = ccfg.separation_weight;
    params.update_flags = ccfg.update_flags;
    params.obstacle_avoidance_type = ccfg.oa_type;
    params.query_filter_type = 0;

    // Spawn layout per behavior. Choke/cluster spatial setups are derived from the
    // navmesh bmin/bmax (§2.6) as fixed bands so both langs land on identical polys.
    const cx = (bmin.x + bmax.x) * 0.5;
    const cz = (bmin.z + bmax.z) * 0.5;
    const cy = (bmin.y + bmax.y) * 0.5;
    const dx = bmax.x - bmin.x;
    const dz = bmax.z - bmin.z;

    var agent_ids = try allocator.alloc(i32, ccfg.n);
    defer allocator.free(agent_ids);
    @memset(agent_ids, -1);

    // A single shared goal ref/pos (choke + moving behaviors).
    var shared_ref: PolyRef = 0;
    var shared_pos: [3]f32 = .{ cx, cy, cz };

    switch (ccfg.behavior) {
        .cross_goals => {
            // Per-agent: spawn at an LCG-placed valid mesh point, then a per-agent
            // LCG-placed cross-map goal (snap, re-roll invalid). No re-target.
            var added: usize = 0;
            var guard: usize = 0;
            while (added < ccfg.n and guard < ccfg.n * 200) : (guard += 1) {
                const sp = drawPointInAabb(&rng, bmin, bmax);
                const ss = snapConst(crowd.navquery, filter, sp);
                if (ss.ref == 0) continue;
                const gp = drawPointInAabb(&rng, bmin, bmax);
                const gg = snapConst(crowd.navquery, filter, gp);
                if (gg.ref == 0) continue;
                if (trace_crowd_ticks and added < 5) {
                    std.debug.print(
                        "[crowd_spawn] {s} idx={d} sp=({d:.9},{d:.9},{d:.9}) sref={d} spt=({d:.9},{d:.9},{d:.9}) gp=({d:.9},{d:.9},{d:.9}) gref={d} gpt=({d:.9},{d:.9},{d:.9})\n",
                        .{
                            ccfg.id,
                            added,
                            sp[0],
                            sp[1],
                            sp[2],
                            ss.ref,
                            ss.pt[0],
                            ss.pt[1],
                            ss.pt[2],
                            gp[0],
                            gp[1],
                            gp[2],
                            gg.ref,
                            gg.pt[0],
                            gg.pt[1],
                            gg.pt[2],
                        },
                    );
                    if (crowd.navquery.nav) |nm| {
                        tracePolyRef(ccfg.id, "sref", nm, ss.ref);
                        tracePolyRef(ccfg.id, "gref", nm, gg.ref);
                        var direct: [3]f32 = undefined;
                        var over = false;
                        nm.closestPointOnPoly(gg.ref, &gp, &direct, &over) catch {};
                        var direct_h: f32 = -999999.0;
                        const height_ok = if (nm.getPolyHeight(gg.ref, &gp, &direct_h)) true else |_| false;
                        std.debug.print(
                            "[crowd_direct] {s} idx={d} gref={d} over={} height_ok={} h={d:.9} closest=({d:.9},{d:.9},{d:.9})\n",
                            .{ ccfg.id, added, gg.ref, over, height_ok, direct_h, direct[0], direct[1], direct[2] },
                        );
                    }
                }
                const idx = try crowd.addAgent(&ss.pt, &params);
                if (idx < 0) break;
                agent_ids[added] = idx;
                _ = crowd.requestMoveTarget(idx, gg.ref, &gg.pt);
                added += 1;
            }
        },
        .choke_shared_goal => {
            // All N spawned on ONE side of a narrow band near center; single shared
            // goal on the FAR side. Spawn band: x∈[cx-0.05dx, cx+0.05dx] one side of
            // z=cz; goal far across z. Jitter is LCG-driven (deterministic).
            const gp0 = [3]f32{ cx, cy, cz + 0.35 * dz };
            const gg = snapConst(crowd.navquery, filter, gp0);
            shared_ref = gg.ref;
            shared_pos = gg.pt;
            var added: usize = 0;
            var guard: usize = 0;
            while (added < ccfg.n and guard < ccfg.n * 300) : (guard += 1) {
                const jx = (@as(f32, @floatCast(rng.nextFloat())) - 0.5) * 0.10 * dx;
                const jz = @as(f32, @floatCast(rng.nextFloat())) * 0.12 * dz; // one side only (+)
                const sp = [3]f32{ cx + jx, cy, cz - 0.20 * dz - jz };
                const ss = snapConst(crowd.navquery, filter, sp);
                if (ss.ref == 0) continue;
                const idx = try crowd.addAgent(&ss.pt, &params);
                if (idx < 0) break;
                agent_ids[added] = idx;
                if (shared_ref != 0) _ = crowd.requestMoveTarget(idx, shared_ref, &shared_pos);
                added += 1;
            }
        },
        .moving_shared_goal => {
            // N spread (LCG starts); single shared goal that moves every repath_period
            // ticks along a fixed deterministic patrol loop (set in the tick loop).
            var added: usize = 0;
            var guard: usize = 0;
            while (added < ccfg.n and guard < ccfg.n * 200) : (guard += 1) {
                const sp = drawPointInAabb(&rng, bmin, bmax);
                const ss = snapConst(crowd.navquery, filter, sp);
                if (ss.ref == 0) continue;
                const idx = try crowd.addAgent(&ss.pt, &params);
                if (idx < 0) break;
                agent_ids[added] = idx;
                added += 1;
            }
        },
        .cluster_no_goal => {
            // Tight ~6m-radius blob around ONE center poly (LCG jitter), heavily
            // overlapping. NO move target → target_none (set by addAgent). Disperse
            // via separation + collision only.
            var added: usize = 0;
            var guard: usize = 0;
            while (added < ccfg.n and guard < ccfg.n * 400) : (guard += 1) {
                const jx = (@as(f32, @floatCast(rng.nextFloat())) - 0.5) * 12.0; // ~±6m
                const jz = (@as(f32, @floatCast(rng.nextFloat())) - 0.5) * 12.0;
                const sp = [3]f32{ cx + jx, cy, cz + jz };
                const ss = snapConst(crowd.navquery, filter, sp);
                if (ss.ref == 0) continue;
                const idx = try crowd.addAgent(&ss.pt, &params);
                if (idx < 0) break;
                agent_ids[added] = idx;
                added += 1; // NO requestMoveTarget — separation-only
            }
        },
    }

    // §5: reset the registry AFTER spawn/goal setup, BEFORE the measured tick loop.
    registry.reset();

    const dt: f32 = 1.0 / 60.0;
    // Deterministic patrol waypoints for the moving-goal behavior (fixed loop).
    const patrol = [_][3]f32{
        .{ cx + 0.35 * dx, cy, cz + 0.35 * dz },
        .{ cx - 0.35 * dx, cy, cz + 0.35 * dz },
        .{ cx - 0.35 * dx, cy, cz - 0.35 * dz },
        .{ cx + 0.35 * dx, cy, cz - 0.35 * dz },
    };
    var patrol_idx: usize = 0;

    if (trace_crowd_ticks) traceCrowdTick(ccfg.id, -1, crowd);

    var tick: usize = 0;
    while (tick < ccfg.ticks) : (tick += 1) {
        if (ccfg.behavior == .moving_shared_goal and ccfg.repath_period > 0 and (tick % ccfg.repath_period) == 0) {
            // Compute the next shared goal poly + requestMoveTarget to ALL agents on
            // the SAME tick → a synchronized mass-repath event (§5).
            const wp = patrol[patrol_idx % patrol.len];
            patrol_idx += 1;
            const gg = snapConst(crowd.navquery, filter, wp);
            if (gg.ref != 0) {
                for (agent_ids) |idx| {
                    if (idx >= 0) _ = crowd.requestMoveTarget(idx, gg.ref, &gg.pt);
                }
            }
        }
        try crowd.update(dt);
        if (trace_crowd_ticks) traceCrowdTick(ccfg.id, @intCast(tick), crowd);
    }

    return .{ .npolys = built.npolys, .nverts = built.nverts };
}

// ===========================================================================
// TILECACHE LAYER (Task: dynamic-obstacle navmesh coverage)
//
// The detour_tilecache module is the dynamic-obstacle navmesh: a tiled
// navmesh whose tiles are stored COMPRESSED and rebuilt incrementally when
// temporary obstacles (cylinder/box/obb) are added or removed. Its hot path is
//   tc.update() -> dtTileCacheBuildNavMeshTile -> decompress layer +
//   buildTileCacheRegions + buildTileCacheContours + buildTileCachePolyMesh +
//   createNavMeshData -> navmesh.removeTile/addTile
// i.e. a per-tile region/contour/polymesh rebuild, ONE tile per update() call.
//
// This layer builds a tiled tile-cache over a BOUNDED CENTRAL REGION of a map
// (mirroring §2.5's tiled-region rule so the cell count stays tractable), at
// fixed cs=0.3, then runs a MEASURED loop that:
//   1. adds a deterministic batch of box obstacles (LCG-placed in the region),
//   2. drives tc.update() until up-to-date (rebuilding every touched tile),
//   3. removes every obstacle,
//   4. drives tc.update() until up-to-date again (restoring the tiles).
// The tile-cache BUILD (rasterize + heightfield layers + compress + addTile +
// initial buildNavMeshTilesAt) is NOT measured: the registry is reset AFTER the
// build, just before the obstacle loop. The in-core dtTileCache* zones fire
// automatically under -Dbench=true / -Dtracy=true; this layer only DRIVES the workload.
//
// LCG: same Numerical-Recipes stream as §2.1 (seed 12345, advance-then-use,
// f = state/2^32) so the obstacle positions are deterministic and a future C++
// mirror can reproduce them draw-for-draw.
// ===========================================================================

const tilecache_cs: f32 = 0.3;
const tilecache_ch: f32 = 0.15;
/// Central half-extent of the tile-cache region (world units) — same scale as
/// the §2.5 tiled-region rule, kept bounded so the tiled grid stays tractable.
const tilecache_region_half_extent: f32 = 300.0;

/// A no-op compressor (store-only). maxCompressedSize=size, compress/decompress
/// are plain memcpy — identical to the demo's NoopCompressor and the pipeline
/// test's StubCompressor. The compression cost is intentionally excluded; the
/// measured cost is the region/contour/polymesh rebuild, not byte packing.
const NoopComp = struct {
    fn maxCompressedSize(_: *anyopaque, buffer_size: usize) usize {
        return buffer_size;
    }
    fn compress(_: *anyopaque, buffer: []const u8, compressed: []u8, compressed_size: *usize) nav.detour.Status {
        @memcpy(compressed[0..buffer.len], buffer);
        compressed_size.* = buffer.len;
        return nav.detour.Status.ok();
    }
    fn decompress(_: *anyopaque, compressed: []const u8, buffer: []u8, buffer_size: *usize) nav.detour.Status {
        @memcpy(buffer[0..compressed.len], compressed);
        buffer_size.* = compressed.len;
        return nav.detour.Status.ok();
    }
    fn iface(self: *NoopComp) nav.detour_tilecache.TileCacheCompressor {
        return .{ .ptr = self, .vtable = &.{
            .maxCompressedSize = maxCompressedSize,
            .compress = compress,
            .decompress = decompress,
        } };
    }
};

const ObstacleType = enum { box, cylinder, oriented_box };

const TileCacheCfg = struct {
    id: []const u8,
    geometry: []const u8,
    tile_size: i32 = 48, // VOXELS per tile (interior, before border)
    walkable_slope_angle: f32 = 45.0,
    walkable_height: i32 = 10,
    walkable_climb: i32 = 4,
    walkable_radius: i32 = 2,
    max_simplification_error: f32 = 1.3,
    obstacles: usize = 16, // obstacles added/removed per measured cycle
    iters: usize = 3, // measured add/update/remove/update cycles
    obstacle_type: ObstacleType = .box, // dynamic-obstacle shape under test
};

const tilecache_scenarios = [_]TileCacheCfg{
    .{ .id = "tilecache_obstacles_map_2", .geometry = "map_2_bvh.obj" },
    // Dynamic-obstacle suite: shape variants + density + a second map. The
    // measured zones (dtTileCacheUpdate rebuild chain) are exercised by each
    // obstacle shape; cylinder/oriented carve differently than the AABB box.
    .{ .id = "tilecache_cylinders_map_2", .geometry = "map_2_bvh.obj", .obstacle_type = .cylinder },
    .{ .id = "tilecache_orientedbox_map_2", .geometry = "map_2_bvh.obj", .obstacle_type = .oriented_box },
    .{ .id = "tilecache_dense_box_map_2", .geometry = "map_2_bvh.obj", .obstacles = 64 },
    .{ .id = "tilecache_obstacles_map_3", .geometry = "map_3_bvh.obj" },
};

fn findTileCacheScenario(id: []const u8) ?*const TileCacheCfg {
    for (&tilecache_scenarios) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// A fully-built tile-cache navmesh + the central-region bounds, kept alive for
/// the measured obstacle loop. The build is NOT measured.
const BuiltTileCache = struct {
    tc: *nav.detour_tilecache.TileCache,
    navmesh: *nav.NavMesh,
    comp: *NoopComp,
    comp_iface: *nav.detour_tilecache.TileCacheCompressor, // must outlive tc (tc stores this ptr)
    rmin: nav.Vec3, // central-region world min (XZ region the obstacles target)
    rmax: nav.Vec3,
    tiles_x: i32,
    tiles_z: i32,
    tile_count: usize, // compressed tiles actually added
};

/// Build a tiled tile-cache over the bounded central region of `geom`. Mirrors
/// the proven demo recipe (sample_temp_obstacles.zig rasterizeTileLayers):
/// per tile rasterize -> chf -> erode -> buildHeightfieldLayers -> per-layer
/// buildTileCacheLayer (compress) + tc.addTile, then buildNavMeshTilesAt to
/// populate the live dtNavMesh. NOT measured (caller resets the registry after).
fn buildTileCache(allocator: std.mem.Allocator, geom: Geom, cfg: *const TileCacheCfg) !BuiltTileCache {
    var ctx = nav.Context.init(allocator);
    ctx.enableLog(enable_core_log);
    ctx.enableTimer(false);

    var bmin = nav.Vec3.zero();
    var bmax = nav.Vec3.zero();
    calcBoundsFlat(geom.verts, &bmin, &bmax);

    const cx = (bmin.x + bmax.x) * 0.5;
    const cz = (bmin.z + bmax.z) * 0.5;
    const rxmin = @max(bmin.x, cx - tilecache_region_half_extent);
    const rxmax = @min(bmax.x, cx + tilecache_region_half_extent);
    const rzmin = @max(bmin.z, cz - tilecache_region_half_extent);
    const rzmax = @min(bmax.z, cz + tilecache_region_half_extent);

    const cs = tilecache_cs;
    const ch = tilecache_ch;
    const border_size: i32 = cfg.walkable_radius + 3;
    const tile_world: f32 = @as(f32, @floatFromInt(cfg.tile_size)) * cs;

    const tiles_x: i32 = @intFromFloat(@ceil((rxmax - rxmin) / tile_world));
    const tiles_z: i32 = @intFromFloat(@ceil((rzmax - rzmin) / tile_world));

    // Tile-cache params: orig at the region min, one logical tile = tile_size
    // voxels. max_tiles must cover tiles_x*tiles_z * layers-per-tile (4 like the
    // demo) so addTile never overflows.
    var tc_params = std.mem.zeroes(nav.detour_tilecache.TileCacheParams);
    tc_params.orig = .{ rxmin, bmin.y, rzmin };
    tc_params.cs = cs;
    tc_params.ch = ch;
    tc_params.width = cfg.tile_size;
    tc_params.height = cfg.tile_size;
    tc_params.walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * ch;
    tc_params.walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cs;
    tc_params.walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * ch;
    tc_params.max_simplification_error = cfg.max_simplification_error;
    tc_params.max_tiles = tiles_x * tiles_z * 4;
    tc_params.max_obstacles = 256;

    const comp = try allocator.create(NoopComp);
    errdefer allocator.destroy(comp);
    comp.* = .{};
    // comp_iface MUST outlive the TileCache: TileCache.init stores this pointer as
    // self.comp. A stack local dangles after buildTileCache returns -> the obstacle-update
    // phase derefs freed stack (ReleaseSafe-masked by 0xAA fill, ReleaseFast-segfault).
    const comp_iface = try allocator.create(nav.detour_tilecache.TileCacheCompressor);
    errdefer allocator.destroy(comp_iface);
    comp_iface.* = comp.iface();

    const tc = try allocator.create(nav.detour_tilecache.TileCache);
    errdefer allocator.destroy(tc);
    tc.* = try nav.detour_tilecache.TileCache.init(allocator, &tc_params, comp_iface, null);
    errdefer tc.deinit();

    // Live navmesh the tile-cache writes its rebuilt tiles into.
    const nm_params = nav.NavMeshParams{
        .orig = nav.Vec3.init(rxmin, bmin.y, rzmin),
        .tile_width = tile_world,
        .tile_height = tile_world,
        .max_tiles = tc_params.max_tiles,
        .max_polys = 16384,
    };
    const navmesh = try allocator.create(nav.NavMesh);
    errdefer allocator.destroy(navmesh);
    navmesh.* = try nav.NavMesh.init(allocator, nm_params);
    errdefer navmesh.deinit();

    // Per-triangle walkable area ids (shared across tiles; recast clips per tile).
    const tri_count = geom.triCount();
    const areas = try allocator.alloc(u8, tri_count);
    defer allocator.free(areas);

    var tile_count: usize = 0;
    const tw = cfg.tile_size + border_size * 2;
    var tz: i32 = 0;
    while (tz < tiles_z) : (tz += 1) {
        var tx: i32 = 0;
        while (tx < tiles_x) : (tx += 1) {
            const ix_min = rxmin + @as(f32, @floatFromInt(tx)) * tile_world;
            const iz_min = rzmin + @as(f32, @floatFromInt(tz)) * tile_world;
            const exp = @as(f32, @floatFromInt(border_size)) * cs;
            const hbmin = nav.Vec3.init(ix_min - exp, bmin.y, iz_min - exp);
            const hbmax = nav.Vec3.init(ix_min + tile_world + exp, bmax.y, iz_min + tile_world + exp);

            var hf = nav.Heightfield.init(allocator, tw, tw, hbmin, hbmax, cs, ch) catch continue;
            defer hf.deinit();

            @memset(areas, nav.recast.config.AreaId.NULL_AREA);
            nav.recast.filter.markWalkableTriangles(&ctx, cfg.walkable_slope_angle, geom.verts, geom.tris, areas);
            nav.recast.rasterization.rasterizeTriangles(&ctx, geom.verts, geom.tris, areas, &hf, cfg.walkable_climb) catch continue;

            nav.recast.filter.filterLowHangingWalkableObstacles(&ctx, cfg.walkable_climb, &hf);
            nav.recast.filter.filterLedgeSpans(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
            nav.recast.filter.filterWalkableLowHeightSpans(&ctx, cfg.walkable_height, &hf);

            const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
            if (span_count == 0) continue;
            var chf = nav.CompactHeightfield.init(allocator, tw, tw, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, hbmin, hbmax, cs, ch, border_size) catch continue;
            defer chf.deinit();
            nav.recast.compact.buildCompactHeightfield(&ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf) catch continue;
            nav.recast.area.erodeWalkableArea(&ctx, cfg.walkable_radius, &chf, allocator) catch continue;

            var lset = nav.recast.HeightfieldLayerSet.init(allocator);
            defer lset.deinit();
            nav.recast.layers.buildHeightfieldLayers(&ctx, &chf, border_size, cfg.walkable_height, &lset, allocator) catch continue;

            const nlayers: usize = @min(lset.layerCount(), 255);
            for (0..nlayers) |li| {
                const layer = &lset.layers[li];
                var header = std.mem.zeroes(nav.detour_tilecache.TileCacheLayerHeader);
                header.magic = nav.detour_tilecache.TILECACHE_MAGIC;
                header.version = nav.detour_tilecache.TILECACHE_VERSION;
                header.tx = tx;
                header.ty = tz;
                header.tlayer = @intCast(li);
                header.bmin = layer.bmin.toArray();
                header.bmax = layer.bmax.toArray();
                header.hmin = @intCast(layer.hmin);
                header.hmax = @intCast(layer.hmax);
                header.width = @intCast(layer.width);
                header.height = @intCast(layer.height);
                header.minx = @intCast(layer.minx);
                header.maxx = @intCast(layer.maxx);
                header.miny = @intCast(layer.miny);
                header.maxy = @intCast(layer.maxy);

                const data = nav.detour_tilecache.builder.buildTileCacheLayer(comp_iface, &header, layer.heights, layer.areas, layer.cons, allocator) catch continue;
                _ = tc.addTile(data, .{}) catch {
                    allocator.free(data);
                    continue;
                };
                tile_count += 1;
            }

            _ = tc.buildNavMeshTilesAt(tx, tz, navmesh) catch {};
        }
    }

    return .{
        .tc = tc,
        .navmesh = navmesh,
        .comp = comp,
        .comp_iface = comp_iface,
        .rmin = nav.Vec3.init(rxmin, bmin.y, rzmin),
        .rmax = nav.Vec3.init(rxmax, bmax.y, rzmax),
        .tiles_x = tiles_x,
        .tiles_z = tiles_z,
        .tile_count = tile_count,
    };
}

/// Drive tc.update() until the cache reports up-to-date (one tile rebuilt per
/// call). A hard cap guards against a stuck queue. Returns the number of
/// update() calls made (= tiles rebuilt + the final no-op poll).
fn drainTileCacheUpdates(built: *BuiltTileCache) !usize {
    var calls: usize = 0;
    var up_to_date = false;
    while (!up_to_date and calls < 100000) : (calls += 1) {
        _ = try built.tc.update(1.0 / 60.0, built.navmesh, &up_to_date);
    }
    return calls;
}

/// Run one TILECACHE scenario: build the tiled tile-cache once (NOT measured),
/// reset the registry, then run `iters` measured add/update/remove/update
/// cycles with `obstacles` LCG-placed box obstacles each cycle.
fn runTileCache(allocator: std.mem.Allocator, geom: Geom, cfg: *const TileCacheCfg) !struct { tiles: usize, obstacles_per_cycle: usize, tiles_x: i32, tiles_z: i32 } {
    var built = try buildTileCache(allocator, geom, cfg);
    defer {
        built.tc.deinit();
        allocator.destroy(built.tc);
        built.navmesh.deinit();
        allocator.destroy(built.navmesh);
        allocator.destroy(built.comp);
        allocator.destroy(built.comp_iface);
    }

    // §2.1 LCG stream: obstacle XZ positions inside the central region.
    var rng = Lcg.init(12345);
    const rmin = built.rmin;
    const rmax = built.rmax;
    // Small AABB box obstacles (~2x2 world units footprint, full-height-ish).
    const half: f32 = 1.0;
    const obs_y0 = rmin.y;
    const obs_y1 = rmax.y;

    const refs = try allocator.alloc(nav.detour_tilecache.ObstacleRef, cfg.obstacles);
    defer allocator.free(refs);

    // §: reset the registry AFTER the (unmeasured) tile-cache build, BEFORE the
    // measured obstacle loop, so only the dtTileCache* rebuild zones land in CSV.
    registry.reset();

    const obs_h: f32 = obs_y1 - obs_y0;
    var it: usize = 0;
    while (it < cfg.iters) : (it += 1) {
        // 1. Add a deterministic batch of obstacles of the configured shape.
        for (refs) |*r| {
            const fx = rng.nextFloat();
            const fz = rng.nextFloat();
            const x = rmin.x + @as(f32, @floatCast(fx)) * (rmax.x - rmin.x);
            const z = rmin.z + @as(f32, @floatCast(fz)) * (rmax.z - rmin.z);
            r.* = switch (cfg.obstacle_type) {
                .box => blk: {
                    const bmn = [3]f32{ x - half, obs_y0, z - half };
                    const bmx = [3]f32{ x + half, obs_y1, z + half };
                    break :blk built.tc.addBoxObstacle(&bmn, &bmx) catch 0;
                },
                .cylinder => blk: {
                    const pos = [3]f32{ x, obs_y0, z };
                    break :blk built.tc.addObstacle(&pos, half, obs_h) catch 0;
                },
                .oriented_box => blk: {
                    // yaw from one extra LCG draw → distinct stream per scenario.
                    const fyaw = rng.nextFloat();
                    const yaw = @as(f32, @floatCast(fyaw)) * std.math.pi;
                    const center = [3]f32{ x, (obs_y0 + obs_y1) * 0.5, z };
                    const he = [3]f32{ half, obs_h * 0.5, half };
                    break :blk built.tc.addOrientedBoxObstacle(&center, &he, yaw) catch 0;
                },
            };
        }
        // 2. Rebuild every touched tile.
        _ = try drainTileCacheUpdates(&built);
        // 3. Remove every obstacle.
        for (refs) |r| {
            if (r != 0) built.tc.removeObstacle(r) catch {};
        }
        // 4. Restore the tiles.
        _ = try drainTileCacheUpdates(&built);
    }

    return .{ .tiles = built.tile_count, .obstacles_per_cycle = cfg.obstacles, .tiles_x = built.tiles_x, .tiles_z = built.tiles_z };
}

/// Run one TILECACHE scenario end-to-end (build tile-cache once -> reset ->
/// measured add/update/remove/update cycles -> dumpCsv -> flush). Same I1/M3
/// contract as runAndDump.
fn runAndDumpTileCache(
    allocator: std.mem.Allocator,
    cache: *GeomCache,
    cfg: *const TileCacheCfg,
    fw: *std.Io.File.Writer,
) !void {
    const w = &fw.interface;
    const geom = try cache.get(cfg.geometry);
    registry.reset();

    std.debug.print(
        "[tracy_scenarios] {s}: TILECACHE map={s} cs={d:.4} tile_size={d} obstacles={d} iters={d}\n",
        .{ cfg.id, cfg.geometry, tilecache_cs, cfg.tile_size, cfg.obstacles, cfg.iters },
    );
    const info = try runTileCache(allocator, geom, cfg);
    std.debug.print(
        "[tracy_scenarios] {s}: tiles={d} grid={d}x{d} obstacles/cycle={d}\n",
        .{ cfg.id, info.tiles, info.tiles_x, info.tiles_z, info.obstacles_per_cycle },
    );

    try registry.dumpCsv(w, cfg.id);
    try w.flush();
    const zone_rows = registry.zoneCount();
    if (zone_rows == 0) {
        std.debug.print("[tracy_scenarios] ERROR {s}: ZERO zone rows (built with -Dbench=true or -Dtracy=true? tiles populated? obstacles touched tiles?)\n", .{cfg.id});
    } else {
        std.debug.print("[tracy_scenarios] {s}: {d} zone rows flushed\n", .{ cfg.id, zone_rows });
    }
}

// ===========================================================================
// CSV output (Zig 0.16 std.Io — std.fs.cwd() does NOT exist).
//
// I1 (incremental flush): the output file is opened ONCE (createFile, truncate),
// the header is written + flushed up front, then EACH scenario appends its
// dumpCsv rows and flushes immediately as it finishes. A File.Writer tracks its
// own positional `pos`, so successive writes append after the header — there is
// no whole-CSV memory buffer that a crash/kill on a multi-hour `all` run would
// lose. After every scenario the bytes are durably on disk.
//
// 8 KiB write buffer: dumpCsv emits ~13 short rows/scenario (well under 8 KiB),
// but flush() drains regardless so partial rows never linger un-written.
// ===========================================================================

const csv_write_buf_len = 8 * 1024;

// ===========================================================================
// Dispatch + main
// ===========================================================================

fn findScenario(id: []const u8) ?*const Scenario {
    for (&build_scenarios) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

/// Run one BUILD scenario end-to-end: reset the registry, apply the §2.3 budget
/// guard, run `iters` full rebuilds (solo or tiled), append its CSV rows to the
/// file via `fw` and FLUSH it durably to disk (I1 — the header was written once
/// by the caller). On a budget skip it emits the `__SKIPPED_BUDGET__` marker row
/// (also flushed) and builds NOTHING.
///
/// M3 (defensive): after the dump we re-check the registry's zone count; a real
/// BUILD scenario must produce non-zero zone rows. Zero rows (the once-observed
/// empty-CSV) is logged loudly as an error so a regression is impossible to miss.
fn runAndDump(
    allocator: std.mem.Allocator,
    cache: *GeomCache,
    scenario: *const Scenario,
    fw: *std.Io.File.Writer,
    iters_override: usize,
) !void {
    const w = &fw.interface;
    const cfg = scenario.cfg;
    const geom = try cache.get(cfg.geometry);
    registry.reset();

    const iters = if (iters_override > 0) iters_override else cfg.iters;

    if (cfg.tiled) {
        // §2.3 guard on the FULL region grid (not per-tile).
        const cells = tiledRegionCells(geom);
        if (cells > cell_budget) {
            std.debug.print("[tracy_scenarios] SKIP {s}: tiled region {d} cells > {d} budget\n", .{ scenario.id, cells, cell_budget });
            try w.print("{s},__SKIPPED_BUDGET__,0,0,0,0,0,0\n", .{scenario.id});
            try w.flush(); // I1: durable before returning.
            return;
        }
        std.debug.print("[tracy_scenarios] {s}: TILED cs={d:.4} region_cells={d} iters={d}\n", .{ scenario.id, tiled_cs, cells, iters });
        var i: usize = 0;
        while (i < iters) : (i += 1) try runTiled(allocator, geom, cfg);
    } else {
        const grid = deriveSoloGrid(geom, cfg.target_cells);
        const cells: i64 = @as(i64, grid.width) * @as(i64, grid.height);
        if (cells > cell_budget) {
            std.debug.print("[tracy_scenarios] SKIP {s}: solo grid {d}x{d}={d} cells > {d} budget (cs={d:.4})\n", .{ scenario.id, grid.width, grid.height, cells, cell_budget, grid.cs });
            try w.print("{s},__SKIPPED_BUDGET__,0,0,0,0,0,0\n", .{scenario.id});
            try w.flush(); // I1: durable before returning.
            return;
        }
        std.debug.print("[tracy_scenarios] {s}: SOLO cs={d:.4} ch={d:.4} w={d} h={d} cells={d} iters={d}\n", .{ scenario.id, grid.cs, grid.ch, grid.width, grid.height, cells, iters });
        var i: usize = 0;
        while (i < iters) : (i += 1) try runSolo(allocator, geom, cfg, grid);
    }

    try registry.dumpCsv(w, scenario.id);
    try w.flush(); // I1: each scenario's rows are durably on disk before the next runs.

    // M3: a completed (non-skipped) BUILD scenario MUST have recorded zones.
    // Guard against the once-observed empty-CSV: log a clear error if zero rows.
    const zone_rows = registry.zoneCount();
    if (zone_rows == 0) {
        std.debug.print(
            "[tracy_scenarios] ERROR {s}: produced ZERO zone rows — empty CSV for this scenario. " ++
                "Built with -Dbench=true or -Dtracy=true? geometry non-empty? (no zones recorded)\n",
            .{scenario.id},
        );
    } else {
        std.debug.print("[tracy_scenarios] {s}: {d} zone rows flushed\n", .{ scenario.id, zone_rows });
    }
}

/// Run one QUERY scenario end-to-end (build navmesh once → reset → measured flood →
/// dumpCsv → flush). Mirrors `runAndDump`'s I1/M3 contract. The navmesh build is NOT
/// measured: `runQuery` resets the registry after building, before the measured loop.
fn runAndDumpQuery(
    allocator: std.mem.Allocator,
    cache: *GeomCache,
    qcfg: *const QueryCfg,
    fw: *std.Io.File.Writer,
) !void {
    const w = &fw.interface;
    const geom = try cache.get(qcfg.geom);
    registry.reset();

    if (qcfg.tiled) {
        std.debug.print(
            "[tracy_scenarios] {s}: QUERY tiled navmesh {s} (cs={d:.2} tile_size={d}) node_pool={d} N={d}\n",
            .{ qcfg.id, qcfg.geom, tiled_cs, query_tiled_tile_size, qcfg.node_pool, qcfg.n },
        );
    } else {
        const grid = deriveSoloGrid(geom, query_target_cells);
        std.debug.print(
            "[tracy_scenarios] {s}: QUERY navmesh {s} @8M cs={d:.4} w={d} h={d} node_pool={d} N={d}\n",
            .{ qcfg.id, qcfg.geom, grid.cs, grid.width, grid.height, qcfg.node_pool, qcfg.n },
        );
    }
    const info = try runQuery(allocator, geom, qcfg);
    std.debug.print("[tracy_scenarios] {s}: navmesh npolys={d} nverts={d}\n", .{ qcfg.id, info.npolys, info.nverts });

    try registry.dumpCsv(w, qcfg.id);
    try w.flush();
    const zone_rows = registry.zoneCount();
    if (zone_rows == 0) {
        std.debug.print("[tracy_scenarios] ERROR {s}: ZERO zone rows (built with -Dbench=true or -Dtracy=true? non-empty navmesh?)\n", .{qcfg.id});
    } else {
        std.debug.print("[tracy_scenarios] {s}: {d} zone rows flushed\n", .{ qcfg.id, zone_rows });
    }
}

/// Run one CROWD scenario end-to-end (build navmesh once → spawn → reset → ticks →
/// dumpCsv → flush). Same I1/M3 contract.
fn runAndDumpCrowd(
    allocator: std.mem.Allocator,
    cache: *GeomCache,
    ccfg: *const CrowdCfg,
    fw: *std.Io.File.Writer,
) !void {
    const w = &fw.interface;
    const geom = try cache.get(crowd_navmesh_geom);
    registry.reset();

    const grid = deriveSoloGrid(geom, crowd_target_cells);
    std.debug.print(
        "[tracy_scenarios] {s}: CROWD navmesh map_2_bvh @8M cs={d:.4} w={d} h={d} N={d} ticks={d} oa={d} flags={d}\n",
        .{ ccfg.id, grid.cs, grid.width, grid.height, ccfg.n, ccfg.ticks, ccfg.oa_type, ccfg.update_flags },
    );
    const info = try runCrowd(allocator, geom, ccfg);
    std.debug.print("[tracy_scenarios] {s}: navmesh npolys={d} nverts={d}\n", .{ ccfg.id, info.npolys, info.nverts });

    try registry.dumpCsv(w, ccfg.id);
    try w.flush();
    const zone_rows = registry.zoneCount();
    if (zone_rows == 0) {
        std.debug.print("[tracy_scenarios] ERROR {s}: ZERO zone rows (built with -Dbench=true or -Dtracy=true? agents on mesh?)\n", .{ccfg.id});
    } else {
        std.debug.print("[tracy_scenarios] {s}: {d} zone rows flushed\n", .{ ccfg.id, zone_rows });
    }
}

/// Resolve an id across ALL THREE layers (BUILD/QUERY/CROWD) and run the right
/// handler. Unknown ids return error.UnknownScenario (the caller lists the known set).
fn dispatchById(
    allocator: std.mem.Allocator,
    cache: *GeomCache,
    id: []const u8,
    fw: *std.Io.File.Writer,
    iters_override: usize,
) !void {
    if (findScenario(id)) |s| {
        return runAndDump(allocator, cache, s, fw, iters_override);
    }
    if (findQueryScenario(id)) |q| {
        return runAndDumpQuery(allocator, cache, q, fw);
    }
    if (findCrowdScenario(id)) |c| {
        return runAndDumpCrowd(allocator, cache, c, fw);
    }
    if (findTileCacheScenario(id)) |t| {
        return runAndDumpTileCache(allocator, cache, t, fw);
    }
    return error.UnknownScenario;
}

pub fn main(init: std.process.Init) !void {
    // Zig 0.16 entrypoint: the runtime hands us a gpa + io + the OS arg vector
    // (via minimal.args) + environ_map.
    const allocator = init.gpa;
    const io = init.io;
    if (init.environ_map.get("RECAST_CORE_LOG")) |v| {
        enable_core_log = v.len != 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
    }
    if (init.environ_map.get("RECAST_CROWD_TICK_TRACE")) |v| {
        trace_crowd_ticks = v.len != 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false");
    }

    // Collect args into an owned slice ([scenario_id, geom_dir, out_csv] after
    // skipping argv[0]). Zig 0.16: std.process.argsAlloc is gone; iterate the
    // provided Args (mirrors demo/src/main.zig).
    var arg_list = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (arg_list.items) |a| allocator.free(a);
        arg_list.deinit();
    }
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer it.deinit();
        _ = it.skip(); // argv[0]
        while (it.next()) |a| try arg_list.append(try allocator.dupe(u8, a));
    }
    const args = arg_list.items;

    if (args.len != 3) {
        std.debug.print(
            \\usage: tracy_scenarios <scenario_id|id1,id2,...|all> <geom_dir> <out_csv>
            \\  geom_dir    = dir with the dense BVH world meshes (<map>_bvh.obj)
            \\  scenario_id = one BUILD/QUERY/CROWD scenario, a comma-separated subset, or 'all'
            \\
        , .{});
        return error.BadUsage;
    }

    const target_id = args[0];
    const geom_dir = args[1];
    const out_csv = args[2];

    // Optional smoke-test override: TRACY_SCENARIOS_ITERS=N forces N iters per
    // scenario (does NOT change the scenarios.md contract default — leave it unset
    // for a real comparison run). Useful for a fast structural smoke of every zone.
    var iters_override: usize = 0;
    if (init.environ_map.get("TRACY_SCENARIOS_ITERS")) |v| {
        iters_override = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t\r\n"), 10) catch 0;
    }

    var cache = GeomCache.init(allocator, geom_dir);
    defer cache.deinit();

    // I1: open the output file ONCE (truncating any prior run) and stream rows
    // into it incrementally. The File.Writer keeps its own positional `pos`, so
    // each scenario's flushed dumpCsv appends after the header — no whole-CSV
    // memory buffer to lose on a crash/kill during the multi-hour `all` run.
    var out_file = try std.Io.Dir.cwd().createFile(io, out_csv, .{ .truncate = true });
    defer out_file.close(io);
    var write_buf: [csv_write_buf_len]u8 = undefined;
    var fw = out_file.writer(io, &write_buf);
    const w = &fw.interface;

    // Header ONCE at the top of the output, before the first scenario, flushed
    // immediately so the file is never empty even if scenario 1 is slow/crashes.
    try registry.writeCsvHeader(w);
    try w.flush();
    const header_len = fw.pos; // M3: durable header length on disk.

    if (std.mem.eql(u8, target_id, "all")) {
        // All 29: 14 BUILD + 8 QUERY + 7 CROWD (§6). Each appends+flushes its rows.
        for (&build_scenarios) |*s| {
            try runAndDump(allocator, &cache, s, &fw, iters_override);
        }
        for (&query_scenarios) |*q| {
            try runAndDumpQuery(allocator, &cache, q, &fw);
        }
        for (&crowd_scenarios) |*c| {
            try runAndDumpCrowd(allocator, &cache, c, &fw);
        }
        for (&tilecache_scenarios) |*t| {
            try runAndDumpTileCache(allocator, &cache, t, &fw);
        }
    } else {
        // Single id OR a comma-separated subset (e.g.
        // "build_solo_watershed_map_1_coarse,query_movealongsurface_flood")
        // — each runs in turn and appends+flushes its rows to the SAME file, so
        // the CSV grows per scenario (incremental flush, I1). dispatchById resolves
        // across all three layers.
        var it = std.mem.tokenizeScalar(u8, target_id, ',');
        while (it.next()) |id| {
            dispatchById(allocator, &cache, id, &fw, iters_override) catch |err| {
                if (err == error.UnknownScenario) {
                    std.debug.print("unknown scenario_id: {s}\n", .{id});
                    std.debug.print("known BUILD scenarios:\n", .{});
                    for (&build_scenarios) |*sc| std.debug.print("  {s}\n", .{sc.id});
                    std.debug.print("known QUERY scenarios:\n", .{});
                    for (&query_scenarios) |*sc| std.debug.print("  {s}\n", .{sc.id});
                    std.debug.print("known CROWD scenarios:\n", .{});
                    for (&crowd_scenarios) |*sc| std.debug.print("  {s}\n", .{sc.id});
                    std.debug.print("known TILECACHE scenarios:\n", .{});
                    for (&tilecache_scenarios) |*sc| std.debug.print("  {s}\n", .{sc.id});
                }
                return err;
            };
        }
    }

    // Final durability + M3: the written file MUST be longer than the header
    // alone (i.e. at least one scenario emitted rows). A file no larger than the
    // header is the empty-CSV failure — surface it loudly and fail.
    try w.flush();
    const total_len = fw.pos;
    if (total_len <= header_len) {
        std.debug.print(
            "[tracy_scenarios] ERROR {s}: file is header-only ({d} bytes <= header {d}) — NO zone rows written.\n",
            .{ out_csv, total_len, header_len },
        );
        return error.EmptyCsv;
    }
    std.debug.print("[tracy_scenarios] wrote {s} ({d} bytes, header {d})\n", .{ out_csv, total_len, header_len });
}
