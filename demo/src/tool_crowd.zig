//! CrowdTool — управление толпой агентов (detour_crowd).
//! Порт RecastDemo/Tool_Crowd (core: add agent, move target, симуляция, рендер).

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ddgl = @import("debug_draw_gl.zig");
const ui = @import("ui.zig");
const sample = @import("sample.zig");

const dt = recast.detour;
const dc = recast.detour_crowd;
const dbg = recast.debug;
const UF = dc.UpdateFlags;

pub const ToolMode = enum { create, move_target, select, toggle_polys };

const AGENT_MAX_TRAIL = 48;
const MAX_AGENTS = 128;
const AgentTrail = struct {
    trail: [AGENT_MAX_TRAIL * 3]f32 = [_]f32{0} ** (AGENT_MAX_TRAIL * 3),
    htrail: usize = 0,
};

pub const CrowdTool = struct {
    alloc: std.mem.Allocator,
    dd_gl: *ddgl.DebugDrawGL,

    navmesh: ?*dt.NavMesh = null,
    crowd: ?dc.Crowd = null,
    query: ?*dt.NavMeshQuery = null,
    filter: dt.QueryFilter,
    running: bool = true,
    agent_count: usize = 0,
    selected: ?usize = null,

    mode: ToolMode = .create,
    // Options (update_flags)
    opt_vis: bool = true,
    opt_topo: bool = true,
    anticipate: bool = true,
    obstacle_avoid: bool = true,
    separation: bool = false,
    avoidance_quality: f32 = 1, // 1-в-1 CrowdToolParams.obstacleAvoidanceType=1 (Medium)
    separation_weight: f32 = 2.0,
    // Debug draw (визуальные флаги — состояние)
    show_corners: bool = false,
    show_collision: bool = false,
    show_path: bool = false,
    show_vo: bool = false,
    show_opt: bool = false,
    show_neighbors: bool = false,
    show_labels: bool = false,
    show_grid: bool = false,
    show_nodes: bool = false,
    show_detail_all: bool = false, // 1-в-1 Tool_Crowd.h:38 (showDetailAll=false). При true detail+float
    // рисуются для ВСЕХ агентов -> разные значения дистанции накладываются в общих точках -> каша.
    // След агентов (история позиций) + текущая цель (для креста).
    trails: [MAX_AGENTS]AgentTrail = [_]AgentTrail{.{}} ** MAX_AGENTS,
    target_pos: [3]f32 = .{ 0, 0, 0 },
    has_target: bool = false,
    // Габариты агента (из sample settings, как sample->agentRadius/Height в оригинале).
    agent_radius: f32 = 0.6,
    agent_height: f32 = 2.0,
    // Debug-инфо выделенного агента (VO-сэмплы / path-opt).
    debug: dc.CrowdAgentDebugInfo = .{},
    vod: ?dc.ObstacleAvoidanceDebugData = null,
    dbg_frame: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, dd_gl: *ddgl.DebugDrawGL) CrowdTool {
        return .{ .alloc = alloc, .dd_gl = dd_gl, .filter = dt.QueryFilter.init() };
    }

    pub fn deinit(self: *CrowdTool) void {
        if (self.crowd) |*c| c.deinit();
        if (self.query) |q| q.deinit();
        if (self.vod) |*v| v.deinit();
        self.crowd = null;
        self.query = null;
        self.vod = null;
    }

    pub fn setNavMesh(self: *CrowdTool, nm: ?*dt.NavMesh) void {
        if (self.crowd) |*c| c.deinit();
        if (self.query) |q| q.deinit();
        self.crowd = null;
        self.query = null;
        self.agent_count = 0;
        self.navmesh = nm;
        if (self.vod) |*v| v.deinit();
        self.vod = null;
        if (nm) |m| {
            self.crowd = dc.Crowd.init(self.alloc, 128, 0.6, m) catch null;
            self.vod = dc.ObstacleAvoidanceDebugData.init(self.alloc, 2048) catch null;
            // Фильтр толпы исключает DISABLED-полигоны (как RecastDemo): иначе Toggle Polys
            // не блокирует проход — отключённый поли всё равно проходит фильтр.
            if (self.crowd) |*cc| {
                if (cc.getEditableFilter(0)) |f| {
                    f.setIncludeFlags(0xffff ^ sample.SamplePolyFlags.disabled);
                    f.setExcludeFlags(sample.SamplePolyFlags.disabled);
                }
                // 4 пресета obstacle-avoidance (Avoidance Quality 0..3) — 1-в-1
                // CrowdToolState::init (Tool_Crowd.cpp:134-165). Базируются на дефолте dtCrowd,
                // меняются только velBias + adaptive divs/rings/depth. Без этого слайдер
                // Avoidance Quality переключал бы 4 ИДЕНТИЧНЫХ пресета (ноль эффекта).
                var p = dc.ObstacleAvoidanceParams.init();
                p.vel_bias = 0.5;
                // Low (0): divs=5 rings=2 depth=1
                p.adaptive_divs = 5;
                p.adaptive_rings = 2;
                p.adaptive_depth = 1;
                cc.setObstacleAvoidanceParams(0, &p);
                // Medium (1): divs=5 rings=2 depth=2
                p.adaptive_divs = 5;
                p.adaptive_rings = 2;
                p.adaptive_depth = 2;
                cc.setObstacleAvoidanceParams(1, &p);
                // Good (2): divs=7 rings=2 depth=3
                p.adaptive_divs = 7;
                p.adaptive_rings = 2;
                p.adaptive_depth = 3;
                cc.setObstacleAvoidanceParams(2, &p);
                // High (3): divs=7 rings=3 depth=3
                p.adaptive_divs = 7;
                p.adaptive_rings = 3;
                p.adaptive_depth = 3;
                cc.setObstacleAvoidanceParams(3, &p);
            }
            var q = dt.NavMeshQuery.init(self.alloc) catch return;
            q.initQuery(m, 2048) catch {
                q.deinit();
                return;
            };
            self.query = q;
        }
    }

    fn buildParams(self: *CrowdTool) dc.CrowdAgentParams {
        // 1-в-1 с CrowdToolState::addAgent (Tool_Crowd.cpp): габариты из sample,
        // collisionQueryRange = radius*12, pathOptimizationRange = radius*30.
        var p = dc.CrowdAgentParams.init();
        p.radius = self.agent_radius;
        p.height = self.agent_height;
        p.max_acceleration = 8.0;
        p.max_speed = 3.5;
        p.collision_query_range = p.radius * 12.0;
        p.path_optimization_range = p.radius * 30.0;
        var f: u8 = 0;
        if (self.anticipate) f |= UF.anticipate_turns;
        if (self.obstacle_avoid) f |= UF.obstacle_avoid;
        if (self.separation) f |= UF.separation;
        if (self.opt_vis) f |= UF.optimize_vis;
        if (self.opt_topo) f |= UF.optimize_topo;
        p.update_flags = f;
        p.obstacle_avoidance_type = @intFromFloat(self.avoidance_quality);
        p.separation_weight = self.separation_weight;
        return p;
    }

    /// Применяет текущие Options ко ВСЕМ уже созданным агентам — 1-в-1
    /// CrowdToolState::updateAgentParams (Tool_Crowd.cpp:922-945). Вызывается при изменении
    /// любой опции (иначе переключение опции не влияло бы на существующих агентов).
    fn applyOptions(self: *CrowdTool) void {
        const c = if (self.crowd) |*cc| cc else return;
        var flags: u8 = 0;
        if (self.anticipate) flags |= UF.anticipate_turns;
        if (self.obstacle_avoid) flags |= UF.obstacle_avoid;
        if (self.separation) flags |= UF.separation;
        if (self.opt_vis) flags |= UF.optimize_vis;
        if (self.opt_topo) flags |= UF.optimize_topo;
        const oa_type: u8 = @intFromFloat(self.avoidance_quality);
        for (0..self.agent_count) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            var p = ag.params; // копия, как memcpy в оригинале
            p.update_flags = flags;
            p.obstacle_avoidance_type = oa_type;
            p.separation_weight = self.separation_weight;
            c.updateAgentParameters(@intCast(i), &p);
        }
    }

    /// Один шаг симуляции + пауза — 1-в-1 CrowdTool::singleStep (Tool_Crowd.cpp:1146-1157).
    pub fn singleStep(self: *CrowdTool) void {
        self.running = true;
        self.update(1.0 / 20.0);
        self.running = false;
    }

    pub fn onClick(self: *CrowdTool, _: *const [3]f32, ray_hit: *const [3]f32, shift: bool) void {
        const c = if (self.crowd) |*cc| cc else return;
        if (self.mode == .create) {
            // 1-в-1 с Tool_Crowd: ЛКМ — добавить агента, Shift+ЛКМ — удалить ближайшего.
            if (shift) {
                var best: ?usize = null;
                var best_d: f32 = std.math.floatMax(f32);
                for (0..self.agent_count) |i| {
                    const ag = c.getAgent(@intCast(i)) orelse continue;
                    if (!ag.active) continue;
                    const dx = ag.npos[0] - ray_hit[0];
                    const dz = ag.npos[2] - ray_hit[2];
                    const d = dx * dx + dz * dz;
                    if (d < best_d) {
                        best_d = d;
                        best = i;
                    }
                }
                if (best) |bi| c.removeAgent(@intCast(bi));
            } else {
                var params = self.buildParams();
                _ = c.addAgent(ray_hit, &params) catch {};
                self.agent_count = c.getAgentCount();
            }
        } else if (self.mode == .move_target) {
            if (shift) {
                // Shift+ЛКМ = velocity-move БЕЗ pathfinder (setMoveTarget adjust=true в оригинале):
                // requestMoveVelocity -> target_state=velocity -> агент ЗЕЛЁНЫЙ, идёт напрямую.
                for (0..self.agent_count) |i| {
                    const ag = c.getAgent(@intCast(i)) orelse continue;
                    if (!ag.active) continue;
                    var vel = [3]f32{ ray_hit[0] - ag.npos[0], ray_hit[1] - ag.npos[1], ray_hit[2] - ag.npos[2] };
                    const len = @sqrt(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);
                    if (len > 0.0001) {
                        const s = ag.params.max_speed / len;
                        vel[0] *= s;
                        vel[1] *= s;
                        vel[2] *= s;
                    }
                    _ = c.requestMoveVelocity(@intCast(i), &vel);
                }
            } else {
                // ЛКМ — назначить цель (pathfinding) ВСЕМ агентам.
                const q = self.query orelse return;
                const ext = [3]f32{ 2, 4, 2 };
                var ref: dt.PolyRef = 0;
                var snapped: [3]f32 = undefined;
                _ = q.findNearestPoly(ray_hit, &ext, &self.filter, &ref, &snapped) catch {};
                if (ref != 0) {
                    for (0..self.agent_count) |i| _ = c.requestMoveTarget(@intCast(i), ref, &snapped);
                    self.target_pos = snapped;
                    self.has_target = true;
                }
            }
        } else if (self.mode == .toggle_polys) {
            // переключить флаг disabled у полигона под кликом
            const q = self.query orelse return;
            const nm = self.navmesh orelse return;
            const ext = [3]f32{ 2, 4, 2 };
            var ref: dt.PolyRef = 0;
            var snapped: [3]f32 = undefined;
            _ = q.findNearestPoly(ray_hit, &ext, &self.filter, &ref, &snapped) catch {};
            if (ref != 0) {
                const flags = nm.getPolyFlags(ref) catch return;
                nm.setPolyFlags(ref, flags ^ sample.SamplePolyFlags.disabled) catch {};
            }
        } else if (self.mode == .select) {
            // выбрать ближайшего агента к точке клика
            var best: ?usize = null;
            var best_d: f32 = std.math.floatMax(f32);
            for (0..self.agent_count) |i| {
                const ag = c.getAgent(@intCast(i)) orelse continue;
                if (!ag.active) continue;
                const dx = ag.npos[0] - ray_hit[0];
                const dz = ag.npos[2] - ray_hit[2];
                const d = dx * dx + dz * dz;
                if (d < best_d) {
                    best_d = d;
                    best = i;
                }
            }
            self.selected = best;
        }
    }

    pub fn update(self: *CrowdTool, delta: f32) void {
        if (!self.running) return;
        if (self.crowd) |*c| {
            // Прокидываем debug-инфо выделенного агента (для VO / path-opt визуализации).
            self.debug.idx = if (self.selected) |s| @intCast(s) else -1;
            if (self.vod) |*v| {
                self.debug.vod = v;
            } else self.debug.vod = null;
            c.updateDebug(delta, &self.debug) catch {};
            // Запись следа (как CrowdToolState::handleUpdate): кольцевой буфер позиций.
            for (0..self.agent_count) |i| {
                const ag = c.getAgent(@intCast(i)) orelse continue;
                if (!ag.active) continue;
                var t = &self.trails[i];
                t.htrail = (t.htrail + 1) % AGENT_MAX_TRAIL;
                t.trail[t.htrail * 3 + 0] = ag.npos[0];
                t.trail[t.htrail * 3 + 1] = ag.npos[1];
                t.trail[t.htrail * 3 + 2] = ag.npos[2];
            }
        }
    }

    /// Цвет агента по target_state (база светло-серая, тонируется) — 1-в-1 с CrowdTool.
    fn agentCol(ag: anytype, a: u8) u32 {
        const base = dbg.rgba(220, 220, 220, a);
        return switch (ag.target_state) {
            .target_requesting, .target_waiting_for_queue => dbg.lerpCol(base, dbg.rgba(128, 0, 255, a), 32),
            .target_waiting_for_path => dbg.lerpCol(base, dbg.rgba(128, 0, 255, a), 128),
            .target_failed => dbg.rgba(255, 32, 16, a),
            .target_velocity => dbg.lerpCol(base, dbg.rgba(64, 255, 0, a), 128),
            else => base,
        };
    }

    pub fn render(self: *CrowdTool) void {
        const c = if (self.crowd) |*cc| cc else return;
        const dd = self.dd_gl.debugDraw();
        const n = self.agent_count;

        // Show Nodes — узлы A*-поиска из navquery очереди путей (как duDebugDrawNavMeshNodes).
        if (self.show_nodes) dbg.debugDrawNavMeshNodes(dd, c.getPathQueueNavQuery());

        dd.depthMask(false);

        // Show Path — полигоны коридора подсвечены (rgba(255,255,255,24)).
        // 1-в-1 Tool_Crowd.cpp:195 — guard showDetailAll: только выделенный, если detail-all выкл.
        if (self.show_path) {
            if (self.navmesh) |m| {
                for (0..n) |i| {
                    if (!self.show_detail_all and @as(i32, @intCast(i)) != self.debug.idx) continue;
                    const ag = c.getAgent(@intCast(i)) orelse continue;
                    if (!ag.active) continue;
                    const path = ag.corridor.getPath();
                    for (0..ag.corridor.getPathCount()) |j| dbg.debugDrawNavMeshPoly(dd, m, path[j], dbg.rgba(255, 255, 255, 24));
                }
            }
        }

        // Цель (крест).
        if (self.has_target) {
            dd.begin(.lines, 2.0);
            dbg.appendCross(dd, self.target_pos[0], self.target_pos[1] + 0.1, self.target_pos[2], 0.6, dbg.rgba(255, 255, 255, 192));
            dd.end();
        }

        // Show Prox Grid — прокси-сетка квадами по числу объектов в ячейке.
        if (self.show_grid) {
            var gridy: f32 = -std.math.floatMax(f32);
            for (0..n) |i| {
                const ag = c.getAgent(@intCast(i)) orelse continue;
                if (ag.active) gridy = @max(gridy, ag.npos[1]);
            }
            gridy += 1.0;
            const grid = c.getGrid();
            const b = grid.getBounds();
            const cs = grid.getCellSize();
            dd.begin(.quads, 1.0);
            var y: i32 = b[1];
            while (y <= b[3]) : (y += 1) {
                var x: i32 = b[0];
                while (x <= b[2]) : (x += 1) {
                    const cnt = grid.getItemCountAt(x, y);
                    if (cnt == 0) continue;
                    const col = dbg.rgba(128, 0, 0, @intCast(@min(cnt * 40, 255)));
                    const fx = @as(f32, @floatFromInt(x)) * cs;
                    const fy = @as(f32, @floatFromInt(y)) * cs;
                    dd.vertexXYZ(fx, gridy, fy, col);
                    dd.vertexXYZ(fx, gridy, fy + cs, col);
                    dd.vertexXYZ(fx + cs, gridy, fy + cs, col);
                    dd.vertexXYZ(fx + cs, gridy, fy, col);
                }
            }
            dd.end();
        }

        // След (trail) — затухающие чёрные линии, всегда.
        for (0..n) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const t = &self.trails[i];
            dd.begin(.lines, 3.0);
            var prev = ag.npos;
            var preva: f32 = 1.0;
            var j: usize = 0;
            while (j < AGENT_MAX_TRAIL - 1) : (j += 1) {
                const idx = (t.htrail + AGENT_MAX_TRAIL - j) % AGENT_MAX_TRAIL;
                const v = t.trail[idx * 3 ..][0..3];
                const a = 1.0 - @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(AGENT_MAX_TRAIL));
                dd.vertexXYZ(prev[0], prev[1] + 0.1, prev[2], dbg.rgba(0, 0, 0, @intFromFloat(128.0 * preva)));
                dd.vertexXYZ(v[0], v[1] + 0.1, v[2], dbg.rgba(0, 0, 0, @intFromFloat(128.0 * a)));
                preva = a;
                prev = .{ v[0], v[1], v[2] };
            }
            dd.end();
        }

        // Show VO — сэмплы obstacle-avoidance. 1-в-1 Tool_Crowd.cpp:481-520: цикл по ВСЕМ
        // агентам с guard showDetailAll. vod — единый буфер, заполнен сэмплами ТОЛЬКО
        // выделенного агента (DetourCrowd.cpp:1286 vod=debug->vod при debugIdx==i), поэтому
        // при detail-all одно и то же облако штрафов рисуется в позиции каждого агента.
        if (self.show_vo) {
            if (self.vod) |*vod| {
                vod.normalizeSamples(); // нормализуем штрафы в [0,1] (как оригинал)
                for (0..n) |i| {
                    if (!self.show_detail_all and @as(i32, @intCast(i)) != self.debug.idx) continue;
                    const ag = c.getAgent(@intCast(i)) orelse continue;
                    if (!ag.active) continue;
                    const dx = ag.npos[0];
                    const dy = ag.npos[1] + ag.params.height;
                    const dz = ag.npos[2];
                    dd.begin(.lines, 2.0);
                    dbg.appendCircle(dd, dx, dy, dz, ag.params.max_speed, dbg.rgba(255, 255, 255, 64));
                    dd.end();
                    dd.begin(.quads, 1.0);
                    for (0..vod.nsamples) |j| {
                        const p = vod.vel[j * 3 ..][0..3];
                        const sr = vod.ssize[j];
                        const pen: u32 = @intFromFloat(std.math.clamp(vod.pen[j], 0, 1) * 255);
                        const pen2: u32 = @intFromFloat(std.math.clamp(vod.spen[j], 0, 1) * 128);
                        var col = dbg.lerpCol(dbg.rgba(255, 255, 255, 220), dbg.rgba(128, 96, 0, 220), pen);
                        col = dbg.lerpCol(col, dbg.rgba(128, 0, 0, 220), pen2);
                        dd.vertexXYZ(dx + p[0] - sr, dy, dz + p[2] - sr, col);
                        dd.vertexXYZ(dx + p[0] - sr, dy, dz + p[2] + sr, col);
                        dd.vertexXYZ(dx + p[0] + sr, dy, dz + p[2] + sr, col);
                        dd.vertexXYZ(dx + p[0] + sr, dy, dz + p[2] - sr, col);
                    }
                    dd.end();
                }
            }
        }

        // Show Path Optimization — отрезок оптимизации видимости (optStart->optEnd).
        if (self.show_opt) {
            const os = self.debug.opt_start;
            const oe = self.debug.opt_end;
            if (!(os[0] == 0 and os[2] == 0 and oe[0] == 0 and oe[2] == 0)) {
                dd.begin(.lines, 2.0);
                dd.vertexXYZ(os[0], os[1] + 0.3, os[2], dbg.rgba(0, 128, 0, 192));
                dd.vertexXYZ(oe[0], oe[1] + 0.3, oe[2], dbg.rgba(0, 128, 0, 192));
                dd.end();
            }
        }

        // Corners / Collision Segments / Neighbors (per agent). 1-в-1 Tool_Crowd.cpp:295-297 —
        // guard showDetailAll: detail рисуется только для выделенного, если detail-all выкл.
        for (0..n) |i| {
            if (!self.show_detail_all and @as(i32, @intCast(i)) != self.debug.idx) continue;
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const radius = ag.params.radius;
            const pos = ag.npos;

            if (self.show_corners and ag.ncorners > 0) {
                dd.begin(.lines, 2.0);
                for (0..ag.ncorners) |j| {
                    const va: [3]f32 = if (j == 0) pos else .{ ag.corner_verts[(j - 1) * 3], ag.corner_verts[(j - 1) * 3 + 1], ag.corner_verts[(j - 1) * 3 + 2] };
                    const vb = ag.corner_verts[j * 3 ..][0..3];
                    dd.vertexXYZ(va[0], va[1] + radius, va[2], dbg.rgba(128, 0, 0, 192));
                    dd.vertexXYZ(vb[0], vb[1] + radius, vb[2], dbg.rgba(128, 0, 0, 192));
                }
                // off-mesh маркер на последнем углу (как оригинал): вертикаль rgba(192,0,0,192) h=radius*2.
                if ((ag.corner_flags[ag.ncorners - 1] & 0x04) != 0) { // DT_STRAIGHTPATH_OFFMESH_CONNECTION
                    const v = ag.corner_verts[(ag.ncorners - 1) * 3 ..][0..3];
                    dd.vertexXYZ(v[0], v[1], v[2], dbg.rgba(192, 0, 0, 192));
                    dd.vertexXYZ(v[0], v[1] + radius * 2, v[2], dbg.rgba(192, 0, 0, 192));
                }
                dd.end();
            }

            if (self.show_collision) {
                const ctr = ag.boundary.getCenter();
                dd.begin(.lines, 2.0);
                dbg.appendCross(dd, ctr[0], ctr[1] + radius, ctr[2], 0.2, dbg.rgba(192, 0, 128, 255));
                dbg.appendCircle(dd, ctr[0], ctr[1] + radius, ctr[2], ag.params.collision_query_range, dbg.rgba(192, 0, 128, 128));
                dd.end();
                dd.begin(.lines, 3.0);
                for (0..ag.boundary.getSegmentCount()) |j| {
                    const s = ag.boundary.getSegment(j);
                    const area = (s[0] - pos[0]) * (s[5] - pos[2]) - (s[3] - pos[0]) * (s[2] - pos[2]);
                    var col = dbg.rgba(192, 0, 128, 192);
                    if (area < 0.0) col = dbg.darkenCol(col);
                    dbg.appendArc(dd, s[0], s[1] + 0.2, s[2], s[3], s[4] + 0.2, s[5], 0.0, 0.0, 0.3, col);
                }
                dd.end();
            }

            if (self.show_neighbors) {
                dd.begin(.lines, 2.0);
                dbg.appendCircle(dd, pos[0], pos[1] + radius, pos[2], ag.params.collision_query_range, dbg.rgba(0, 192, 128, 128));
                for (0..ag.nneis) |j| {
                    const nag = c.getAgent(@intCast(ag.neis[j].idx)) orelse continue;
                    dd.vertexXYZ(pos[0], pos[1] + radius, pos[2], dbg.rgba(0, 192, 128, 128));
                    dd.vertexXYZ(nag.npos[0], nag.npos[1] + radius, nag.npos[2], dbg.rgba(0, 192, 128, 128));
                }
                dd.end();
            }
        }

        // Кольцо на земле (тёмное / красное у выделенного).
        for (0..n) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const col = if (self.selected == i) dbg.rgba(255, 0, 0, 128) else dbg.rgba(0, 0, 0, 32);
            dd.begin(.lines, 2.0);
            dbg.appendCircle(dd, ag.npos[0], ag.npos[1], ag.npos[2], ag.params.radius, col);
            dd.end();
        }

        // Солидные цилиндры (цвет по состоянию).
        for (0..n) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const r = ag.params.radius;
            const hh = ag.params.height;
            const col = agentCol(ag, 128);
            dd.begin(.tris, 1.0);
            dbg.appendCylinder(dd, ag.npos[0] - r, ag.npos[1] + r * 0.1, ag.npos[2] - r, ag.npos[0] + r, ag.npos[1] + hh, ag.npos[2] + r, col);
            dd.end();
        }

        // Скорость: кольцо сверху + стрелки dvel(синяя)/vel(чёрная).
        for (0..n) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const r = ag.params.radius;
            const by = ag.npos[1] + ag.params.height;
            const col = agentCol(ag, 192);
            dd.begin(.lines, 2.0);
            dbg.appendCircle(dd, ag.npos[0], by, ag.npos[2], r, col);
            dbg.appendArc(dd, ag.npos[0], by, ag.npos[2], ag.npos[0] + ag.dvel[0], by + ag.dvel[1], ag.npos[2] + ag.dvel[2], 0.0, 0.0, 0.4, dbg.rgba(0, 192, 255, 192));
            dbg.appendArc(dd, ag.npos[0], by, ag.npos[2], ag.npos[0] + ag.vel[0], by + ag.vel[1], ag.npos[2] + ag.vel[2], 0.0, 0.0, 0.4, dbg.rgba(0, 0, 0, 160));
            dd.end();
        }

        dd.depthMask(true);
    }

    pub fn drawMenu(self: *CrowdTool) void {
        if (ui.radio(@src(), self.mode == .create, "Create Agents", 0)) self.mode = .create;
        if (ui.radio(@src(), self.mode == .move_target, "Move Target", 1)) self.mode = .move_target;
        if (ui.radio(@src(), self.mode == .select, "Select Agent", 2)) self.mode = .select;
        if (ui.radio(@src(), self.mode == .toggle_polys, "Toggle Polys", 3)) self.mode = .toggle_polys;
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        if (ui.treeNode(@src(), "Options")) {
            // 1-в-1 порядок и виджеты Tool_Crowd.cpp:1037-1043. Любое изменение -> реапплай
            // ко всем существующим агентам (paramsChanged -> updateAgentParams).
            var changed = false;
            changed = dvui.checkbox(@src(), &self.opt_vis, "Optimize Visibility", .{}) or changed;
            changed = dvui.checkbox(@src(), &self.opt_topo, "Optimize Topology", .{}) or changed;
            changed = dvui.checkbox(@src(), &self.anticipate, "Anticipate Turns", .{}) or changed;
            changed = dvui.checkbox(@src(), &self.obstacle_avoid, "Obstacle Avoidance", .{}) or changed;
            changed = dvui.sliderEntry(@src(), "Avoidance Quality: {d:.0}", .{ .value = &self.avoidance_quality, .min = 0, .max = 3, .interval = 1 }, .{ .expand = .horizontal }) or changed;
            changed = dvui.checkbox(@src(), &self.separation, "Separation", .{}) or changed;
            changed = dvui.sliderEntry(@src(), "Separation Weight = {d:.2}", .{ .value = &self.separation_weight, .min = 0.0, .max = 20.0, .interval = null }, .{ .expand = .horizontal }) or changed;
            if (changed) self.applyOptions();
        }
        if (ui.treeNode(@src(), "Selected Debug Draw")) {
            _ = dvui.checkbox(@src(), &self.show_corners, "Show Corners", .{});
            _ = dvui.checkbox(@src(), &self.show_collision, "Show Collision Segments", .{});
            _ = dvui.checkbox(@src(), &self.show_path, "Show Path", .{});
            _ = dvui.checkbox(@src(), &self.show_vo, "Show VO", .{});
            _ = dvui.checkbox(@src(), &self.show_opt, "Show Path Optimization", .{});
            _ = dvui.checkbox(@src(), &self.show_neighbors, "Show Neighbors", .{});
        }
        if (ui.treeNode(@src(), "Debug Draw")) {
            _ = dvui.checkbox(@src(), &self.show_labels, "Show Labels", .{});
            _ = dvui.checkbox(@src(), &self.show_grid, "Show Prox Grid", .{});
            _ = dvui.checkbox(@src(), &self.show_nodes, "Show Nodes", .{});
            _ = dvui.checkbox(@src(), &self.show_detail_all, "Show Detail All", .{});
        }

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
        // Чекбокса "Run" нет (как в оригинале) — пауза/шаг управляются хоткеями SPACE / "1".
        dvui.label(@src(), "{s}  (SPACE: run/pause, 1: step)", .{if (self.running) "- RUNNING -" else "- PAUSED -"}, .{});
        dvui.label(@src(), "agents: {d}", .{self.agent_count}, .{});
        const hint = switch (self.mode) {
            .create => "LMB: add agent   Shift+LMB: remove agent",
            .move_target => "LMB: set target   Shift+LMB: set velocity",
            .select => "LMB: select agent",
            .toggle_polys => "LMB: toggle poly enabled/disabled",
        };
        dvui.labelNoFmt(@src(), hint, .{}, .{});
    }
};

fn drawAgent(dd: dbg.DebugDraw, pos: [3]f32, radius: f32, height: f32, col: u32) void {
    const segs = 16;
    dd.begin(.lines, 1.0);
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a0 = @as(f32, @floatFromInt(i)) / segs * std.math.tau;
        const a1 = @as(f32, @floatFromInt(i + 1)) / segs * std.math.tau;
        // нижняя окружность
        dd.vertexXYZ(pos[0] + @cos(a0) * radius, pos[1], pos[2] + @sin(a0) * radius, col);
        dd.vertexXYZ(pos[0] + @cos(a1) * radius, pos[1], pos[2] + @sin(a1) * radius, col);
        // верхняя окружность
        dd.vertexXYZ(pos[0] + @cos(a0) * radius, pos[1] + height, pos[2] + @sin(a0) * radius, col);
        dd.vertexXYZ(pos[0] + @cos(a1) * radius, pos[1] + height, pos[2] + @sin(a1) * radius, col);
    }
    // вертикальные рёбра
    dd.vertexXYZ(pos[0] + radius, pos[1], pos[2], col);
    dd.vertexXYZ(pos[0] + radius, pos[1] + height, pos[2], col);
    dd.vertexXYZ(pos[0] - radius, pos[1], pos[2], col);
    dd.vertexXYZ(pos[0] - radius, pos[1] + height, pos[2], col);
    dd.end();
}
