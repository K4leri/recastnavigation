//! Sample_SoloMesh — построение navmesh из всей геометрии за один проход.
//! Порт RecastDemo/Sample_SoloMesh.cpp (build pipeline + DrawMode + UI).

const std = @import("std");
const dvui = @import("dvui");
const zgl = @import("zgl");
const recast = @import("recast-nav");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const InputGeom = @import("input_geom.zig").InputGeom;
const BuildContext = @import("build_context.zig").BuildContext;
const ddgl = @import("debug_draw_gl.zig");
const io_util = @import("io_util.zig");
const ui = @import("ui.zig");
const nav_io = @import("navmesh_io.zig");
const poly_visit = @import("render/poly_visit.zig");
const scheme_state = @import("render/scheme_state.zig");
const filter_state = @import("render/filter_state.zig");
const view_state = @import("render/view_state.zig");
const convex_surface = @import("convex_surface.zig");
const build_stats = @import("diag/build_stats.zig");
const profiler = @import("diag/profiler.zig");
const artifacts = @import("diag/artifacts.zig");

const rc = recast.recast;
const dt = recast.detour;
const dbg = recast.debug;
const Vec3 = recast.math.Vec3;

pub const DrawMode = enum {
    mesh,
    navmesh,
    navmesh_trans,
    navmesh_bvtree,
    navmesh_nodes,
    voxels,
    voxels_walkable,
    compact,
    compact_distance,
    compact_regions,
    region_connections,
    raw_contours,
    both_contours,
    contours,
    polymesh,
    polymesh_detail,
};

pub const SampleSolo = struct {
    alloc: std.mem.Allocator,
    settings: sample.CommonSettings = .{},
    geom: ?*InputGeom = null,
    bctx: *BuildContext,
    dd_gl: *ddgl.DebugDrawGL,

    draw_mode: DrawMode = .navmesh,
    build_time_ms: f32 = 0,
    build_gen: u32 = 0, // инкремент при каждой успешной сборке (для синхронизации тулов)

    // Build Inspector (B-1): per-stage counters + wall-clock times of the last build.
    // Additive instrumentation, заполняется в doBuild. Действителен при build_gen>0.
    build_stats: build_stats.BuildStats = .{},

    // Build Param Diff (B-2): снимок предыдущей сборки (один шаг истории).
    // BuildStats — value-type (фиксированные массивы, без heap), копируется присваиванием.
    // Build Param Diff (B-2): snapshot of the immediately previous build (one-deep history).
    // BuildStats is a value type (fixed arrays, no heap pointers) — plain assignment suffices.
    prev_build_stats: ?build_stats.BuildStats = null,
    // Показывать ли дельту в Build Inspector. Сохраняется между кадрами.
    // Whether to show the diff panel in Build Inspector. Persists across frames.
    show_build_diff: bool = false,

    // Build Profiler + Run History (C1): кольцо последних N=16 сборок (per-stage
    // ms + total) для панели Profiler. VALUE-тип (фиксированный массив, без heap) —
    // не требует deinit, не течёт. Заполняется ОДИН раз на успешную сборку.
    // Build Profiler ring of the last N=16 builds (value type — no heap, no leak).
    // Pushed once per successful build. show_profiler toggles the panel; selected
    // index into the history for the table/bar (default newest when null).
    profile_history: profiler.History = .{},
    show_profiler: bool = false,
    profiler_sel: f32 = 0, // выбранный элемент истории (слайдер 0..len-1)

    // Build Artifact Detectors (B-3): cached report from the last "Scan artifacts"
    // press (degenerate detail tris / tiny polys / dead-end polys + capped culprit
    // list). Owns a heap ArrayList -> freed on re-scan + on deinit. highlight reads
    // the cached report (analyze runs on the button, NOT per frame).
    artifact_report: ?artifacts.ArtifactReport = null,
    highlight_culprits: bool = false,

    // промежуточные результаты (для отрисовки)
    hf: ?recast.Heightfield = null,
    chf: ?recast.CompactHeightfield = null,
    cset: ?recast.ContourSet = null,
    pmesh: ?recast.PolyMesh = null,
    dmesh: ?recast.PolyMeshDetail = null,
    navmesh: ?dt.NavMesh = null,
    navmesh_data: ?[]u8 = null,

    pub fn init(alloc: std.mem.Allocator, bctx: *BuildContext, dd_gl: *ddgl.DebugDrawGL) SampleSolo {
        return .{ .alloc = alloc, .bctx = bctx, .dd_gl = dd_gl };
    }

    pub fn deinit(self: *SampleSolo) void {
        self.cleanup();
    }

    fn cleanup(self: *SampleSolo) void {
        if (self.hf) |*h| h.deinit();
        if (self.chf) |*c| c.deinit();
        if (self.cset) |*c| c.deinit();
        if (self.pmesh) |*p| p.deinit();
        if (self.dmesh) |*d| d.deinit();
        if (self.navmesh) |*n| n.deinit();
        if (self.navmesh_data) |d| self.alloc.free(d);
        if (self.artifact_report) |*r| r.deinit(self.alloc);
        self.artifact_report = null;
        self.hf = null;
        self.chf = null;
        self.cset = null;
        self.pmesh = null;
        self.dmesh = null;
        self.navmesh = null;
        self.navmesh_data = null;
    }

    pub fn setGeom(self: *SampleSolo, geom: *InputGeom) void {
        self.geom = geom;
        self.cleanup();
    }

    /// Указатель на построенный navmesh (для инструментов), или null.
    pub fn navMesh(self: *SampleSolo) ?*dt.NavMesh {
        if (self.navmesh) |*n| return n;
        return null;
    }

    /// Sample-интерфейс.
    pub fn sampleIface(self: *SampleSolo) sample.Sample {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = sample.Sample.VTable{
        .drawSettings = vtDrawSettings,
        .drawDebugMode = vtDrawDebugMode,
        .onClick = vtOnClick,
        .onToggle = vtNoop,
        .step = vtNoop,
        .render = vtRender,
        .renderOverlay = vtNoop,
        .onMeshChanged = vtNoop,
        .build = vtBuild,
        .update = vtUpdate,
    };

    fn vtNoop(_: *anyopaque) void {}
    fn vtUpdate(_: *anyopaque, _: f32) void {}
    fn vtOnClick(_: *anyopaque, _: *const [3]f32, _: *const [3]f32, _: bool) void {}

    fn vtBuild(ptr: *anyopaque) bool {
        const self: *SampleSolo = @ptrCast(@alignCast(ptr));
        return self.build();
    }

    fn vtRender(ptr: *anyopaque) void {
        const self: *SampleSolo = @ptrCast(@alignCast(ptr));
        self.render();
    }

    fn vtDrawSettings(ptr: *anyopaque) void {
        const self: *SampleSolo = @ptrCast(@alignCast(ptr));
        self.drawSettings();
    }

    fn vtDrawDebugMode(ptr: *anyopaque) void {
        const self: *SampleSolo = @ptrCast(@alignCast(ptr));
        self.drawDebugMode();
    }

    // ========================================================================
    // BUILD
    // ========================================================================
    pub fn build(self: *SampleSolo) bool {
        const geom = self.geom orelse return false;
        if (geom.triCount() == 0) return false;
        self.cleanup();
        self.bctx.resetLog();
        const ctx = self.bctx.context();
        const s = &self.settings;

        // Build Param Diff (B-2): снимаем текущие stats в prev ПЕРЕД reset(),
        // только если уже была хотя бы одна успешная сборка (build_gen > 0).
        // Build Param Diff (B-2): snapshot current stats into prev BEFORE reset(),
        // but only when at least one successful build already exists (build_gen > 0).
        if (self.build_gen > 0) {
            self.prev_build_stats = self.build_stats;
        }

        // Build Inspector (B-1): сброс per-stage статистики перед сборкой.
        self.build_stats.reset();
        self.build_stats.partition = switch (s.partition_type) {
            .watershed => .watershed,
            .monotone => .monotone,
            .layers => .layers,
        };

        var timer = io_util.PerfTimer.start();

        // конфиг (конвертация параметров как RecastDemo)
        const cs = s.cell_size;
        const ch = s.cell_height;
        const walkable_height: i32 = @intFromFloat(@ceil(s.agent_height / ch));
        const walkable_climb: i32 = @intFromFloat(@floor(s.agent_max_climb / ch));
        const walkable_radius: i32 = @intFromFloat(@ceil(s.agent_radius / cs));
        const max_edge_len: i32 = @intFromFloat(s.edge_max_len / cs);
        const min_region_area: i32 = @intFromFloat(s.region_min_size * s.region_min_size);
        const merge_region_area: i32 = @intFromFloat(s.region_merge_size * s.region_merge_size);
        const detail_sample_dist: f32 = if (s.detail_sample_dist < 0.9) 0 else cs * s.detail_sample_dist;
        const detail_sample_max_error: f32 = ch * s.detail_sample_max_error;
        const border_size: i32 = 0;

        var bmin = Vec3.init(geom.bmin[0], geom.bmin[1], geom.bmin[2]);
        var bmax = Vec3.init(geom.bmax[0], geom.bmax[1], geom.bmax[2]);

        var size_x: i32 = 0;
        var size_z: i32 = 0;
        recast.RecastConfig.calcGridSize(bmin, bmax, cs, &size_x, &size_z);

        self.doBuild(ctx, geom, .{
            .cs = cs,
            .ch = ch,
            .width = size_x,
            .height = size_z,
            .bmin = bmin,
            .bmax = bmax,
            .walkable_height = walkable_height,
            .walkable_climb = walkable_climb,
            .walkable_radius = walkable_radius,
            .walkable_slope = s.agent_max_slope,
            .max_edge_len = max_edge_len,
            .max_simpl_error = s.edge_max_error,
            .min_region_area = min_region_area,
            .merge_region_area = merge_region_area,
            .nvp = @intFromFloat(s.verts_per_poly),
            .detail_sample_dist = detail_sample_dist,
            .detail_sample_max_error = detail_sample_max_error,
            .border_size = border_size,
        }) catch |e| {
            ctx.log(.err, "build failed: {s}", .{@errorName(e)});
            return false;
        };
        _ = &bmin;
        _ = &bmax;

        self.build_time_ms = timer.readMs();
        // total_ms — авторитетный полный wall-clock (тот же, что "Build OK in N ms");
        // не сумма стадий (есть несекундомеренные шаги: areas alloc, navmesh data).
        self.build_stats.total_ms = self.build_time_ms;
        self.build_gen +%= 1;
        ctx.log(.progress, "Build OK in {d:.1} ms", .{self.build_time_ms});
        // One-line stderr dump (observability). Counts from the just-built stats.
        const bs = &self.build_stats;
        ctx.log(.progress, "[BUILD] hf={d} chf={d} regions={d} polys={d} detail_tris={d} total={d:.1}ms", .{
            bs.stage(.heightfield).spans,
            bs.stage(.compact).compact_spans,
            bs.stage(.regions).max_regions,
            bs.stage(.polymesh).pm_polys,
            bs.stage(.detail).dm_tris,
            bs.total_ms,
        });
        // Build Profiler (C1): push a snapshot of THIS successful build into the
        // run-history ring (once per build, not per frame). Headline counts come
        // from the polymesh / regions stages already filled above.
        self.profile_history.push(profiler.BuildProfile.fromBuildStats(
            bs,
            self.build_gen,
            // pm_polys is u64; clamp before the u32 cast so a (practically impossible)
            // >4G poly count can't panic the @intCast in ReleaseSafe.
            @intCast(@min(bs.stage(.polymesh).pm_polys, std.math.maxInt(u32))),
            bs.stage(.regions).max_regions,
        ));
        // Default the history selector to the newest entry.
        self.profiler_sel = @floatFromInt(self.profile_history.len - 1);
        return true;
    }

    const Cfg = struct {
        cs: f32,
        ch: f32,
        width: i32,
        height: i32,
        bmin: Vec3,
        bmax: Vec3,
        walkable_height: i32,
        walkable_climb: i32,
        walkable_radius: i32,
        walkable_slope: f32,
        max_edge_len: i32,
        max_simpl_error: f32,
        min_region_area: i32,
        merge_region_area: i32,
        nvp: i32,
        detail_sample_dist: f32,
        detail_sample_max_error: f32,
        border_size: i32,
    };

    fn doBuild(self: *SampleSolo, ctx: *recast.Context, geom: *InputGeom, cfg: Cfg) !void {
        const a = self.alloc;
        const verts = geom.verts.items;
        const tris = geom.tris.items;
        const ntris = geom.triCount();
        // Build Inspector (B-1): per-stage timers + count reads. Additive & cheap;
        // does not alter pipeline order or recast calls.
        const bs = &self.build_stats;

        // 1. heightfield (rasterize + filters)
        var t_hf = io_util.PerfTimer.start();
        var hf = try recast.Heightfield.init(a, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch);
        errdefer hf.deinit();

        const areas = try a.alloc(u8, ntris);
        defer a.free(areas);
        // ВАЖНО: markWalkableTriangles ставит WALKABLE только для проходимых граней,
        // не-walkable оставляет КАК ЕСТЬ. Как в upstream (Sample_SoloMesh: memset(triareas,0))
        // буфер нужно обнулить, иначе мусор (0xAA) делает все грани walkable.
        @memset(areas, rc.config.AreaId.NULL_AREA);
        rc.filter.markWalkableTriangles(ctx, cfg.walkable_slope, verts, tris, areas);

        try rc.rasterization.rasterizeTriangles(ctx, verts, tris, areas, &hf, cfg.walkable_climb);

        // 2. фильтры (условно по переключателям UI, 1-в-1 Sample_SoloMesh::handleBuild)
        const s = &self.settings;
        if (s.filter_low_hanging_obstacles)
            rc.filter.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
        if (s.filter_ledge_spans)
            rc.filter.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
        if (s.filter_walkable_low_height_spans)
            rc.filter.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);
        self.hf = hf;
        {
            // hf stats: total spans + walkable (area != NULL_AREA) via column walk.
            var total: u64 = 0;
            var walk: u64 = 0;
            for (hf.spans) |col| {
                var sp = col;
                while (sp) |span| : (sp = span.next) {
                    total += 1;
                    if (span.area != rc.config.AreaId.NULL_AREA) walk += 1;
                }
            }
            const st = bs.stage(.heightfield);
            st.ran = true;
            st.ms = t_hf.readMs();
            st.spans = total;
            st.walkable_spans = walk;
        }

        // 3. compact heightfield
        var t_chf = io_util.PerfTimer.start();
        const span_count = rc.compact.getHeightFieldSpanCount(ctx, &hf);
        var chf = try recast.CompactHeightfield.init(a, cfg.width, cfg.height, @intCast(span_count), cfg.walkable_height, cfg.walkable_climb, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch, cfg.border_size);
        errdefer chf.deinit();
        try rc.compact.buildCompactHeightfield(ctx, cfg.walkable_height, cfg.walkable_climb, &hf, &chf);
        {
            const st = bs.stage(.compact);
            st.ran = true;
            st.ms = t_chf.readMs();
            st.compact_spans = @intCast(chf.span_count);
            st.walkable_height = chf.walkable_height;
            st.walkable_climb = chf.walkable_climb;
        }

        // 4. erode + выпуклые объёмы + регионы (watershed)
        // (erode + volumes timed together with the region growth into the
        //  `regions` stage; distancefield is its own watershed-only stage.)
        var t_reg = io_util.PerfTimer.start();
        try rc.area.erodeWalkableArea(ctx, cfg.walkable_radius, &chf, a);
        for (geom.volumes.items) |*vol| {
            const nv: usize = @intCast(vol.nverts);
            switch (vol.mode) {
                .prism => rc.area.markConvexPolyArea(ctx, vol.verts[0 .. nv * 3], nv, vol.hmin, vol.hmax, vol.area, &chf),
                .surface => convex_surface.markConvexPolyAreaSurface(vol.verts[0 .. nv * 3], nv, vol.band_below, vol.band_above, vol.area, &chf),
            }
        }
        // Partitioning (ветвление по типу, 1-в-1 Sample_SoloMesh::handleBuild).
        switch (s.partition_type) {
            .watershed => {
                // Watershed: дистанционное поле + рост регионов.
                var t_df = io_util.PerfTimer.start();
                try rc.region.buildDistanceField(ctx, &chf, a);
                const sdf = bs.stage(.distancefield);
                sdf.ran = true;
                sdf.ms = t_df.readMs();
                sdf.max_distance = chf.max_distance;
                try rc.region.buildRegions(ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, a);
            },
            // Monotone: без distancefield (distancefield stage остаётся N/A).
            .monotone => try rc.region.buildRegionsMonotone(ctx, &chf, cfg.border_size, cfg.min_region_area, cfg.merge_region_area, a),
            // Layers: без distancefield; merge_region_area не используется (как в оригинале).
            .layers => try rc.region.buildLayerRegions(ctx, &chf, cfg.border_size, cfg.min_region_area, a),
        }
        {
            // regions stage time = erode + volumes + (distancefield if watershed) +
            // region growth (the full t_reg window). max_regions is the key metric.
            const st = bs.stage(.regions);
            st.ran = true;
            st.ms = t_reg.readMs();
            st.max_regions = chf.max_regions;
        }
        self.chf = chf;

        // 5. контуры
        var t_cset = io_util.PerfTimer.start();
        var cset = recast.ContourSet.init(a);
        errdefer cset.deinit();
        try rc.contour.buildContours(ctx, &chf, cfg.max_simpl_error, cfg.max_edge_len, &cset, rc.config.CONTOUR_TESS_WALL_EDGES, a);
        self.cset = cset;
        {
            var raw: u64 = 0;
            var simpl: u64 = 0;
            const nc: usize = @intCast(cset.nconts);
            for (cset.conts[0..nc]) |c| {
                raw += @intCast(c.nrverts);
                simpl += @intCast(c.nverts);
            }
            const st = bs.stage(.contours);
            st.ran = true;
            st.ms = t_cset.readMs();
            st.nconts = @intCast(cset.nconts);
            st.raw_verts = raw;
            st.simplified_verts = simpl;
        }

        // 6. polymesh
        var t_pm = io_util.PerfTimer.start();
        var pmesh = recast.PolyMesh.init(a);
        errdefer pmesh.deinit();
        try rc.mesh.buildPolyMesh(ctx, &cset, @intCast(cfg.nvp), &pmesh, a);
        self.pmesh = pmesh;
        {
            const st = bs.stage(.polymesh);
            st.ran = true;
            st.ms = t_pm.readMs();
            st.pm_verts = pmesh.vertCount();
            st.pm_polys = pmesh.polyCount();
            st.nvp = pmesh.nvp;
        }

        // 7. detail mesh
        var t_dm = io_util.PerfTimer.start();
        var dmesh = recast.PolyMeshDetail.init(a);
        errdefer dmesh.deinit();
        try rc.detail.buildPolyMeshDetail(ctx, &pmesh, &chf, cfg.detail_sample_dist, cfg.detail_sample_max_error, &dmesh, a);
        self.dmesh = dmesh;
        {
            const st = bs.stage(.detail);
            st.ran = true;
            st.ms = t_dm.readMs();
            st.dm_meshes = @intCast(dmesh.nmeshes);
            st.dm_verts = dmesh.vertCount();
            st.dm_tris = dmesh.triCount();
        }

        // 8. флаги полигонов по областям
        const pm = &self.pmesh.?;
        const npolys: usize = pm.polyCount();
        const poly_flags = try a.alloc(u16, npolys);
        defer a.free(poly_flags);
        for (0..npolys) |i| {
            // RecastDemo: walkable sentinel (63) -> ground. Also normalize areas the
            // registry doesn't know (uninitialised 0xAA from WIP builds) -> ground,
            // so the navmesh doesn't paint with garbage colours. Flags come from the
            // area-type registry (area -> poly flags), supporting custom types.
            if (pm.areas[i] == rc.config.AreaId.WALKABLE_AREA or area_types.get(pm.areas[i]) == null) {
                pm.areas[i] = @intFromEnum(sample.SamplePolyAreas.ground);
            }
            poly_flags[i] = area_types.flagsFor(pm.areas[i]);
        }

        // 9. navmesh data
        const params = dt.NavMeshCreateParams{
            .verts = pm.verts,
            .vert_count = pm.vertCount(),
            .polys = pm.polys,
            .poly_flags = poly_flags,
            .poly_areas = pm.areas,
            .poly_count = pm.polyCount(),
            .nvp = @intCast(pm.nvp),
            .detail_meshes = self.dmesh.?.meshes,
            .detail_verts = self.dmesh.?.verts,
            .detail_verts_count = self.dmesh.?.vertCount(),
            .detail_tris = self.dmesh.?.tris,
            .detail_tri_count = self.dmesh.?.triCount(),
            .bmin = .{ pm.bmin.x, pm.bmin.y, pm.bmin.z },
            .bmax = .{ pm.bmax.x, pm.bmax.y, pm.bmax.z },
            .walkable_height = @as(f32, @floatFromInt(cfg.walkable_height)) * cfg.ch,
            .walkable_radius = @as(f32, @floatFromInt(cfg.walkable_radius)) * cfg.cs,
            .walkable_climb = @as(f32, @floatFromInt(cfg.walkable_climb)) * cfg.ch,
            .cs = pm.cs,
            .ch = pm.ch,
            .off_mesh_con_verts = if (geom.offMeshCount() > 0) geom.off_verts.items else null,
            .off_mesh_con_rad = if (geom.offMeshCount() > 0) geom.off_rad.items else null,
            .off_mesh_con_flags = if (geom.offMeshCount() > 0) geom.off_flags.items else null,
            .off_mesh_con_areas = if (geom.offMeshCount() > 0) geom.off_area.items else null,
            .off_mesh_con_dir = if (geom.offMeshCount() > 0) geom.off_dir.items else null,
            .off_mesh_con_user_id = if (geom.offMeshCount() > 0) geom.off_id.items else null,
            .off_mesh_con_count = geom.offMeshCount(),
            .build_bv_tree = true,
        };
        const data = try dt.createNavMeshData(&params, a);
        self.navmesh_data = data;

        const nm_params = dt.NavMeshParams{
            .orig = cfg.bmin,
            .tile_width = cfg.bmax.x - cfg.bmin.x,
            .tile_height = cfg.bmax.z - cfg.bmin.z,
            .max_tiles = 1,
            .max_polys = 1024,
        };
        var navmesh = try dt.NavMesh.init(a, nm_params);
        errdefer navmesh.deinit();
        _ = try navmesh.addTile(data, dt.TileFlags{ .free_data = false }, 0);
        self.navmesh = navmesh;
    }

    // Cluster E (P1-1): unified navmesh-layer draw shared by every draw_mode that
    // shows the navmesh. Gated on the `navmesh` group; routes wireframe ->
    // poly_visit.outlineNavMesh (works with filter on/off), else filtered draw
    // (clip/iso active) else faithful + optional scheme overdraw.
    fn drawNavmeshLayer(self: *SampleSolo, dd: dbg.DebugDraw, n: *dt.NavMesh) void {
        if (!view_state.groups.navmesh) return;
        if (view_state.wireframe) {
            poly_visit.outlineNavMesh(dd, n, scheme_state.active, filter_state.active, self.alloc);
        } else if (filter_state.active.active()) {
            poly_visit.fillNavMeshFiltered(dd, n, scheme_state.active, filter_state.active, self.alloc);
        } else {
            dbg.debugDrawNavMesh(dd, n, 0);
            if (scheme_state.active != .area) poly_visit.fillNavMesh(dd, n, scheme_state.active, self.alloc);
        }
        // B-3: overdraw flagged culprit polys in a warning colour (reads the cached
        // report — analyze runs on the button, not here).
        if (self.highlight_culprits) self.drawArtifactHighlight(dd, n);
    }

    /// Warning colour for highlighted artifact culprits (translucent orange).
    const ARTIFACT_HL_COL: u32 = dbg.rgba(255, 140, 0, 160);

    /// B-3 highlight: overdraw each cached culprit poly's detail triangles in a
    /// warning colour. Mirrors poly_visit.fillNavMesh's detail-tri walk; reads the
    /// cached report (no analyze() here). Bounds-safe (bad ref -> skip).
    fn drawArtifactHighlight(self: *SampleSolo, dd: dbg.DebugDraw, n: *dt.NavMesh) void {
        const rep = if (self.artifact_report) |*r| r else return;
        if (rep.culprits.items.len == 0) return;

        dd.depthMask(false);
        dd.begin(.tris, 1.0);
        for (rep.culprits.items) |c| {
            var tile: ?*const dt.MeshTile = null;
            var poly: ?*const dt.Poly = null;
            n.getTileAndPolyByRefUnsafe(c.ref, &tile, &poly);
            const t = tile orelse continue;
            const p = poly orelse continue;
            const d = n.decodePolyId(c.ref);
            if (d.poly >= t.detail_meshes.len) continue;
            const pd = &t.detail_meshes[d.poly];

            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (@as(usize, pd.tri_base) + j) * 4;
                if (t_idx + 3 >= t.detail_tris.len) break;
                const tri = t.detail_tris[t_idx .. t_idx + 4];
                // Pre-validate all 3 verts, THEN emit — emitting partial vertices
                // into a .tris batch (on a corrupt index mid-triangle) would desync
                // the 3-vertex grouping for every following triangle.
                var pts: [3]*const [3]f32 = undefined;
                var tri_ok = true;
                for (0..3) |k| {
                    if (tri[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[tri[k]]) * 3;
                        if (v_idx + 2 >= t.verts.len) {
                            tri_ok = false;
                            break;
                        }
                        pts[k] = @ptrCast(&t.verts[v_idx]);
                    } else {
                        const d_idx = (@as(usize, pd.vert_base) + @as(usize, tri[k] - p.vert_count)) * 3;
                        if (d_idx + 2 >= t.detail_verts.len) {
                            tri_ok = false;
                            break;
                        }
                        pts[k] = @ptrCast(&t.detail_verts[d_idx]);
                    }
                }
                if (tri_ok) for (pts) |pt| dd.vertex(pt, ARTIFACT_HL_COL);
            }
        }
        dd.end();
        dd.depthMask(true);
    }

    // ========================================================================
    // RENDER
    // ========================================================================
    pub fn render(self: *SampleSolo) void {
        self.dd_gl.area_to_col = sample.sampleAreaToCol;
        const dd = self.dd_gl.debugDraw();

        // Culling включён ГЛОБАЛЬНО на весь кадр (как оригинал main.cpp: glEnable(GL_CULL_FACE)).
        // Применяется ко ВСЕМ draw'ам, включая воксели/навмеш — иначе двусторонние грани
        // соседних боксов z-fight'ят и дают «сетку из отдельных кубиков». Клавиша C меняет режим.
        // Воксели — полные боксы + back-cull (как оригинал): back-cull снимает совпадение
        // копланарных граней соседних боксов (одна отсекается -> нет z-fight), а боковые
        // грани остаются -> тонкая крыша видна с ребра.
        const voxel_mode = self.draw_mode == .voxels or self.draw_mode == .voxels_walkable;
        const vv: u8 = self.dd_gl.voxel_variant % 8; // вариант рендера вокселей (клавиша V)
        if (voxel_mode) {
            zgl.enable(.cull_face);
            zgl.cullFace(.back);
        } else switch (self.dd_gl.cull_mode) {
            1 => {
                zgl.enable(.cull_face);
                zgl.cullFace(.back);
            },
            2 => {
                zgl.enable(.cull_face);
                zgl.cullFace(.front);
            },
            else => zgl.disable(.cull_face),
        }

        // Инпут-меш как подложка (кроме navmesh_trans). Для вокселей варианты 1/3 — без меша.
        // Cluster E (P1-1): gated on the `input_mesh` group.
        const skip_mesh = voxel_mode and (vv == 1 or vv == 3);
        if (view_state.groups.input_mesh and self.draw_mode != .navmesh_trans and !skip_mesh) self.renderInputMesh(dd);

        // Применяем стейт ВАРИАНТА для отрисовки вокселей (после меша, до switch).
        if (voxel_mode) {
            self.dd_gl.enableFog(vv != 2 and vv != 3); // 2/3 — без тумана
            switch (vv) {
                4 => zgl.disable(.cull_face), // без culling
                5 => {
                    zgl.enable(.cull_face);
                    zgl.cullFace(.front);
                }, // front-cull
                6 => zgl.depthFunc(.less), // LESS вместо LEQUAL
                7 => zgl.disable(.blend), // без blend
                else => {}, // 0/1/2/3: back-cull + LEQUAL (умолчания)
            }
        }

        switch (self.draw_mode) {
            .mesh => {}, // уже нарисован подложкой
            // Туман как в оригинале: гасит контраст белые-фронты/серые-бока ступенчатых
            // вокселей -> выглядит однородно-сплошным (без тумана контраст читается как «полосы/просвет»).
            .voxels => if (self.hf) |*h| dbg.debugDrawHeightfieldSolid(dd, h),
            .voxels_walkable => if (self.hf) |*h| dbg.debugDrawHeightfieldWalkable(dd, h),
            .compact => if (self.chf) |*c| dbg.debugDrawCompactHeightfieldSolid(dd, c),
            .compact_distance => if (self.chf) |*c| dbg.debugDrawCompactHeightfieldDistance(dd, c),
            .compact_regions => if (self.chf) |*c| dbg.debugDrawCompactHeightfieldRegions(dd, c),
            // Оригинал: рисует цветные регионы compact-heightfield, затем дуги-связи поверх.
            .region_connections => {
                if (self.chf) |*c| dbg.debugDrawCompactHeightfieldRegions(dd, c);
                if (self.cset) |*c| {
                    dd.depthMask(false);
                    dbg.debugDrawRegionConnections(dd, c, 1.0);
                    dd.depthMask(true);
                }
            },
            .raw_contours => if (self.cset) |*c| dbg.debugDrawRawContours(dd, c, 1.0),
            .both_contours => if (self.cset) |*c| {
                dbg.debugDrawRawContours(dd, c, 0.5);
                dbg.debugDrawContours(dd, c, 1.0);
            },
            .contours => if (self.cset) |*c| dbg.debugDrawContours(dd, c, 1.0),
            .polymesh => if (self.pmesh) |*p| {
                if (p.nverts > 0 and p.npolys > 0) dbg.debugDrawPolyMesh(dd, p);
            },
            .polymesh_detail => if (self.dmesh) |*d| {
                if (d.nmeshes > 0) dbg.debugDrawPolyMeshDetail(dd, d);
            },
            .navmesh, .navmesh_trans => if (self.navmesh) |*n| {
                // Cluster E (P0-2/P1-1): navmesh group gate + wireframe/filter/faithful
                // routing centralised in drawNavmeshLayer.
                self.drawNavmeshLayer(dd, n);
            },
            // BVTree/Nodes: оригинал рисует САМ навмеш + overlay поверх (Sample_SoloMesh::render).
            .navmesh_bvtree => if (self.navmesh) |*n| {
                self.drawNavmeshLayer(dd, n);
                if (view_state.groups.navmesh) dbg.debugDrawNavMeshBVTree(dd, n);
            },
            .navmesh_nodes => if (self.navmesh) |*n| {
                self.drawNavmeshLayer(dd, n);
            },
        }

        // Тёмный оверлей на DISABLED-полигонах (Toggle Polys) — 1-в-1 Sample_SoloMesh::render
        // (duDebugDrawNavMeshPolysWithFlags(..., DISABLED, rgba(0,0,0,128))). Видно отключённые.
        // Gated under !filter.active(): the disabled overlay draws the FAITHFUL
        // (unclipped) navmesh and would visually fight the filtered/clipped draw.
        if (view_state.groups.navmesh and !filter_state.active.active()) switch (self.draw_mode) {
            .navmesh, .navmesh_trans, .navmesh_bvtree, .navmesh_nodes => if (self.navmesh) |*n|
                dbg.debugDrawNavMeshPolysWithFlags(dd, n, sample.SamplePolyFlags.disabled, dbg.rgba(0, 0, 0, 128)),
            else => {},
        };

        // Off-mesh connections and convex volumes are part of the scene and are
        // drawn regardless of the active tool (1:1 Sample::handleRender). The
        // tools only render their in-progress editing state.
        if (self.geom) |g| {
            // Mesh bounds wireframe (1:1 Sample::handleRender — duDebugDrawBoxWire,
            // white 255,255,255,128). Marks the 3D object's extent.
            dbg.debugDrawBoxWire(dd, g.bmin[0], g.bmin[1], g.bmin[2], g.bmax[0], g.bmax[1], g.bmax[2], dbg.rgba(255, 255, 255, 128), 1.0);
            // Cluster E (P1-1): convex / off-mesh gated on their groups.
            if (view_state.groups.convex) g.drawConvexVolumes(dd);
            if (view_state.groups.offmesh) g.drawOffMeshConnections(dd);
        }

        // ВОССТАНОВЛЕНИЕ GL-стейта после варианта вокселей — чтобы НЕ протекало в UI/др. режимы.
        if (voxel_mode) {
            self.dd_gl.enableFog(false);
            zgl.enable(.cull_face);
            zgl.cullFace(.back);
            zgl.depthFunc(.less_or_equal);
            zgl.enable(.blend);
            zgl.enable(.depth_test);
            zgl.depthMask(true);
        }
    }

    fn renderInputMesh(self: *SampleSolo, dd: dbg.DebugDraw) void {
        const geom = self.geom orelse return;
        const v = geom.verts.items;
        const t = geom.tris.items;
        const ng = geom.normals.items;
        // checker-текстура пола как в RecastDemo: масштаб 1/(cellSize*10).
        const ts = 1.0 / (self.settings.cell_size * 10.0);
        self.dd_gl.setTexScale(ts);
        dd.texture(true);
        // culling задан глобально в render() (как оригинал) — здесь не трогаем.

        // раскраска по склону (duDebugDrawTriMeshSlope): walkable -> серый с освещением,
        // unwalkable (крутые грани) -> подмешан tan(192,128,0). Это «текстурный» вид оригинала.
        const walkable_thr = @cos(self.settings.agent_max_slope * std.math.pi / 180.0);
        const unwalkable = dbg.rgba(192, 128, 0, 255);
        // Туман только на input-mesh (как Sample::render: glEnable/glDisable GL_FOG).
        self.dd_gl.enableFog(true);
        defer self.dd_gl.enableFog(false);
        // Polygon offset: отодвигаем input-mesh чуть в глубину, чтобы debug-оверлеи
        // (воксели/контуры/навмеш) НАДЁЖНО выигрывали depth на совпадающих высотах
        // (полы на кратных ch Y совпадают точь-в-точь -> иначе z-fight «стипплом»).
        zgl.enable(.polygon_offset_fill);
        zgl.polygonOffset(1.0, 1.0);
        defer zgl.disable(.polygon_offset_fill);
        dd.begin(.tris, 1.0);
        var i: usize = 0;
        while (i < t.len) : (i += 3) {
            const a: usize = @intCast(t[i]);
            const b: usize = @intCast(t[i + 1]);
            const c: usize = @intCast(t[i + 2]);
            const tri = i / 3;
            var n = [3]f32{ 0, 1, 0 };
            if (tri * 3 + 2 < ng.len) {
                n = .{ ng[tri * 3], ng[tri * 3 + 1], ng[tri * 3 + 2] };
            }
            const lit = std.math.clamp(220.0 * (2.0 + n[0] + n[1]) / 4.0, 0.0, 255.0);
            const av: u8 = @intFromFloat(lit);
            const gray = dbg.rgba(av, av, av, 255);
            const col = if (n[1] < walkable_thr) dbg.lerpCol(gray, unwalkable, 64) else gray;

            // Triplanar UV (1:1 duDebugDrawTriMesh): доминантная ось нормали → две
            // перпендикулярные оси как uv. Иначе стены смазаны вертикально (нет
            // горизонтальных линий сетки). ax=(dom+1)%3, ay=(ax+1)%3 == (1<<ax)&3.
            var dom: usize = 0;
            if (@abs(n[1]) > @abs(n[dom])) dom = 1;
            if (@abs(n[2]) > @abs(n[dom])) dom = 2;
            const ax: usize = (dom + 1) % 3;
            const ay: usize = (ax + 1) % 3;

            // Сырые оси: масштаб (ts) накладывает шейдер (vUV * uTexScale) — один раз,
            // как texScale в duDebugDrawTriMesh. Здесь НЕ умножаем (иначе ts² → клетки крупнее).
            self.dd_gl.vertexUV(v[a * 3], v[a * 3 + 1], v[a * 3 + 2], col, v[a * 3 + ax], v[a * 3 + ay]);
            self.dd_gl.vertexUV(v[b * 3], v[b * 3 + 1], v[b * 3 + 2], col, v[b * 3 + ax], v[b * 3 + ay]);
            self.dd_gl.vertexUV(v[c * 3], v[c * 3 + 1], v[c * 3 + 2], col, v[c * 3 + ax], v[c * 3 + ay]);
        }
        dd.end();
        dd.texture(false);
    }

    // ========================================================================
    // UI
    // ========================================================================
    fn drawSettings(self: *SampleSolo) void {
        const s = &self.settings;
        // воксельная сетка для строки "Voxels  W x H"
        var gw: i32 = 0;
        var gh: i32 = 0;
        if (self.geom) |g| {
            const bmin = Vec3.init(g.bmin[0], g.bmin[1], g.bmin[2]);
            const bmax = Vec3.init(g.bmax[0], g.bmax[1], g.bmax[2]);
            recast.RecastConfig.calcGridSize(bmin, bmax, s.cell_size, &gw, &gh);
        }
        sample.drawCommonSettings(s, gw, gh);

        if (dvui.button(@src(), "Save", .{}, .{})) self.saveNavMesh();
        if (dvui.button(@src(), "Load", .{}, .{})) self.loadNavMesh();
        dvui.label(@src(), "Build Time: {d:.1}ms", .{self.build_time_ms}, .{});
    }

    /// Build Inspector (B-1 + B-2): таблица из 7 стадий (счётчики + время) + total.
    /// При наличии предыдущей сборки и включённом чекбоксе — дополнительная строка
    /// со знаковой дельтой под каждой стадией + итоговая Δtotal.
    ///
    /// Build Inspector table: 7 stage rows (counts + ms) + total. When a previous
    /// build exists and "Show diff" is checked, an extra delta line is shown under
    /// each stage row, plus a Δtotal line.
    pub fn drawBuildInspector(self: *SampleSolo) void {
        ui.section(@src(), "Build Inspector");
        if (self.build_gen == 0) {
            dvui.labelNoFmt(@src(), "Build the Solo mesh to inspect stages.", .{}, .{ .id_extra = 7400 });
            return;
        }
        const bs = &self.build_stats;
        var buf: [160]u8 = undefined;
        inline for (0..build_stats.STAGE_COUNT) |i| {
            const stage: build_stats.Stage = @enumFromInt(i);
            const st = bs.stages[i];
            const row = build_stats.formatStageRow(&buf, stage, st);
            // N/A rows greyed; ran rows normal.
            const col: ?dvui.Color = if (st.ran) null else .{ .r = 140, .g = 140, .b = 140 };
            dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = 7410 + i, .color_text = col });

            // B-2: delta line below each stage row (shown only when diff is on + prev exists).
            if (self.show_build_diff) {
                if (self.prev_build_stats) |prev| {
                    var dbuf: [160]u8 = undefined;
                    const delta = build_stats.diffStage(prev.stages[i], bs.stages[i], stage);
                    const drow = build_stats.formatStageDelta(&dbuf, stage, delta);
                    // дельта-строки выводим немного светлее / delta rows slightly dimmed
                    dvui.labelNoFmt(@src(), drow, .{}, .{ .id_extra = 7430 + i, .color_text = .{ .r = 170, .g = 200, .b = 255 } });
                }
            }
        }
        dvui.label(@src(), "total: {d:.1}ms  ({s})", .{ bs.total_ms, @tagName(bs.partition) }, .{ .id_extra = 7420 });

        // B-2: "Show diff vs previous" checkbox + Δtotal line.
        _ = dvui.checkbox(@src(), &self.show_build_diff, "Show diff vs previous", .{ .id_extra = 7421 });
        if (self.show_build_diff) {
            if (self.prev_build_stats) |prev| {
                const delta_total = bs.total_ms - prev.total_ms;
                const sign: []const u8 = if (delta_total >= 0) "+" else "";
                dvui.label(@src(), "Δtotal: {s}{d:.1}ms", .{ sign, delta_total }, .{ .id_extra = 7422 });
            } else {
                dvui.labelNoFmt(@src(), "no previous build to diff", .{}, .{ .id_extra = 7423 });
            }
        }

        self.drawArtifactScan();
    }

    /// Build Profiler + Run History (C1). Таблица стадий выбранной сборки
    /// (label | ms | %), горизонтальный stacked-bar (доли стадий в палитре),
    /// sparkline total_ms по истории (новейший справа), селектор истории и
    /// кнопка Clear. История читается из кеша (наполняется раз на сборку).
    ///
    /// Stage table (label | ms | %), a horizontal stacked bar (stage fractions
    /// in the palette), a sparkline of total_ms across the run history, a history
    /// selector and a Clear button. Reads cached history (filled once per build).
    /// id_extra range 7490-7520 (no collision with B's 7400-7485).
    pub fn drawProfiler(self: *SampleSolo) void {
        ui.section(@src(), "Profiler");
        const hist = &self.profile_history;
        if (hist.len == 0) {
            dvui.labelNoFmt(@src(), "Build the Solo mesh to profile.", .{}, .{ .id_extra = 7490 });
            return;
        }

        // History selector (slider 0..len-1; default newest). Show its headline.
        if (hist.len > 1) {
            const maxf: f32 = @floatFromInt(hist.len - 1);
            if (self.profiler_sel > maxf) self.profiler_sel = maxf;
            ui.sliderInt(@src(), "history idx: {d:.0}", &self.profiler_sel, 0, maxf);
        } else {
            self.profiler_sel = 0;
        }
        const sel_i: usize = @intFromFloat(@round(std.math.clamp(self.profiler_sel, 0, @as(f32, @floatFromInt(hist.len - 1)))));
        const profile = hist.at(sel_i) orelse hist.newest().?;

        dvui.label(@src(), "build #{d}  ({s})  total {d:.1}ms  polys={d} regions={d}", .{
            profile.gen, @tagName(profile.partition), profile.total_ms, profile.n_polys, profile.n_regions,
        }, .{ .id_extra = 7491 });

        // Stage table: label | ms | % for each RAN stage, + a total row.
        var buf: [96]u8 = undefined;
        inline for (0..build_stats.STAGE_COUNT) |i| {
            const stage: build_stats.Stage = @enumFromInt(i);
            const label = build_stats.stageLabel(stage);
            if (profile.stage_ran[i]) {
                const pct = profiler.stagePercent(profile, stage);
                const row = std.fmt.bufPrint(&buf, "{s:<13} {d:>7.2}ms  {d:>5.1}%", .{ label, profile.stage_ms[i], pct }) catch buf[0..0];
                dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = 7492 + i, .color_text = profiler.stageColor(i) });
            } else {
                const row = std.fmt.bufPrint(&buf, "{s:<13}      N/A", .{label}) catch buf[0..0];
                dvui.labelNoFmt(@src(), row, .{}, .{ .id_extra = 7492 + i, .color_text = .{ .r = 140, .g = 140, .b = 140 } });
            }
        }
        dvui.label(@src(), "total         {d:>7.2}ms  100.0%", .{profile.total_ms}, .{ .id_extra = 7500 });

        // Stacked bar (full-width, ~16px). Grab a box rect and draw segments.
        {
            var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = 200, .h = 16 }, .expand = .horizontal, .id_extra = 7501 });
            const r = bar.data().rectScale().r;
            bar.deinit();
            profiler.drawStackedBar(profile, r.x, r.y, r.w, r.h);
        }

        // Sparkline of total_ms across the history (~30px), newest on the right.
        {
            var spark = dvui.box(@src(), .{ .dir = .horizontal }, .{ .min_size_content = .{ .w = 200, .h = 30 }, .expand = .horizontal, .id_extra = 7502 });
            const r = spark.data().rectScale().r;
            spark.deinit();
            profiler.drawSparkline(hist, r.x, r.y, r.w, r.h, .{ .r = 120, .g = 220, .b = 160, .a = 255 });
        }

        // min/max total over the history (sparkline scale labels).
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        for (0..hist.len) |i| {
            const t = hist.at(i).?.total_ms;
            if (t < lo) lo = t;
            if (t > hi) hi = t;
        }
        dvui.label(@src(), "history n={d}  total min {d:.1}ms / max {d:.1}ms", .{ hist.len, lo, hi }, .{ .id_extra = 7503 });

        if (dvui.button(@src(), "Clear history", .{}, .{ .id_extra = 7504 })) {
            self.profile_history.clear();
            self.profiler_sel = 0;
        }
    }

    /// Tiny-poly area threshold (XZ world units²): a fraction of a cell's area, so
    /// it scales with the build's cell size. Polys smaller than a sliver of one
    /// voxel are flagged as dust/slivers.
    fn tinyPolyThreshold(self: *SampleSolo) f32 {
        const cs = self.settings.cell_size;
        return 0.25 * cs * cs;
    }

    /// Build Artifact Detectors (B-3): "Scan artifacts" button runs analyze() on the
    /// current navmesh (NOT per frame), caches the report, then shows the counts +
    /// a "Highlight culprits" checkbox. Frees the previous report before re-scanning.
    fn drawArtifactScan(self: *SampleSolo) void {
        ui.section(@src(), "Artifacts (B-3)");
        const nm = if (self.navmesh) |*n| n else {
            dvui.labelNoFmt(@src(), "Build the navmesh to scan.", .{}, .{ .id_extra = 7470 });
            return;
        };

        if (dvui.button(@src(), "Scan artifacts", .{}, .{ .id_extra = 7471 })) {
            // Free the previous report before re-scanning (no leak / double-free).
            if (self.artifact_report) |*r| {
                r.deinit(self.alloc);
                self.artifact_report = null;
            }
            if (artifacts.analyze(nm, self.tinyPolyThreshold(), self.alloc)) |r| {
                self.artifact_report = r;
            } else |e| {
                self.bctx.context().log(.err, "Artifact scan failed: {s}", .{@errorName(e)});
            }
        }

        if (self.artifact_report) |*r| {
            dvui.label(@src(), "degenerate detail tris: {d}", .{r.degenerate_tris}, .{ .id_extra = 7472 });
            dvui.label(@src(), "tiny polys (<{d:.3}): {d}", .{ self.tinyPolyThreshold(), r.tiny_polys }, .{ .id_extra = 7473 });
            dvui.label(@src(), "dead-end polys: {d}", .{r.dead_end_polys}, .{ .id_extra = 7474 });
            dvui.label(@src(), "highlight list: {d}/{d}", .{ r.culprits.items.len, artifacts.MAX_CULPRITS }, .{ .id_extra = 7475 });
            _ = dvui.checkbox(@src(), &self.highlight_culprits, "Highlight culprits", .{ .id_extra = 7476 });
        } else {
            dvui.labelNoFmt(@src(), "press Scan to run detectors", .{}, .{ .id_extra = 7477 });
        }
    }

    const SAVE_PATH = "solo_navmesh.bin";

    fn saveNavMesh(self: *SampleSolo) void {
        const nm = if (self.navmesh) |*n| n else {
            self.bctx.context().log(.err, "Save: no navmesh", .{});
            return;
        };
        nav_io.save(self.alloc, SAVE_PATH, nm) catch |e| {
            self.bctx.context().log(.err, "Save failed: {s}", .{@errorName(e)});
            return;
        };
        self.bctx.context().log(.progress, "Saved {s}", .{SAVE_PATH});
    }

    fn loadNavMesh(self: *SampleSolo) void {
        const loaded = nav_io.load(self.alloc, SAVE_PATH) catch |e| {
            self.bctx.context().log(.err, "Load failed: {s}", .{@errorName(e)});
            return;
        };
        self.cleanup(); // освобождаем старый navmesh + промежуточные результаты
        self.navmesh = loaded;
        self.build_gen +%= 1; // тулзы пересоберут query
        self.draw_mode = .navmesh;
        self.bctx.context().log(.progress, "Loaded {s}", .{SAVE_PATH});
    }

    fn drawDebugMode(self: *SampleSolo) void {
        dvui.labelNoFmt(@src(), "Draw", .{}, .{});
        const has_nav = self.navmesh != null;
        const has_hf = self.hf != null;
        const has_chf = self.chf != null;
        const has_cset = self.cset != null;
        const has_pm = self.pmesh != null;
        const has_dm = self.dmesh != null;
        // (label, mode, доступность) — порядок и тексты как в Sample_SoloMesh::drawDebugUI
        self.dmOpt("Input Mesh", .mesh, self.geom != null, 0);
        self.dmOpt("Navmesh", .navmesh, has_nav, 1);
        self.dmOpt("Navmesh Trans", .navmesh_trans, has_nav, 2);
        self.dmOpt("Navmesh BVTree", .navmesh_bvtree, has_nav, 3);
        self.dmOpt("Navmesh Nodes", .navmesh_nodes, has_nav, 4);
        self.dmOpt("Voxels", .voxels, has_hf, 5);
        self.dmOpt("Walkable Voxels", .voxels_walkable, has_hf, 6);
        self.dmOpt("Compact", .compact, has_chf, 7);
        self.dmOpt("Compact Distance", .compact_distance, has_chf, 8);
        self.dmOpt("Compact Regions", .compact_regions, has_chf, 9);
        self.dmOpt("Region Connections", .region_connections, has_cset, 10);
        self.dmOpt("Raw Contours", .raw_contours, has_cset, 11);
        self.dmOpt("Both Contours", .both_contours, has_cset, 12);
        self.dmOpt("Contours", .contours, has_cset, 13);
        self.dmOpt("Poly Mesh", .polymesh, has_pm, 14);
        self.dmOpt("Poly Mesh Detail", .polymesh_detail, has_dm, 15);
    }

    fn dmOpt(self: *SampleSolo, label: []const u8, mode: DrawMode, avail: bool, id: usize) void {
        if (!avail) return;
        if (ui.radio(@src(), self.draw_mode == mode, label, id)) self.draw_mode = mode;
    }
};
