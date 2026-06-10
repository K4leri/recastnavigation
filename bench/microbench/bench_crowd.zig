//! Bench group: detour_crowd.obstacle_avoidance leaf fns (orig) + analogs. Aggregated by ../microbench.zig.
const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;
const ProximityGrid = nav.detour_crowd.ProximityGrid;

const alloc = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// normalizeArray — orig
// ---------------------------------------------------------------------------

fn runNormalizeArray(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var arr = [8]f32{ 0.1 + f, 0.5, 0.9, 0.2, 0.8, 0.3, 0.7 + f * 0.01, 0.4 };
    nav.detour_crowd.obstacle_avoidance.normalizeArray(arr[0..], 8);
    dna(arr[0]);
}
fn checkNormalizeArray() bool {
    var arr = [8]f32{ 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0 };
    nav.detour_crowd.obstacle_avoidance.normalizeArray(arr[0..], 8);
    // linear ramp 10..80 -> should map to 0..1 uniformly
    if (@abs(arr[0] - 0.0) > 1e-4) return false;
    if (@abs(arr[7] - 1.0) > 1e-4) return false;
    // all values must be in [0,1]
    for (arr) |v| {
        if (v < 0.0 or v > 1.0) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// normalizeArray — analog: single-pass structure but SAME ops (multiply by
// reciprocal of range) -> TIE.  Difference: inline the clamp via manual
// comparison instead of std.math.clamp.  Ops are identical to orig (same
// min/max scan + 1/range * elem) so results are bit-identical.
// ---------------------------------------------------------------------------

fn normalizeArray_analog(arr: []f32, n: usize) void {
    var mn: f32 = std.math.floatMax(f32);
    var mx: f32 = -std.math.floatMax(f32);
    for (0..n) |k| {
        mn = @min(mn, arr[k]);
        mx = @max(mx, arr[k]);
    }
    const range = mx - mn;
    const s: f32 = if (range > 0.001) 1.0 / range else 1.0;
    for (0..n) |k| {
        const v = (arr[k] - mn) * s;
        arr[k] = if (v < 0.0) 0.0 else if (v > 1.0) 1.0 else v;
    }
}

fn runNormalizeArrayAnalog(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var arr = [8]f32{ 0.1 + f, 0.5, 0.9, 0.2, 0.8, 0.3, 0.7 + f * 0.01, 0.4 };
    normalizeArray_analog(arr[0..], 8);
    dna(arr[0]);
}
fn checkNormalizeArrayAnalog() bool {
    // EXACT identity gate vs lib orig over >= 2000 varied inputs.
    var seed: u32 = 0xdeadbeef;
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        var orig_arr: [8]f32 = undefined;
        var analog_arr: [8]f32 = undefined;
        for (0..8) |j| {
            // lcg-ish float in [-5, 50]
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            const fv = @as(f32, @floatFromInt(seed & 0xffff)) / 65535.0 * 55.0 - 5.0;
            orig_arr[j] = fv;
            analog_arr[j] = fv;
        }
        nav.detour_crowd.obstacle_avoidance.normalizeArray(orig_arr[0..], 8);
        normalizeArray_analog(analog_arr[0..], 8);
        for (0..8) |j| {
            if (orig_arr[j] != analog_arr[j]) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// normalize2D — orig
// ---------------------------------------------------------------------------

fn runNormalize2D(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var v = [3]f32{ 1.1 + f, 2.2, 3.3 };
    nav.detour_crowd.obstacle_avoidance.normalize2D(&v);
    dna(v[0]);
}
fn checkNormalize2D() bool {
    var v = [3]f32{ 3.0, 0.0, 4.0 };
    nav.detour_crowd.obstacle_avoidance.normalize2D(&v);
    const len2 = v[0] * v[0] + v[2] * v[2];
    if (@abs(len2 - 1.0) > 1e-3) return false; // unit length in xz
    // zero-length: early-return, v unchanged
    var z = [3]f32{ 0.0, 5.5, 0.0 };
    nav.detour_crowd.obstacle_avoidance.normalize2D(&z);
    return z[0] == 0.0 and z[1] == 5.5 and z[2] == 0.0;
}

// ---------------------------------------------------------------------------
// normalize2D — analog: divide v[i]/=d (direct division) instead of
// multiply-by-reciprocal.  NOT bit-identical to orig -> REJECT.
// Gate compares BOTH non-zero and zero-length cases exactly.
// ---------------------------------------------------------------------------

fn normalize2D_analog(v: *[3]f32) void {
    const d2 = @sqrt(v[0] * v[0] + v[2] * v[2]);
    if (d2 == 0) return;
    v[0] /= d2; // direct division — differs from orig's *= 1/d
    v[2] /= d2;
    // v[1] intentionally untouched, matching orig
}

fn runNormalize2DAnalog(i: usize) void {
    const f: f32 = @floatFromInt(i & 31);
    var v = [3]f32{ 1.1 + f, 2.2, 3.3 };
    normalize2D_analog(&v);
    dna(v[0]);
}
fn checkNormalize2DAnalog() bool {
    // EXACT identity gate vs lib orig over >= 2000 varied inputs.
    // Also exercises the zero-length early-return path.
    var seed: u32 = 0xc0ffee42;
    var k: usize = 0;
    while (k < 2000) : (k += 1) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const fx = @as(f32, @floatFromInt(seed & 0x7fff)) / 100.0 - 163.0;
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed << 5;
        const fz = @as(f32, @floatFromInt(seed & 0x7fff)) / 100.0 - 163.0;
        var orig_v = [3]f32{ fx, 99.0, fz };
        var analog_v = [3]f32{ fx, 99.0, fz };
        nav.detour_crowd.obstacle_avoidance.normalize2D(&orig_v);
        normalize2D_analog(&analog_v);
        if (orig_v[0] != analog_v[0]) return false;
        if (orig_v[1] != analog_v[1]) return false;
        if (orig_v[2] != analog_v[2]) return false;
    }
    // zero-length case: both must leave v unchanged
    var orig_z = [3]f32{ 0.0, 7.0, 0.0 };
    var analog_z = [3]f32{ 0.0, 7.0, 0.0 };
    nav.detour_crowd.obstacle_avoidance.normalize2D(&orig_z);
    normalize2D_analog(&analog_z);
    if (orig_z[0] != analog_z[0]) return false;
    if (orig_z[1] != analog_z[1]) return false;
    if (orig_z[2] != analog_z[2]) return false;
    return true;
}

// ---------------------------------------------------------------------------
// ProximityGrid subsystem benches
// ---------------------------------------------------------------------------

var query_grid: ?ProximityGrid = null;
var clear_grid: ?ProximityGrid = null;
var add_grid: ?ProximityGrid = null;
var register_grid: ?ProximityGrid = null;
var register_crowd_grid: ?ProximityGrid = null;
var integrate_agents: [100]nav.detour_crowd.CrowdAgent = undefined;
var register_crowd_agents: [100]nav.detour_crowd.CrowdAgent = undefined;

const AgentFootprint = struct {
    x: f32,
    y: f32,
    r: f32,
};

var register_agents: [100]AgentFootprint = undefined;

fn initRegisterAgents() void {
    for (&register_agents, 0..) |*ag, i| {
        const lane: f32 = @floatFromInt(i % 10);
        const row: f32 = @floatFromInt(i / 10);
        const jitter: f32 = @as(f32, @floatFromInt((i * 37) & 15)) * 0.03125;
        ag.* = .{
            .x = lane * 2.15 + jitter,
            .y = row * 2.05 - jitter,
            .r = 0.42 + @as(f32, @floatFromInt(i & 3)) * 0.04,
        };
    }
}

fn fillGrid(grid: *ProximityGrid, count: usize) void {
    grid.clear();
    for (0..count) |i| {
        const x: f32 = @floatFromInt(i % 32);
        const y: f32 = @floatFromInt(i / 32);
        const r: f32 = 0.35 + @as(f32, @floatFromInt(i & 3)) * 0.05;
        grid.addItem(@intCast(i), x - r, y - r, x + r, y + r);
    }
}

fn setupQueryGrid() void {
    if (query_grid == null) {
        query_grid = ProximityGrid.init(alloc, 2048, 1.0) catch @panic("ProximityGrid.init failed");
        fillGrid(&query_grid.?, 256);
    }
}

fn setupClearGrid() void {
    if (clear_grid == null) {
        clear_grid = ProximityGrid.init(alloc, 2048, 1.0) catch @panic("ProximityGrid.init failed");
        fillGrid(&clear_grid.?, 256);
    }
}

fn setupAddGrid() void {
    if (add_grid == null) {
        add_grid = ProximityGrid.init(alloc, 2048, 1.0) catch @panic("ProximityGrid.init failed");
    }
}

fn setupRegisterGrid() void {
    if (register_grid == null) {
        register_grid = ProximityGrid.init(alloc, 2048, 1.0) catch @panic("ProximityGrid.init failed");
        initRegisterAgents();
    }
}

fn setupRegisterCrowdAgents() void {
    if (register_crowd_grid == null) {
        register_crowd_grid = ProximityGrid.init(alloc, 2048, 1.0) catch @panic("ProximityGrid.init failed");
        for (&register_crowd_agents, 0..) |*ag, i| {
            const lane: f32 = @floatFromInt(i % 10);
            const row: f32 = @floatFromInt(i / 10);
            const jitter: f32 = @as(f32, @floatFromInt((i * 37) & 15)) * 0.03125;
            ag.params = nav.detour_crowd.CrowdAgentParams.init();
            ag.params.radius = 0.42 + @as(f32, @floatFromInt(i & 3)) * 0.04;
            ag.npos = .{
                lane * 2.15 + jitter,
                0.0,
                row * 2.05 - jitter,
            };
        }
    }
}

fn runProximityGridQueryItems(i: usize) void {
    const grid = &query_grid.?;
    var ids: [32]u16 = undefined;
    const x: f32 = @floatFromInt(i & 15);
    const y: f32 = @floatFromInt((i >> 4) & 7);
    const n = grid.queryItems(x - 1.25, y - 1.25, x + 1.25, y + 1.25, &ids);
    dna(n);
    if (n > 0) dna(ids[0]);
}

fn checkProximityGridQueryItems() bool {
    setupQueryGrid();
    var ids: [32]u16 = undefined;
    const n = query_grid.?.queryItems(0.0, 0.0, 2.0, 2.0, &ids);
    return n > 0 and n <= ids.len;
}

fn runProximityGridClear(_: usize) void {
    const grid = &clear_grid.?;
    grid.clear();
    dna(grid.pool_head);
}

fn checkProximityGridClear() bool {
    setupClearGrid();
    clear_grid.?.clear();
    return clear_grid.?.pool_head == 0;
}

fn runProximityGridAddItemAfterClear(i: usize) void {
    const grid = &add_grid.?;
    grid.clear();
    const x: f32 = @floatFromInt(i & 63);
    const y: f32 = @floatFromInt((i >> 6) & 63);
    grid.addItem(@intCast(i & 0xffff), x - 0.35, y - 0.35, x + 0.35, y + 0.35);
    dna(grid.pool_head);
}

fn checkProximityGridAddItemAfterClear() bool {
    setupAddGrid();
    add_grid.?.clear();
    add_grid.?.addItem(7, 0.0, 0.0, 1.0, 1.0);
    var ids: [8]u16 = undefined;
    const n = add_grid.?.queryItems(0.0, 0.0, 1.0, 1.0, &ids);
    return n > 0;
}

fn runProximityGridRegisterN(comptime n: usize) void {
    const grid = &register_grid.?;
    grid.clear();
    for (register_agents[0..n], 0..) |ag, i| {
        grid.addItem(@intCast(i), ag.x - ag.r, ag.y - ag.r, ag.x + ag.r, ag.y + ag.r);
    }
    dna(grid.pool_head);
}

fn runProximityGridRegister25(_: usize) void {
    runProximityGridRegisterN(25);
}

fn runProximityGridRegister60(_: usize) void {
    runProximityGridRegisterN(60);
}

fn runProximityGridRegister100(_: usize) void {
    runProximityGridRegisterN(100);
}

fn checkProximityGridRegister100() bool {
    setupRegisterGrid();
    runProximityGridRegisterN(100);
    var ids: [32]u16 = undefined;
    const n = register_grid.?.queryItems(register_agents[0].x - 1.0, register_agents[0].y - 1.0, register_agents[0].x + 1.0, register_agents[0].y + 1.0, &ids);
    return register_grid.?.pool_head > 0 and n > 0;
}

fn runProximityGridRegisterCrowdN(comptime n: usize) void {
    const grid = &register_crowd_grid.?;
    grid.clear();
    for (register_crowd_agents[0..n], 0..) |*ag, i| {
        const p = &ag.npos;
        const r = ag.params.radius;
        grid.addItem(@intCast(i), p[0] - r, p[2] - r, p[0] + r, p[2] + r);
    }
    dna(grid.pool_head);
}

fn runProximityGridRegisterCrowd25(_: usize) void {
    runProximityGridRegisterCrowdN(25);
}

fn runProximityGridRegisterCrowd60(_: usize) void {
    runProximityGridRegisterCrowdN(60);
}

fn runProximityGridRegisterCrowd100(_: usize) void {
    runProximityGridRegisterCrowdN(100);
}

fn checkProximityGridRegisterCrowd100() bool {
    setupRegisterCrowdAgents();
    runProximityGridRegisterCrowdN(100);
    var ids: [32]u16 = undefined;
    const n = register_crowd_grid.?.queryItems(register_crowd_agents[0].npos[0] - 1.0, register_crowd_agents[0].npos[2] - 1.0, register_crowd_agents[0].npos[0] + 1.0, register_crowd_agents[0].npos[2] + 1.0, &ids);
    return register_crowd_grid.?.pool_head > 0 and n > 0;
}

fn setupIntegrateAgents() void {
    for (&integrate_agents, 0..) |*ag, i| {
        ag.params = nav.detour_crowd.CrowdAgentParams.init();
        ag.params.max_acceleration = 8.0 + @as(f32, @floatFromInt(i & 7)) * 0.25;
        ag.npos = .{
            @as(f32, @floatFromInt(i % 10)) * 2.0,
            0.0,
            @as(f32, @floatFromInt(i / 10)) * 2.0,
        };
        ag.vel = .{
            @as(f32, @floatFromInt(i & 3)) * 0.11,
            0.0,
            @as(f32, @floatFromInt((i >> 2) & 3)) * -0.13,
        };
        ag.nvel = .{
            1.25 + @as(f32, @floatFromInt(i & 15)) * 0.03,
            0.0,
            -0.75 + @as(f32, @floatFromInt((i * 7) & 15)) * 0.025,
        };
    }
}

fn runCrowdIntegrateOne(i: usize) void {
    const ag = &integrate_agents[i % integrate_agents.len];
    nav.detour_crowd.integrate(ag, 1.0 / 60.0);
    dna(ag.npos[0]);
}

fn runCrowdIntegrate100(_: usize) void {
    for (&integrate_agents) |*ag| {
        nav.detour_crowd.integrate(ag, 1.0 / 60.0);
    }
    dna(integrate_agents[0].npos[0]);
}

fn checkCrowdIntegrate() bool {
    setupIntegrateAgents();
    runCrowdIntegrate100(0);
    return integrate_agents[0].npos[0] != 0.0 or integrate_agents[0].vel[0] != 0.0;
}

pub const benches = [_]core.Bench{
    .{ .name = "normalizeArray",        .module = "detour_crowd.obstacle_avoidance", .impl = "orig",   .isolation = "A", .run = runNormalizeArray,        .check = checkNormalizeArray },
    .{ .name = "normalizeArray",        .module = "detour_crowd.obstacle_avoidance", .impl = "analog", .isolation = "A", .run = runNormalizeArrayAnalog,   .check = checkNormalizeArrayAnalog },
    .{ .name = "normalize2D",           .module = "detour_crowd.obstacle_avoidance", .impl = "orig",   .isolation = "A", .run = runNormalize2D,            .check = checkNormalize2D },
    .{ .name = "normalize2D",           .module = "detour_crowd.obstacle_avoidance", .impl = "analog", .isolation = "A", .run = runNormalize2DAnalog,      .check = checkNormalize2DAnalog },
    .{ .name = "queryItems_populated",   .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupQueryGrid,          .run = runProximityGridQueryItems,       .check = checkProximityGridQueryItems },
    .{ .name = "clear_populated",        .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupClearGrid,          .run = runProximityGridClear,            .check = checkProximityGridClear },
    .{ .name = "addItem_after_clear",    .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupAddGrid,            .run = runProximityGridAddItemAfterClear, .check = checkProximityGridAddItemAfterClear },
    .{ .name = "register_25_agents",     .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupRegisterGrid,       .run = runProximityGridRegister25,       .check = checkProximityGridRegister100 },
    .{ .name = "register_60_agents",     .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupRegisterGrid,       .run = runProximityGridRegister60,       .check = checkProximityGridRegister100 },
    .{ .name = "register_100_agents",    .module = "detour_crowd.proximity_grid",     .impl = "orig",   .isolation = "B", .setup = setupRegisterGrid,       .run = runProximityGridRegister100,      .check = checkProximityGridRegister100 },
    .{ .name = "register_25_crowd_agents",  .module = "detour_crowd.proximity_grid",  .impl = "orig",   .isolation = "B", .setup = setupRegisterCrowdAgents, .run = runProximityGridRegisterCrowd25,  .check = checkProximityGridRegisterCrowd100 },
    .{ .name = "register_60_crowd_agents",  .module = "detour_crowd.proximity_grid",  .impl = "orig",   .isolation = "B", .setup = setupRegisterCrowdAgents, .run = runProximityGridRegisterCrowd60,  .check = checkProximityGridRegisterCrowd100 },
    .{ .name = "register_100_crowd_agents", .module = "detour_crowd.proximity_grid",  .impl = "orig",   .isolation = "B", .setup = setupRegisterCrowdAgents, .run = runProximityGridRegisterCrowd100, .check = checkProximityGridRegisterCrowd100 },
    .{ .name = "integrate_one",          .module = "detour_crowd.crowd",              .impl = "orig",   .isolation = "A", .setup = setupIntegrateAgents,    .run = runCrowdIntegrateOne,             .check = checkCrowdIntegrate },
    .{ .name = "integrate_100_agents",   .module = "detour_crowd.crowd",              .impl = "orig",   .isolation = "B", .setup = setupIntegrateAgents,    .run = runCrowdIntegrate100,             .check = checkCrowdIntegrate },
};
