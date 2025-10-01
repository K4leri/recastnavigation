const std = @import("std");
const math = @import("../math.zig");

/// Circular obstacle
pub const ObstacleCircle = struct {
    pos: [3]f32, // Position of the obstacle
    vel: [3]f32, // Velocity of the obstacle
    dvel: [3]f32, // Desired velocity of the obstacle
    rad: f32, // Radius of the obstacle
    dp: [3]f32, // Use for side selection during sampling
    np: [3]f32, // Use for side selection during sampling
};

/// Segment obstacle
pub const ObstacleSegment = struct {
    p: [3]f32, // Start point of the obstacle segment
    q: [3]f32, // End point of the obstacle segment
    touch: bool, // Is touching
};

pub const MAX_PATTERN_DIVS = 32;
pub const MAX_PATTERN_RINGS = 4;

const PI: f32 = 3.14159265;
const EPS: f32 = 0.0001;

/// Obstacle avoidance parameters
pub const ObstacleAvoidanceParams = struct {
    vel_bias: f32,
    weight_des_vel: f32,
    weight_cur_vel: f32,
    weight_side: f32,
    weight_toi: f32,
    horiz_time: f32,
    grid_size: u8, // grid
    adaptive_divs: u8, // adaptive
    adaptive_rings: u8, // adaptive
    adaptive_depth: u8, // adaptive

    pub fn init() ObstacleAvoidanceParams {
        return .{
            .vel_bias = 0.4,
            .weight_des_vel = 2.0,
            .weight_cur_vel = 0.75,
            .weight_side = 0.75,
            .weight_toi = 2.5,
            .horiz_time = 2.5,
            .grid_size = 33,
            .adaptive_divs = 7,
            .adaptive_rings = 2,
            .adaptive_depth = 5,
        };
    }
};

/// Obstacle avoidance debug data
/// NOTE: Simplified - debug data collection not fully implemented
pub const ObstacleAvoidanceDebugData = struct {
    nsamples: usize,
    max_samples: usize,
    vel: []f32,
    ssize: []f32,
    pen: []f32,
    vpen: []f32,
    vcpen: []f32,
    spen: []f32,
    tpen: []f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_samples: usize) !ObstacleAvoidanceDebugData {
        return .{
            .nsamples = 0,
            .max_samples = max_samples,
            .vel = try allocator.alloc(f32, max_samples * 3),
            .ssize = try allocator.alloc(f32, max_samples),
            .pen = try allocator.alloc(f32, max_samples),
            .vpen = try allocator.alloc(f32, max_samples),
            .vcpen = try allocator.alloc(f32, max_samples),
            .spen = try allocator.alloc(f32, max_samples),
            .tpen = try allocator.alloc(f32, max_samples),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ObstacleAvoidanceDebugData) void {
        self.allocator.free(self.vel);
        self.allocator.free(self.ssize);
        self.allocator.free(self.pen);
        self.allocator.free(self.vpen);
        self.allocator.free(self.vcpen);
        self.allocator.free(self.spen);
        self.allocator.free(self.tpen);
    }

    pub fn reset(self: *ObstacleAvoidanceDebugData) void {
        self.nsamples = 0;
    }
};

/// Helper: Sweep circle-circle collision
fn sweepCircleCircle(
    c0: *const [3]f32,
    r0: f32,
    v: *const [3]f32,
    c1: *const [3]f32,
    r1: f32,
    tmin: *f32,
    tmax: *f32,
) bool {
    var s = [3]f32{ 0, 0, 0 };
    math.vsub(&s, c1, c0);
    const r = r0 + r1;
    const c = math.vdot2D(&s, &s) - r * r;
    var a = math.vdot2D(v, v);
    if (a < EPS) return false; // not moving

    // Overlap, calc time to exit
    const b = math.vdot2D(v, &s);
    const d = b * b - a * c;
    if (d < 0.0) return false; // no intersection
    a = 1.0 / a;
    const rd = @sqrt(d);
    tmin.* = (b - rd) * a;
    tmax.* = (b + rd) * a;
    return true;
}

/// Helper: Ray-segment intersection
fn isectRaySeg(
    ap: *const [3]f32,
    u: *const [3]f32,
    bp: *const [3]f32,
    bq: *const [3]f32,
    t: *f32,
) bool {
    var v = [3]f32{ 0, 0, 0 };
    var w = [3]f32{ 0, 0, 0 };
    math.vsub(&v, bq, bp);
    math.vsub(&w, ap, bp);
    var d = math.vperp2D(u, &v);
    if (@abs(d) < 1e-6) return false;
    d = 1.0 / d;
    t.* = math.vperp2D(&v, &w) * d;
    if (t.* < 0 or t.* > 1) return false;
    const s = math.vperp2D(u, &w) * d;
    if (s < 0 or s > 1) return false;
    return true;
}

/// Helper: Normalize 2D vector (ignoring y)
fn normalize2D(v: *[3]f32) void {
    var d = @sqrt(v[0] * v[0] + v[2] * v[2]);
    if (d == 0) return;
    d = 1.0 / d;
    v[0] *= d;
    v[2] *= d;
}

/// Helper: Rotate 2D vector (ignoring y)
fn rotate2D(dest: *[3]f32, v: *const [3]f32, ang: f32) void {
    const c = @cos(ang);
    const s = @sin(ang);
    dest[0] = v[0] * c - v[2] * s;
    dest[2] = v[0] * s + v[2] * c;
    dest[1] = v[1];
}

/// Obstacle avoidance query
pub const ObstacleAvoidanceQuery = struct {
    params: ObstacleAvoidanceParams,
    inv_horiz_time: f32,
    vmax: f32,
    inv_vmax: f32,

    max_circles: usize,
    circles: []ObstacleCircle,
    ncircles: usize,

    max_segments: usize,
    segments: []ObstacleSegment,
    nsegments: usize,

    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize obstacle avoidance query
    pub fn init(allocator: std.mem.Allocator, max_circles: usize, max_segments: usize) !Self {
        const circles = try allocator.alloc(ObstacleCircle, max_circles);
        errdefer allocator.free(circles);

        const segments = try allocator.alloc(ObstacleSegment, max_segments);
        errdefer allocator.free(segments);

        return Self{
            .params = ObstacleAvoidanceParams.init(),
            .inv_horiz_time = 0,
            .vmax = 0,
            .inv_vmax = 0,
            .max_circles = max_circles,
            .circles = circles,
            .ncircles = 0,
            .max_segments = max_segments,
            .segments = segments,
            .nsegments = 0,
            .allocator = allocator,
        };
    }

    /// Free obstacle avoidance query resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.circles);
        self.allocator.free(self.segments);
    }

    /// Reset the query
    pub fn reset(self: *Self) void {
        self.ncircles = 0;
        self.nsegments = 0;
    }

    /// Add a circular obstacle
    pub fn addCircle(
        self: *Self,
        pos: *const [3]f32,
        rad: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
    ) void {
        if (self.ncircles >= self.max_circles) return;

        var circle = &self.circles[self.ncircles];
        math.vcopy(&circle.pos, pos);
        circle.rad = rad;
        math.vcopy(&circle.vel, vel);
        math.vcopy(&circle.dvel, dvel);

        self.ncircles += 1;
    }

    /// Add a segment obstacle
    pub fn addSegment(self: *Self, p: *const [3]f32, q: *const [3]f32) void {
        if (self.nsegments >= self.max_segments) return;

        var seg = &self.segments[self.nsegments];
        math.vcopy(&seg.p, p);
        math.vcopy(&seg.q, q);
        seg.touch = false;

        self.nsegments += 1;
    }

    /// Get obstacle circle count
    pub fn getObstacleCircleCount(self: *const Self) usize {
        return self.ncircles;
    }

    /// Get obstacle circle by index
    pub fn getObstacleCircle(self: *const Self, i: usize) ?*const ObstacleCircle {
        if (i >= self.ncircles) return null;
        return &self.circles[i];
    }

    /// Get obstacle segment count
    pub fn getObstacleSegmentCount(self: *const Self) usize {
        return self.nsegments;
    }

    /// Get obstacle segment by index
    pub fn getObstacleSegment(self: *const Self, i: usize) ?*const ObstacleSegment {
        if (i >= self.nsegments) return null;
        return &self.segments[i];
    }

    /// Prepare obstacles for sampling
    fn prepare(self: *Self, pos: *const [3]f32, dvel: *const [3]f32) void {
        // Prepare circle obstacles
        for (0..self.ncircles) |i| {
            var cir = &self.circles[i];

            // Calculate direction and normal vectors
            const pa = pos;
            const pb = &cir.pos;

            const orig = [3]f32{ 0, 0, 0 };
            var dv = [3]f32{ 0, 0, 0 };
            math.vsub(&cir.dp, pb, pa);
            math.vnormalize(&cir.dp);
            math.vsub(&dv, &cir.dvel, dvel);

            const a = math.triArea2D(math.Vec3.fromArray(&orig), math.Vec3.fromArray(&cir.dp), math.Vec3.fromArray(&dv));
            if (a < 0.01) {
                cir.np[0] = -cir.dp[2];
                cir.np[2] = cir.dp[0];
            } else {
                cir.np[0] = cir.dp[2];
                cir.np[2] = -cir.dp[0];
            }
        }

        // Prepare segment obstacles
        for (0..self.nsegments) |i| {
            var seg = &self.segments[i];

            // Check if agent is really close to the segment
            const r: f32 = 0.01;
            var t: f32 = undefined;
            seg.touch = math.distancePtSegSqr2D(pos, &seg.p, &seg.q, &t) < (r * r);
        }
    }

    /// Process a velocity sample and return penalty
    fn processSample(
        self: *const Self,
        vcand: *const [3]f32,
        cs: f32,
        pos: *const [3]f32,
        rad: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
        min_penalty: f32,
        debug: ?*ObstacleAvoidanceDebugData,
    ) f32 {
        // Penalty for straying from desired and current velocities
        const vpen = self.params.weight_des_vel * (math.vdist2D(vcand, dvel) * self.inv_vmax);
        const vcpen = self.params.weight_cur_vel * (math.vdist2D(vcand, vel) * self.inv_vmax);

        // Early out threshold
        const min_pen = min_penalty - vpen - vcpen;
        const t_threshold = (self.params.weight_toi / min_pen - 0.1) * self.params.horiz_time;
        if (t_threshold - self.params.horiz_time > -std.math.floatEps(f32)) {
            return min_penalty;
        }

        // Find min time of impact among all obstacles
        var tmin = self.params.horiz_time;
        var side: f32 = 0;
        var nside: usize = 0;

        // Check circle obstacles
        for (0..self.ncircles) |i| {
            const cir = &self.circles[i];

            // RVO (Reciprocal Velocity Obstacles)
            var vab = [3]f32{ 0, 0, 0 };
            math.vscale(&vab, vcand, 2);
            math.vsub(&vab, &vab, vel);
            math.vsub(&vab, &vab, &cir.vel);

            // Side calculation
            side += math.clamp(
                f32,
                @min(math.vdot2D(&cir.dp, &vab) * 0.5 + 0.5, math.vdot2D(&cir.np, &vab) * 2),
                0.0,
                1.0,
            );
            nside += 1;

            var htmin: f32 = 0;
            var htmax: f32 = 0;
            if (!sweepCircleCircle(pos, rad, &vab, &cir.pos, cir.rad, &htmin, &htmax)) {
                continue;
            }

            // Handle overlapping obstacles
            if (htmin < 0.0 and htmax > 0.0) {
                htmin = -htmin * 0.5;
            }

            if (htmin >= 0.0) {
                if (htmin < tmin) {
                    tmin = htmin;
                    if (tmin < t_threshold) {
                        return min_penalty;
                    }
                }
            }
        }

        // Check segment obstacles
        for (0..self.nsegments) |i| {
            const seg = &self.segments[i];
            var htmin: f32 = 0;

            if (seg.touch) {
                // Special case: agent very close to segment
                var sdir = [3]f32{ 0, 0, 0 };
                var snorm = [3]f32{ 0, 0, 0 };
                math.vsub(&sdir, &seg.q, &seg.p);
                snorm[0] = -sdir[2];
                snorm[2] = sdir[0];

                // If velocity points towards segment, no collision
                if (math.vdot2D(&snorm, vcand) < 0.0) {
                    continue;
                }
                // Else immediate collision
                htmin = 0.0;
            } else {
                if (!isectRaySeg(pos, vcand, &seg.p, &seg.q, &htmin)) {
                    continue;
                }
            }

            // Avoid less when facing walls
            htmin *= 2.0;

            if (htmin < tmin) {
                tmin = htmin;
                if (tmin < t_threshold) {
                    return min_penalty;
                }
            }
        }

        // Normalize side bias
        if (nside > 0) {
            side /= @as(f32, @floatFromInt(nside));
        }

        const spen = self.params.weight_side * side;
        const tpen = self.params.weight_toi * (1.0 / (0.1 + tmin * self.inv_horiz_time));

        const penalty = vpen + vcpen + spen + tpen;

        // Store debug info
        if (debug) |d| {
            if (d.nsamples < d.max_samples) {
                const idx = d.nsamples * 3;
                d.vel[idx + 0] = vcand[0];
                d.vel[idx + 1] = vcand[1];
                d.vel[idx + 2] = vcand[2];
                d.ssize[d.nsamples] = cs;
                d.pen[d.nsamples] = penalty;
                d.vpen[d.nsamples] = vpen;
                d.vcpen[d.nsamples] = vcpen;
                d.spen[d.nsamples] = spen;
                d.tpen[d.nsamples] = tpen;
                d.nsamples += 1;
            }
        }

        return penalty;
    }

    /// Sample velocity using grid pattern
    pub fn sampleVelocityGrid(
        self: *Self,
        pos: *const [3]f32,
        rad: f32,
        vmax: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
        nvel: *[3]f32,
        params: *const ObstacleAvoidanceParams,
        debug: ?*ObstacleAvoidanceDebugData,
    ) usize {
        self.prepare(pos, dvel);

        self.params = params.*;
        self.inv_horiz_time = 1.0 / self.params.horiz_time;
        self.vmax = vmax;
        self.inv_vmax = if (vmax > 0) 1.0 / vmax else std.math.floatMax(f32);

        nvel.* = [3]f32{ 0, 0, 0 };

        if (debug) |d| {
            d.reset();
        }

        const cvx = dvel[0] * self.params.vel_bias;
        const cvz = dvel[2] * self.params.vel_bias;
        const cs = vmax * 2.0 * (1.0 - self.params.vel_bias) / @as(f32, @floatFromInt(self.params.grid_size - 1));
        const half = @as(f32, @floatFromInt(self.params.grid_size - 1)) * cs * 0.5;

        var min_penalty = std.math.floatMax(f32);
        var ns: usize = 0;

        var y: usize = 0;
        while (y < self.params.grid_size) : (y += 1) {
            var x: usize = 0;
            while (x < self.params.grid_size) : (x += 1) {
                const vcand = [3]f32{
                    cvx + @as(f32, @floatFromInt(x)) * cs - half,
                    0,
                    cvz + @as(f32, @floatFromInt(y)) * cs - half,
                };

                // Check if velocity is within max speed
                if (vcand[0] * vcand[0] + vcand[2] * vcand[2] > (vmax + cs / 2) * (vmax + cs / 2)) {
                    continue;
                }

                const penalty = self.processSample(&vcand, cs, pos, rad, vel, dvel, min_penalty, debug);
                ns += 1;

                if (penalty < min_penalty) {
                    min_penalty = penalty;
                    math.vcopy(nvel, &vcand);
                }
            }
        }

        return ns;
    }

    /// Sample velocity using adaptive pattern
    pub fn sampleVelocityAdaptive(
        self: *Self,
        pos: *const [3]f32,
        rad: f32,
        vmax: f32,
        vel: *const [3]f32,
        dvel: *const [3]f32,
        nvel: *[3]f32,
        params: *const ObstacleAvoidanceParams,
        debug: ?*ObstacleAvoidanceDebugData,
    ) usize {
        self.prepare(pos, dvel);

        self.params = params.*;
        self.inv_horiz_time = 1.0 / self.params.horiz_time;
        self.vmax = vmax;
        self.inv_vmax = if (vmax > 0) 1.0 / vmax else std.math.floatMax(f32);

        nvel.* = [3]f32{ 0, 0, 0 };

        if (debug) |d| {
            d.reset();
        }

        // Build sampling pattern aligned to desired velocity
        var pat: [(MAX_PATTERN_DIVS * MAX_PATTERN_RINGS + 1) * 2]f32 = undefined;
        var npat: usize = 0;

        const ndivs = math.clamp(i32, @as(i32, @intCast(self.params.adaptive_divs)), 1, MAX_PATTERN_DIVS);
        const nrings = math.clamp(i32, @as(i32, @intCast(self.params.adaptive_rings)), 1, MAX_PATTERN_RINGS);
        const depth = self.params.adaptive_depth;

        const nd = @as(usize, @intCast(ndivs));
        const nr = @as(usize, @intCast(nrings));
        const da = (1.0 / @as(f32, @floatFromInt(nd))) * PI * 2.0;
        const ca = @cos(da);
        const sa = @sin(da);

        // Desired direction
        var ddir: [6]f32 = undefined;
        ddir[0] = dvel[0];
        ddir[1] = dvel[1];
        ddir[2] = dvel[2];
        var ddir0: [3]f32 = .{ ddir[0], ddir[1], ddir[2] };
        normalize2D(&ddir0);
        ddir[0] = ddir0[0];
        ddir[1] = ddir0[1];
        ddir[2] = ddir0[2];
        var ddir1: [3]f32 = undefined;
        rotate2D(&ddir1, &ddir0, da * 0.5);
        ddir[3] = ddir1[0];
        ddir[4] = ddir1[1];
        ddir[5] = ddir1[2];

        // Always add sample at zero
        pat[npat * 2 + 0] = 0;
        pat[npat * 2 + 1] = 0;
        npat += 1;

        // Build ring pattern
        var j: usize = 0;
        while (j < nr) : (j += 1) {
            const r = @as(f32, @floatFromInt(nr - j)) / @as(f32, @floatFromInt(nr));
            const dir_idx = (j % 2) * 3;
            pat[npat * 2 + 0] = ddir[dir_idx] * r;
            pat[npat * 2 + 1] = ddir[dir_idx + 2] * r;
            var last1_idx = npat * 2;
            var last2_idx = last1_idx;
            npat += 1;

            var i: usize = 1;
            while (i < nd - 1) : (i += 2) {
                // Get next point on the "right" (rotate CW)
                pat[npat * 2 + 0] = pat[last1_idx] * ca + pat[last1_idx + 1] * sa;
                pat[npat * 2 + 1] = -pat[last1_idx] * sa + pat[last1_idx + 1] * ca;
                // Get next point on the "left" (rotate CCW)
                pat[npat * 2 + 2] = pat[last2_idx] * ca - pat[last2_idx + 1] * sa;
                pat[npat * 2 + 3] = pat[last2_idx] * sa + pat[last2_idx + 1] * ca;

                last1_idx = npat * 2;
                last2_idx = last1_idx + 2;
                npat += 2;
            }

            if ((nd & 1) == 0) {
                pat[npat * 2 + 2] = pat[last2_idx] * ca - pat[last2_idx + 1] * sa;
                pat[npat * 2 + 3] = pat[last2_idx] * sa + pat[last2_idx + 1] * ca;
                npat += 1;
            }
        }

        // Start sampling
        var cr = vmax * (1.0 - self.params.vel_bias);
        var res = [3]f32{
            dvel[0] * self.params.vel_bias,
            0,
            dvel[2] * self.params.vel_bias,
        };
        var ns: usize = 0;

        var k: usize = 0;
        while (k < depth) : (k += 1) {
            var min_penalty = std.math.floatMax(f32);
            var bvel = [3]f32{ 0, 0, 0 };

            var i: usize = 0;
            while (i < npat) : (i += 1) {
                const vcand = [3]f32{
                    res[0] + pat[i * 2 + 0] * cr,
                    0,
                    res[2] + pat[i * 2 + 1] * cr,
                };

                // Check if velocity is within max speed
                if (vcand[0] * vcand[0] + vcand[2] * vcand[2] > (vmax + 0.001) * (vmax + 0.001)) {
                    continue;
                }

                const penalty = self.processSample(&vcand, cr / 10.0, pos, rad, vel, dvel, min_penalty, debug);
                ns += 1;

                if (penalty < min_penalty) {
                    min_penalty = penalty;
                    math.vcopy(&bvel, &vcand);
                }
            }

            math.vcopy(&res, &bvel);
            cr *= 0.5;
        }

        math.vcopy(nvel, &res);
        return ns;
    }
};

test "ObstacleAvoidanceQuery basic" {
    const allocator = std.testing.allocator;

    var query = try ObstacleAvoidanceQuery.init(allocator, 32, 32);
    defer query.deinit();

    const pos = [3]f32{ 0, 0, 0 };
    const vel = [3]f32{ 1, 0, 0 };
    const dvel = [3]f32{ 1, 0, 1 };

    query.addCircle(&pos, 0.5, &vel, &dvel);
    try std.testing.expectEqual(@as(usize, 1), query.getObstacleCircleCount());

    const p = [3]f32{ 5, 0, 0 };
    const q = [3]f32{ 5, 0, 5 };
    query.addSegment(&p, &q);
    try std.testing.expectEqual(@as(usize, 1), query.getObstacleSegmentCount());

    query.reset();
    try std.testing.expectEqual(@as(usize, 0), query.getObstacleCircleCount());
    try std.testing.expectEqual(@as(usize, 0), query.getObstacleSegmentCount());
}
