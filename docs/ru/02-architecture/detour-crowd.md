# DetourCrowd

Multi-agent crowd simulation с collision avoidance.

---

## Overview

DetourCrowd управляет множеством агентов, симулирует их движение по NavMesh с:
- **Local steering** - локальное управление движением
- **Collision avoidance** - избежание столкновений (RVO)
- **Path following** - следование по пути
- **Neighbor detection** - обнаружение соседних агентов
- **Dynamic replanning** - динамическое перепланирование

```
Agents → Crowd Manager → Update Loop
         ├─ Path following
         ├─ Collision avoidance
         ├─ Local steering
         └─ Neighbor queries
```

---

## Crowd

Основной manager для crowd simulation.

### Structure

```zig
pub const Crowd = struct {
    allocator: Allocator,
    max_agents: i32,
    agents: []CrowdAgent,
    active_agents: []i32,
    agent_anims: []CrowdAgentAnimation,
    path_queue: PathQueue,
    obstacle_query: [MAX_OBSTAVOIDANCE_PARAMS]ObstacleAvoidanceQuery,
    grid: ProximityGrid,
    path_result: []PolyRef,
    nav_query: *NavMeshQuery,
    nav_mesh: *const NavMesh,
    filters: [MAX_QUERY_FILTER_TYPE]QueryFilter,
    obstacle_query_params: [MAX_OBSTAVOIDANCE_PARAMS]ObstacleAvoidanceParams,
    velocity_sample_count: i32,

    pub fn init(
        allocator: Allocator,
        max_agents: i32,
        max_agent_radius: f32,
        nav: *const NavMesh,
    ) !*Crowd

    pub fn deinit(self: *Crowd) void

    // Agent management
    pub fn addAgent(self: *Crowd, pos: *const [3]f32, params: *const CrowdAgentParams) !i32
    pub fn removeAgent(self: *Crowd, idx: i32) void
    pub fn getAgent(self: *Crowd, idx: i32) ?*CrowdAgent
    pub fn getAgentCount(self: *const Crowd) i32

    // Agent targets
    pub fn requestMoveTarget(self: *Crowd, idx: i32, ref: PolyRef, pos: *const [3]f32) !void
    pub fn requestMoveVelocity(self: *Crowd, idx: i32, vel: *const [3]f32) !void
    pub fn resetMoveTarget(self: *Crowd, idx: i32) void

    // Update
    pub fn update(self: *Crowd, dt: f32, debug: ?*DebugData) !void

    // Configuration
    pub fn setObstacleAvoidanceParams(
        self: *Crowd,
        idx: usize,
        params: *const ObstacleAvoidanceParams,
    ) void

    pub fn getObstacleAvoidanceParams(self: *const Crowd, idx: usize) *const ObstacleAvoidanceParams

    pub fn getFilter(self: *Crowd, i: usize) *QueryFilter
};
```

---

## CrowdAgent

Отдельный агент в crowd.

### Structure

```zig
pub const CrowdAgent = struct {
    active: bool,
    state: CrowdAgentState,
    corridor: PathCorridor,
    boundary: LocalBoundary,
    topologyOptTime: f32,

    // Current state
    npos: [3]f32,                // Position
    nvel: [3]f32,                // Desired velocity
    vel: [3]f32,                 // Actual velocity
    dvel: [3]f32,                // Desired velocity (before avoidance)

    // Path
    ncorners: usize,
    corner_verts: [MAX_CORNERS * 3]f32,
    corner_flags: [MAX_CORNERS]u8,
    corner_polys: [MAX_CORNERS]PolyRef,

    // Neighbors
    nneis: usize,
    neis: [MAX_NEIGHBOURS]CrowdNeighbour,

    // Target
    target_ref: PolyRef,
    target_pos: [3]f32,
    target_pathq_ref: PathQueueRef,
    target_replan: bool,
    target_state: MoveRequestState,

    // Parameters
    params: CrowdAgentParams,
};

pub const CrowdAgentState = enum(u8) {
    invalid,
    walking,
    offmesh,
};

pub const CrowdNeighbour = struct {
    idx: i32,                    // Agent index
    dist: f32,                   // Distance
};
```

---

## CrowdAgentParams

Конфигурация агента.

```zig
pub const CrowdAgentParams = struct {
    radius: f32,                         // Agent radius
    height: f32,                         // Agent height
    max_acceleration: f32,               // Max acceleration
    max_speed: f32,                      // Max speed
    collision_query_range: f32,          // Collision detection range
    path_optimization_range: f32,        // Path optimization range
    separation_weight: f32,              // Separation strength
    update_flags: u8,                    // Update behavior flags
    obstacle_avoidance_type: u8,         // Avoidance config index
    query_filter_type: u8,               // Query filter index
    user_data: ?*anyopaque,              // User data

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

pub const UpdateFlags = struct {
    pub const anticipate_turns: u8 = 1;
    pub const obstacle_avoid: u8 = 2;
    pub const separation: u8 = 4;
    pub const optimize_vis: u8 = 8;
    pub const optimize_topo: u8 = 16;
    pub const all: u8 = anticipate_turns | obstacle_avoid | separation | optimize_vis;
};
```

---

## Obstacle Avoidance (RVO)

Velocity obstacles для collision avoidance.

### Structure

```zig
pub const ObstacleAvoidanceParams = struct {
    vel_bias: f32,               // Bias towards desired velocity
    weight_desired_vel: f32,     // Weight for desired velocity
    weight_current_vel: f32,     // Weight for current velocity
    weight_side: f32,            // Weight for side preference
    weight_toi: f32,             // Weight for time-of-impact
    horiz_time: f32,             // Prediction horizon
    grid_size: u8,               // Sample grid size
    adaptive_divs: u8,           // Adaptive sampling divisions
    adaptive_rings: u8,          // Adaptive sampling rings
    adaptive_depth: u8,          // Adaptive sampling depth
};

pub const ObstacleAvoidanceQuery = struct {
    // Obstacles
    circles: []ObstacleCircle,
    segments: []ObstacleSegment,

    // Sampling
    params: ObstacleAvoidanceParams,

    pub fn init(allocator: Allocator, max_circles: usize, max_segments: usize) !*ObstacleAvoidanceQuery
    pub fn deinit(self: *ObstacleAvoidanceQuery) void

    pub fn reset(self: *ObstacleAvoidanceQuery) void

    pub fn addCircle(
        self: *ObstacleAvoidanceQuery,
        pos: *const [3]f32,
        radius: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
    ) void

    pub fn sampleVelocityAdaptive(
        self: *ObstacleAvoidanceQuery,
        pos: *const [3]f32,
        radius: f32,
        vmax: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
        nvel: *[3]f32,
        params: *const ObstacleAvoidanceParams,
        debug: ?*DebugData,
    ) i32
};
```

---

## Update Loop

Основной цикл обновления агентов.

### Update Stages

```zig
pub fn update(self: *Crowd, dt: f32, debug: ?*DebugData) !void {
    // 1. Check path validity
    for (active_agents) |agent_idx| {
        checkPathValidity(agent, dt);
    }

    // 2. Update topology optimization
    for (active_agents) |agent_idx| {
        updateTopologyOptimization(agent, dt);
    }

    // 3. Trigger path requests
    for (active_agents) |agent_idx| {
        triggerOffMeshConnections(agent);
    }

    // 4. Update async path queue
    path_queue.update(max_path_queue_nodes);

    // 5. Read path queue results
    for (active_agents) |agent_idx| {
        readPathQueueResults(agent);
    }

    // 6. Update move request
    for (active_agents) |agent_idx| {
        updateMoveRequest(agent, dt);
    }

    // 7. Find neighbors
    for (active_agents) |agent_idx| {
        findNeighbors(agent);
    }

    // 8. Plan steering
    for (active_agents) |agent_idx| {
        planSteering(agent, dt);
    }

    // 9. Velocity planning (obstacle avoidance)
    for (active_agents) |agent_idx| {
        velocityPlanning(agent, dt, debug);
    }

    // 10. Integrate
    for (active_agents) |agent_idx| {
        integrate(agent, dt);
    }

    // 11. Handle collisions
    for (active_agents) |agent_idx| {
        handleCollisions(agent);
    }

    // 12. Move along surface
    for (active_agents) |agent_idx| {
        moveAlongSurface(agent);
    }
}
```

---

## Path Following

Path corridor для dynamic path following.

```zig
pub const PathCorridor = struct {
    path: []PolyRef,
    path_count: i32,
    max_path: i32,
    pos: [3]f32,
    target: [3]f32,

    pub fn init(allocator: Allocator, max_path: i32) !PathCorridor
    pub fn deinit(self: *PathCorridor, allocator: Allocator) void

    pub fn reset(self: *PathCorridor, ref: PolyRef, pos: *const [3]f32) void

    pub fn findCorners(
        self: *PathCorridor,
        corners: []f32,
        corner_flags: []u8,
        corner_polys: []PolyRef,
        max_corners: i32,
        nav_query: *NavMeshQuery,
        filter: *const QueryFilter,
    ) !i32

    pub fn optimizePathVisibility(
        self: *PathCorridor,
        next: *const [3]f32,
        path_opt_range: f32,
        nav_query: *NavMeshQuery,
        filter: *const QueryFilter,
    ) void

    pub fn optimizePathTopology(
        self: *PathCorridor,
        nav_query: *NavMeshQuery,
        filter: *const QueryFilter,
    ) !bool

    pub fn moveOverOffmeshConnection(
        self: *PathCorridor,
        offmesh_con_ref: PolyRef,
        refs: []PolyRef,
        start_pos: *[3]f32,
        end_pos: *[3]f32,
        nav_query: *NavMeshQuery,
    ) !bool

    pub fn movePosition(
        self: *PathCorridor,
        npos: *const [3]f32,
        nav_query: *NavMeshQuery,
        filter: *const QueryFilter,
    ) !bool
};
```

---

## Example Usage

### Basic Crowd Simulation

```zig
const std = @import("std");
const nav = @import("zig-recast");

pub fn crowdExample(
    allocator: Allocator,
    navmesh: *const nav.detour.NavMesh,
) !void {
    // 1. Create crowd manager
    var crowd = try nav.detour_crowd.Crowd.init(
        allocator,
        100,    // Max 100 agents
        0.6,    // Max agent radius
        navmesh,
    );
    defer crowd.deinit();

    // 2. Configure obstacle avoidance
    var avoid_params = nav.detour_crowd.ObstacleAvoidanceParams{
        .vel_bias = 0.4,
        .weight_desired_vel = 2.0,
        .weight_current_vel = 0.75,
        .weight_side = 0.75,
        .weight_toi = 2.5,
        .horiz_time = 2.5,
        .grid_size = 33,
        .adaptive_divs = 7,
        .adaptive_rings = 2,
        .adaptive_depth = 5,
    };
    crowd.setObstacleAvoidanceParams(0, &avoid_params);

    // 3. Add agents
    var agent_params = nav.detour_crowd.CrowdAgentParams.init();
    agent_params.radius = 0.6;
    agent_params.height = 2.0;
    agent_params.max_acceleration = 8.0;
    agent_params.max_speed = 3.5;

    const agent_id = try crowd.addAgent(&[3]f32{ 0, 0, 0 }, &agent_params);

    // 4. Set target
    const target_pos = [3]f32{ 10, 0, 10 };
    const extents = [3]f32{ 2, 4, 2 };
    const filter = crowd.getFilter(0);

    var target_ref: nav.detour.PolyRef = 0;
    try crowd.nav_query.findNearestPoly(&target_pos, &extents, filter, &target_ref, null);

    try crowd.requestMoveTarget(agent_id, target_ref, &target_pos);

    // 5. Update loop
    const dt: f32 = 1.0 / 60.0;  // 60 FPS
    var time: f32 = 0;

    while (time < 10.0) : (time += dt) {
        try crowd.update(dt, null);

        // Get agent state
        const agent = crowd.getAgent(agent_id).?;
        std.debug.print("Agent pos: ({d:.2}, {d:.2}, {d:.2})\n", .{
            agent.npos[0],
            agent.npos[1],
            agent.npos[2],
        });

        // Check if reached target
        const dist = std.math.sqrt(
            (agent.npos[0] - target_pos[0]) * (agent.npos[0] - target_pos[0]) +
                (agent.npos[2] - target_pos[2]) * (agent.npos[2] - target_pos[2]),
        );

        if (dist < 1.0) {
            std.debug.print("Target reached!\n", .{});
            break;
        }
    }
}
```

---

## Constants

```zig
pub const MAX_NEIGHBOURS: usize = 6;
pub const MAX_CORNERS: usize = 4;
pub const MAX_OBSTAVOIDANCE_PARAMS: usize = 8;
pub const MAX_QUERY_FILTER_TYPE: usize = 16;
```

---

## Best Practices

### 1. Agent Configuration

```zig
// Fast aggressive agent
var params = CrowdAgentParams.init();
params.max_speed = 5.0;
params.max_acceleration = 12.0;
params.separation_weight = 3.0;

// Slow cautious agent
params.max_speed = 2.0;
params.max_acceleration = 4.0;
params.separation_weight = 1.0;
```

### 2. Update Frequency

```zig
// 60 FPS - good for games
const dt = 1.0 / 60.0;

// 30 FPS - sufficient for many scenarios
const dt = 1.0 / 30.0;

// Variable timestep
const dt = time_since_last_update;
```

### 3. Neighbor Detection

```zig
// Larger collision query range for crowded areas
params.collision_query_range = 15.0;

// Smaller range for sparse environments
params.collision_query_range = 8.0;
```

---

## Performance

**Time Complexity:** O(N²) for neighbor queries (можно оптимизировать с proximity grid)

**Memory:** ~500 bytes per agent

**Recommended:** До 100-200 агентов на современном CPU при 60 FPS

---

## See Also

- 📖 [Detour API](../03-api-reference/detour-api.md)
- 🏗️ [Detour Pipeline](detour-pipeline.md)
- 📚 [Pathfinding Guide](../04-guides/pathfinding.md)
