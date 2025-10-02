# Raycast Guide

Практическое руководство по использованию raycast для line-of-sight и collision detection.

---

## Overview

Raycast позволяет проверить видимость между двумя точками на NavMesh, обнаружить препятствия, и найти точки пересечения.

**Что вы изучите:**
- ✅ Basic raycast
- ✅ Hit detection и normal calculation
- ✅ Path visualization
- ✅ Line-of-sight checks
- ✅ Cover detection
- ✅ Shooting mechanics

**Время:** 15-30 минут

---

## Prerequisites

```zig
const std = @import("std");
const nav = @import("zig-recast");

const Allocator = std.mem.Allocator;
const NavMeshQuery = nav.detour.NavMeshQuery;
const QueryFilter = nav.detour.QueryFilter;
const PolyRef = nav.detour.PolyRef;
const RaycastHit = nav.detour.RaycastHit;
```

**Требования:**
- NavMesh и NavMeshQuery (см. [Pathfinding Guide](pathfinding.md))

---

## Step 1: Basic Raycast

### Simple Raycast

```zig
pub fn performRaycast(
    query: *const NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    start_ref: PolyRef,
) !RaycastHit {
    const filter = QueryFilter.init();

    var hit = RaycastHit{
        .t = 0,
        .hit_normal = .{ 0, 0, 0 },
        .path = undefined,
        .path_count = 0,
        .path_cost = 0,
        .hit_edge_index = 0,
    };

    _ = try query.raycast(
        start_ref,
        &start_pos,
        &end_pos,
        &filter,
        0,  // options
        &hit,
        0,  // prev_ref
    );

    return hit;
}
```

### Interpret Results

```zig
pub fn interpretRaycastHit(hit: *const RaycastHit, start_pos: [3]f32, end_pos: [3]f32) void {
    if (hit.t == std.math.floatMax(f32)) {
        // No hit - line of sight clear
        std.debug.print("✅ Clear line of sight\n", .{});
        std.debug.print("   Path: {d} polygons\n", .{hit.path_count});
    } else {
        // Hit - obstruction found
        std.debug.print("❌ Hit obstruction\n", .{});

        // Calculate hit position
        const hit_pos = [3]f32{
            start_pos[0] + hit.t * (end_pos[0] - start_pos[0]),
            start_pos[1] + hit.t * (end_pos[1] - start_pos[1]),
            start_pos[2] + hit.t * (end_pos[2] - start_pos[2]),
        };

        std.debug.print("   Hit position: ({d:.2}, {d:.2}, {d:.2})\n", .{
            hit_pos[0],
            hit_pos[1],
            hit_pos[2],
        });
        std.debug.print("   Hit t: {d:.3}\n", .{hit.t});
        std.debug.print("   Hit normal: ({d:.2}, {d:.2}, {d:.2})\n", .{
            hit.hit_normal[0],
            hit.hit_normal[1],
            hit.hit_normal[2],
        });
    }
}
```

---

## Step 2: Line-of-Sight Check

### Simple LOS Check

```zig
pub fn hasLineOfSight(
    query: *const NavMeshQuery,
    pos1: [3]f32,
    pos2: [3]f32,
) !bool {
    // Find start polygon
    const extents = [3]f32{ 2.0, 4.0, 2.0 };
    const filter = QueryFilter.init();

    var start_ref: PolyRef = 0;
    try query.findNearestPoly(&pos1, &extents, &filter, &start_ref, null);

    if (start_ref == 0) {
        return error.StartNotOnNavMesh;
    }

    // Perform raycast
    var hit = RaycastHit{
        .t = 0,
        .hit_normal = .{ 0, 0, 0 },
        .path = undefined,
        .path_count = 0,
        .path_cost = 0,
        .hit_edge_index = 0,
    };

    _ = try query.raycast(start_ref, &pos1, &pos2, &filter, 0, &hit, 0);

    // No hit = clear LOS
    return (hit.t == std.math.floatMax(f32));
}
```

### LOS with Distance Threshold

```zig
pub fn hasLineOfSightWithinDistance(
    query: *const NavMeshQuery,
    pos1: [3]f32,
    pos2: [3]f32,
    max_distance: f32,
) !bool {
    // Calculate distance
    const dx = pos2[0] - pos1[0];
    const dy = pos2[1] - pos1[1];
    const dz = pos2[2] - pos1[2];
    const distance = @sqrt(dx * dx + dy * dy + dz * dz);

    if (distance > max_distance) {
        std.debug.print("⚠️ Distance {d:.2}m exceeds max {d:.2}m\n", .{ distance, max_distance });
        return false;
    }

    return try hasLineOfSight(query, pos1, pos2);
}
```

---

## Step 3: Hit Position & Normal

### Calculate Hit Details

```zig
pub const RaycastResult = struct {
    hit: bool,
    hit_pos: [3]f32,
    hit_normal: [3]f32,
    distance: f32,
    path_count: usize,
};

pub fn raycastWithDetails(
    query: *const NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    start_ref: PolyRef,
) !RaycastResult {
    const filter = QueryFilter.init();

    var hit_data = RaycastHit{
        .t = 0,
        .hit_normal = .{ 0, 0, 0 },
        .path = undefined,
        .path_count = 0,
        .path_cost = 0,
        .hit_edge_index = 0,
    };

    _ = try query.raycast(start_ref, &start_pos, &end_pos, &filter, 0, &hit_data, 0);

    const is_hit = (hit_data.t != std.math.floatMax(f32));

    var hit_pos: [3]f32 = undefined;
    var distance: f32 = 0;

    if (is_hit) {
        // Calculate hit position
        hit_pos = .{
            start_pos[0] + hit_data.t * (end_pos[0] - start_pos[0]),
            start_pos[1] + hit_data.t * (end_pos[1] - start_pos[1]),
            start_pos[2] + hit_data.t * (end_pos[2] - start_pos[2]),
        };

        // Calculate distance to hit
        const dx = hit_pos[0] - start_pos[0];
        const dy = hit_pos[1] - start_pos[1];
        const dz = hit_pos[2] - start_pos[2];
        distance = @sqrt(dx * dx + dy * dy + dz * dz);
    } else {
        hit_pos = end_pos;
        const dx = end_pos[0] - start_pos[0];
        const dy = end_pos[1] - start_pos[1];
        const dz = end_pos[2] - start_pos[2];
        distance = @sqrt(dx * dx + dy * dy + dz * dz);
    }

    return RaycastResult{
        .hit = is_hit,
        .hit_pos = hit_pos,
        .hit_normal = hit_data.hit_normal,
        .distance = distance,
        .path_count = hit_data.path_count,
    };
}
```

### Reflect Ray

```zig
pub fn reflectRay(
    incident: [3]f32,
    normal: [3]f32,
) [3]f32 {
    // Reflect formula: R = I - 2 * (I · N) * N

    // Normalize incident vector
    const len = @sqrt(incident[0] * incident[0] +
        incident[1] * incident[1] +
        incident[2] * incident[2]);

    const I = [3]f32{
        incident[0] / len,
        incident[1] / len,
        incident[2] / len,
    };

    // Dot product: I · N
    const dot = I[0] * normal[0] + I[1] * normal[1] + I[2] * normal[2];

    // Reflection
    return .{
        I[0] - 2 * dot * normal[0],
        I[1] - 2 * dot * normal[1],
        I[2] - 2 * dot * normal[2],
    };
}
```

---

## Step 4: Vision System

### Vision Cone Check

```zig
pub const VisionConfig = struct {
    max_distance: f32 = 20.0,
    fov_angle: f32 = 90.0,  // degrees
};

pub fn canSeeTarget(
    query: *const NavMeshQuery,
    viewer_pos: [3]f32,
    viewer_forward: [3]f32,  // Direction viewer is facing
    target_pos: [3]f32,
    config: VisionConfig,
) !bool {
    // 1. Distance check
    const dx = target_pos[0] - viewer_pos[0];
    const dy = target_pos[1] - viewer_pos[1];
    const dz = target_pos[2] - viewer_pos[2];
    const distance = @sqrt(dx * dx + dy * dy + dz * dz);

    if (distance > config.max_distance) {
        return false;  // Too far
    }

    // 2. FOV check (2D in XZ plane)
    const to_target = [2]f32{ dx, dz };
    const forward_2d = [2]f32{ viewer_forward[0], viewer_forward[2] };

    const angle = angleBetween2D(forward_2d, to_target);
    const half_fov = config.fov_angle / 2.0;

    if (angle > half_fov) {
        return false;  // Outside FOV
    }

    // 3. Line of sight check
    return try hasLineOfSight(query, viewer_pos, target_pos);
}

fn angleBetween2D(a: [2]f32, b: [2]f32) f32 {
    const dot = a[0] * b[0] + a[1] * b[1];
    const len_a = @sqrt(a[0] * a[0] + a[1] * a[1]);
    const len_b = @sqrt(b[0] * b[0] + b[1] * b[1]);

    if (len_a == 0 or len_b == 0) return 0;

    const cos_angle = dot / (len_a * len_b);
    const angle_rad = std.math.acos(std.math.clamp(cos_angle, -1.0, 1.0));

    // Convert to degrees
    return angle_rad * 180.0 / std.math.pi;
}
```

### Multiple Target Visibility

```zig
pub fn findVisibleTargets(
    query: *const NavMeshQuery,
    viewer_pos: [3]f32,
    viewer_forward: [3]f32,
    targets: []const [3]f32,
    config: VisionConfig,
    allocator: Allocator,
) ![]usize {
    var visible = std.ArrayList(usize).init(allocator);
    errdefer visible.deinit();

    for (targets, 0..) |target_pos, i| {
        const is_visible = canSeeTarget(
            query,
            viewer_pos,
            viewer_forward,
            target_pos,
            config,
        ) catch false;

        if (is_visible) {
            try visible.append(i);
        }
    }

    return visible.toOwnedSlice();
}
```

---

## Step 5: Cover Detection

### Find Cover Point

```zig
pub fn findCoverFrom(
    query: *const NavMeshQuery,
    agent_pos: [3]f32,
    threat_pos: [3]f32,
    search_radius: f32,
    allocator: Allocator,
) !?[3]f32 {
    // Sample points around agent
    const sample_count: usize = 16;
    var best_cover: ?[3]f32 = null;
    var best_score: f32 = -1;

    var angle: f32 = 0;
    const angle_step = 360.0 / @as(f32, @floatFromInt(sample_count));

    while (angle < 360.0) : (angle += angle_step) {
        const rad = angle * std.math.pi / 180.0;

        const sample_pos = [3]f32{
            agent_pos[0] + @cos(rad) * search_radius,
            agent_pos[1],
            agent_pos[2] + @sin(rad) * search_radius,
        };

        // Check if this point has LOS to threat
        const has_los = hasLineOfSight(query, sample_pos, threat_pos) catch continue;

        if (!has_los) {
            // This is a cover point!
            const distance_to_threat = distance3D(&sample_pos, &threat_pos);
            const score = distance_to_threat;  // Prefer farther cover

            if (score > best_score) {
                best_score = score;
                best_cover = sample_pos;
            }
        }
    }

    return best_cover;
}

fn distance3D(a: *const [3]f32, b: *const [3]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
```

### Evaluate Cover Quality

```zig
pub const CoverQuality = enum {
    None,
    Partial,
    Full,
};

pub fn evaluateCover(
    query: *const NavMeshQuery,
    cover_pos: [3]f32,
    agent_height: f32,
    threat_pos: [3]f32,
) !CoverQuality {
    // Check LOS at different heights
    const head_offset = agent_height * 0.9;
    const chest_offset = agent_height * 0.6;
    const waist_offset = agent_height * 0.3;

    var head_pos = cover_pos;
    head_pos[1] += head_offset;

    var chest_pos = cover_pos;
    chest_pos[1] += chest_offset;

    var waist_pos = cover_pos;
    waist_pos[1] += waist_offset;

    const head_visible = hasLineOfSight(query, head_pos, threat_pos) catch false;
    const chest_visible = hasLineOfSight(query, chest_pos, threat_pos) catch false;
    const waist_visible = hasLineOfSight(query, waist_pos, threat_pos) catch false;

    if (!head_visible and !chest_visible and !waist_visible) {
        return .Full;  // Fully covered
    } else if (!head_visible or !chest_visible) {
        return .Partial;  // Partially covered
    } else {
        return .None;  // No cover
    }
}
```

---

## Step 6: Shooting Mechanics

### Projectile Path

```zig
pub const ProjectileHit = struct {
    hit: bool,
    hit_pos: [3]f32,
    hit_normal: [3]f32,
    travel_distance: f32,
};

pub fn simulateProjectile(
    query: *const NavMeshQuery,
    origin: [3]f32,
    direction: [3]f32,
    max_range: f32,
) !ProjectileHit {
    // Calculate end position
    const end_pos = [3]f32{
        origin[0] + direction[0] * max_range,
        origin[1] + direction[1] * max_range,
        origin[2] + direction[2] * max_range,
    };

    // Find start polygon
    const extents = [3]f32{ 2.0, 4.0, 2.0 };
    const filter = QueryFilter.init();

    var start_ref: PolyRef = 0;
    try query.findNearestPoly(&origin, &extents, &filter, &start_ref, null);

    // Raycast
    const result = try raycastWithDetails(query, origin, end_pos, start_ref);

    return ProjectileHit{
        .hit = result.hit,
        .hit_pos = result.hit_pos,
        .hit_normal = result.hit_normal,
        .travel_distance = result.distance,
    };
}
```

### Ricochet System

```zig
pub fn simulateRicochet(
    query: *const NavMeshQuery,
    origin: [3]f32,
    direction: [3]f32,
    max_bounces: usize,
    max_range: f32,
    allocator: Allocator,
) ![]ProjectileHit {
    var hits = std.ArrayList(ProjectileHit).init(allocator);
    errdefer hits.deinit();

    var current_pos = origin;
    var current_dir = direction;
    var remaining_range = max_range;

    var bounce: usize = 0;
    while (bounce < max_bounces) : (bounce += 1) {
        const hit = try simulateProjectile(
            query,
            current_pos,
            current_dir,
            remaining_range,
        );

        try hits.append(hit);

        if (!hit.hit) {
            break;  // No more bounces
        }

        // Setup next bounce
        current_pos = hit.hit_pos;
        current_dir = reflectRay(current_dir, hit.hit_normal);
        remaining_range -= hit.travel_distance;

        if (remaining_range <= 0) {
            break;  // Out of range
        }
    }

    return hits.toOwnedSlice();
}
```

---

## Step 7: Complete Example

```zig
pub fn raycastExample(
    allocator: Allocator,
    query: *const NavMeshQuery,
) !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("   Raycast Example\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Scenario 1: Simple LOS check
    std.debug.print("=== Scenario 1: Line of Sight ===\n", .{});
    const pos1 = [3]f32{ 0, 0, 0 };
    const pos2 = [3]f32{ 10, 0, 10 };

    const has_los = try hasLineOfSight(query, pos1, pos2);
    std.debug.print("LOS from (0,0,0) to (10,0,10): {}\n\n", .{has_los});

    // Scenario 2: Vision cone
    std.debug.print("=== Scenario 2: Vision Cone ===\n", .{});
    const viewer_pos = [3]f32{ 0, 0, 0 };
    const viewer_forward = [3]f32{ 1, 0, 0 };  // Facing +X
    const target_pos = [3]f32{ 5, 0, 2 };

    const can_see = try canSeeTarget(
        query,
        viewer_pos,
        viewer_forward,
        target_pos,
        .{ .max_distance = 20.0, .fov_angle = 90.0 },
    );
    std.debug.print("Can see target: {}\n\n", .{can_see});

    // Scenario 3: Cover detection
    std.debug.print("=== Scenario 3: Cover Detection ===\n", .{});
    const agent_pos = [3]f32{ 0, 0, 0 };
    const threat_pos = [3]f32{ 10, 0, 0 };

    const cover_pos = try findCoverFrom(query, agent_pos, threat_pos, 5.0, allocator);

    if (cover_pos) |pos| {
        std.debug.print("Cover found at: ({d:.2}, {d:.2}, {d:.2})\n", .{
            pos[0],
            pos[1],
            pos[2],
        });

        const quality = try evaluateCover(query, pos, 2.0, threat_pos);
        std.debug.print("Cover quality: {s}\n\n", .{@tagName(quality)});
    } else {
        std.debug.print("No cover found\n\n", .{});
    }

    // Scenario 4: Projectile simulation
    std.debug.print("=== Scenario 4: Projectile ===\n", .{});
    const shoot_origin = [3]f32{ 0, 1, 0 };
    const shoot_dir = [3]f32{ 1, 0, 0 };

    const projectile = try simulateProjectile(query, shoot_origin, shoot_dir, 20.0);

    if (projectile.hit) {
        std.debug.print("Hit at: ({d:.2}, {d:.2}, {d:.2})\n", .{
            projectile.hit_pos[0],
            projectile.hit_pos[1],
            projectile.hit_pos[2],
        });
        std.debug.print("Distance: {d:.2}m\n", .{projectile.travel_distance});
    } else {
        std.debug.print("No hit (max range reached)\n", .{});
    }

    std.debug.print("\n✅ Raycast examples complete!\n", .{});
}
```

---

## Performance Tips

### 1. Cache Start Polygons

```zig
pub const RaycastCache = struct {
    start_ref: PolyRef,
    start_pos: [3]f32,
    valid: bool = false,

    pub fn update(
        self: *RaycastCache,
        query: *const NavMeshQuery,
        pos: [3]f32,
    ) !void {
        const extents = [3]f32{ 2.0, 4.0, 2.0 };
        const filter = QueryFilter.init();

        try query.findNearestPoly(&pos, &extents, &filter, &self.start_ref, null);
        self.start_pos = pos;
        self.valid = true;
    }
};
```

### 2. Batch Raycasts

```zig
pub fn batchRaycast(
    query: *const NavMeshQuery,
    rays: []const struct { start: [3]f32, end: [3]f32 },
    results: []RaycastResult,
) !void {
    std.debug.assert(rays.len == results.len);

    // Cache to avoid repeated findNearestPoly
    var cache: [32]RaycastCache = undefined;
    var cache_count: usize = 0;

    for (rays, 0..) |ray, i| {
        // Try to find cached start_ref
        var start_ref: PolyRef = 0;

        for (cache[0..cache_count]) |*c| {
            if (distance3D(&c.start_pos, &ray.start) < 1.0) {
                start_ref = c.start_ref;
                break;
            }
        }

        if (start_ref == 0) {
            // Not cached, find and cache
            // ...
        }

        results[i] = try raycastWithDetails(query, ray.start, ray.end, start_ref);
    }
}
```

---

## Troubleshooting

### Raycast always misses

**Причины:**
- Start position not on NavMesh
- End position outside NavMesh bounds

**Решение:**
```zig
// Ensure start position is valid
var start_ref: PolyRef = 0;
try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);

if (start_ref == 0) {
    std.debug.print("⚠️ Start position not on NavMesh\n", .{});
}
```

### Incorrect hit normal

**Решение:** Убедитесь что используется правильная формула в `perp2D` (см. raycast bug fix #3)

---

## Next Steps

- 👥 [Crowd Simulation](crowd-simulation.md) - multi-agent AI
- 🏗️ [Performance Guide](performance.md) - optimization
- 📖 [Detour Pipeline](../02-architecture/detour-pipeline.md) - internals

---

**Поздравляем!** Вы освоили raycast. 🎉
