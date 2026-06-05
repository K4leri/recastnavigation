//! NavMeshTesterTool — интерактивное тестирование navmesh-запросов.
//! Порт RecastDemo/Tool_NavMeshTester: pathfind (follow/straight/sliced), raycast,
//! distance-to-wall, find-polys (circle/shape), local-neighbourhood + include/exclude флаги.

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ddgl = @import("debug_draw_gl.zig");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const poly_flags = @import("poly_flags.zig");
const ui = @import("ui.zig");
const components = @import("render/components.zig");
const poly_visit = @import("render/poly_visit.zig");
const reachability = @import("diag/reachability.zig");
const diagnose = @import("diag/diagnose.zig");
const wnp = @import("diag/why_no_path.zig");
const astar_player = @import("diag/astar_player.zig");
const funnel = @import("diag/funnel.zig");
const filter_compare = @import("diag/filter_compare.zig");
const query_bench = @import("diag/query_bench.zig");
const profiler = @import("diag/profiler.zig");

const dt = recast.detour;
const dbg = recast.debug;
const PF = sample.SamplePolyFlags;

const MAX_POLYS = 256;
const MAX_SMOOTH = 2048;

// Цвета подсветки. NB: цвета относительно upstream поменяны местами — start
// рисуется зелёным, end красным (интуитивнее: LMB ставит зелёный старт).
const startCol = dbg.rgba(51, 102, 0, 192);
const endCol = dbg.rgba(128, 25, 0, 129);
const pathCol = dbg.rgba(0, 0, 0, 64);

pub const ToolMode = enum {
    pathfind_follow,
    pathfind_straight,
    pathfind_sliced,
    distance_to_wall,
    raycast,
    find_polys_circle,
    find_polys_shape,
    find_local_neighbourhood,
};

pub const NavMeshTesterTool = struct {
    alloc: std.mem.Allocator,
    dd_gl: *ddgl.DebugDrawGL,

    navmesh: ?*dt.NavMesh = null,
    query: ?*dt.NavMeshQuery = null,
    filter: dt.QueryFilter,

    mode: ToolMode = .pathfind_follow,

    spos: [3]f32 = .{ 0, 0, 0 },
    epos: [3]f32 = .{ 0, 0, 0 },
    spos_set: bool = false,
    epos_set: bool = false,

    start_ref: dt.PolyRef = 0,
    end_ref: dt.PolyRef = 0,

    polys: [MAX_POLYS]dt.PolyRef = undefined,
    parent: [MAX_POLYS]dt.PolyRef = undefined,
    npolys: usize = 0,

    straight: [MAX_POLYS * 3]f32 = undefined,
    straight_flags: [MAX_POLYS]u8 = undefined,
    straight_refs: [MAX_POLYS]dt.PolyRef = undefined,
    nstraight: usize = 0,

    // follow-режим: отдельный буфер сглаженного пути (upstream MAX_SMOOTH=2048),
    // НЕ переиспользуем `straight` (256) — иначе путь обрывается на 256 точках.
    smooth: [MAX_SMOOTH * 3]f32 = undefined,
    nsmooth: usize = 0,

    // размеры агента для drawAgent (синхронятся из sample.settings через setAgent).
    agent_radius: f32 = 0.6,
    agent_height: f32 = 2.0,
    agent_climb: f32 = 0.9,

    ray_t: f32 = 0,
    ray_has: bool = false,

    // distance-to-wall
    wall_dist: f32 = 0,
    wall_pos: [3]f32 = .{ 0, 0, 0 },
    wall_normal: [3]f32 = .{ 0, 0, 0 },
    // circle/shape
    query_radius: f32 = 0,
    shape_verts: [12]f32 = undefined,
    shape_nverts: usize = 0,

    // WHY-NO-PATH verdict (A1): recomputed on every recalc that produces start/end
    // refs. `verdict` is shown in the panel; `signals` feeds the Explain expander.
    // `verdict_valid` gates display (false until a pathfind recalc with both refs).
    verdict: diagnose.Verdict = .unknown,
    signals: wnp.Signals = std.mem.zeroes(wnp.Signals),
    verdict_valid: bool = false,
    diag_scratch: [MAX_POLYS]dt.PolyRef = undefined,

    // include/exclude filter masks (bits = poly_flags registry). Default: include
    // the four built-in flags, exclude none. Custom flags start unchecked.
    include_mask: u16 = PF.walk | PF.swim | PF.door | PF.jump,
    exclude_mask: u16 = 0,

    // --- Sliced pathfinding playback (incremental A* visualizer) -------------
    // Состояние пошагового проигрывания sliced findPath. Машина состояний:
    //   init ОДИН раз (Reset / recalc) -> update МНОГО (per-frame / по кнопке)
    //   -> finalize ОДИН раз (когда статус перестал быть in_progress).
    // НИКОГДА не re-init в середине поиска — только на Reset/recalc.
    slice_active: bool = false, // поиск инициализирован и ещё не «сброшен»
    slice_auto: bool = false, // авто-продвижение каждый кадр (Play)
    slice_iters: i32 = 1, // итераций за один «Advance 1»/кадр Play
    slice_big: i32 = 20, // итераций за «Advance N»
    slice_done_total: usize = 0, // суммарно выполнено A*-итераций
    slice_finished: bool = false, // поиск завершён (success/failure) + finalize сделан
    slice_status: dt.Status = .{}, // последний статус update/init (для status-строки)

    // --- Reachability heatmap (cluster A, A6) --------------------------------
    // When ON and start_ref != 0, flood from the start poly under the current
    // filter and overlay each reachable poly's accumulated cost as a green->red
    // gradient (unreachable = dim grey). The flood is O((V+E) log V) and RARE:
    // computed only when start/filter change (recalc), cached here, freed on
    // recompute + deinit. `heatmap` null = nothing computed yet (or no source).
    reach_on: bool = false,
    heatmap: ?reachability.Heatmap = null,

    // --- Funnel / portal debug overlay (cluster A, A3) -----------------------
    // When ON (straight/sliced/follow mode + corridor present) the render path
    // visualizes how string-pulling turns the polygon corridor into waypoints:
    //   - PORTALS: the shared edge (left/right) between each consecutive corridor
    //     pair, via getPortalPoints — drawn as a segment with left/right markers.
    //   - ALL-CROSSINGS waypoints (`funnel_pts`): findStraightPath re-run with
    //     DT_STRAIGHTPATH_ALL_CROSSINGS into a SEPARATE scratch (does NOT clobber
    //     self.straight) — a point at every portal crossing, joined by a polyline.
    //   - TURN/APEX points (`turn_pts`): findStraightPath re-run WITHOUT crossings
    //     into another scratch; its interior vertices are the genuine funnel apex
    //     (corner) points — highlighted with larger yellow markers.
    // All three scratches are recomputed ONLY in recalc (corridor change), never
    // per frame. See recomputeFunnel.
    funnel_on: bool = false,
    funnel_pts: [MAX_POLYS * 3]f32 = undefined, // ALL_CROSSINGS waypoint positions
    funnel_flags: [MAX_POLYS]u8 = undefined,
    funnel_refs: [MAX_POLYS]dt.PolyRef = undefined,
    nfunnel: usize = 0,
    turn_pts: [MAX_POLYS * 3]f32 = undefined, // no-crossings (turns-only) positions
    turn_flags: [MAX_POLYS]u8 = undefined,
    turn_refs: [MAX_POLYS]dt.PolyRef = undefined,
    nturn: usize = 0,

    // --- Side-by-side filter comparison (cluster A, A4) ----------------------
    // When ON (pathfind modes, both endpoints), run the SAME start/end route under
    // up to 3 user-configured QueryFilters (each = an include/exclude mask pair +
    // colour) and render each route in its colour with a legend (poly count + an
    // approximate total cost + reaches Y/N). Recomputed ONLY on recalc / Run — the
    // routes + results live in `compare`'s fixed scratch (no per-frame alloc).
    // See diag/filter_compare.zig for the cost approximation (centroid-distance,
    // reused from reachability.edgeWeight).
    compare: filter_compare.Compare = undefined,

    // --- Route-query benchmark (cluster C, C2) ------------------------------
    // "Run query bench" generates K random (start,end) pairs on the built navmesh,
    // times each findPath, and reports latency percentiles + success-rate + avg
    // visited-node count + a latency histogram. Runs ONLY on the button (K findPaths
    // is heavy) — never per frame. `bench_result` caches the last run for display;
    // null until a run. `bench_k`/`bench_seed` are reproducibility UI params;
    // `bench_use_filter` picks the tester's filter (else a neutral one).
    bench_result: ?query_bench.BenchResult = null,
    bench_k: f32 = 1000, // iterations (slider proxy, see drawBenchControls)
    bench_seed: f32 = 1, // PRNG seed (slider proxy)
    bench_use_filter: bool = true,

    pub fn init(alloc: std.mem.Allocator, dd_gl: *ddgl.DebugDrawGL) NavMeshTesterTool {
        var self = NavMeshTesterTool{ .alloc = alloc, .dd_gl = dd_gl, .filter = dt.QueryFilter.init() };
        self.applyFlags();
        area_types.applyCosts(&self.filter); // per-area movement cost from the registry
        self.compare = filter_compare.Compare.init();
        // Seed sensible defaults so the first toggle shows a meaningful diff:
        // F1 = current include/exclude, F2 = same but exclude swim (water-free).
        self.compare.variants[0].include = self.include_mask;
        self.compare.variants[0].exclude = self.exclude_mask;
        self.compare.variants[1].include = self.include_mask;
        self.compare.variants[1].exclude = self.exclude_mask | PF.swim;
        return self;
    }

    fn applyFlags(self: *NavMeshTesterTool) void {
        self.filter.setIncludeFlags(self.include_mask);
        self.filter.setExcludeFlags(self.exclude_mask);
    }

    pub fn deinit(self: *NavMeshTesterTool) void {
        if (self.query) |q| q.deinit();
        self.query = null;
        self.freeHeatmap();
    }

    /// Free the cached reachability heatmap (no-op if none). Called before each
    /// recompute and on deinit/navmesh-reload so the per-tile slices never leak.
    /// Освобождает кэш хитмапа (перед пересчётом / при deinit).
    fn freeHeatmap(self: *NavMeshTesterTool) void {
        if (self.heatmap) |*hm| hm.deinit();
        self.heatmap = null;
    }

    /// (Re)compute the reachability heatmap from the current start_ref under the
    /// current filter, if the overlay is on. Frees any previous heatmap first.
    /// Called from recalc (start/filter changed) and when the toggle flips on.
    /// On OOM/flood failure, leaves heatmap = null (overlay falls back to nothing).
    fn recomputeHeatmap(self: *NavMeshTesterTool) void {
        self.freeHeatmap();
        if (!self.reach_on) return;
        const nav = self.navmesh orelse return;
        if (self.start_ref == 0) return;
        self.heatmap = reachability.flood(nav, self.start_ref, &self.filter, self.alloc) catch null;
    }

    /// (Re)compute the funnel-overlay scratch buffers from the current corridor
    /// (self.polys[0..npolys]) + start/end. Called ONLY from recalc (corridor /
    /// endpoints changed) and when the toggle flips on — never per frame.
    /// Populates `funnel_pts` (ALL_CROSSINGS) and `turn_pts` (no-crossings turns).
    /// On failure / overlay-off leaves the counts at 0 (render skips).
    ///
    /// Пересчёт буферов оверлея воронки из текущего коридора. Только в recalc.
    fn recomputeFunnel(self: *NavMeshTesterTool) void {
        self.nfunnel = 0;
        self.nturn = 0;
        if (!self.funnel_on) return;
        const q = self.query orelse return;
        if (self.npolys == 0) return;
        const corr = self.polys[0..self.npolys];

        // ALL_CROSSINGS: waypoint at every portal crossing (full funnel trace).
        var nc: usize = 0;
        _ = q.findStraightPath(
            &self.spos,
            &self.epos,
            corr,
            self.funnel_pts[0..],
            self.funnel_flags[0..],
            self.funnel_refs[0..],
            &nc,
            funnel.OPT_ALL_CROSSINGS,
        ) catch {};
        self.nfunnel = nc;

        // No-crossings: only the funnel turns (apex corners) + start/end.
        var nt: usize = 0;
        _ = q.findStraightPath(
            &self.spos,
            &self.epos,
            corr,
            self.turn_pts[0..],
            self.turn_flags[0..],
            self.turn_refs[0..],
            &nt,
            0,
        ) catch {};
        self.nturn = nt;
    }

    /// (Re)run the side-by-side filter comparison (A4) from the current start/end
    /// under each enabled variant. Called ONLY from recalc (endpoints / filter
    /// changed) and the "Run comparison" button — never per frame. No-op (clears
    /// results) when the overlay is off or only meaningful in pathfind modes.
    ///
    /// Пересчёт сравнения фильтров. Только в recalc / по кнопке, не покадрово.
    fn recomputeCompare(self: *NavMeshTesterTool) void {
        if (!self.compare.on) {
            for (&self.compare.results) |*r| r.* = .{};
            return;
        }
        // Only the pathfind modes produce a start/end route to compare.
        if (self.mode != .pathfind_follow and self.mode != .pathfind_straight and self.mode != .pathfind_sliced) {
            for (&self.compare.results) |*r| r.* = .{};
            return;
        }
        const q = self.query orelse return;
        const nav = self.navmesh orelse return;
        self.compare.run(q, nav, self.start_ref, self.end_ref, &self.spos, &self.epos, &self.filter);
    }

    pub fn setNavMesh(self: *NavMeshTesterTool, nm: ?*dt.NavMesh) void {
        if (self.query) |q| {
            q.deinit();
            self.query = null;
        }
        self.navmesh = nm;
        self.npolys = 0;
        self.nstraight = 0;
        self.nfunnel = 0;
        self.nturn = 0;
        self.spos_set = false;
        self.epos_set = false;
        for (&self.compare.results) |*r| r.* = .{}; // stale routes can't apply to a new mesh
        self.bench_result = null; // stale bench can't apply to a new mesh
        self.freeHeatmap(); // stale heatmap can't apply to a new mesh
        // Reset the sliced-search player so a stale slice can't tick against the new
        // (freshly-initialised, never-sliced) query after a navmesh reload.
        self.slice_active = false;
        self.slice_auto = false;
        self.slice_finished = false;
        self.slice_done_total = 0;
        self.slice_status = .{};
        if (nm) |m| {
            var q = dt.NavMeshQuery.init(self.alloc) catch return;
            q.initQuery(m, 2048) catch {
                q.deinit();
                return;
            };
            self.query = q;
        }
    }

    pub fn onClick(self: *NavMeshTesterTool, _: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        // LMB = start, Shift+LMB = end (intuitive default-click-sets-start). NOTE:
        // this is swapped from upstream RecastDemo (Shift = start there).
        if (shift) {
            self.epos = ray_hit.*;
            self.epos_set = true;
        } else {
            self.spos = ray_hit.*;
            self.spos_set = true;
        }
        self.recalc();
    }

    fn recalc(self: *NavMeshTesterTool) void {
        const q = self.query orelse return;
        const ext = [3]f32{ 2, 4, 2 };
        self.npolys = 0;
        self.nstraight = 0;
        self.nsmooth = 0;
        self.ray_has = false;
        self.shape_nverts = 0;
        self.verdict_valid = false;

        if (self.spos_set) {
            var snapped: [3]f32 = undefined;
            _ = q.findNearestPoly(&self.spos, &ext, &self.filter, &self.start_ref, &snapped) catch {};
        }
        if (self.epos_set) {
            var snapped: [3]f32 = undefined;
            _ = q.findNearestPoly(&self.epos, &ext, &self.filter, &self.end_ref, &snapped) catch {};
        }

        const have_both = self.spos_set and self.epos_set and self.start_ref != 0 and self.end_ref != 0;
        switch (self.mode) {
            .pathfind_follow => {
                if (have_both) {
                    var n: usize = 0;
                    _ = q.findPath(self.start_ref, self.end_ref, &self.spos, &self.epos, &self.filter, self.polys[0..], &n) catch {};
                    self.npolys = n;
                    self.nsmooth = 0;
                    if (n > 0) {
                        // Сглаженный путь по поверхности (как оригинал FOLLOW): много точек
                        // -> при отрисовке line-list даёт «пунктирный» след. Пишем в отдельный
                        // буфер smooth (2048), НЕ в straight (256) — иначе путь обрывается.
                        self.nsmooth = smoothPath(q, self.start_ref, &self.spos, &self.epos, &self.filter, self.polys[0..n], self.smooth[0..]);
                    }
                }
            },
            .pathfind_straight => {
                if (have_both) {
                    var n: usize = 0;
                    _ = q.findPath(self.start_ref, self.end_ref, &self.spos, &self.epos, &self.filter, self.polys[0..], &n) catch {};
                    self.npolys = n;
                    if (n > 0) {
                        var ns: usize = 0;
                        _ = q.findStraightPath(&self.spos, &self.epos, self.polys[0..n], self.straight[0..], self.straight_flags[0..], self.straight_refs[0..], &ns, 0) catch {};
                        self.nstraight = ns;
                    }
                }
            },
            .pathfind_sliced => {
                // Incremental visualizer: init ONCE here (recalc fires on click /
                // flag change / mode switch). We do NOT loop the update — the
                // search is advanced per-frame (Play) or by the Advance buttons.
                // Reset re-enters this path via recalc(). See startSlice/tickSlice.
                self.startSlice(q, have_both);
            },
            .raycast => {
                if (self.spos_set and self.epos_set and self.start_ref != 0) {
                    var hit = dt.RaycastHit.init(self.polys[0..]);
                    _ = q.raycast(self.start_ref, &self.spos, &self.epos, &self.filter, 0, &hit, 0) catch {};
                    self.ray_t = hit.t;
                    self.ray_has = true;
                    self.npolys = hit.path_count;
                }
            },
            .distance_to_wall => {
                if (self.spos_set and self.start_ref != 0) {
                    self.wall_dist = 0;
                    _ = q.findDistanceToWall(self.start_ref, &self.spos, 100.0, &self.filter, &self.wall_dist, &self.wall_pos, &self.wall_normal) catch {};
                }
            },
            .find_polys_circle => {
                if (have_both) {
                    self.query_radius = dist2d(self.spos, self.epos);
                    var n: usize = 0;
                    _ = q.findPolysAroundCircle(self.start_ref, &self.spos, self.query_radius, &self.filter, self.polys[0..], self.parent[0..], null, &n) catch {};
                    self.npolys = n;
                }
            },
            .find_polys_shape => {
                if (have_both) {
                    self.buildShape();
                    var n: usize = 0;
                    _ = q.findPolysAroundShape(self.start_ref, self.shape_verts[0 .. self.shape_nverts * 3], self.shape_nverts, &self.filter, self.polys[0..], self.parent[0..], null, &n) catch {};
                    self.npolys = n;
                }
            },
            .find_local_neighbourhood => {
                if (self.spos_set and self.start_ref != 0) {
                    // upstream: m_neighbourhoodRadius = agentRadius * 20. При 2.5 в радиус
                    // попадал только старт-поли (npolys=1) → выглядело пусто.
                    self.query_radius = self.agent_radius * 20.0;
                    var n: usize = 0;
                    _ = q.findLocalNeighbourhood(self.start_ref, &self.spos, self.query_radius, &self.filter, self.polys[0..], self.parent[0..], &n) catch {};
                    self.npolys = n;
                }
            },
        }

        // WHY-NO-PATH verdict (A1): only for the three pathfind modes, when both
        // endpoints are placed (refs may still be 0 -> invalid_start/end verdict).
        switch (self.mode) {
            .pathfind_follow, .pathfind_straight, .pathfind_sliced => self.runDiagnosis(q),
            else => {},
        }

        // Reachability heatmap (A6): recompute only here — recalc fires exactly on
        // the inputs that change the flood (start point click / filter flag edit /
        // mode switch). Result is cached on the tool; render() only reads it.
        self.recomputeHeatmap();

        // Funnel/portal overlay (A3): recompute scratch from the just-built
        // corridor. recalc fires exactly on corridor change (click / flag / mode),
        // so this is the only place the funnel buffers are (re)built — never per
        // frame. render() only reads them.
        self.recomputeFunnel();

        // Side-by-side filter comparison (A4): re-run the route under each enabled
        // variant from the just-updated start/end. recalc fires exactly on the
        // inputs that change the routes (click / flag / mode), so this is the only
        // recompute site — never per frame. render() only reads the cached routes.
        self.recomputeCompare();
    }

    /// Запускает живую диагностику why-no-path и сохраняет вердикт на инструменте.
    /// Components считаются on-demand из nav (O(polys+links)); дёшево для редких recalc.
    /// Runs the live why-no-path diagnosis and stores the verdict on the tool.
    fn runDiagnosis(self: *NavMeshTesterTool, q: *dt.NavMeshQuery) void {
        if (!self.spos_set or !self.epos_set) return;
        const nav = self.navmesh orelse return;

        // Topological connectivity (filter-agnostic flood-fill). Compute fresh;
        // if it fails (OOM), fall back to neutral-reach=false (real-gap bias) by
        // passing an empty Components — componentForRef then returns null.
        var comps = components.compute(nav, self.alloc) catch components.Components{ .alloc = self.alloc };
        defer comps.deinit();

        const res = diagnose.diagnose(
            self.alloc,
            q,
            nav,
            &comps,
            self.start_ref,
            self.end_ref,
            self.spos,
            self.epos,
            &self.filter,
            self.diag_scratch[0..],
        );
        self.verdict = res.verdict;
        self.signals = res.signals;
        self.verdict_valid = true;
    }

    // ===== Sliced pathfinding playback (incremental A* visualizer) ==========

    /// (Re)initialise the sliced search from the current start/end/filter — the
    /// "init ONCE" half of the state machine. Called from recalc (.pathfind_sliced)
    /// and from the Reset button. Resets all playback counters; leaves the search
    /// in_progress so per-frame/button updates can advance it.
    ///
    /// (Пере)инициализация sliced-поиска. «init ОДИН раз». Сбрасывает счётчики.
    fn startSlice(self: *NavMeshTesterTool, q: *dt.NavMeshQuery, have_both: bool) void {
        self.npolys = 0;
        self.nstraight = 0;
        self.slice_active = false;
        self.slice_finished = false;
        self.slice_done_total = 0;
        self.slice_status = .{};
        if (!have_both) return;
        self.slice_status = q.initSlicedFindPath(self.start_ref, self.end_ref, &self.spos, &self.epos, &self.filter, 0);
        self.slice_active = true;
        // start==end (or immediate failure) — no in-progress search to play.
        if (!self.slice_status.in_progress) self.finishSlice(q);
    }

    /// Advance the sliced search by `iters` A* iterations (one update call —
    /// NEVER re-init mid-search). Accumulates done_total and finalizes once the
    /// status leaves in_progress. The "update MANY / finalize ONCE" half.
    ///
    /// Продвинуть поиск на `iters` итераций (один update). finalize по завершении.
    fn advanceSlice(self: *NavMeshTesterTool, q: *dt.NavMeshQuery, iters: i32) void {
        if (!self.slice_active or self.slice_finished) return;
        var done: u32 = 0;
        const n: u32 = @intCast(@max(iters, 1));
        self.slice_status = q.updateSlicedFindPath(n, &done);
        self.slice_done_total += done;
        if (!self.slice_status.in_progress) self.finishSlice(q);
    }

    /// Read out the final route (finalizeSlicedFindPath ONCE) into self.polys and
    /// build the straight path for rendering. Clears auto-play. Idempotent-ish:
    /// only meaningful once per search (guarded by slice_finished at call sites).
    ///
    /// Считать итоговый маршрут (finalize ОДИН раз) и построить straight-путь.
    fn finishSlice(self: *NavMeshTesterTool, q: *dt.NavMeshQuery) void {
        self.slice_finished = true;
        self.slice_auto = false;
        var n: usize = 0;
        _ = q.finalizeSlicedFindPath(self.polys[0..], &n);
        self.npolys = n;
        self.nstraight = 0;
        if (n > 0) {
            var ns: usize = 0;
            _ = q.findStraightPath(&self.spos, &self.epos, self.polys[0..n], self.straight[0..], self.straight_flags[0..], self.straight_refs[0..], &ns, 0) catch {};
            self.nstraight = ns;
        }
    }

    /// Per-frame tick: when Play is on and a search is live, advance exactly ONE
    /// update of slice_iters. Called once per frame from render(). Never re-inits.
    ///
    /// Покадровый тик: при Play продвигает поиск ровно на один update за кадр.
    fn tickSlice(self: *NavMeshTesterTool) void {
        if (self.mode != .pathfind_sliced) return;
        if (!self.slice_auto or !self.slice_active or self.slice_finished) return;
        const q = self.query orelse return;
        self.advanceSlice(q, self.slice_iters);
    }

    /// "Finish" button: loop updates to completion then finalize (the old
    /// non-incremental behaviour — whole route at once). Preserves no-regression.
    fn finishSliceNow(self: *NavMeshTesterTool) void {
        const q = self.query orelse return;
        if (!self.slice_active) return;
        var guard: u32 = 0;
        while (!self.slice_finished and guard < 100000) : (guard += 1) {
            self.advanceSlice(q, self.slice_big);
        }
    }

    /// Visualise the in-progress A* search read straight from the NodePool:
    ///   - visited (closed) nodes  -> dim blue dots
    ///   - frontier (open) nodes   -> bright green dots
    ///   - current best node       -> yellow ring (m_query.last_best_node)
    ///   - best partial corridor   -> line traced via pidx from best back to start
    /// Only meaningful while slice_active. Numeric g/h/f labels are drawn separately
    /// in main.zig (needs cam/worldToScreen) — see drawSearchLabels.
    ///
    /// Рисует состояние поиска прямо из NodePool: visited(closed)/frontier(open)/
    /// текущий лучший узел + частичный коридор (по pidx). Числа g/h/f — в main.zig.
    fn drawSearchState(self: *NavMeshTesterTool, dd: dbg.DebugDraw) void {
        const q = self.query orelse return;
        const pool = q.getNodePool() orelse return;
        const count = pool.getNodeCount();
        if (count == 0) return;

        const visited_col = dbg.rgba(64, 96, 200, 220); // dim blue — closed list
        const frontier_col = dbg.rgba(64, 255, 96, 255); // bright green — open list

        dd.depthMask(false);
        // visited/frontier markers (raise dots slightly so they sit above the mesh).
        dd.begin(.points, 5.0);
        for (0..count) |i| {
            const node = &pool.nodes[i];
            const col = if (node.flags.closed) visited_col else if (node.flags.open) frontier_col else continue;
            dd.vertexXYZ(node.pos[0], node.pos[1] + 0.15, node.pos[2], col);
        }
        dd.end();

        // Best partial corridor: follow pidx from the current best node to start.
        if (q.query.last_best_node) |best| {
            const corr_col = dbg.rgba(255, 200, 0, 220);
            dd.begin(.lines, 2.0);
            var node: ?*const dt.Node = best;
            var guard: usize = 0;
            while (node) |n| : (guard += 1) {
                if (guard >= count) break; // pidx-loop guard (defensive: at most `count` hops)
                // pidx is a 1-based index into the pool's [1..node_count]; a 0 pidx is
                // the root (stop), and an out-of-range pidx (shouldn't happen) would
                // read an uninitialised slot — bound it here since the core getter
                // (faithful src/*) has no upper check and we must not edit it.
                if (n.pidx == 0 or n.pidx > count) break;
                const parent = pool.getNodeAtIdxConst(n.pidx) orelse break;
                dd.vertexXYZ(n.pos[0], n.pos[1] + 0.2, n.pos[2], corr_col);
                dd.vertexXYZ(parent.pos[0], parent.pos[1] + 0.2, parent.pos[2], corr_col);
                node = parent;
            }
            dd.end();

            // current best node — yellow ring.
            drawCircle(dd, .{ best.pos[0], best.pos[1] + 0.2, best.pos[2] }, 0.6, dbg.rgba(255, 255, 0, 255));
        }
        dd.depthMask(true);
    }

    /// Draw g/h/f numeric labels over search nodes (called from main.zig, which
    /// owns cam/viewport for worldToScreen). Density-capped: only when the node
    /// count is small enough to stay readable (<= MAX_LABEL_NODES). `emit` is a
    /// closure-like callback (world pos + text) so this stays GL/UI-free here.
    ///
    /// Numbers culled by the caller via sp.z∈[0,1]. h = total - cost (f - g).
    pub const MAX_LABEL_NODES: usize = 150;

    /// Iterate visited+frontier nodes for label drawing. Returns false (skip) when
    /// over the density cap. Caller passes a context + fn(ctx, pos, text).
    pub fn forEachSearchLabel(
        self: *NavMeshTesterTool,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), pos: [3]f32, text: []const u8) void,
    ) void {
        if (self.mode != .pathfind_sliced or !self.slice_active) return;
        const q = self.query orelse return;
        const pool = q.getNodePool() orelse return;
        const count = pool.getNodeCount();
        if (count == 0 or count > MAX_LABEL_NODES) return; // density cap

        var buf: [48]u8 = undefined;
        for (0..count) |i| {
            const node = &pool.nodes[i];
            if (!node.flags.closed and !node.flags.open) continue;
            const g = node.cost;
            const f = node.total;
            const h = f - g; // heuristic = f - g (caller convention)
            const txt = astar_player.formatNodeLabel(&buf, g, h, f);
            if (txt.len == 0) continue;
            emit(ctx, .{ node.pos[0], node.pos[1] + 0.3, node.pos[2] }, txt);
        }
    }

    // ===== Funnel / portal debug overlay (A3) ================================

    pub const MAX_FUNNEL_LABELS: usize = 80; // density cap for portal/waypoint labels

    /// Draw the funnel overlay: corridor portals (left/right segments via the
    /// precomputed corridor), the ALL_CROSSINGS waypoint polyline + markers, and
    /// the no-crossings turn/apex highlights. Reads ONLY precomputed scratch — no
    /// queries here. Gated by the caller on funnel_on + straight/follow/sliced mode.
    ///
    /// Рисует портали коридора (left/right), полилинию ALL_CROSSINGS-вейпойнтов и
    /// подсветку поворотов (apex). Только чтение готовых буферов, без запросов.
    fn drawFunnel(self: *NavMeshTesterTool, dd: dbg.DebugDraw) void {
        const q = self.query orelse return;
        if (self.npolys == 0) return;

        const left_col = dbg.rgba(255, 96, 96, 220); // portal LEFT endpoint — red
        const right_col = dbg.rgba(96, 160, 255, 220); // portal RIGHT endpoint — blue
        const portal_col = dbg.rgba(200, 200, 200, 160); // portal segment — grey
        const cross_col = dbg.rgba(0, 200, 200, 230); // ALL_CROSSINGS polyline — cyan
        const apex_col = dbg.rgba(255, 255, 0, 255); // turn/apex — yellow

        dd.depthMask(false);

        // 1) PORTALS: shared edge between each consecutive corridor pair.
        dd.begin(.lines, 2.0);
        for (0..self.npolys -| 1) |i| {
            var left: [3]f32 = undefined;
            var right: [3]f32 = undefined;
            var ft: u8 = 0;
            var tt: u8 = 0;
            q.getPortalPoints(self.polys[i], self.polys[i + 1], &left, &right, &ft, &tt) catch continue;
            // portal segment (grey) + colored left/right end nubs (short verticals).
            dd.vertexXYZ(left[0], left[1] + 0.3, left[2], portal_col);
            dd.vertexXYZ(right[0], right[1] + 0.3, right[2], portal_col);
            dd.vertexXYZ(left[0], left[1] + 0.3, left[2], left_col);
            dd.vertexXYZ(left[0], left[1] + 0.9, left[2], left_col);
            dd.vertexXYZ(right[0], right[1] + 0.3, right[2], right_col);
            dd.vertexXYZ(right[0], right[1] + 0.9, right[2], right_col);
        }
        dd.end();
        // left/right endpoint markers (points).
        dd.begin(.points, 6.0);
        for (0..self.npolys -| 1) |i| {
            var left: [3]f32 = undefined;
            var right: [3]f32 = undefined;
            var ft: u8 = 0;
            var tt: u8 = 0;
            q.getPortalPoints(self.polys[i], self.polys[i + 1], &left, &right, &ft, &tt) catch continue;
            dd.vertexXYZ(left[0], left[1] + 0.3, left[2], left_col);
            dd.vertexXYZ(right[0], right[1] + 0.3, right[2], right_col);
        }
        dd.end();

        // 2) ALL_CROSSINGS waypoints: polyline + markers (distinct from the normal
        //    straight-path render, drawn higher in cyan).
        if (self.nfunnel > 1) {
            dd.begin(.lines, 2.0);
            var i: usize = 0;
            while (i + 1 < self.nfunnel) : (i += 1) {
                dd.vertexXYZ(self.funnel_pts[i * 3], self.funnel_pts[i * 3 + 1] + 0.6, self.funnel_pts[i * 3 + 2], cross_col);
                dd.vertexXYZ(self.funnel_pts[(i + 1) * 3], self.funnel_pts[(i + 1) * 3 + 1] + 0.6, self.funnel_pts[(i + 1) * 3 + 2], cross_col);
            }
            dd.end();
        }
        if (self.nfunnel > 0) {
            dd.begin(.points, 5.0);
            for (0..self.nfunnel) |k| {
                const f = self.funnel_flags[k];
                const col = if (funnel.isStart(f)) startCol else if (funnel.isEnd(f)) endCol else cross_col;
                dd.vertexXYZ(self.funnel_pts[k * 3], self.funnel_pts[k * 3 + 1] + 0.6, self.funnel_pts[k * 3 + 2], col);
            }
            dd.end();
        }

        // 3) TURN / APEX points: interior vertices of the no-crossings straight
        //    path are genuine funnel corners — big yellow markers.
        if (self.nturn > 0) {
            dd.begin(.points, 9.0);
            for (0..self.nturn) |k| {
                if (!funnel.isTurn(self.turn_flags[k])) continue; // skip start/end/offmesh
                dd.vertexXYZ(self.turn_pts[k * 3], self.turn_pts[k * 3 + 1] + 0.7, self.turn_pts[k * 3 + 2], apex_col);
            }
            dd.end();
        }

        dd.depthMask(true);
    }

    // ===== Side-by-side filter comparison (A4) ==============================

    /// Draw each enabled variant's cached route as a coloured polyline joining the
    /// route's poly centroids, raised +0.4 + 0.12*i in Y per variant so overlapping
    /// corridors don't perfectly z-fight. Highlights the per-variant route polys in
    /// the variant colour too (faint). Reads ONLY cached routes (recomputed in
    /// recalc) — no queries here. Legend is panel text (drawCompareLegend).
    ///
    /// Рисует маршрут каждого варианта своим цветом (со смещением по Y).
    fn drawCompare(self: *NavMeshTesterTool, dd: dbg.DebugDraw) void {
        const nm = self.navmesh orelse return;
        dd.depthMask(false);
        for (&self.compare.variants, 0..) |*v, i| {
            if (!v.enabled or !self.compare.results[i].valid) continue;
            const r = self.compare.route(i);
            if (r.len < 1) continue;
            const yoff: f32 = 0.4 + 0.12 * @as(f32, @floatFromInt(i));
            // faint poly fill in the variant colour (alpha already baked into v.color;
            // re-tint lighter for the fill so it reads as "this filter's corridor").
            const fill = (v.color & 0x00ffffff) | (@as(u32, 56) << 24);
            for (r) |ref| dbg.debugDrawNavMeshPoly(dd, nm, ref, fill);
            // polyline through centroids.
            if (r.len > 1) {
                dd.begin(.lines, 3.0);
                var k: usize = 1;
                while (k < r.len) : (k += 1) {
                    const a = self.getPolyCenter(r[k - 1]);
                    const b = self.getPolyCenter(r[k]);
                    dd.vertexXYZ(a[0], a[1] + yoff, a[2], v.color);
                    dd.vertexXYZ(b[0], b[1] + yoff, b[2], v.color);
                }
                dd.end();
            }
        }
        dd.depthMask(true);
    }

    /// Iterate funnel labels for the worldspace-label pass (drawn in main.zig,
    /// which owns cam/worldToScreen). Emits "P{i}" at each portal midpoint and
    /// "W{k}" at each ALL_CROSSINGS waypoint. Density-capped: skips entirely when
    /// the total would exceed MAX_FUNNEL_LABELS. Caller passes ctx + fn(ctx,pos,txt).
    ///
    /// Подписи воронки (P{i} на середине портала, W{k} на вейпойнте) — рисуются в
    /// main.zig. С ограничением плотности (MAX_FUNNEL_LABELS).
    pub fn forEachFunnelLabel(
        self: *NavMeshTesterTool,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), pos: [3]f32, text: []const u8) void,
    ) void {
        if (!self.funnel_on) return;
        if (self.mode != .pathfind_straight and self.mode != .pathfind_sliced and self.mode != .pathfind_follow) return;
        if (self.npolys == 0) return;
        const q = self.query orelse return;
        const nportals = self.npolys -| 1;
        if (nportals + self.nfunnel > MAX_FUNNEL_LABELS) return; // density cap

        var buf: [24]u8 = undefined;
        // P{i} at portal midpoints.
        for (0..nportals) |i| {
            var left: [3]f32 = undefined;
            var right: [3]f32 = undefined;
            var ft: u8 = 0;
            var tt: u8 = 0;
            q.getPortalPoints(self.polys[i], self.polys[i + 1], &left, &right, &ft, &tt) catch continue;
            const mid = funnel.portalMid(left, right);
            const txt = std.fmt.bufPrint(&buf, "P{d}", .{i}) catch continue;
            emit(ctx, .{ mid[0], mid[1] + 0.5, mid[2] }, txt);
        }
        // W{k} at ALL_CROSSINGS waypoints.
        for (0..self.nfunnel) |k| {
            const txt = std.fmt.bufPrint(&buf, "W{d}", .{k}) catch continue;
            emit(ctx, .{ self.funnel_pts[k * 3], self.funnel_pts[k * 3 + 1] + 0.8, self.funnel_pts[k * 3 + 2] }, txt);
        }
    }

    /// Box-полигон вокруг отрезка spos->epos (1-в-1 m_queryPoly в Tool_NavMeshTester).
    /// ВАЖНО: знак перпендикуляра (nx,nz) задаёт winding фигуры. intersectSegmentPoly2D
    /// рассчитан именно на upstream-winding — обратный знак ломает расширение (npolys=1).
    fn buildShape(self: *NavMeshTesterTool) void {
        const nx = (self.epos[2] - self.spos[2]) * 0.25;
        const nz = -(self.epos[0] - self.spos[0]) * 0.25;
        const ah2 = self.agent_height * 0.5;
        const v = &self.shape_verts;
        v[0] = self.spos[0] + nx * 1.2;
        v[1] = self.spos[1] + ah2;
        v[2] = self.spos[2] + nz * 1.2;
        v[3] = self.spos[0] - nx * 1.3;
        v[4] = self.spos[1] + ah2;
        v[5] = self.spos[2] - nz * 1.3;
        v[6] = self.epos[0] - nx * 0.8;
        v[7] = self.epos[1] + ah2;
        v[8] = self.epos[2] - nz * 0.8;
        v[9] = self.epos[0] + nx;
        v[10] = self.epos[1] + ah2;
        v[11] = self.epos[2] + nz;
        self.shape_nverts = 4;
    }

    pub fn render(self: *NavMeshTesterTool) void {
        // Per-frame incremental tick (Play): advance the live sliced search ONCE.
        self.tickSlice();

        const dd = self.dd_gl.debugDraw();

        // Reachability heatmap (A6): overlay the cost gradient FIRST (under the
        // start/end/path highlights, which stay readable on top). Cached — drawn
        // only; no per-frame flood.
        if (self.reach_on) {
            if (self.heatmap) |*hm| {
                if (self.navmesh) |nm| poly_visit.fillNavMeshHeatmap(dd, nm, hm);
            }
        }

        // подсветка полигонов результата: start/end/path разными цветами (как оригинал)
        if (self.navmesh) |nm| {
            // start/end подсвечиваются безусловно, в цикле пути — пропускаются (как upstream).
            if (self.start_ref != 0) dbg.debugDrawNavMeshPoly(dd, nm, self.start_ref, startCol);
            if (self.end_ref != 0) dbg.debugDrawNavMeshPoly(dd, nm, self.end_ref, endCol);
            for (0..self.npolys) |i| {
                const r = self.polys[i];
                if (r == self.start_ref or r == self.end_ref) continue;
                dbg.debugDrawNavMeshPoly(dd, nm, r, pathCol);
            }
        }

        // WHY-NO-PATH culprit highlight (A1, best-effort): for invalid start/end
        // draw the findNearestPoly search half-extents (ext={2,4,2}) as a circle at
        // the offending endpoint — shows "the snap radius found no polygon here".
        if (self.verdict_valid) {
            const warn = dbg.rgba(255, 64, 64, 255);
            if (self.verdict == .invalid_start and self.spos_set)
                drawCircle(dd, self.spos, 2.0, warn);
            if (self.verdict == .invalid_end and self.epos_set)
                drawCircle(dd, self.epos, 2.0, warn);
        }

        // Старт/энд — wire-цилиндр агента (как upstream drawAgent), под depthMask(false).
        dd.depthMask(false);
        if (self.spos_set) self.drawAgent(dd, self.spos, startCol);
        if (self.epos_set) self.drawAgent(dd, self.epos, endCol);
        dd.depthMask(true);

        // Funnel/portal overlay (A3): portals + ALL_CROSSINGS waypoints + apex.
        // Reads precomputed scratch only (recomputed in recalc, not per frame).
        if (self.funnel_on and self.npolys > 0 and
            (self.mode == .pathfind_straight or self.mode == .pathfind_sliced or self.mode == .pathfind_follow))
            self.drawFunnel(dd);

        // Side-by-side filter comparison (A4): each enabled variant's route as a
        // coloured polyline (offset +Y per variant to avoid z-fight). Reads only
        // the cached routes (recomputed in recalc). The legend is panel text.
        if (self.compare.on and
            (self.mode == .pathfind_straight or self.mode == .pathfind_sliced or self.mode == .pathfind_follow))
            self.drawCompare(dd);

        switch (self.mode) {
            .pathfind_follow => {
                // follow: сглаженный путь. upstream эмитит точки ПОСЛЕДОВАТЕЛЬНО в DU_DRAW_LINES,
                // который парует их (0-1),(2-3),(4-5)… пропуская (1-2),(3-4) → отсюда «пунктир».
                // Эмитим по одной вершине на точку (НЕ парами i,i+1) — иначе линия сплошная.
                if (self.nsmooth > 1) {
                    const line_col = dbg.rgba(0, 0, 0, 220);
                    dd.depthMask(false);
                    dd.begin(.lines, 3.0);
                    for (0..self.nsmooth) |k| {
                        dd.vertexXYZ(self.smooth[k * 3], self.smooth[k * 3 + 1] + 0.1, self.smooth[k * 3 + 2], line_col);
                    }
                    dd.end();
                    dd.depthMask(true);
                }
            },
            .pathfind_straight, .pathfind_sliced => {
                // In-progress A* search state (sliced only): visited/frontier dots,
                // current best ring + partial corridor traced via pidx.
                if (self.mode == .pathfind_sliced and self.slice_active)
                    self.drawSearchState(dd);
                if (self.nstraight > 1) {
                    const line_col = dbg.rgba(64, 16, 0, 220);
                    dd.depthMask(false);
                    dd.begin(.lines, 2.0);
                    var i: usize = 0;
                    while (i + 1 < self.nstraight) : (i += 1) {
                        dd.vertexXYZ(self.straight[i * 3], self.straight[i * 3 + 1] + 0.4, self.straight[i * 3 + 2], line_col);
                        dd.vertexXYZ(self.straight[(i + 1) * 3], self.straight[(i + 1) * 3 + 1] + 0.4, self.straight[(i + 1) * 3 + 2], line_col);
                    }
                    dd.end();
                    // углы straight-path: цвет по флагу (START/END/OFFMESH/корнер) — как upstream.
                    dd.begin(.points, 6.0);
                    for (0..self.nstraight) |k| {
                        const f = self.straight_flags[k];
                        const col = if ((f & 0x01) != 0) startCol // DT_STRAIGHTPATH_START
                        else if ((f & SP_END) != 0) endCol
                        else if ((f & SP_OFFMESH) != 0) dbg.rgba(128, 96, 0, 220)
                        else line_col;
                        dd.vertexXYZ(self.straight[k * 3], self.straight[k * 3 + 1] + 0.4, self.straight[k * 3 + 2], col);
                    }
                    dd.end();
                    dd.depthMask(true);
                }
            },
            .raycast => {
                if (self.ray_has and self.spos_set and self.epos_set) {
                    const t = @min(self.ray_t, 1.0);
                    const hx = self.spos[0] + (self.epos[0] - self.spos[0]) * t;
                    const hy = self.spos[1] + (self.epos[1] - self.spos[1]) * t;
                    const hz = self.spos[2] + (self.epos[2] - self.spos[2]) * t;
                    const col = if (self.ray_t > 1.0) dbg.rgba(64, 255, 64, 255) else dbg.rgba(255, 64, 64, 255);
                    dd.begin(.lines, 1.0);
                    dd.vertexXYZ(self.spos[0], self.spos[1] + 0.1, self.spos[2], col);
                    dd.vertexXYZ(hx, hy + 0.1, hz, col);
                    dd.end();
                }
            },
            .distance_to_wall => {
                if (self.spos_set and self.start_ref != 0) {
                    drawCircle(dd, self.spos, self.wall_dist, dbg.rgba(64, 160, 255, 255));
                    // нормаль до ближайшей стены
                    const col = dbg.rgba(255, 64, 64, 255);
                    dd.begin(.lines, 1.0);
                    dd.vertexXYZ(self.wall_pos[0], self.wall_pos[1] + 0.02, self.wall_pos[2], col);
                    dd.vertexXYZ(self.wall_pos[0], self.wall_pos[1] + 3.0, self.wall_pos[2], col);
                    dd.end();
                }
            },
            .find_polys_circle => {
                self.drawParentArcs(dd);
                if (self.spos_set and self.start_ref != 0)
                    drawCircle(dd, self.spos, self.query_radius, dbg.rgba(64, 160, 255, 255));
            },
            .find_polys_shape => {
                self.drawParentArcs(dd);
                if (self.shape_nverts >= 3) {
                    const col = dbg.rgba(64, 160, 255, 220);
                    dd.begin(.lines, 1.0);
                    for (0..self.shape_nverts) |i| {
                        const j = (i + 1) % self.shape_nverts;
                        dd.vertexXYZ(self.shape_verts[i * 3], self.shape_verts[i * 3 + 1], self.shape_verts[i * 3 + 2], col);
                        dd.vertexXYZ(self.shape_verts[j * 3], self.shape_verts[j * 3 + 1], self.shape_verts[j * 3 + 2], col);
                    }
                    dd.end();
                }
            },
            .find_local_neighbourhood => {
                self.drawParentArcs(dd);
                if (self.spos_set and self.start_ref != 0)
                    drawCircle(dd, self.spos, self.query_radius, dbg.rgba(64, 160, 255, 255));
            },
        }
    }

    /// Центр полигона (среднее его вершин) — порт getPolyCenter из Tool_NavMeshTester.
    fn getPolyCenter(self: *NavMeshTesterTool, ref: dt.PolyRef) [3]f32 {
        var c = [3]f32{ 0, 0, 0 };
        const nm = self.navmesh orelse return c;
        const r = nm.getTileAndPolyByRef(ref) catch return c;
        const nv = r.poly.vert_count;
        if (nv == 0) return c;
        for (0..nv) |i| {
            const vi = @as(usize, r.poly.verts[i]) * 3;
            c[0] += r.tile.verts[vi];
            c[1] += r.tile.verts[vi + 1];
            c[2] += r.tile.verts[vi + 2];
        }
        const s = 1.0 / @as(f32, @floatFromInt(nv));
        c[0] *= s;
        c[1] *= s;
        c[2] *= s;
        return c;
    }

    /// Дуги-стрелки дерева поиска: от центра каждого найденного поли к центру родителя
    /// (parent[]). Это характерная визуализация find-режимов в оригинале (duAppendArc).
    fn drawParentArcs(self: *NavMeshTesterTool, dd: dbg.DebugDraw) void {
        if (self.npolys == 0) return;
        const col = dbg.rgba(0, 0, 0, 128);
        dd.depthMask(false);
        dd.begin(.lines, 2.0);
        for (0..self.npolys) |i| {
            if (self.parent[i] == 0) continue;
            const p0 = self.getPolyCenter(self.polys[i]);
            const p1 = self.getPolyCenter(self.parent[i]);
            // as1=0.4 — наконечник стрелки на конце (у родителя), h=0.25 — высота дуги.
            dbg.appendArc(dd, p0[0], p0[1], p0[2], p1[0], p1[1], p1[2], 0.25, 0.0, 0.4, col);
        }
        dd.end();
        dd.depthMask(true);
    }

    /// Синхронизация размеров агента из sample.settings (для drawAgent-цилиндра).
    pub fn setAgent(self: *NavMeshTesterTool, radius: f32, height: f32, climb: f32) void {
        self.agent_radius = radius;
        self.agent_height = height;
        self.agent_climb = climb;
    }

    /// Порт NavMeshTesterTool::drawAgent — wire-цилиндр агента + круг на climb + крест.
    /// Вызывать под dd.depthMask(false).
    fn drawAgent(self: *NavMeshTesterTool, dd: dbg.DebugDraw, pos: [3]f32, col: u32) void {
        const r = self.agent_radius;
        const h = self.agent_height;
        const c = self.agent_climb;
        const NUM_SEG = 16;
        var dir: [NUM_SEG * 2]f32 = undefined;
        for (0..NUM_SEG) |i| {
            const a = @as(f32, @floatFromInt(i)) / @as(f32, NUM_SEG) * std.math.tau;
            dir[i * 2] = @cos(a);
            dir[i * 2 + 1] = @sin(a);
        }
        const miny = pos[1] + 0.02;
        const maxy = pos[1] + h;
        // wire-цилиндр: нижняя+верхняя окружности + 4 вертикали.
        dd.begin(.lines, 2.0);
        var j: usize = NUM_SEG - 1;
        for (0..NUM_SEG) |i| {
            dd.vertexXYZ(pos[0] + dir[j * 2] * r, miny, pos[2] + dir[j * 2 + 1] * r, col);
            dd.vertexXYZ(pos[0] + dir[i * 2] * r, miny, pos[2] + dir[i * 2 + 1] * r, col);
            dd.vertexXYZ(pos[0] + dir[j * 2] * r, maxy, pos[2] + dir[j * 2 + 1] * r, col);
            dd.vertexXYZ(pos[0] + dir[i * 2] * r, maxy, pos[2] + dir[i * 2 + 1] * r, col);
            j = i;
        }
        var k: usize = 0;
        while (k < NUM_SEG) : (k += NUM_SEG / 4) {
            dd.vertexXYZ(pos[0] + dir[k * 2] * r, miny, pos[2] + dir[k * 2 + 1] * r, col);
            dd.vertexXYZ(pos[0] + dir[k * 2] * r, maxy, pos[2] + dir[k * 2 + 1] * r, col);
        }
        dd.end();
        // круг радиуса r на высоте climb
        drawCircle(dd, .{ pos[0], pos[1] + c, pos[2] }, r, dbg.rgba(0, 0, 0, 64));
        // крест (вертикаль ±climb + оси ±r/2)
        const colb = dbg.rgba(0, 0, 0, 196);
        dd.begin(.lines, 1.0);
        dd.vertexXYZ(pos[0], pos[1] - c, pos[2], colb);
        dd.vertexXYZ(pos[0], pos[1] + c, pos[2], colb);
        dd.vertexXYZ(pos[0] - r / 2, pos[1] + 0.02, pos[2], colb);
        dd.vertexXYZ(pos[0] + r / 2, pos[1] + 0.02, pos[2], colb);
        dd.vertexXYZ(pos[0], pos[1] + 0.02, pos[2] - r / 2, colb);
        dd.vertexXYZ(pos[0], pos[1] + 0.02, pos[2] + r / 2, colb);
        dd.end();
    }

    pub fn drawMenu(self: *NavMeshTesterTool) void {
        self.modeRadio("Pathfind Follow", .pathfind_follow, 0);
        self.modeRadio("Pathfind Straight", .pathfind_straight, 1);
        self.modeRadio("Pathfind Sliced", .pathfind_sliced, 2);
        self.modeRadio("Distance to Wall", .distance_to_wall, 3);
        self.modeRadio("Raycast", .raycast, 4);
        self.modeRadio("Find Polys in Circle", .find_polys_circle, 5);
        self.modeRadio("Find Polys in Shape", .find_polys_shape, 6);
        self.modeRadio("Find Local Neighbourhood", .find_local_neighbourhood, 7);

        var changed = false;
        ui.section(@src(), "Include Flags");
        {
            var i: usize = 0;
            while (i < poly_flags.MAX_FLAGS) : (i += 1) {
                const fl = poly_flags.get(i) orelse continue;
                const bit = poly_flags.bitOf(i).?;
                var on = (self.include_mask & bit) != 0;
                if (dvui.checkbox(@src(), &on, fl.name(), .{ .id_extra = i })) {
                    if (on) self.include_mask |= bit else self.include_mask &= ~bit;
                    changed = true;
                }
            }
        }
        ui.section(@src(), "Exclude Flags");
        {
            var i: usize = 0;
            while (i < poly_flags.MAX_FLAGS) : (i += 1) {
                const fl = poly_flags.get(i) orelse continue;
                const bit = poly_flags.bitOf(i).?;
                var on = (self.exclude_mask & bit) != 0;
                if (dvui.checkbox(@src(), &on, fl.name(), .{ .id_extra = i })) {
                    if (on) self.exclude_mask |= bit else self.exclude_mask &= ~bit;
                    changed = true;
                }
            }
        }
        if (changed) {
            self.applyFlags();
            self.recalc();
        }

        // Reachability heatmap toggle (A6). Flooding from the current start poly
        // under the active filter; recomputes only on toggle / start / filter.
        ui.section(@src(), "Reachability");
        if (dvui.checkbox(@src(), &self.reach_on, "Heatmap from start", .{})) {
            self.recomputeHeatmap();
        }
        if (self.reach_on) {
            if (self.heatmap) |hm|
                dvui.label(@src(), "reached: {d}  cost {d:.2}..{d:.2}", .{ hm.reached, hm.lo, hm.hi }, .{})
            else
                dvui.labelNoFmt(@src(), "(set a start point — LMB)", .{}, .{});
        }

        // Funnel / portal debug overlay (A3). Meaningful in the pathfind modes
        // with a corridor: draws portals (getPortalPoints), ALL_CROSSINGS
        // waypoints, and turn/apex highlights. Recomputed only on toggle / recalc.
        if (self.mode == .pathfind_straight or self.mode == .pathfind_sliced or self.mode == .pathfind_follow) {
            ui.section(@src(), "Funnel debug");
            if (dvui.checkbox(@src(), &self.funnel_on, "Portals + funnel overlay", .{ .id_extra = 0xF0 })) {
                self.recomputeFunnel();
            }
            if (self.funnel_on)
                dvui.label(@src(), "portals: {d}  crossings: {d}  turns: {d}", .{ self.npolys -| 1, self.nfunnel, self.nturn }, .{});
        }

        // Side-by-side filter comparison (A4). Up to 3 variant rows (enable +
        // include/exclude per-flag checkboxes + colour swatch); the comparison
        // reruns on recalc when ON, or via "Run comparison". Legend below shows
        // each enabled variant's poly count + approx cost + reaches Y/N.
        if (self.mode == .pathfind_follow or self.mode == .pathfind_straight or self.mode == .pathfind_sliced)
            self.drawCompareControls();

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        const wpts = if (self.mode == .pathfind_follow) self.nsmooth else self.nstraight;
        dvui.label(@src(), "polys: {d}  waypoints: {d}", .{ self.npolys, wpts }, .{});
        dvui.labelNoFmt(@src(), "Shift+LMB: start  LMB: end", .{}, .{});

        // Sliced pathfinding playback controls — incremental A* visualizer.
        if (self.mode == .pathfind_sliced) self.drawSliceControls();

        // WHY-NO-PATH verdict panel (A1): status line + Explain expander. Shown only
        // for pathfind modes once a recalc has produced a verdict.
        if (self.verdict_valid) {
            ui.section(@src(), "Why no path?");
            const ok = self.verdict == .ok or self.verdict == .same_poly;
            const icon: []const u8 = if (ok) "[OK] " else "[X] ";
            dvui.label(@src(), "{s}{s}", .{ icon, wnp.reasonText(self.verdict) }, .{});
            if (dvui.expander(@src(), "Explain", .{}, .{})) {
                var ebuf: [512]u8 = undefined;
                const txt = wnp.explainText(&ebuf, self.verdict, self.signals);
                dvui.labelNoFmt(@src(), txt, .{}, .{});
            }
        }

        // Route-query benchmark (C2): K random findPaths -> latency percentiles +
        // histogram. Runs on the button only (heavy).
        self.drawBenchControls();
    }

    /// UI for the route-query benchmark (C2): K + seed sliders, a "use tester
    /// filter" checkbox, a "Run query bench" button, then (when a result is
    /// cached) a stats table + a small latency histogram. The bench loop is heavy
    /// (K findPaths) — it runs ONLY when the button is pressed, never per frame.
    ///
    /// Управление бенчмарком запросов (C2): слайдеры K + seed, чекбокс фильтра,
    /// кнопка запуска, таблица статистики + гистограмма латентности. Запуск только
    /// по кнопке (K findPath тяжело) — никогда не покадрово.
    fn drawBenchControls(self: *NavMeshTesterTool) void {
        ui.section(@src(), "Query Bench");

        if (self.navmesh == null or self.query == null) {
            dvui.labelNoFmt(@src(), "(build a navmesh first)", .{}, .{});
            return;
        }

        ui.sliderInt(@src(), "K queries: {d:.0}", &self.bench_k, 100, 5000);
        ui.sliderInt(@src(), "seed: {d:.0}", &self.bench_seed, 0, 9999);
        _ = dvui.checkbox(@src(), &self.bench_use_filter, "use tester filter", .{ .id_extra = 0xB0 });

        if (dvui.button(@src(), "Run query bench", .{}, .{ .id_extra = 0xB1 }))
            self.runBench();

        const res = self.bench_result orelse {
            dvui.labelNoFmt(@src(), "(press Run to benchmark route queries)", .{}, .{});
            return;
        };

        // Stats table. ns formatted human-readable (µs/ms) via fmtNs.
        var b0: [32]u8 = undefined;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        var b4: [32]u8 = undefined;
        var b5: [32]u8 = undefined;
        dvui.label(@src(), "N {d}   success {d:.1}%   avg nodes {d:.1}", .{ res.n, res.successPct(), res.avg_nodes }, .{});
        dvui.label(@src(), "p50 {s}   p95 {s}   p99 {s}", .{ fmtNs(&b0, res.p50_ns), fmtNs(&b1, res.p95_ns), fmtNs(&b2, res.p99_ns) }, .{});
        dvui.label(@src(), "min {s}   max {s}   avg {s}", .{ fmtNs(&b3, res.min_ns), fmtNs(&b4, res.max_ns), fmtNs(&b5, res.avg_ns) }, .{});

        // Latency histogram (HIST_BINS coloured bars), lo..hi labelled.
        self.drawBenchHistogram(res);

        // Worst-path highlight is DEFERRED: the tester's path render is driven by
        // spos/epos clicks + recalc(); re-driving it from worst_start/worst_end
        // (which are PolyRefs, not click points) would need a separate render path.
        // The worst refs ARE captured in the result for a future overlay.
        var bw0: [32]u8 = undefined;
        dvui.label(@src(), "worst: {s}  (refs {d}->{d})", .{ fmtNs(&bw0, res.max_ns), res.worst_start, res.worst_end }, .{});
    }

    /// Draw the latency histogram as HIST_BINS coloured bars (profiler.fillRect
    /// pattern), scaled to the tallest bin, with lo..hi labels. Reads ONLY the
    /// cached result — no queries here.
    ///
    /// Рисует гистограмму латентности столбцами (как profiler.fillRect), нормируя
    /// по самому высокому бину, с подписями lo..hi.
    fn drawBenchHistogram(self: *NavMeshTesterTool, res: query_bench.BenchResult) void {
        _ = self;
        const bins = res.hist;
        var maxc: u32 = 0;
        for (bins) |c| {
            if (c > maxc) maxc = c;
        }
        if (maxc == 0) return;

        // Reserve a fixed-height canvas inside the panel; bars fill it bottom-up.
        var r: dvui.Rect.Physical = undefined;
        {
            var box = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = 200, .h = 60 }, .expand = .horizontal, .id_extra = 0xB2 });
            r = box.data().rectScale().r; // physical pixels
            box.deinit();
        }
        const n: f32 = @floatFromInt(query_bench.HIST_BINS);
        const bar_w = r.w / n;
        const bar_col = dvui.Color{ .r = 70, .g = 180, .b = 220, .a = 255 }; // cyan, profiler-style

        const maxc_f: f32 = @floatFromInt(maxc);
        for (0..query_bench.HIST_BINS) |i| {
            const c: f32 = @floatFromInt(bins[i]);
            const h = if (maxc_f > 0) c / maxc_f * r.h else 0;
            if (h <= 0) continue;
            const x = r.x + @as(f32, @floatFromInt(i)) * bar_w;
            const y = r.y + (r.h - h);
            profiler.fillRect(x, y, @max(bar_w - 1, 1), h, bar_col);
        }

        var lb: [32]u8 = undefined;
        var hb: [32]u8 = undefined;
        dvui.label(@src(), "latency {s} .. {s}  (x={d})", .{ fmtNs(&lb, res.hist_lo_ns), fmtNs(&hb, res.hist_hi_ns), maxc }, .{});
    }

    /// Run the route-query benchmark with the current K/seed/filter selection and
    /// cache the result. Heavy (K findPaths) — called ONLY from the Run button.
    /// On OOM / no navmesh the result is left unchanged (no crash).
    ///
    /// Запускает бенчмарк запросов и кэширует результат. Тяжело — только по кнопке.
    fn runBench(self: *NavMeshTesterTool) void {
        const q = self.query orelse return;
        const nav = self.navmesh orelse return;
        const k: usize = @intFromFloat(@max(self.bench_k, 0));
        const seed: u64 = @intFromFloat(@max(self.bench_seed, 0));

        // Neutral filter when "use tester filter" is off (raw mesh cost, all flags).
        var neutral = dt.QueryFilter.init();
        const filter: *const dt.QueryFilter = if (self.bench_use_filter) &self.filter else &neutral;

        self.bench_result = query_bench.run(q, nav, filter, k, seed, self.alloc) catch null;
    }

    /// UI for the incremental sliced search: Play/Pause, Advance 1/N, Reset,
    /// Finish, per-advance sliders, and a live status line. State machine stays
    /// init-once / update-many / finalize-once; buttons only drive update/finalize.
    ///
    /// Управление пошаговым sliced-поиском (Play/Advance/Reset/Finish + слайдеры).
    fn drawSliceControls(self: *NavMeshTesterTool) void {
        ui.section(@src(), "Sliced Playback");
        const q = self.query;

        {
            var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hb.deinit();
            const play_lbl: []const u8 = if (self.slice_auto) "Pause" else "Play";
            if (dvui.button(@src(), play_lbl, .{}, .{ .id_extra = 0 })) {
                // Only meaningful while a live search exists; toggling resumes it.
                if (self.slice_active and !self.slice_finished) self.slice_auto = !self.slice_auto;
            }
            if (dvui.button(@src(), "Advance 1", .{}, .{ .id_extra = 1 })) {
                if (q) |qq| self.advanceSlice(qq, self.slice_iters);
            }
            if (dvui.button(@src(), "Advance N", .{}, .{ .id_extra = 2 })) {
                if (q) |qq| self.advanceSlice(qq, self.slice_big);
            }
        }
        {
            var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hb.deinit();
            if (dvui.button(@src(), "Reset", .{}, .{ .id_extra = 3 })) {
                // Re-init from current start/end/filter — the only sanctioned re-init.
                self.recalc();
            }
            if (dvui.button(@src(), "Finish", .{}, .{ .id_extra = 4 })) {
                self.finishSliceNow();
            }
        }

        // Per-advance amounts. i32 fields bridged through f32 proxies for the slider.
        var it: f32 = @floatFromInt(self.slice_iters);
        ui.sliderInt(@src(), "iters/advance: {d:.0}", &it, 1, 50);
        self.slice_iters = @intFromFloat(it);
        var big: f32 = @floatFromInt(self.slice_big);
        ui.sliderInt(@src(), "advance N: {d:.0}", &big, 1, 200);
        self.slice_big = @intFromFloat(big);

        // Status line: iters / nodes used / current status word.
        const status_txt: []const u8 = if (self.slice_finished)
            (if (self.slice_status.success) "done" else if (self.slice_status.partial_result) "partial" else "failed")
        else if (self.slice_active)
            "in progress"
        else
            "idle";
        var ncount: usize = 0;
        var nmax: usize = 0;
        if (q) |qq| {
            if (qq.getNodePool()) |pool| {
                ncount = pool.getNodeCount();
                nmax = pool.getMaxNodes();
            }
        }
        dvui.label(@src(), "iters {d}  nodes {d}/{d}  status {s}", .{ self.slice_done_total, ncount, nmax, status_txt }, .{});

        // Dijkstra (zero-heuristic) mode: the faithful core's initSlicedFindPath
        // `options` only exposes FINDPATH_ANY_ANGLE — there is no zero-heuristic
        // flag, so Dijkstra-mode is DEFERRED (would require a core change). Only
        // the default A* search is visualised.
        dvui.labelNoFmt(@src(), "(Dijkstra mode: deferred — no core option)", .{}, .{});
    }

    /// UI for the side-by-side filter comparison (A4): an ON toggle, up to 3
    /// variant rows (enable + a colour swatch + per-flag include/exclude
    /// checkboxes), a "Run comparison" button, and a legend listing each enabled
    /// variant's poly count + approx cost + reaches Y/N. Editing anything that
    /// changes a route re-runs the comparison (cheap; only on edit, not per frame).
    ///
    /// Управление сравнением фильтров (A4): тумблер + до 3 строк-вариантов + легенда.
    fn drawCompareControls(self: *NavMeshTesterTool) void {
        ui.section(@src(), "Compare filters");
        var dirty = false;
        if (dvui.checkbox(@src(), &self.compare.on, "Side-by-side filter comparison", .{ .id_extra = 0xC0 }))
            dirty = true;

        if (self.compare.on) {
            for (&self.compare.variants, 0..) |*v, vi| {
                const base: usize = 0xC100 + vi * 0x100;
                {
                    var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = base });
                    defer hb.deinit();
                    // colour swatch (small filled box, the variant's route colour).
                    var sw = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .id_extra = base + 1,
                        .min_size_content = .{ .w = 14, .h = 14 },
                        .gravity_y = 0.5,
                        .color_fill = colToDvui(v.color),
                        .background = true,
                    });
                    sw.deinit();
                    if (dvui.checkbox(@src(), &v.enabled, v.label(), .{ .id_extra = base + 2 }))
                        dirty = true;
                }
                if (v.enabled) {
                    // Per-flag include/exclude — compact: one checkbox row each.
                    if (compareFlagRow(v, true, base + 0x10)) dirty = true;
                    if (compareFlagRow(v, false, base + 0x40)) dirty = true;
                }
            }
            if (dvui.button(@src(), "Run comparison", .{}, .{ .id_extra = 0xC0FF }))
                dirty = true;

            // Legend: per enabled variant — poly count + approx cost + reaches.
            for (&self.compare.variants, 0..) |*v, vi| {
                if (!v.enabled) continue;
                const r = self.compare.results[vi];
                const reach: []const u8 = if (r.reaches) "Y" else "N";
                dvui.label(@src(), "[{d}] {s}: {d} polys  cost {d:.1}  reaches:{s}", .{ vi + 1, v.label(), r.npolys, r.cost, reach }, .{ .id_extra = 0xCE00 + vi });
            }
        }

        if (dirty) self.recomputeCompare();
    }

    /// One compact include- OR exclude-flag checkbox row for a comparison variant.
    /// `inc=true` edits v.include, else v.exclude. `id_base` must be unique per row.
    /// Returns true if any flag was toggled (caller re-runs the comparison).
    fn compareFlagRow(v: *filter_compare.Variant, inc: bool, id_base: usize) bool {
        var changed = false;
        var hb = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id_base });
        defer hb.deinit();
        dvui.labelNoFmt(@src(), if (inc) "incl" else "excl", .{}, .{ .gravity_y = 0.5 });
        var i: usize = 0;
        while (i < poly_flags.MAX_FLAGS) : (i += 1) {
            const fl = poly_flags.get(i) orelse continue;
            const bit = poly_flags.bitOf(i).?;
            const mask = if (inc) &v.include else &v.exclude;
            var on = (mask.* & bit) != 0;
            if (dvui.checkbox(@src(), &on, fl.name(), .{ .id_extra = id_base + 1 + i })) {
                if (on) mask.* |= bit else mask.* &= ~bit;
                changed = true;
            }
        }
        return changed;
    }

    fn modeRadio(self: *NavMeshTesterTool, label: []const u8, m: ToolMode, id: usize) void {
        if (ui.radio(@src(), self.mode == m, label, id)) {
            self.mode = m;
            self.recalc();
        }
    }
};

fn dist2d(a: [3]f32, b: [3]f32) f32 {
    const dx = b[0] - a[0];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dz * dz);
}

/// Decompose a packed debug `rgba` u32 (R in low byte) into a dvui.Color for the
/// comparison swatch. Forces full alpha so the swatch reads solid in the panel.
fn colToDvui(col: u32) dvui.Color {
    return .{
        .r = @intCast(col & 0xff),
        .g = @intCast((col >> 8) & 0xff),
        .b = @intCast((col >> 16) & 0xff),
        .a = 255,
    };
}

const SP_END: u8 = 0x02;
const SP_OFFMESH: u8 = 0x04;

/// Format a nanosecond latency into a human-readable µs/ms/ns string in `buf`.
/// >=1ms -> "{d:.2}ms", >=1µs -> "{d:.1}µs", else "{d}ns". Used by the bench table.
///
/// Форматирует наносекунды в читаемую строку (ms/µs/ns) для таблицы бенча.
fn fmtNs(buf: []u8, ns: u64) []const u8 {
    if (ns >= 1_000_000) {
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0}) catch "?";
    } else if (ns >= 1_000) {
        return std.fmt.bufPrint(buf, "{d:.1}us", .{@as(f64, @floatFromInt(ns)) / 1_000.0}) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
}

fn inRange(v1: *const [3]f32, v2: *const [3]f32, r: f32, h: f32) bool {
    const dx = v2[0] - v1[0];
    const dy = v2[1] - v1[1];
    const dz = v2[2] - v1[2];
    return (dx * dx + dz * dz) < r * r and @abs(dy) < h;
}

fn getSteerTarget(q: *dt.NavMeshQuery, start: *const [3]f32, end: *const [3]f32, min_dist: f32, path: []const dt.PolyRef, steer_pos: *[3]f32, steer_flag: *u8, steer_ref: *dt.PolyRef) bool {
    var sp: [9]f32 = undefined;
    var sf: [3]u8 = undefined;
    var sr: [3]dt.PolyRef = undefined;
    var nsteer: usize = 0;
    _ = q.findStraightPath(start, end, path, sp[0..], sf[0..], sr[0..], &nsteer, 0) catch return false;
    if (nsteer == 0) return false;
    var ns: usize = 0;
    while (ns < nsteer) : (ns += 1) {
        if ((sf[ns] & SP_OFFMESH) != 0) break;
        if (!inRange(sp[ns * 3 ..][0..3], start, min_dist, 1000.0)) break;
    }
    if (ns >= nsteer) return false;
    steer_pos.* = .{ sp[ns * 3], start[1], sp[ns * 3 + 2] };
    steer_flag.* = sf[ns];
    steer_ref.* = sr[ns];
    return true;
}

/// Слияние пройденных полигонов (visited) в коридор path — порт fixupCorridor.
fn fixupCorridor(path: []dt.PolyRef, npath_in: usize, visited: []const dt.PolyRef) usize {
    var furthest_path: i64 = -1;
    var furthest_visited: i64 = -1;
    var i: i64 = @as(i64, @intCast(npath_in)) - 1;
    while (i >= 0) : (i -= 1) {
        var found = false;
        var j: i64 = @as(i64, @intCast(visited.len)) - 1;
        while (j >= 0) : (j -= 1) {
            if (path[@intCast(i)] == visited[@intCast(j)]) {
                furthest_path = i;
                furthest_visited = j;
                found = true; // upstream: НЕ break — ищем самый дальний (наименьший j)
            }
        }
        if (found) break;
    }
    if (furthest_path == -1 or furthest_visited == -1) return npath_in;
    const req: usize = visited.len - @as(usize, @intCast(furthest_visited));
    const orig: usize = @min(@as(usize, @intCast(furthest_path)) + 1, npath_in);
    var size: usize = if (npath_in > orig) npath_in - orig else 0;
    if (req + size > path.len) size = path.len - req;
    // memmove(path+req, path+orig, size): направление КРИТИЧНО при перекрытии.
    // req<=orig (сжатие коридора, частый случай) -> сдвиг влево -> копировать
    // спереди-назад. req>orig -> сдвиг вправо -> сзади-наперёд. Однонаправленный
    // цикл размножал ячейку (дубликаты поли -> вырожденный портал в findStraightPath).
    if (size > 0) {
        if (req <= orig) {
            for (0..size) |k| path[req + k] = path[orig + k];
        } else {
            var k: usize = size;
            while (k > 0) : (k -= 1) path[req + k - 1] = path[orig + k - 1];
        }
    }
    for (0..req) |k| path[k] = visited[visited.len - 1 - k];
    return req + size;
}

/// Сглаженный путь по поверхности навмеша (порт recalc FOLLOW). Возвращает число точек в out.
fn smoothPath(q: *dt.NavMeshQuery, start_ref: dt.PolyRef, spos: *const [3]f32, epos: *const [3]f32, filter: *const dt.QueryFilter, path_in: []const dt.PolyRef, out: []f32) usize {
    const max_pts = out.len / 3;
    if (max_pts == 0 or path_in.len == 0) return 0;
    var polys: [MAX_POLYS]dt.PolyRef = undefined;
    @memcpy(polys[0..path_in.len], path_in);
    var npolys = path_in.len;

    var iter_pos: [3]f32 = undefined;
    var target_pos: [3]f32 = undefined;
    _ = q.closestPointOnPoly(start_ref, spos, &iter_pos, null) catch return 0;
    _ = q.closestPointOnPoly(polys[npolys - 1], epos, &target_pos, null) catch return 0;

    const STEP: f32 = 0.5;
    const SLOP: f32 = 0.01;
    var nsmooth: usize = 0;
    out[0..3].* = iter_pos;
    nsmooth = 1;

    while (npolys > 0 and nsmooth < max_pts) {
        var steer_pos: [3]f32 = undefined;
        var steer_flag: u8 = 0;
        var steer_ref: dt.PolyRef = 0;
        if (!getSteerTarget(q, &iter_pos, &target_pos, SLOP, polys[0..npolys], &steer_pos, &steer_flag, &steer_ref)) break;
        const end_of_path = (steer_flag & SP_END) != 0;

        const delta = [3]f32{ steer_pos[0] - iter_pos[0], steer_pos[1] - iter_pos[1], steer_pos[2] - iter_pos[2] };
        var len = @sqrt(delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]);
        // Не перепрыгивать цель ближе шага. upstream делает это только для end_of_path,
        // но при огибании ПРОМЕЖУТОЧНОГО угла перелёт (move_tgt на STEP за углом) попадает
        // в боковой полигон → коридор всасывает вылазку → funnel тянет назад → осцилляция.
        // Встаём точно на угол (len=1 => move_tgt=steer): угол потребляется, путь продвигается.
        if (len < STEP) {
            len = 1;
        } else if (len > 1e-6) {
            len = STEP / len;
        }
        const move_tgt = [3]f32{ iter_pos[0] + delta[0] * len, iter_pos[1] + delta[1] * len, iter_pos[2] + delta[2] * len };

        var result: [3]f32 = undefined;
        var visited: [16]dt.PolyRef = undefined;
        var nvisited: usize = 0;
        _ = q.moveAlongSurface(polys[0], &iter_pos, &move_tgt, filter, &result, visited[0..], &nvisited) catch break;
        npolys = fixupCorridor(polys[0..], npolys, visited[0..nvisited]);
        // getPolyHeight падает, если точка легла на границу detail-mesh (частый случай у
        // скруглённых углов). По умолчанию держим прошлый валидный y (iter_pos[1]), а НЕ 0 —
        // иначе точка проваливается в y=0, что и рисует вертикальную линию и дестабилизирует
        // moveAlongSurface (на y=0 другой набор поли → застревание/осцилляция).
        var h: f32 = iter_pos[1];
        _ = q.getPolyHeight(polys[0], &result, &h) catch {};
        result[1] = h;
        iter_pos = result;

        if (end_of_path and inRange(&iter_pos, &steer_pos, SLOP, 1.0)) {
            iter_pos = target_pos;
            if (nsmooth < max_pts) {
                out[nsmooth * 3 ..][0..3].* = iter_pos;
                nsmooth += 1;
            }
            break;
        }
        if (nsmooth < max_pts) {
            out[nsmooth * 3 ..][0..3].* = iter_pos;
            nsmooth += 1;
        }
    }
    return nsmooth;
}

fn drawCircle(dd: dbg.DebugDraw, c: [3]f32, r: f32, col: u32) void {
    const segs = 32;
    dd.begin(.lines, 1.0);
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a0 = @as(f32, @floatFromInt(i)) / segs * std.math.tau;
        const a1 = @as(f32, @floatFromInt(i + 1)) / segs * std.math.tau;
        dd.vertexXYZ(c[0] + @cos(a0) * r, c[1] + 0.05, c[2] + @sin(a0) * r, col);
        dd.vertexXYZ(c[0] + @cos(a1) * r, c[1] + 0.05, c[2] + @sin(a1) * r, col);
    }
    dd.end();
}

fn drawMarker(dd: dbg.DebugDraw, p: [3]f32, col: u32) void {
    dd.begin(.lines, 1.0);
    dd.vertexXYZ(p[0] - 0.4, p[1] + 0.1, p[2], col);
    dd.vertexXYZ(p[0] + 0.4, p[1] + 0.1, p[2], col);
    dd.vertexXYZ(p[0], p[1] + 0.1, p[2] - 0.4, col);
    dd.vertexXYZ(p[0], p[1] + 0.1, p[2] + 0.4, col);
    dd.vertexXYZ(p[0], p[1], p[2], col);
    dd.vertexXYZ(p[0], p[1] + 1.5, p[2], col);
    dd.end();
}
