//! CrowdTool — управление толпой агентов (detour_crowd).
//! Порт RecastDemo/Tool_Crowd (core: add agent, move target, симуляция, рендер).

const std = @import("std");
const dvui = @import("dvui");
const recast = @import("recast-nav");
const ddgl = @import("debug_draw_gl.zig");
const ui = @import("ui.zig");
const sample = @import("sample.zig");
const area_types = @import("area_types.zig");
const vh_mod = @import("value_history.zig");
const ValueHistory = vh_mod.ValueHistory;
const io_util = @import("io_util.zig");
const why_stuck = @import("diag/why_stuck.zig");
const crowd_replay = @import("diag/crowd_replay.zig");
const CrowdEvent = crowd_replay.CrowdEvent;
const EventLog = crowd_replay.EventLog;

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
    show_perf_graph: bool = false,
    show_why_stuck: bool = false, // LIVE why-stuck диагностика (метки над застрявшими + панель).
    // Perf-graph histories (1:1 Tool_Crowd crowdTotalTime / crowdSampleCount).
    crowd_total_time: ValueHistory = .{}, // ms per crowd update
    crowd_sample_count: ValueHistory = .{}, // velocity samples per update
    // Crowd Analytics (P1) — агрегатные истории по кадрам, обновляются раз в update().
    show_analytics: bool = false,
    an_stuck_count: ValueHistory = .{}, // число «застрявших» агентов (classify ∉ {moving,arrived})
    an_avg_speed: ValueHistory = .{}, // средняя |vel| по активным агентам (m/s)
    an_max_speed: ValueHistory = .{}, // макс |vel| по активным агентам (m/s)
    an_max_density: ValueHistory = .{}, // макс. занятость ячейки прокси-сетки (агентов в ячейке)
    // Текущие (последние) значения аналитики — для подписей рядом с графиками.
    an_cur_stuck: usize = 0,
    an_cur_avg: f32 = 0,
    an_cur_max: f32 = 0,
    an_cur_density: usize = 0,
    // Off-mesh toggle (P2) — глобально помечает все off-mesh-полигоны disabled.
    offmesh_disabled: bool = false,
    show_detail_all: bool = false, // 1-в-1 Tool_Crowd.h:38 (showDetailAll=false). При true detail+float
    // рисуются для ВСЕХ агентов -> разные значения дистанции накладываются в общих точках -> каша.
    // След агентов (история позиций) + текущая цель (для креста).
    trails: [MAX_AGENTS]AgentTrail = [_]AgentTrail{.{}} ** MAX_AGENTS,
    target_pos: [3]f32 = .{ 0, 0, 0 },
    target_ref: dt.PolyRef = 0, // current move-target poly (so new agents can join it)
    has_target: bool = false,
    // Габариты агента (из sample settings, как sample->agentRadius/Height в оригинале).
    agent_radius: f32 = 0.6,
    agent_height: f32 = 2.0,
    // Debug-инфо выделенного агента (VO-сэмплы / path-opt).
    debug: dc.CrowdAgentDebugInfo = .{},
    vod: ?dc.ObstacleAvoidanceDebugData = null,
    dbg_frame: u32 = 0,

    // --- Crowd Record/Replay (Cluster J / P1) --------------------------------
    // Журнал событий + монотонный кадровый счётчик. Запись (recording) логирует
    // каждое пользовательское действие с текущим replay_frame. Реплей (replay_active)
    // сбрасывает толпу и покадрово re-симулирует журнал ФИКСИРОВАННЫМ dt — детерминизм
    // обеспечивается тем же навмешем + теми же событиями + фиксированным dt (ядро без RNG).
    log: ?EventLog = null,
    replay_frame: u64 = 0, // ++ каждый update() (общий счётчик и для записи, и для реплея)
    recording: bool = false,
    replay_active: bool = false,
    replay_cursor: usize = 0, // индекс следующего непроигранного события
    replay_frame_cur: u64 = 0, // текущий кадр в ходе реплея (для UI)
    const REPLAY_DT: f32 = 1.0 / 60.0; // фиксированный шаг реплея

    pub fn init(alloc: std.mem.Allocator, dd_gl: *ddgl.DebugDrawGL) CrowdTool {
        return .{ .alloc = alloc, .dd_gl = dd_gl, .filter = dt.QueryFilter.init() };
    }

    pub fn deinit(self: *CrowdTool) void {
        if (self.crowd) |*c| c.deinit();
        if (self.query) |q| q.deinit();
        if (self.vod) |*v| v.deinit();
        if (self.log) |*l| l.deinit();
        self.crowd = null;
        self.query = null;
        self.vod = null;
        self.log = null;
    }

    /// Лениво создаёт журнал событий (alloc нужен, а init() — литерал без alloc-вызовов).
    fn getLog(self: *CrowdTool) *EventLog {
        if (self.log == null) self.log = EventLog.init(self.alloc);
        return &self.log.?;
    }

    /// Логирует событие, если запись активна (и НЕ во время реплея — реплей не пишет в журнал).
    fn record(self: *CrowdTool, ev: CrowdEvent) void {
        if (!self.recording or self.replay_active) return;
        self.getLog().append(ev) catch {};
    }

    /// Экспорт журнала в бинарь (через io_util.writeWholeFile) — сценарий пересылается.
    pub fn saveLog(self: *CrowdTool, path: []const u8) !void {
        const log = self.getLog();
        const blob = try log.serialize(self.alloc);
        defer self.alloc.free(blob);
        try io_util.writeWholeFile(path, blob, self.alloc);
    }

    /// Импорт журнала из бинаря (перезаписывает текущий журнал).
    pub fn loadLog(self: *CrowdTool, path: []const u8) !void {
        const blob = try io_util.readWholeFile(path, self.alloc);
        defer self.alloc.free(blob);
        const log = self.getLog();
        log.clear();
        try log.deserialize(blob);
    }

    /// Re-push area costs into the crowd's filter 0 after they were edited.
    pub fn reapplyAreaCosts(self: *CrowdTool) void {
        if (self.crowd) |*cc| {
            if (cc.getEditableFilter(0)) |f| area_types.applyCosts(f);
        }
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
                    area_types.applyCosts(f); // per-area movement cost — agents avoid expensive areas
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
                if (best) |bi| {
                    c.removeAgent(@intCast(bi));
                    self.record(.{ .remove_agent = .{ .frame = self.replay_frame, .idx = @intCast(bi) } });
                }
            } else {
                var params = self.buildParams();
                const idx = c.addAgent(ray_hit, &params) catch -1;
                self.agent_count = c.getAgentCount();
                if (idx >= 0) self.record(.{ .add_agent = .{ .frame = self.replay_frame, .pos = ray_hit.* } });
                // New agent joins the current move target, if any (1:1 C++
                // CrowdToolState::addAgent: `if (targetPolyRef) requestMoveTarget(...)`).
                if (idx >= 0 and self.has_target and self.target_ref != 0) {
                    _ = c.requestMoveTarget(idx, self.target_ref, &self.target_pos);
                }
            }
        } else if (self.mode == .move_target) {
            if (shift) {
                // Shift+ЛКМ = velocity-move БЕЗ pathfinder (setMoveTarget adjust=true в оригинале):
                // requestMoveVelocity -> target_state=velocity -> агент ЗЕЛЁНЫЙ, идёт напрямую.
                // Запись: храним целевую ТОЧКУ клика (vel — производная от позиций агентов;
                // реплей пересчитает её тем же путём applyVelocityToward, что и здесь).
                self.record(.{ .set_velocity = .{ .frame = self.replay_frame, .vel = ray_hit.* } });
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
                    self.target_ref = ref;
                    self.has_target = true;
                    // Запись: храним сырую точку клика (реплей сам прогонит findNearestPoly,
                    // чтобы получить тот же ref/snapped на том же навмеше).
                    self.record(.{ .move_target = .{ .frame = self.replay_frame, .pos = ray_hit.* } });
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

    // --- Реплей: применение событий журнала к толпе (re-sim) -----------------
    // Эти хелперы повторяют 1-в-1 эффект соответствующих веток onClick, но без
    // записи в журнал и без зависимости от мыши. Семантика move/velocity — «всем
    // активным агентам», как в onClick.

    fn applyAddAgent(self: *CrowdTool, pos: *const [3]f32) void {
        const c = if (self.crowd) |*cc| cc else return;
        var params = self.buildParams();
        const idx = c.addAgent(pos, &params) catch -1;
        self.agent_count = c.getAgentCount();
        if (idx >= 0 and self.has_target and self.target_ref != 0) {
            _ = c.requestMoveTarget(idx, self.target_ref, &self.target_pos);
        }
    }

    fn applyMoveTargetAt(self: *CrowdTool, pos: *const [3]f32) void {
        const c = if (self.crowd) |*cc| cc else return;
        const q = self.query orelse return;
        const ext = [3]f32{ 2, 4, 2 };
        var ref: dt.PolyRef = 0;
        var snapped: [3]f32 = undefined;
        _ = q.findNearestPoly(pos, &ext, &self.filter, &ref, &snapped) catch {};
        if (ref != 0) {
            for (0..self.agent_count) |i| _ = c.requestMoveTarget(@intCast(i), ref, &snapped);
            self.target_pos = snapped;
            self.target_ref = ref;
            self.has_target = true;
        }
    }

    fn applyVelocityToward(self: *CrowdTool, pos: *const [3]f32) void {
        const c = if (self.crowd) |*cc| cc else return;
        for (0..self.agent_count) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            var vel = [3]f32{ pos[0] - ag.npos[0], pos[1] - ag.npos[1], pos[2] - ag.npos[2] };
            const len = @sqrt(vel[0] * vel[0] + vel[1] * vel[1] + vel[2] * vel[2]);
            if (len > 0.0001) {
                const s = ag.params.max_speed / len;
                vel[0] *= s;
                vel[1] *= s;
                vel[2] *= s;
            }
            _ = c.requestMoveVelocity(@intCast(i), &vel);
        }
    }

    /// Сбрасывает толпу в стартовое состояние реплея: удаляет всех агентов,
    /// чистит следы/цель/счётчики. Навмеш/фильтры/пресеты не трогаем (старт = текущий навмеш).
    fn resetCrowdForReplay(self: *CrowdTool) void {
        const c = if (self.crowd) |*cc| cc else return;
        for (0..self.agent_count) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (ag.active) c.removeAgent(@intCast(i));
        }
        self.agent_count = c.getAgentCount();
        self.selected = null;
        self.has_target = false;
        self.target_ref = 0;
        self.trails = [_]AgentTrail{.{}} ** MAX_AGENTS;
    }

    /// Запускает реплей: сбрасывает толпу и ставит проигрывание журнала с кадра 0.
    /// Если журнал пуст — ничего не делает.
    pub fn startReplay(self: *CrowdTool) void {
        const log = if (self.log) |*l| l else return;
        if (log.count() == 0) return;
        self.recording = false;
        self.resetCrowdForReplay();
        self.replay_active = true;
        self.replay_cursor = 0;
        self.replay_frame_cur = 0;
        self.running = true;
    }

    /// Один кадр реплея: применяет все события, чей frame == текущему кадру реплея,
    /// затем один шаг симуляции фиксированным dt. Возвращает true, пока реплей идёт.
    fn replayStep(self: *CrowdTool) void {
        const log = if (self.log) |*l| l else {
            self.replay_active = false;
            return;
        };
        const items = log.events.items;
        // Применяем все события на текущем кадре (в порядке журнала).
        while (self.replay_cursor < items.len and items[self.replay_cursor].frame() <= self.replay_frame_cur) {
            switch (items[self.replay_cursor]) {
                .add_agent => |e| self.applyAddAgent(&e.pos),
                .move_target => |e| self.applyMoveTargetAt(&e.pos),
                .set_velocity => |e| self.applyVelocityToward(&e.vel),
                .remove_agent => |e| {
                    if (self.crowd) |*c| {
                        c.removeAgent(@intCast(e.idx));
                        self.agent_count = c.getAgentCount();
                    }
                },
            }
            self.replay_cursor += 1;
        }
        // Шаг симуляции фиксированным dt.
        self.simStep(REPLAY_DT);
        self.replay_frame_cur += 1;
        // Реплей завершён, когда все события проиграны И толпа «успокоилась» — здесь
        // упрощённо: останавливаем проигрывание событий, но продолжаем step ещё немного,
        // чтобы агенты доехали. Закрываем реплей, как только курсор исчерпан и прошло
        // достаточно «послесобытийных» кадров (held below by a tail counter).
        if (self.replay_cursor >= items.len) {
            // последний кадр события + хвост (3 сек при 60 fps) на доезд агентов
            const last_frame = items[items.len - 1].frame();
            if (self.replay_frame_cur > last_frame + 180) self.replay_active = false;
        }
    }

    /// Чистый шаг симуляции толпы (без кадрового счётчика реплея) — общий код для
    /// update() и реплея: debug-инфо, dtCrowd::update, аналитика, следы.
    fn simStep(self: *CrowdTool, delta: f32) void {
        const c = if (self.crowd) |*cc| cc else return;
        self.debug.idx = if (self.selected) |s| @intCast(s) else -1;
        if (self.vod) |*v| {
            self.debug.vod = v;
        } else self.debug.vod = null;
        var timer = io_util.PerfTimer.start();
        c.updateDebug(delta, &self.debug) catch {};
        self.crowd_total_time.addSample(timer.readMs());
        self.crowd_sample_count.addSample(@floatFromInt(c.getVelocitySampleCount()));
        var stuck: usize = 0;
        var sum_speed: f32 = 0;
        var max_speed: f32 = 0;
        var n_active: usize = 0;
        for (0..self.agent_count) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const vx = ag.vel[0];
            const vy = ag.vel[1];
            const vz = ag.vel[2];
            const sp = @sqrt(vx * vx + vy * vy + vz * vz);
            sum_speed += sp;
            if (sp > max_speed) max_speed = sp;
            n_active += 1;
            const v = why_stuck.classify(gatherSignals(ag));
            if (v != .moving and v != .arrived) stuck += 1;
            var t = &self.trails[i];
            t.htrail = (t.htrail + 1) % AGENT_MAX_TRAIL;
            t.trail[t.htrail * 3 + 0] = ag.npos[0];
            t.trail[t.htrail * 3 + 1] = ag.npos[1];
            t.trail[t.htrail * 3 + 2] = ag.npos[2];
        }
        const avg_speed: f32 = if (n_active > 0) sum_speed / @as(f32, @floatFromInt(n_active)) else 0;
        var max_density: usize = 0;
        const grid = c.getGrid();
        const b = grid.getBounds();
        var gy: i32 = b[1];
        while (gy <= b[3]) : (gy += 1) {
            var gx: i32 = b[0];
            while (gx <= b[2]) : (gx += 1) {
                const cnt = grid.getItemCountAt(gx, gy);
                if (cnt > max_density) max_density = cnt;
            }
        }
        self.an_cur_stuck = stuck;
        self.an_cur_avg = avg_speed;
        self.an_cur_max = max_speed;
        self.an_cur_density = max_density;
        self.an_stuck_count.addSample(@floatFromInt(stuck));
        self.an_avg_speed.addSample(avg_speed);
        self.an_max_speed.addSample(max_speed);
        self.an_max_density.addSample(@floatFromInt(max_density));
    }

    pub fn update(self: *CrowdTool, delta: f32) void {
        if (!self.running) return;
        // Реплей: игнорируем входящий dt из main, степпим ФИКСИРОВАННЫМ REPLAY_DT
        // (детерминизм). Один update()-кадр = один replayStep (1/60). main не трогаем.
        if (self.replay_active) {
            self.replayStep();
            return;
        }
        // Обычный (live) ход: монотонный кадровый счётчик для записи.
        self.replay_frame += 1;
        self.simStep(delta);
    }


    /// Draw the crowd perf graphs (1:1 CrowdToolState::handleRenderOverlay,
    /// showPerfGraph). Total update time (0..2 ms) + velocity sample count
    /// (0..2000), anchored to the bottom of the viewport. dvui-frame only.
    pub fn renderPerfGraph(self: *CrowdTool, fb_h: f32) void {
        if (!self.show_perf_graph) return;
        const x: f32 = 300;
        const w: f32 = 500;
        const pad: f32 = 8;
        const bottom = fb_h - 10;
        vh_mod.drawGraph(self.alloc, x, bottom - 200, w, 200, pad, 0.0, 2.0, "ms", &self.crowd_total_time, dbg.rgba(255, 128, 0, 255), "Total", 1, true);
        vh_mod.drawGraph(self.alloc, x, bottom - 50, w, 50, pad, 0.0, 2000.0, "", &self.crowd_sample_count, dbg.rgba(96, 96, 96, 128), "Sample Count", 0, false);
    }

    /// Crowd Analytics graphs (P1) — 3 агрегатных мини-графика по кадрам, через тот же
    /// drawGraph, что и perf-граф. Привязаны к верхнему-левому углу вьюпорта, чтобы не
    /// перекрывать perf-граф (он у нижней кромки). dvui-frame only.
    pub fn renderAnalyticsGraph(self: *CrowdTool, fb_h: f32) void {
        if (!self.show_analytics) return;
        _ = fb_h;
        const x: f32 = 300;
        const w: f32 = 360;
        const pad: f32 = 8;
        const h: f32 = 70;
        const gap: f32 = 30; // место под легенду между графиками
        var y: f32 = 80;

        // 1) Stuck count (0..agent_count). range_max — текущее число агентов (мин. 1).
        const stuck_max: f32 = @max(1.0, @as(f32, @floatFromInt(self.agent_count)));
        vh_mod.drawGraph(self.alloc, x, y, w, h, pad, 0.0, stuck_max, "stuck", &self.an_stuck_count, dbg.rgba(255, 64, 32, 255), "Stuck", 0, true);
        y += h + gap;

        // 2) Speed: avg (зелёный) + max (синий) на одном графике (0..max_speed агента ~3.5).
        vh_mod.drawGraph(self.alloc, x, y, w, h, pad, 0.0, 4.0, "m/s", &self.an_max_speed, dbg.rgba(64, 128, 255, 255), "Max speed", 1, true);
        vh_mod.drawGraph(self.alloc, x, y, w, h, pad, 0.0, 4.0, "m/s", &self.an_avg_speed, dbg.rgba(64, 255, 64, 255), "Avg speed", 0, false);
        y += h + gap;

        // 3) Max density (агентов в самой плотной ячейке прокси-сетки).
        vh_mod.drawGraph(self.alloc, x, y, w, h, pad, 0.0, 8.0, "ag/cell", &self.an_max_density, dbg.rgba(255, 192, 0, 255), "Max density", 0, true);
    }

    /// Off-mesh toggle (P2): помечает ВСЕ off-mesh-полигоны навмеша disabled (или снимает
    /// флаг) — тем же механизмом, что Toggle Polys (setPolyFlags ^ SamplePolyFlags.disabled,
    /// фильтр толпы исключает disabled, см. setNavMesh). Глобально (per-link не выделяем):
    /// перебирает все тайлы, для каждого off-mesh-коннекта берёт его poly-ref
    /// (getPolyRefBase(tile) | con.poly) и ВЫСТАВЛЯЕТ бит disabled = `disabled` (идемпотентно,
    /// не XOR — чтобы повторный вызов с тем же значением не «мигал» состоянием).
    /// Ядро не трогаем: всё через публичные getPolyRefBase / setPolyFlags / getPolyFlags.
    fn applyOffMeshDisabled(self: *CrowdTool, disabled: bool) void {
        const nm = self.navmesh orelse return;
        for (nm.tiles) |*tile| {
            const hdr = tile.header orelse continue;
            const base = nm.getPolyRefBase(tile);
            const cnt: usize = @intCast(hdr.off_mesh_con_count);
            for (0..cnt) |i| {
                const con = &tile.off_mesh_cons[i];
                const ref = base | @as(dt.PolyRef, con.poly);
                const flags = nm.getPolyFlags(ref) catch continue;
                const new_flags = if (disabled)
                    flags | sample.SamplePolyFlags.disabled
                else
                    flags & ~sample.SamplePolyFlags.disabled;
                nm.setPolyFlags(ref, new_flags) catch {};
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

    /// Маппинг CrowdAgent -> why_stuck.Signals (LIVE-диагностика «why-stuck»).
    /// Снимает только УЖЕ хранимые поля агента (ядро не трогаем). near_target —
    /// горизонтальная (2D) дистанция npos->target_pos < radius*2 (порог как у
    /// CrowdTool вообще: радиус агента — естественная "у цели" зона). Для
    /// velocity-таргета (target_pos = вектор скорости, не точка) near_target
    /// бессмыслен -> false.
    pub fn gatherSignals(ag: anytype) why_stuck.Signals {
        const vx = ag.vel[0];
        const vy = ag.vel[1];
        const vz = ag.vel[2];
        const speed = @sqrt(vx * vx + vy * vy + vz * vz);

        const ts = ag.target_state;
        const target_none = (ts == .target_none);
        const target_failed = (ts == .target_failed);
        const target_pending = (ts == .target_requesting or
            ts == .target_waiting_for_queue or
            ts == .target_waiting_for_path);

        // near_target: 2D-дистанция до целевой точки < radius*2. Только для
        // настоящих point-таргетов (не velocity), где target_pos — позиция в мире.
        var near_target = false;
        if (ts != .target_velocity and ts != .target_none) {
            const dx = ag.npos[0] - ag.target_pos[0];
            const dz = ag.npos[2] - ag.target_pos[2];
            const d2 = dx * dx + dz * dz;
            const thr = ag.params.radius * 2.0;
            near_target = d2 < thr * thr;
        }

        return .{
            .state_invalid = (ag.state == .invalid),
            .target_none = target_none,
            .target_failed = target_failed,
            .target_pending = target_pending,
            .partial = ag.partial,
            .ncorners = @intCast(ag.ncorners),
            .desired_speed = ag.desired_speed,
            .speed = speed,
            .near_target = near_target,
        };
    }

    /// Итератор по «застрявшим» агентам для отрисовки why-stuck меток в мире
    /// (метки рисует main.zig, владеющий cam/worldToScreen — как forEachSearchLabel
    /// у tester'а). «Застрявший» = classify(...) НЕ ∈ {moving, arrived}. emit
    /// получает позицию над агентом + короткий reasonText(verdict).
    pub fn forEachWhyStuckLabel(
        self: *CrowdTool,
        ctx: anytype,
        comptime emit: fn (@TypeOf(ctx), pos: [3]f32, text: []const u8) void,
    ) void {
        if (!self.show_why_stuck) return;
        const c = if (self.crowd) |*cc| cc else return;
        for (0..self.agent_count) |i| {
            const ag = c.getAgent(@intCast(i)) orelse continue;
            if (!ag.active) continue;
            const sig = gatherSignals(ag);
            const v = why_stuck.classify(sig);
            if (v == .moving or v == .arrived) continue; // реально не застрял
            const wp: [3]f32 = .{ ag.npos[0], ag.npos[1] + ag.params.height + 0.3, ag.npos[2] };
            emit(ctx, wp, why_stuck.reasonShort(v));
        }
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
                    // guard stale corridor refs: bound by tiles.len BEFORE isValidPolyRef
                    // (faithful poly-draw + isValidPolyRef check only against max_tiles,
                    // which can exceed tiles.len for a stale ref -> OOB crash).
                    for (0..ag.corridor.getPathCount()) |j| {
                        const pr = path[j];
                        if (@as(usize, m.decodePolyId(pr).tile) >= m.tiles.len) continue;
                        if (m.isValidPolyRef(pr)) dbg.debugDrawNavMeshPoly(dd, m, pr, dbg.rgba(255, 255, 255, 24));
                    }
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
            _ = dvui.checkbox(@src(), &self.show_why_stuck, "Show Why-Stuck", .{});
        }

        // LIVE why-stuck: развёрнутое объяснение для ВЫДЕЛЕННОГО агента (под Selected
        // Debug Draw). Метки над всеми застрявшими рисует main.zig (worldToScreen).
        if (self.show_why_stuck) {
            if (self.crowd) |*c| {
                if (self.selected) |sel| {
                    if (c.getAgent(@intCast(sel))) |ag| {
                        if (ag.active) {
                            const sig = gatherSignals(ag);
                            const v = why_stuck.classify(sig);
                            var ebuf: [512]u8 = undefined;
                            const txt = why_stuck.explainText(&ebuf, v, sig);
                            dvui.label(@src(), "Why-Stuck [agent {d}]:", .{sel}, .{});
                            dvui.labelNoFmt(@src(), txt, .{}, .{ .expand = .horizontal });
                        }
                    }
                } else {
                    dvui.labelNoFmt(@src(), "Why-Stuck: select an agent for details", .{}, .{});
                }
            }
        }
        if (ui.treeNode(@src(), "Debug Draw")) {
            _ = dvui.checkbox(@src(), &self.show_labels, "Show Labels", .{});
            _ = dvui.checkbox(@src(), &self.show_grid, "Show Prox Grid", .{});
            _ = dvui.checkbox(@src(), &self.show_nodes, "Show Nodes", .{});
            _ = dvui.checkbox(@src(), &self.show_perf_graph, "Show Perf Graph", .{});
            _ = dvui.checkbox(@src(), &self.show_detail_all, "Show Detail All", .{});
        }

        // Crowd Analytics (P1) — агрегатные графики + текущие значения.
        if (ui.treeNode(@src(), "Crowd Analytics")) {
            _ = dvui.checkbox(@src(), &self.show_analytics, "Show Analytics Graphs", .{});
            dvui.label(@src(), "stuck: {d} / {d}", .{ self.an_cur_stuck, self.agent_count }, .{});
            dvui.label(@src(), "avg speed: {d:.2} m/s", .{self.an_cur_avg}, .{});
            dvui.label(@src(), "max speed: {d:.2} m/s", .{self.an_cur_max}, .{});
            dvui.label(@src(), "max density: {d} ag/cell", .{self.an_cur_density}, .{});
        }

        // Dynamic off-mesh toggle (P2) — глобально disabled/enabled все off-mesh-связи.
        if (ui.treeNode(@src(), "Off-Mesh Links")) {
            if (dvui.checkbox(@src(), &self.offmesh_disabled, "Disable off-mesh links", .{})) {
                self.applyOffMeshDisabled(self.offmesh_disabled);
            }
            dvui.labelNoFmt(@src(), if (self.offmesh_disabled)
                "Off-mesh links DISABLED - agents reroute around them."
            else
                "Off-mesh links enabled.", .{}, .{ .expand = .horizontal });
        }

        // Crowd Record/Replay (Cluster J / P1) — запись действий + детерминированный реплей.
        if (ui.treeNode(@src(), "Crowd Record/Replay")) {
            const n_ev = if (self.log) |*l| l.count() else 0;
            if (!self.replay_active) {
                _ = dvui.checkbox(@src(), &self.recording, "Record", .{});
            } else {
                dvui.labelNoFmt(@src(), "Record (disabled during replay)", .{}, .{});
            }
            dvui.label(@src(), "events recorded: {d}", .{n_ev}, .{});

            if (self.replay_active) {
                dvui.label(@src(), "REPLAY frame: {d}", .{self.replay_frame_cur}, .{});
                if (dvui.button(@src(), "Stop Replay", .{}, .{})) self.replay_active = false;
            } else {
                if (dvui.button(@src(), "Play Recording", .{}, .{})) self.startReplay();
            }

            if (dvui.button(@src(), "Clear Log", .{}, .{})) {
                if (self.log) |*l| l.clear();
                self.replay_frame = 0;
            }
            // Disk-сериализация журнала (export/import) в meshes/crowd_replay.bin.
            if (dvui.button(@src(), "Save Log -> meshes/crowd_replay.bin", .{}, .{})) {
                self.saveLog("meshes/crowd_replay.bin") catch {};
            }
            if (dvui.button(@src(), "Load Log <- meshes/crowd_replay.bin", .{}, .{})) {
                self.loadLog("meshes/crowd_replay.bin") catch {};
            }
            dvui.labelNoFmt(@src(), "Record -> act -> Play Recording (fixed 1/60 dt re-sim).", .{}, .{ .expand = .horizontal });
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
