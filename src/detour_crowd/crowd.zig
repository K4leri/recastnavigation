const std = @import("std");
const detour = @import("../detour.zig");
const math = @import("../math.zig");
const path_corridor = @import("path_corridor.zig");
const local_boundary = @import("local_boundary.zig");
const proximity_grid = @import("proximity_grid.zig");
const path_queue = @import("path_queue.zig");
const obstacle_avoidance = @import("obstacle_avoidance.zig");

const NavMesh = detour.NavMesh;
const NavMeshQuery = detour.NavMeshQuery;
const QueryFilter = detour.QueryFilter;
const PolyRef = detour.PolyRef;
const Status = detour.Status;

const PathCorridor = path_corridor.PathCorridor;
const LocalBoundary = local_boundary.LocalBoundary;
const ProximityGrid = proximity_grid.ProximityGrid;
const PathQueue = path_queue.PathQueue;
const PathQueueRef = path_queue.PathQueueRef;
const INVALID_QUEUE_REF = path_queue.INVALID_QUEUE_REF;
const ObstacleAvoidanceQuery = obstacle_avoidance.ObstacleAvoidanceQuery;
const ObstacleAvoidanceParams = obstacle_avoidance.ObstacleAvoidanceParams;
pub const ObstacleAvoidanceDebugData = obstacle_avoidance.ObstacleAvoidanceDebugData;

/// Debug-инфо для выделенного агента (для визуализации VO / path-opt), порт dtCrowdAgentDebugInfo.
pub const CrowdAgentDebugInfo = struct {
    idx: i32 = -1,
    vod: ?*ObstacleAvoidanceDebugData = null,
    opt_start: [3]f32 = .{ 0, 0, 0 },
    opt_end: [3]f32 = .{ 0, 0, 0 },
};

/// Maximum number of neighbors that a crowd agent can take into account
pub const MAX_NEIGHBOURS = 6;

/// Maximum number of corners a crowd agent will look ahead in the path
pub const MAX_CORNERS = 4;

/// Maximum number of crowd avoidance configurations
pub const MAX_OBSTAVOIDANCE_PARAMS = 8;

/// Maximum number of query filter types
pub const MAX_QUERY_FILTER_TYPE = 16;

/// Provides neighbor data for agents
pub const CrowdNeighbour = struct {
    idx: i32, // Index of the neighbor in the crowd
    dist: f32, // Distance between current agent and neighbor
};

/// The type of navigation mesh polygon the agent is traversing
pub const CrowdAgentState = enum(u8) {
    invalid, // Agent is not in a valid state
    walking, // Agent is traversing a normal navigation mesh polygon
    offmesh, // Agent is traversing an off-mesh connection
};

/// Configuration parameters for a crowd agent
pub const CrowdAgentParams = struct {
    radius: f32, // Agent radius
    height: f32, // Agent height
    max_acceleration: f32, // Maximum allowed acceleration
    max_speed: f32, // Maximum allowed speed
    collision_query_range: f32, // How close a collision element must be
    path_optimization_range: f32, // Path visibility optimization range
    separation_weight: f32, // How aggressive to avoid collisions
    update_flags: u8, // Flags that impact steering behavior
    obstacle_avoidance_type: u8, // Index of avoidance configuration
    query_filter_type: u8, // Index of query filter
    user_data: ?*anyopaque, // User defined data

    pub fn init() CrowdAgentParams {
        return .{
            .radius = 0.6,
            .height = 2.0,
            .max_acceleration = 8.0,
            .max_speed = 3.5,
            .collision_query_range = 12.0,
            .path_optimization_range = 30.0,
            .separation_weight = 2.0,
            .update_flags = UpdateFlags.all,
            .obstacle_avoidance_type = 0,
            .query_filter_type = 0,
            .user_data = null,
        };
    }
};

/// Move request state
pub const MoveRequestState = enum(u8) {
    target_none = 0,
    target_failed,
    target_valid,
    target_requesting,
    target_waiting_for_queue,
    target_waiting_for_path,
    target_velocity,
};

/// Crowd agent update flags
pub const UpdateFlags = struct {
    pub const anticipate_turns: u8 = 1;
    pub const obstacle_avoid: u8 = 2;
    pub const separation: u8 = 4;
    pub const optimize_vis: u8 = 8;
    pub const optimize_topo: u8 = 16;
    pub const all: u8 = anticipate_turns | obstacle_avoid | separation | optimize_vis | optimize_topo;
};

/// Animation for off-mesh connection traversal
const CrowdAgentAnimation = struct {
    active: bool,
    init_pos: [3]f32,
    start_pos: [3]f32,
    end_pos: [3]f32,
    poly_ref: PolyRef,
    t: f32,
    tmax: f32,
};

/// Helper: normalized, clamped interpolation parameter for off-mesh animation.
/// 1-в-1 DetourCrowd.cpp:54 `tween`.
fn tween(t: f32, t0: f32, t1: f32) f32 {
    return std.math.clamp((t - t0) / (t1 - t0), 0.0, 1.0);
}

/// Helper: Integrate velocity with acceleration constraint
fn integrate(ag: *CrowdAgent, dt: f32) void {
    // Fake dynamic constraint
    const max_delta = ag.params.max_acceleration * dt;
    var dv = [3]f32{ 0, 0, 0 };
    math.vsub(&dv, &ag.nvel, &ag.vel);
    const ds = math.vlen(&dv);
    if (ds > max_delta) {
        math.vscale(&dv, &dv, max_delta / ds);
    }
    math.vadd(&ag.vel, &ag.vel, &dv);

    // Integrate
    if (math.vlen(&ag.vel) > 0.0001) {
        math.vmad(&ag.npos, &ag.npos, &ag.vel, dt);
    } else {
        ag.vel = [3]f32{ 0, 0, 0 };
    }
}

/// Helper: Calculate smooth steering direction
fn calcSmoothSteerDirection(ag: *const CrowdAgent, dir: *[3]f32) void {
    if (ag.ncorners == 0) {
        dir.* = [3]f32{ 0, 0, 0 };
        return;
    }

    const ip0: usize = 0;
    const ip1: usize = @min(1, ag.ncorners - 1);
    const p0_slice = ag.corner_verts[ip0 * 3 .. ip0 * 3 + 3];
    const p1_slice = ag.corner_verts[ip1 * 3 .. ip1 * 3 + 3];
    const p0: [3]f32 = .{ p0_slice[0], p0_slice[1], p0_slice[2] };
    const p1: [3]f32 = .{ p1_slice[0], p1_slice[1], p1_slice[2] };

    var dir0 = [3]f32{ 0, 0, 0 };
    var dir1 = [3]f32{ 0, 0, 0 };
    math.vsub(&dir0, &p0, &ag.npos);
    math.vsub(&dir1, &p1, &ag.npos);
    dir0[1] = 0;
    dir1[1] = 0;

    const len0 = math.vlen(&dir0);
    var len1 = math.vlen(&dir1);
    if (len1 > 0.001) {
        len1 = 1.0 / len1;
        math.vscale(&dir1, &dir1, len1);
    }

    dir[0] = dir0[0] - dir1[0] * len0 * 0.5;
    dir[1] = 0;
    dir[2] = dir0[2] - dir1[2] * len0 * 0.5;

    math.vnormalize(dir);
}

/// Helper: Calculate straight steering direction
fn calcStraightSteerDirection(ag: *const CrowdAgent, dir: *[3]f32) void {
    if (ag.ncorners == 0) {
        dir.* = [3]f32{ 0, 0, 0 };
        return;
    }
    const corner = ag.corner_verts[0..3];
    math.vsub(dir, corner, &ag.npos);
    dir[1] = 0;
    math.vnormalize(dir);
}

/// Helper: Get distance to goal
fn getDistanceToGoal(ag: *const CrowdAgent, range: f32) f32 {
    if (ag.ncorners == 0) return range;

    const end_of_path = (ag.corner_flags[ag.ncorners - 1] & detour.STRAIGHTPATH_END) != 0;
    if (end_of_path) {
        const last_corner_slice = ag.corner_verts[(ag.ncorners - 1) * 3 .. (ag.ncorners - 1) * 3 + 3];
        const last_corner: [3]f32 = .{ last_corner_slice[0], last_corner_slice[1], last_corner_slice[2] };
        return @min(math.vdist2D(&ag.npos, &last_corner), range);
    }
    return range;
}

/// Helper: Check if agent is over off-mesh connection
fn overOffmeshConnection(ag: *const CrowdAgent, radius: f32) bool {
    if (ag.ncorners == 0) return false;

    const offmesh_connection = (ag.corner_flags[ag.ncorners - 1] & detour.STRAIGHTPATH_OFFMESH_CONNECTION) != 0;
    if (offmesh_connection) {
        const last_corner_slice = ag.corner_verts[(ag.ncorners - 1) * 3 .. (ag.ncorners - 1) * 3 + 3];
        const last_corner: [3]f32 = .{ last_corner_slice[0], last_corner_slice[1], last_corner_slice[2] };
        const dist_sq = math.vdist2DSqr(&ag.npos, &last_corner);
        if (dist_sq < radius * radius) {
            return true;
        }
    }
    return false;
}

/// Represents an agent managed by a Crowd object
pub const CrowdAgent = struct {
    active: bool, // True if agent is active
    state: CrowdAgentState, // Type of mesh polygon the agent is traversing
    partial: bool, // True if path does not lead to requested position
    corridor: PathCorridor, // Path corridor the agent is using
    boundary: LocalBoundary, // Local boundary data
    topology_opt_time: f32, // Time since path corridor was optimized
    neis: [MAX_NEIGHBOURS]CrowdNeighbour, // Known neighbors
    nneis: usize, // Number of neighbors
    desired_speed: f32, // Desired speed
    npos: [3]f32, // Current agent position
    disp: [3]f32, // Temporary displacement accumulator
    dvel: [3]f32, // Desired velocity (from path)
    nvel: [3]f32, // Desired velocity adjusted by obstacle avoidance
    vel: [3]f32, // Actual velocity
    params: CrowdAgentParams, // Agent configuration
    corner_verts: [MAX_CORNERS * 3]f32, // Local path corridor corners
    corner_flags: [MAX_CORNERS]u8, // Corner flags
    corner_polys: [MAX_CORNERS]PolyRef, // Polygon refs at corners
    ncorners: usize, // Number of corners
    target_state: MoveRequestState, // State of movement request
    target_ref: PolyRef, // Target polyref
    target_pos: [3]f32, // Target position
    target_pathq_ref: PathQueueRef, // Path finder ref
    target_replan: bool, // Flag indicating path is being replanned
    target_replan_time: f32, // Time since target was replanned
};

/// Crowd manager - provides local steering behaviors for a group of agents
pub const Crowd = struct {
    max_agents: usize,
    agents: []CrowdAgent,
    active_agents: []?*CrowdAgent,
    agent_anims: []CrowdAgentAnimation,
    path_queue: PathQueue,
    obstacle_query_params: [MAX_OBSTAVOIDANCE_PARAMS]ObstacleAvoidanceParams,
    obstacle_query: ObstacleAvoidanceQuery,
    grid: ProximityGrid,
    path_result: []PolyRef,
    agent_placement_half_extents: [3]f32,
    filters: [MAX_QUERY_FILTER_TYPE]QueryFilter,
    max_agent_radius: f32,
    velocity_sample_count: usize,
    navquery: *NavMeshQuery,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize crowd manager
    pub fn init(
        allocator: std.mem.Allocator,
        max_agents: usize,
        max_agent_radius: f32,
        nav: *NavMesh,
    ) !Self {
        const max_path_result: usize = 256;

        // Initialize path queue
        var path_q = try PathQueue.init(allocator, max_path_result, 4096, nav);
        errdefer path_q.deinit();

        // Allocate agents
        const agents = try allocator.alloc(CrowdAgent, max_agents);
        errdefer allocator.free(agents);

        // Allocate active agents list
        const active_agents = try allocator.alloc(?*CrowdAgent, max_agents);
        errdefer allocator.free(active_agents);

        // Allocate agent animations
        const agent_anims = try allocator.alloc(CrowdAgentAnimation, max_agents);
        errdefer allocator.free(agent_anims);
        for (agent_anims) |*anim| {
            anim.* = .{
                .active = false,
                .init_pos = [3]f32{ 0, 0, 0 },
                .start_pos = [3]f32{ 0, 0, 0 },
                .end_pos = [3]f32{ 0, 0, 0 },
                .poly_ref = 0,
                .t = 0,
                .tmax = 0,
            };
        }

        // Allocate path result buffer
        const path_result = try allocator.alloc(PolyRef, max_path_result);
        errdefer allocator.free(path_result);

        // Initialize proximity grid
        var grid = try ProximityGrid.init(allocator, max_agents * 4, max_agent_radius * 3);
        errdefer grid.deinit();

        // Initialize obstacle avoidance query
        var obstacle_query = try ObstacleAvoidanceQuery.init(allocator, 6, 8);
        errdefer obstacle_query.deinit();

        // Initialize nav query
        const navquery = try NavMeshQuery.init(allocator);
        errdefer navquery.deinit();
        try navquery.initQuery(nav, 512);

        // Initialize all agents
        for (agents) |*agent| {
            agent.* = .{
                .active = false,
                .state = .invalid,
                .partial = false,
                .corridor = try PathCorridor.init(allocator, max_path_result),
                .boundary = LocalBoundary.init(),
                .topology_opt_time = 0,
                .neis = undefined,
                .nneis = 0,
                .desired_speed = 0,
                .npos = [3]f32{ 0, 0, 0 },
                .disp = [3]f32{ 0, 0, 0 },
                .dvel = [3]f32{ 0, 0, 0 },
                .nvel = [3]f32{ 0, 0, 0 },
                .vel = [3]f32{ 0, 0, 0 },
                .params = CrowdAgentParams.init(),
                .corner_verts = undefined,
                .corner_flags = undefined,
                .corner_polys = undefined,
                .ncorners = 0,
                .target_state = .target_none,
                .target_ref = 0,
                .target_pos = [3]f32{ 0, 0, 0 },
                .target_pathq_ref = INVALID_QUEUE_REF,
                .target_replan = false,
                .target_replan_time = 0,
            };
        }

        // Initialize filters with default settings
        var filters: [MAX_QUERY_FILTER_TYPE]QueryFilter = undefined;
        for (&filters) |*filter| {
            filter.* = QueryFilter.init();
        }

        // Initialize obstacle avoidance params
        var obstacle_query_params: [MAX_OBSTAVOIDANCE_PARAMS]ObstacleAvoidanceParams = undefined;
        for (&obstacle_query_params) |*params| {
            params.* = ObstacleAvoidanceParams.init();
        }

        return Self{
            .max_agents = max_agents,
            .agents = agents,
            .active_agents = active_agents,
            .agent_anims = agent_anims,
            .path_queue = path_q,
            .obstacle_query_params = obstacle_query_params,
            .obstacle_query = obstacle_query,
            .grid = grid,
            .path_result = path_result,
            .agent_placement_half_extents = [3]f32{
                max_agent_radius * 2.0,
                max_agent_radius * 1.5,
                max_agent_radius * 2.0,
            },
            .filters = filters,
            .max_agent_radius = max_agent_radius,
            .velocity_sample_count = 0,
            .navquery = navquery,
            .allocator = allocator,
        };
    }

    /// Free crowd resources
    pub fn deinit(self: *Self) void {
        for (self.agents) |*agent| {
            agent.corridor.deinit();
        }
        self.allocator.free(self.agents);
        self.allocator.free(self.active_agents);
        self.allocator.free(self.agent_anims);
        self.allocator.free(self.path_result);
        self.path_queue.deinit();
        self.obstacle_query.deinit();
        self.grid.deinit();
        self.navquery.deinit();
    }

    /// Add a new agent to the crowd
    pub fn addAgent(self: *Self, pos: *const [3]f32, params: *const CrowdAgentParams) !i32 {
        // Find empty slot
        var idx: i32 = -1;
        for (self.agents, 0..) |*agent, i| {
            if (!agent.active) {
                idx = @intCast(i);
                break;
            }
        }

        if (idx == -1) return -1;

        const ag = &self.agents[@intCast(idx)];

        // Update agent parameters
        ag.params = params.*;

        // Find nearest position on navmesh
        var nearest = [3]f32{ 0, 0, 0 };
        var ref: PolyRef = 0;
        math.vcopy(&nearest, pos);

        const filter = &self.filters[ag.params.query_filter_type];
        self.navquery.findNearestPoly(
            pos,
            &self.agent_placement_half_extents,
            filter,
            &ref,
            &nearest,
        ) catch {
            math.vcopy(&nearest, pos);
            ref = 0;
        };

        // Initialize agent
        ag.corridor.reset(ref, &nearest);
        ag.boundary.reset();
        ag.partial = false;
        ag.topology_opt_time = 0;
        ag.target_replan_time = 0;
        ag.nneis = 0;

        ag.dvel = [3]f32{ 0, 0, 0 };
        ag.nvel = [3]f32{ 0, 0, 0 };
        ag.vel = [3]f32{ 0, 0, 0 };
        math.vcopy(&ag.npos, &nearest);

        ag.desired_speed = 0;

        if (ref != 0) {
            ag.state = .walking;
        } else {
            ag.state = .invalid;
        }

        ag.target_state = .target_none;
        ag.active = true;

        return idx;
    }

    /// Remove an agent from the crowd
    pub fn removeAgent(self: *Self, idx: i32) void {
        if (idx >= 0 and idx < self.max_agents) {
            self.agents[@intCast(idx)].active = false;
        }
    }

    /// Request move target for an agent
    pub fn requestMoveTarget(
        self: *Self,
        idx: i32,
        ref: PolyRef,
        pos: *const [3]f32,
    ) bool {
        if (idx < 0 or idx >= self.max_agents) return false;
        if (ref == 0) return false;

        var ag = &self.agents[@intCast(idx)];

        ag.target_ref = ref;
        math.vcopy(&ag.target_pos, pos);
        ag.target_pathq_ref = INVALID_QUEUE_REF;
        ag.target_replan = false;

        if (ag.target_ref != 0) {
            ag.target_state = .target_requesting;
        } else {
            ag.target_state = .target_failed;
        }

        return true;
    }

    /// Request move velocity for an agent
    pub fn requestMoveVelocity(self: *Self, idx: i32, vel: *const [3]f32) bool {
        if (idx < 0 or idx >= self.max_agents) return false;

        var ag = &self.agents[@intCast(idx)];

        ag.target_ref = 0;
        math.vcopy(&ag.target_pos, vel);
        ag.target_pathq_ref = INVALID_QUEUE_REF;
        ag.target_replan = false;
        ag.target_state = .target_velocity;

        return true;
    }

    /// Reset move target for an agent
    pub fn resetMoveTarget(self: *Self, idx: i32) bool {
        if (idx < 0 or idx >= self.max_agents) return false;

        var ag = &self.agents[@intCast(idx)];

        ag.target_ref = 0;
        ag.target_pos = [3]f32{ 0, 0, 0 };
        ag.dvel = [3]f32{ 0, 0, 0 };
        ag.target_pathq_ref = INVALID_QUEUE_REF;
        ag.target_replan = false;
        ag.target_state = .target_none;

        return true;
    }

    /// Get active agents
    pub fn getActiveAgents(self: *Self, agents: []*CrowdAgent, max_agents: usize) usize {
        var n: usize = 0;
        for (self.agents) |*agent| {
            if (!agent.active) continue;
            if (n < max_agents) {
                agents[n] = agent;
                n += 1;
            }
        }
        return n;
    }

    /// Update the crowd simulation
    pub fn update(self: *Self, dt: f32) !void {
        return self.updateDebug(dt, null);
    }

    pub fn updateDebug(self: *Self, dt: f32, debug: ?*CrowdAgentDebugInfo) !void {
        self.velocity_sample_count = 0;

        // Get active agents
        var active_list: [256]*CrowdAgent = undefined;
        var nagents: usize = 0;
        for (self.agents) |*agent| {
            if (agent.active and nagents < active_list.len) {
                active_list[nagents] = agent;
                nagents += 1;
            }
        }
        const agents = active_list[0..nagents];

        // Check that all agents still have valid paths
        try self.checkPathValidity(agents, dt);

        // Update async move request and path finder
        self.updateMoveRequest(dt);

        // Optimize path topology
        self.updateTopologyOptimization(agents, dt);

        // Update path queue
        self.path_queue.update(100);

        // Register agents to proximity grid
        self.grid.clear();
        for (agents, 0..) |ag, i| {
            const p = &ag.npos;
            const r = ag.params.radius;
            self.grid.addItem(@intCast(i), p[0] - r, p[2] - r, p[0] + r, p[2] + r);
        }

        // Update boundaries and find neighbors
        for (agents, 0..) |ag, i| {
            if (ag.state != .walking) continue;

            // Update boundary
            const update_thr = ag.params.collision_query_range * 0.25;
            if (math.vdist2DSqr(&ag.npos, ag.boundary.getCenter()) > update_thr * update_thr) {
                try ag.boundary.update(
                    ag.corridor.getFirstPoly(),
                    &ag.npos,
                    ag.params.collision_query_range,
                    self.navquery,
                    &self.filters[ag.params.query_filter_type],
                    self.allocator,
                );
            }

            // Find neighbors (simplified - using proximity grid)
            ag.nneis = 0;
            const range = ag.params.collision_query_range;
            var ids: [32]u16 = undefined;
            const nids = self.grid.queryItems(
                ag.npos[0] - range,
                ag.npos[2] - range,
                ag.npos[0] + range,
                ag.npos[2] + range,
                &ids,
            );

            for (ids[0..nids]) |id| {
                if (id == i) continue;
                if (ag.nneis >= MAX_NEIGHBOURS) break;

                const nei = agents[id];
                var diff = [3]f32{ 0, 0, 0 };
                math.vsub(&diff, &ag.npos, &nei.npos);
                if (@abs(diff[1]) >= (ag.params.height + nei.params.height) / 2.0) continue;
                diff[1] = 0;
                const dist_sq = math.vlenSqr(&diff);
                if (dist_sq > range * range) continue;

                ag.neis[ag.nneis] = .{ .idx = @intCast(id), .dist = dist_sq };
                ag.nneis += 1;
            }

            // 1-в-1 dtCrowd::update (DetourCrowd.cpp:1095): индексы соседей из
            // активного списка -> глобальные индексы агентов (для render/separation/collision).
            for (0..ag.nneis) |j| {
                ag.neis[j].idx = self.getAgentIndex(agents[@intCast(ag.neis[j].idx)]);
            }
        }

        // Find corners for steering
        for (agents) |ag| {
            if (ag.state != .walking) continue;
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;

            ag.ncorners = try ag.corridor.findCorners(
                &ag.corner_verts,
                &ag.corner_flags,
                &ag.corner_polys,
                MAX_CORNERS,
                self.navquery,
                &self.filters[ag.params.query_filter_type],
                self.allocator,
            );

            // Optimize path visibility
            if ((ag.params.update_flags & UpdateFlags.optimize_vis) != 0 and ag.ncorners > 0) {
                const target_idx: usize = @min(1, ag.ncorners - 1);
                const target_slice = ag.corner_verts[target_idx * 3 .. target_idx * 3 + 3];
                const target: [3]f32 = .{ target_slice[0], target_slice[1], target_slice[2] };
                try ag.corridor.optimizePathVisibility(
                    &target,
                    ag.params.path_optimization_range,
                    self.navquery,
                    &self.filters[ag.params.query_filter_type],
                    self.allocator,
                );
                // Debug-визуализация оптимизации пути для выделенного агента.
                if (debug) |d| {
                    if (self.getAgentIndex(ag) == d.idx) {
                        d.opt_start = ag.corridor.getPos().*; // 1в1: optStart = corridor.getPos()
                        d.opt_end = target;
                    }
                }
            } else if (debug) |d| {
                if (self.getAgentIndex(ag) == d.idx) {
                    d.opt_start = .{ 0, 0, 0 };
                    d.opt_end = .{ 0, 0, 0 };
                }
            }
        }

        // Trigger off-mesh connections (depends on corners).
        // 1-в-1 dtCrowd::update (DetourCrowd.cpp:1154-1193).
        for (agents) |ag| {
            if (ag.state != .walking) continue;
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;

            // Check
            const trigger_radius = ag.params.radius * 2.25;
            if (overOffmeshConnection(ag, trigger_radius)) {
                // Prepare to off-mesh connection.
                const idx: usize = @intCast(self.getAgentIndex(ag));
                const anim = &self.agent_anims[idx];

                // Adjust the path over the off-mesh connection.
                var refs = [2]PolyRef{ 0, 0 };
                const ok = ag.corridor.moveOverOffmeshConnection(
                    ag.corner_polys[ag.ncorners - 1],
                    &refs,
                    &anim.start_pos,
                    &anim.end_pos,
                    self.navquery,
                ) catch false;
                if (ok) {
                    math.vcopy(&anim.init_pos, &ag.npos);
                    anim.poly_ref = refs[1];
                    anim.active = true;
                    anim.t = 0.0;
                    anim.tmax = (math.vdist2D(&anim.start_pos, &anim.end_pos) / ag.params.max_speed) * 0.5;

                    ag.state = .offmesh;
                    ag.ncorners = 0;
                    ag.nneis = 0;
                    continue;
                } else {
                    // Path validity check will ensure that bad/blocked connections will be replanned.
                }
            }
        }

        // Calculate steering
        for (agents) |ag| {
            if (ag.state != .walking) continue;
            if (ag.target_state == .target_none) continue;

            var dvel = [3]f32{ 0, 0, 0 };

            if (ag.target_state == .target_velocity) {
                math.vcopy(&dvel, &ag.target_pos);
                ag.desired_speed = math.vlen(&ag.target_pos);
            } else {
                // Calculate steering direction
                if ((ag.params.update_flags & UpdateFlags.anticipate_turns) != 0) {
                    calcSmoothSteerDirection(ag, &dvel);
                } else {
                    calcStraightSteerDirection(ag, &dvel);
                }

                // Speed scale for slowing down at goal
                const slow_down_radius = ag.params.radius * 2.0;
                const speed_scale = getDistanceToGoal(ag, slow_down_radius) / slow_down_radius;

                ag.desired_speed = ag.params.max_speed;
                math.vscale(&dvel, &dvel, ag.desired_speed * speed_scale);
            }

            // Separation
            if ((ag.params.update_flags & UpdateFlags.separation) != 0) {
                const sep_dist = ag.params.collision_query_range;
                const inv_sep_dist = 1.0 / sep_dist;
                const sep_weight = ag.params.separation_weight;

                var w: f32 = 0;
                var disp = [3]f32{ 0, 0, 0 };

                for (0..ag.nneis) |j| {
                    const nei_idx: usize = @intCast(ag.neis[j].idx);
                    const nei = &self.agents[nei_idx];

                    var diff = [3]f32{ 0, 0, 0 };
                    math.vsub(&diff, &ag.npos, &nei.npos);
                    diff[1] = 0;

                    const dist_sqr = math.vlenSqr(&diff);
                    if (dist_sqr < 0.00001) continue;
                    if (dist_sqr > sep_dist * sep_dist) continue;

                    const dist = @sqrt(dist_sqr);
                    const weight = sep_weight * (1.0 - (dist * inv_sep_dist) * (dist * inv_sep_dist));

                    math.vmad(&disp, &disp, &diff, weight / dist);
                    w += 1.0;
                }

                if (w > 0.0001) {
                    math.vmad(&dvel, &dvel, &disp, 1.0 / w);
                    const speed_sqr = math.vlenSqr(&dvel);
                    const desired_sqr = ag.desired_speed * ag.desired_speed;
                    if (speed_sqr > desired_sqr) {
                        math.vscale(&dvel, &dvel, desired_sqr / speed_sqr);
                    }
                }
            }

            math.vcopy(&ag.dvel, &dvel);
        }

        // Velocity planning with obstacle avoidance
        for (agents) |ag| {
            if (ag.state != .walking) continue;

            if ((ag.params.update_flags & UpdateFlags.obstacle_avoid) != 0) {
                self.obstacle_query.reset();

                // Add neighbors as obstacles
                for (0..ag.nneis) |j| {
                    const nei_idx: usize = @intCast(ag.neis[j].idx);
                    const nei = &self.agents[nei_idx];
                    self.obstacle_query.addCircle(&nei.npos, nei.params.radius, &nei.vel, &nei.dvel);
                }

                // Add boundary segments as obstacles
                for (0..ag.boundary.getSegmentCount()) |j| {
                    const seg = ag.boundary.getSegment(j);
                    const seg_start = math.Vec3.init(seg[0], seg[1], seg[2]);
                    const seg_end = math.Vec3.init(seg[3], seg[4], seg[5]);
                    const ag_pos = math.Vec3.fromArray(&ag.npos);
                    if (math.triArea2D(ag_pos, seg_start, seg_end) < 0.0) continue;
                    self.obstacle_query.addSegment(seg[0..3], seg[3..6]);
                }

                // Sample new safe velocity (для выделенного агента пишем debug-сэмплы VO).
                const params = &self.obstacle_query_params[ag.params.obstacle_avoidance_type];
                const vod: ?*ObstacleAvoidanceDebugData = if (debug) |d|
                    (if (self.getAgentIndex(ag) == d.idx) d.vod else null)
                else
                    null;
                const ns = self.obstacle_query.sampleVelocityAdaptive(
                    &ag.npos,
                    ag.params.radius,
                    ag.desired_speed,
                    &ag.vel,
                    &ag.dvel,
                    &ag.nvel,
                    params,
                    vod,
                );
                self.velocity_sample_count += ns;
            } else {
                math.vcopy(&ag.nvel, &ag.dvel);
            }
        }

        // Integrate
        for (agents) |ag| {
            if (ag.state != .walking) continue;
            integrate(ag, dt);
        }

        // Handle collisions (simplified - 4 iterations)
        const COLLISION_RESOLVE_FACTOR: f32 = 0.7;
        var iter: usize = 0;
        while (iter < 4) : (iter += 1) {
            for (agents) |ag| {
                if (ag.state != .walking) continue;

                ag.disp = [3]f32{ 0, 0, 0 };
                var w: f32 = 0;

                for (0..ag.nneis) |j| {
                    const nei_idx: usize = @intCast(ag.neis[j].idx);
                    const nei = &self.agents[nei_idx];

                    var diff = [3]f32{ 0, 0, 0 };
                    math.vsub(&diff, &ag.npos, &nei.npos);
                    diff[1] = 0;

                    var dist = math.vlenSqr(&diff);
                    if (dist > (ag.params.radius + nei.params.radius) * (ag.params.radius + nei.params.radius)) {
                        continue;
                    }
                    dist = @sqrt(dist);
                    var pen = (ag.params.radius + nei.params.radius) - dist;

                    if (dist < 0.0001) {
                        // Agents on top of each other (idx0 -> глобальный индекс, как nei_idx)
                        if (@as(i32, @intCast(self.getAgentIndex(ag))) > @as(i32, @intCast(nei_idx))) {
                            diff[0] = -ag.dvel[2];
                            diff[2] = ag.dvel[0];
                        } else {
                            diff[0] = ag.dvel[2];
                            diff[2] = -ag.dvel[0];
                        }
                        pen = 0.01;
                    } else {
                        pen = (1.0 / dist) * (pen * 0.5) * COLLISION_RESOLVE_FACTOR;
                    }

                    math.vmad(&ag.disp, &ag.disp, &diff, pen);
                    w += 1.0;
                }

                if (w > 0.0001) {
                    math.vscale(&ag.disp, &ag.disp, 1.0 / w);
                }
            }

            for (agents) |ag| {
                if (ag.state != .walking) continue;
                math.vadd(&ag.npos, &ag.npos, &ag.disp);
            }
        }

        // Move agents along navmesh
        for (agents) |ag| {
            if (ag.state != .walking) continue;

            _ = try ag.corridor.movePosition(
                &ag.npos,
                self.navquery,
                &self.filters[ag.params.query_filter_type],
                self.allocator,
            );
            math.vcopy(&ag.npos, ag.corridor.getPos());

            // Truncate corridor if not using path
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) {
                ag.corridor.reset(ag.corridor.getFirstPoly(), &ag.npos);
                ag.partial = false;
            }
        }

        // Update agents using off-mesh connection.
        // 1-в-1 dtCrowd::update (DetourCrowd.cpp:1442-1479).
        for (agents) |ag| {
            const idx: usize = @intCast(self.getAgentIndex(ag));
            const anim = &self.agent_anims[idx];
            if (!anim.active) continue;

            anim.t += dt;
            if (anim.t > anim.tmax) {
                // Reset animation
                anim.active = false;
                // Prepare agent for walking.
                ag.state = .walking;
                continue;
            }

            // Update position
            const ta = anim.tmax * 0.15;
            const tb = anim.tmax;
            if (anim.t < ta) {
                const u = tween(anim.t, 0.0, ta);
                math.vlerp(&ag.npos, &anim.init_pos, &anim.start_pos, u);
            } else {
                const u = tween(anim.t, ta, tb);
                math.vlerp(&ag.npos, &anim.start_pos, &anim.end_pos, u);
            }

            // Update velocity.
            ag.vel = [3]f32{ 0, 0, 0 };
            ag.dvel = [3]f32{ 0, 0, 0 };
        }
    }

    /// Get agent by index
    pub fn getAgent(self: *const Self, idx: i32) ?*const CrowdAgent {
        if (idx < 0 or idx >= self.max_agents) return null;
        return &self.agents[@intCast(idx)];
    }

    /// Get editable agent by index
    pub fn getEditableAgent(self: *Self, idx: i32) ?*CrowdAgent {
        if (idx < 0 or idx >= self.max_agents) return null;
        return &self.agents[@intCast(idx)];
    }

    /// Update agent params (1-в-1 dtCrowd::updateAgentParameters — копирует params в агента).
    /// Нужно для применения изменённых Options ко ВСЕМ уже созданным агентам.
    pub fn updateAgentParameters(self: *Self, idx: i32, params: *const CrowdAgentParams) void {
        if (idx < 0 or idx >= self.max_agents) return;
        self.agents[@intCast(idx)].params = params.*;
    }

    /// Get agent count
    pub fn getAgentCount(self: *const Self) usize {
        return self.max_agents;
    }

    /// Set obstacle avoidance params
    pub fn setObstacleAvoidanceParams(
        self: *Self,
        idx: usize,
        params: *const ObstacleAvoidanceParams,
    ) void {
        if (idx < MAX_OBSTAVOIDANCE_PARAMS) {
            self.obstacle_query_params[idx] = params.*;
        }
    }

    /// Get obstacle avoidance params
    pub fn getObstacleAvoidanceParams(self: *const Self, idx: usize) ?*const ObstacleAvoidanceParams {
        if (idx < MAX_OBSTAVOIDANCE_PARAMS) {
            return &self.obstacle_query_params[idx];
        }
        return null;
    }

    /// Get query filter
    pub fn getFilter(self: *const Self, idx: usize) ?*const QueryFilter {
        if (idx < MAX_QUERY_FILTER_TYPE) {
            return &self.filters[idx];
        }
        return null;
    }

    /// navquery очереди путей (для визуализации узлов A*-поиска — Show Nodes).
    pub fn getPathQueueNavQuery(self: *const Self) *const NavMeshQuery {
        return self.path_queue.getNavQuery();
    }

    /// Get editable query filter
    pub fn getEditableFilter(self: *Self, idx: usize) ?*QueryFilter {
        if (idx < MAX_QUERY_FILTER_TYPE) {
            return &self.filters[idx];
        }
        return null;
    }

    /// Get query half extents
    pub fn getQueryHalfExtents(self: *const Self) *const [3]f32 {
        return &self.agent_placement_half_extents;
    }

    /// Get velocity sample count
    pub fn getVelocitySampleCount(self: *const Self) usize {
        return self.velocity_sample_count;
    }

    /// Get proximity grid
    pub fn getGrid(self: *const Self) *const ProximityGrid {
        return &self.grid;
    }

    /// Get path queue
    pub fn getPathQueue(self: *const Self) *const PathQueue {
        return &self.path_queue;
    }

    /// Get nav mesh query
    pub fn getNavMeshQuery(self: *const Self) *const NavMeshQuery {
        return self.navquery;
    }

    // ========================================================================
    // Private helper functions
    // ========================================================================

    /// Get agent index from pointer
    fn getAgentIndex(self: *const Self, agent: *const CrowdAgent) i32 {
        const agents_start = @intFromPtr(&self.agents[0]);
        const agent_ptr = @intFromPtr(agent);
        const offset = agent_ptr - agents_start;
        const index = offset / @sizeOf(CrowdAgent);
        return @intCast(index);
    }

    /// Add agent to path queue sorted by replan time (oldest first)
    fn addToPathQueue(
        newag: *CrowdAgent,
        queue: []*CrowdAgent,
        nqueue: usize,
        max_agents: usize,
    ) usize {
        if (nqueue >= max_agents) return nqueue;

        // Insert based on greatest time
        var slot: usize = nqueue;

        if (nqueue > 0) {
            // Find insertion point
            for (0..nqueue) |i| {
                if (newag.target_replan_time > queue[i].target_replan_time) {
                    slot = i;
                    break;
                }
            }

            // Shift elements to make room if not inserting at end
            if (slot < nqueue) {
                var j = nqueue;
                while (j > slot) : (j -= 1) {
                    queue[j] = queue[j - 1];
                }
            }
        }

        queue[slot] = newag;
        return nqueue + 1;
    }

    /// Add agent to optimization queue sorted by topology opt time (oldest first)
    fn addToOptQueue(
        newag: *CrowdAgent,
        queue: []*CrowdAgent,
        nqueue: usize,
        max_agents: usize,
    ) usize {
        if (nqueue >= max_agents) return nqueue;

        // Insert based on greatest time
        var slot: usize = nqueue;

        if (nqueue > 0) {
            // Find insertion point
            for (0..nqueue) |i| {
                if (newag.topology_opt_time > queue[i].topology_opt_time) {
                    slot = i;
                    break;
                }
            }

            // Shift elements to make room if not inserting at end
            if (slot < nqueue) {
                var j = nqueue;
                while (j > slot) : (j -= 1) {
                    queue[j] = queue[j - 1];
                }
            }
        }

        queue[slot] = newag;
        return nqueue + 1;
    }

    /// Request move target with replan flag
    fn requestMoveTargetReplan(self: *Self, idx: i32, ref: PolyRef, pos: *const [3]f32) bool {
        if (idx < 0 or idx >= self.max_agents) return false;
        if (ref == 0) return false;

        var ag = &self.agents[@intCast(idx)];
        ag.target_ref = ref;
        math.vcopy(&ag.target_pos, pos);
        ag.target_pathq_ref = INVALID_QUEUE_REF;
        ag.target_replan = true;
        ag.target_state = .target_requesting;

        return true;
    }

    // ========================================================================
    // Path validation and optimization functions
    // ========================================================================

    /// Check path validity and recover invalid paths
    fn checkPathValidity(self: *Self, agents: []*CrowdAgent, dt: f32) !void {
        const CHECK_LOOKAHEAD: usize = 10;
        const TARGET_REPLAN_DELAY: f32 = 1.0; // seconds

        for (agents) |ag| {
            if (ag.state != .walking) continue;

            ag.target_replan_time += dt;

            var replan = false;

            // First check that the current location is valid
            const idx = self.getAgentIndex(ag);
            var agent_pos = ag.npos;
            var agent_ref = ag.corridor.getFirstPoly();

            if (!self.navquery.isValidPolyRef(agent_ref, &self.filters[ag.params.query_filter_type])) {
                // Current location is not valid, try to reposition
                var nearest = agent_pos;
                agent_ref = 0;
                _ = try self.navquery.findNearestPoly(
                    &ag.npos,
                    &self.agent_placement_half_extents,
                    &self.filters[ag.params.query_filter_type],
                    &agent_ref,
                    &nearest,
                );
                agent_pos = nearest;

                if (agent_ref == 0) {
                    // Could not find location in navmesh, set state to invalid
                    ag.corridor.reset(0, &agent_pos);
                    ag.partial = false;
                    ag.boundary.reset();
                    ag.state = .invalid;
                    continue;
                }

                // Make sure the first polygon is valid
                _ = ag.corridor.fixPathStart(agent_ref, &agent_pos);
                ag.boundary.reset();
                ag.npos = agent_pos;

                replan = true;
            }

            // If the agent does not have move target or is controlled by velocity, no need to recover
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;

            // Try to recover move request position
            if (ag.target_state != .target_none and ag.target_state != .target_failed) {
                if (!self.navquery.isValidPolyRef(ag.target_ref, &self.filters[ag.params.query_filter_type])) {
                    // Current target is not valid, try to reposition
                    var nearest = ag.target_pos;
                    ag.target_ref = 0;
                    _ = try self.navquery.findNearestPoly(
                        &ag.target_pos,
                        &self.agent_placement_half_extents,
                        &self.filters[ag.params.query_filter_type],
                        &ag.target_ref,
                        &nearest,
                    );
                    ag.target_pos = nearest;
                    replan = true;
                }

                if (ag.target_ref == 0) {
                    // Failed to reposition target, fail move request
                    ag.corridor.reset(agent_ref, &agent_pos);
                    ag.partial = false;
                    ag.target_state = .target_none;
                }
            }

            // If nearby corridor is not valid, replan
            if (!ag.corridor.isValid(CHECK_LOOKAHEAD, self.navquery, &self.filters[ag.params.query_filter_type])) {
                replan = true;
            }

            // If the end of the path is near and it is not the requested location, replan
            if (ag.target_state == .target_valid) {
                if (ag.target_replan_time > TARGET_REPLAN_DELAY and
                    ag.corridor.getPathCount() < CHECK_LOOKAHEAD and
                    ag.corridor.getLastPoly() != ag.target_ref)
                {
                    replan = true;
                }
            }

            // Try to replan path to goal
            if (replan) {
                if (ag.target_state != .target_none) {
                    _ = self.requestMoveTargetReplan(idx, ag.target_ref, &ag.target_pos);
                }
            }
        }
    }

    /// Process move requests asynchronously through the sliced path queue.
    /// 1:1 with dtCrowd::updateMoveRequest (DetourCrowd.cpp:677): a quick sliced
    /// search runs inline for new requests; longer/unreachable plans are queued
    /// (target_waiting_for_queue -> _for_path), polled, then merged with the
    /// existing corridor (trackback removal) before setCorridor.
    fn updateMoveRequest(self: *Self, _: f32) void {
        const PATH_MAX_AGENTS = 8;
        const MAX_ITERS_PER_UPDATE = 100;
        var queue: [PATH_MAX_AGENTS]*CrowdAgent = undefined;
        var nqueue: usize = 0;

        // Fire off new requests.
        for (self.agents) |*ag| {
            if (!ag.active) continue;
            if (ag.state == .invalid) continue;
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;

            if (ag.target_state == .target_requesting) {
                const path = ag.corridor.getPath();

                const MAX_RES = 32;
                var req_pos: [3]f32 = .{ 0, 0, 0 };
                var req_path: [MAX_RES]PolyRef = undefined;
                var req_path_count: usize = 0;

                const filter = &self.filters[ag.params.query_filter_type];

                // Quick search towards the goal.
                const MAX_ITER = 20;
                _ = self.navquery.initSlicedFindPath(path[0], ag.target_ref, &ag.npos, &ag.target_pos, filter, 0);
                _ = self.navquery.updateSlicedFindPath(MAX_ITER, null);
                const status = if (ag.target_replan)
                    // Try to use existing steady path during replan if possible.
                    self.navquery.finalizeSlicedFindPathPartial(path, req_path[0..], &req_path_count)
                else
                    // Try to move towards target when goal changes.
                    self.navquery.finalizeSlicedFindPath(req_path[0..], &req_path_count);

                if (!status.isFailure() and req_path_count > 0) {
                    if (req_path[req_path_count - 1] != ag.target_ref) {
                        // Partial path, constrain target inside the last polygon.
                        if (self.navquery.closestPointOnPoly(req_path[req_path_count - 1], &ag.target_pos, &req_pos, null)) |s2| {
                            if (s2.isFailure()) req_path_count = 0;
                        } else |_| {
                            req_path_count = 0;
                        }
                    } else {
                        math.vcopy(&req_pos, &ag.target_pos);
                    }
                } else {
                    req_path_count = 0;
                }

                if (req_path_count == 0) {
                    // Could not find path, start the request from current location.
                    math.vcopy(&req_pos, &ag.npos);
                    req_path[0] = path[0];
                    req_path_count = 1;
                }

                ag.corridor.setCorridor(&req_pos, req_path[0..req_path_count]);
                ag.boundary.reset();
                ag.partial = false;

                if (req_path[req_path_count - 1] == ag.target_ref) {
                    ag.target_state = .target_valid;
                    ag.target_replan_time = 0.0;
                } else {
                    // The path is longer or potentially unreachable, full plan.
                    ag.target_state = .target_waiting_for_queue;
                }
            }

            if (ag.target_state == .target_waiting_for_queue) {
                nqueue = addToPathQueue(ag, queue[0..], nqueue, PATH_MAX_AGENTS);
            }
        }

        for (queue[0..nqueue]) |ag| {
            ag.target_pathq_ref = self.path_queue.request(
                ag.corridor.getLastPoly(),
                ag.target_ref,
                ag.corridor.getTarget(),
                &ag.target_pos,
                &self.filters[ag.params.query_filter_type],
            );
            if (ag.target_pathq_ref != INVALID_QUEUE_REF) {
                ag.target_state = .target_waiting_for_path;
            }
        }

        // Update requests.
        self.path_queue.update(MAX_ITERS_PER_UPDATE);

        // Process path results.
        for (self.agents) |*ag| {
            if (!ag.active) continue;
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;

            if (ag.target_state == .target_waiting_for_path) {
                const status = self.path_queue.getRequestStatus(ag.target_pathq_ref);
                if (status.isFailure()) {
                    // Path find failed, retry if the target location is still valid.
                    ag.target_pathq_ref = INVALID_QUEUE_REF;
                    ag.target_state = if (ag.target_ref != 0) .target_requesting else .target_failed;
                    ag.target_replan_time = 0.0;
                } else if (status.isSuccess()) {
                    const path = ag.corridor.getPath();
                    const npath = ag.corridor.getPathCount();

                    var target_pos: [3]f32 = ag.target_pos;
                    const res = self.path_result;
                    var valid = true;
                    var nres: usize = 0;
                    const rstatus = self.path_queue.getPathResult(ag.target_pathq_ref, res, &nres);
                    if (rstatus.isFailure() or nres == 0) valid = false;
                    ag.partial = rstatus.partial_result;

                    // The last ref of the old path should match where the request was issued.
                    if (valid and path[npath - 1] != res[0]) valid = false;

                    if (valid) {
                        // Put the old path in front of the new result.
                        if (npath > 1) {
                            if ((npath - 1) + nres > res.len) nres = res.len - (npath - 1);
                            // memmove res+npath-1 <- res (shift right)
                            std.mem.copyBackwards(PolyRef, res[npath - 1 .. npath - 1 + nres], res[0..nres]);
                            @memcpy(res[0 .. npath - 1], path[0 .. npath - 1]);
                            nres += npath - 1;

                            // Remove trackbacks.
                            var nres_i: isize = @intCast(nres);
                            var j: isize = 0;
                            while (j < nres_i) : (j += 1) {
                                if (j - 1 >= 0 and j + 1 < nres_i) {
                                    const jm1: usize = @intCast(j - 1);
                                    const jp1: usize = @intCast(j + 1);
                                    if (res[jm1] == res[jp1]) {
                                        const cnt: usize = @intCast(nres_i - (j + 1));
                                        std.mem.copyForwards(PolyRef, res[jm1 .. jm1 + cnt], res[jp1 .. jp1 + cnt]);
                                        nres_i -= 2;
                                        j -= 2;
                                    }
                                }
                            }
                            nres = @intCast(nres_i);
                        }

                        // Check for partial path.
                        if (res[nres - 1] != ag.target_ref) {
                            var nearest: [3]f32 = undefined;
                            if (self.navquery.closestPointOnPoly(res[nres - 1], &target_pos, &nearest, null)) |s3| {
                                if (s3.isSuccess()) math.vcopy(&target_pos, &nearest) else valid = false;
                            } else |_| {
                                valid = false;
                            }
                        }
                    }

                    if (valid) {
                        ag.corridor.setCorridor(&target_pos, res[0..nres]);
                        ag.boundary.reset();
                        ag.target_state = .target_valid;
                    } else {
                        ag.target_state = .target_failed;
                    }
                    ag.target_replan_time = 0.0;
                }
            }
        }
    }

    /// Optimize path topology for agents
    fn updateTopologyOptimization(self: *Self, agents: []*CrowdAgent, dt: f32) void {
        const OPT_TIME_THR: f32 = 0.5; // seconds
        const OPT_MAX_AGENTS: usize = 1;

        var queue: [OPT_MAX_AGENTS]*CrowdAgent = undefined;
        var nqueue: usize = 0;

        for (agents) |ag| {
            if (ag.state != .walking) continue;
            if (ag.target_state == .target_none or ag.target_state == .target_velocity) continue;
            if ((ag.params.update_flags & UpdateFlags.optimize_topo) == 0) continue;

            ag.topology_opt_time += dt;
            if (ag.topology_opt_time >= OPT_TIME_THR) {
                nqueue = addToOptQueue(ag, &queue, nqueue, OPT_MAX_AGENTS);
            }
        }

        // Optimize topology for queued agents
        for (0..nqueue) |i| {
            const ag = queue[i];
            _ = ag.corridor.optimizePathTopology(
                self.navquery,
                &self.filters[ag.params.query_filter_type],
                self.allocator,
            ) catch false;
            ag.topology_opt_time = 0;
        }
    }
};

test "Crowd basic" {
    const allocator = std.testing.allocator;

    // Create a minimal navmesh for testing
    var nav_params = detour.NavMeshParams.init();
    nav_params.orig = math.Vec3.init(0, 0, 0);
    nav_params.tile_width = 10.0;
    nav_params.tile_height = 10.0;
    nav_params.max_tiles = 128;
    nav_params.max_polys = 256;

    var navmesh = try NavMesh.init(allocator, nav_params);
    defer navmesh.deinit();

    var crowd = try Crowd.init(allocator, 10, 0.6, &navmesh);
    defer crowd.deinit();

    try std.testing.expectEqual(@as(usize, 10), crowd.getAgentCount());

    const pos = [3]f32{ 0, 0, 0 };
    const params = CrowdAgentParams.init();

    const idx = try crowd.addAgent(&pos, &params);
    try std.testing.expect(idx >= 0);

    const agent = crowd.getAgent(idx);
    try std.testing.expect(agent != null);
    try std.testing.expect(agent.?.active);

    crowd.removeAgent(idx);
    const removed_agent = crowd.getAgent(idx);
    try std.testing.expect(removed_agent != null);
    try std.testing.expect(!removed_agent.?.active);
}
