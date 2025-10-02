# Pathfinding Guide

Практическое руководство по использованию pathfinding в Detour.

---

## Overview

Этот guide покажет как использовать NavMesh для поиска пути, spatial queries, и navigation.

**Что вы изучите:**
- ✅ Инициализация NavMeshQuery
- ✅ Поиск nearest polygon
- ✅ A* pathfinding
- ✅ String pulling (waypoints)
- ✅ Path following
- ✅ Custom costs и filters

**Время:** 20-40 минут

---

## Prerequisites

```zig
const std = @import("std");
const nav = @import("zig-recast");

const Allocator = std.mem.Allocator;
const NavMesh = nav.detour.NavMesh;
const NavMeshQuery = nav.detour.NavMeshQuery;
const QueryFilter = nav.detour.QueryFilter;
const PolyRef = nav.detour.PolyRef;
```

**Требования:**
- Готовый NavMesh (см. [Creating NavMesh Guide](creating-navmesh.md))

---

## Step 1: Initialize Query

### Basic Setup

```zig
pub fn setupPathfinding(
    allocator: Allocator,
    navmesh: *const NavMesh,
) !*NavMeshQuery {
    // Create query with 2048 nodes (sufficient for most cases)
    const max_nodes: usize = 2048;

    var query = try NavMeshQuery.init(allocator);
    errdefer query.deinit();

    try query.initQuery(navmesh, max_nodes);

    std.debug.print("✅ NavMeshQuery initialized\n", .{});
    std.debug.print("   Max nodes: {d}\n", .{max_nodes});

    return query;
}
```

### Advanced Setup

```zig
pub fn setupAdvancedQuery(
    allocator: Allocator,
    navmesh: *const NavMesh,
    config: QueryConfig,
) !*NavMeshQuery {
    var query = try NavMeshQuery.init(allocator);
    errdefer query.deinit();

    // Custom node pool size based on expected path length
    const max_nodes = config.max_expected_path_length * 4;
    try query.initQuery(navmesh, max_nodes);

    std.debug.print("Query configured:\n", .{});
    std.debug.print("  Node pool: {d}\n", .{max_nodes});

    return query;
}

pub const QueryConfig = struct {
    max_expected_path_length: usize = 512,
};
```

---

## Step 2: Find Nearest Polygon

### Basic Nearest Poly

```zig
pub fn findNearestPolygon(
    query: *const NavMeshQuery,
    position: [3]f32,
) !PolyRef {
    // Search extents (how far to look for nearby polygons)
    const extents = [3]f32{
        2.0,  // X: 2 meters
        4.0,  // Y: 4 meters (allow vertical distance)
        2.0,  // Z: 2 meters
    };

    // Default filter (all walkable polygons)
    const filter = QueryFilter.init();

    var nearest_ref: PolyRef = 0;
    var nearest_pos: [3]f32 = undefined;

    try query.findNearestPoly(
        &position,
        &extents,
        &filter,
        &nearest_ref,
        &nearest_pos,
    );

    if (nearest_ref == 0) {
        std.debug.print("⚠️ No polygon found near ({d:.2}, {d:.2}, {d:.2})\n", .{
            position[0],
            position[1],
            position[2],
        });
        return error.NoNearbyPolygon;
    }

    std.debug.print("✅ Found polygon {d}\n", .{nearest_ref});
    std.debug.print("   Closest point: ({d:.2}, {d:.2}, {d:.2})\n", .{
        nearest_pos[0],
        nearest_pos[1],
        nearest_pos[2],
    });

    return nearest_ref;
}
```

### Adaptive Search

```zig
pub fn findNearestPolygonAdaptive(
    query: *const NavMeshQuery,
    position: [3]f32,
) !struct { ref: PolyRef, pos: [3]f32 } {
    const filter = QueryFilter.init();

    // Try increasingly larger search radii
    const search_radii = [_]f32{ 1.0, 2.0, 5.0, 10.0, 20.0 };

    for (search_radii) |radius| {
        const extents = [3]f32{ radius, radius * 2, radius };

        var nearest_ref: PolyRef = 0;
        var nearest_pos: [3]f32 = undefined;

        query.findNearestPoly(
            &position,
            &extents,
            &filter,
            &nearest_ref,
            &nearest_pos,
        ) catch continue;

        if (nearest_ref != 0) {
            std.debug.print("✅ Found polygon (radius={d:.1}m)\n", .{radius});
            return .{ .ref = nearest_ref, .pos = nearest_pos };
        }
    }

    return error.NoNearbyPolygon;
}
```

---

## Step 3: Find Path (A*)

### Basic Pathfinding

```zig
pub fn findPath(
    query: *NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    allocator: Allocator,
) ![]PolyRef {
    const filter = QueryFilter.init();

    // 1. Find start and end polygons
    var start_ref: PolyRef = undefined;
    var end_ref: PolyRef = undefined;

    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, null);

    if (start_ref == 0 or end_ref == 0) {
        return error.InvalidStartOrEnd;
    }

    std.debug.print("Start polygon: {d}\n", .{start_ref});
    std.debug.print("End polygon: {d}\n", .{end_ref});

    // 2. Find polygon path
    var poly_path = try allocator.alloc(PolyRef, 256);
    defer allocator.free(poly_path);

    const poly_count = try query.findPath(
        start_ref,
        end_ref,
        &start_pos,
        &end_pos,
        &filter,
        poly_path,
    );

    std.debug.print("Polygon path length: {d}\n", .{poly_count});

    if (poly_count == 0) {
        return error.NoPathFound;
    }

    // 3. Return path (caller owns)
    const result = try allocator.alloc(PolyRef, poly_count);
    @memcpy(result, poly_path[0..poly_count]);

    return result;
}
```

### Pathfinding with Status

```zig
pub const PathResult = struct {
    path: []PolyRef,
    status: nav.detour.Status,
    complete: bool,

    pub fn deinit(self: *PathResult, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub fn findPathDetailed(
    query: *NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    allocator: Allocator,
) !PathResult {
    const filter = QueryFilter.init();

    var start_ref: PolyRef = 0;
    var end_ref: PolyRef = 0;

    const extents = [3]f32{ 2.0, 4.0, 2.0 };

    try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);
    try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, null);

    var poly_path = try allocator.alloc(PolyRef, 256);
    defer allocator.free(poly_path);

    const poly_count = try query.findPath(
        start_ref,
        end_ref,
        &start_pos,
        &end_pos,
        &filter,
        poly_path,
    );

    // Check if path is complete
    const complete = (poly_count > 0 and poly_path[poly_count - 1] == end_ref);

    const result_path = try allocator.alloc(PolyRef, poly_count);
    @memcpy(result_path, poly_path[0..poly_count]);

    return PathResult{
        .path = result_path,
        .status = nav.detour.Status.ok(),
        .complete = complete,
    };
}
```

---

## Step 4: String Pulling (Waypoints)

### Convert Path to Waypoints

```zig
pub fn findStraightPath(
    query: *const NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    poly_path: []const PolyRef,
    allocator: Allocator,
) ![]f32 {
    // Maximum waypoints = poly_path.len + 2
    const max_waypoints = poly_path.len + 2;

    var straight_path = try allocator.alloc(f32, max_waypoints * 3);
    errdefer allocator.free(straight_path);

    var waypoint_count: usize = 0;

    _ = try query.findStraightPath(
        &start_pos,
        &end_pos,
        poly_path,
        straight_path,
        null,  // No flags needed
        null,  // No poly refs needed
        &waypoint_count,
        0,  // No options
    );

    std.debug.print("Waypoints: {d}\n", .{waypoint_count});

    // Resize to actual count
    const result = try allocator.realloc(straight_path, waypoint_count * 3);

    return result;
}
```

### Waypoints with Metadata

```zig
pub const Waypoint = struct {
    position: [3]f32,
    flags: u8,
    poly_ref: PolyRef,
};

pub fn findWaypointsWithMetadata(
    query: *const NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    poly_path: []const PolyRef,
    allocator: Allocator,
) ![]Waypoint {
    const max_waypoints = poly_path.len + 2;

    var positions = try allocator.alloc(f32, max_waypoints * 3);
    defer allocator.free(positions);

    var flags = try allocator.alloc(u8, max_waypoints);
    defer allocator.free(flags);

    var poly_refs = try allocator.alloc(PolyRef, max_waypoints);
    defer allocator.free(poly_refs);

    var waypoint_count: usize = 0;

    _ = try query.findStraightPath(
        &start_pos,
        &end_pos,
        poly_path,
        positions,
        flags,
        poly_refs,
        &waypoint_count,
        0,
    );

    // Convert to Waypoint structs
    var waypoints = try allocator.alloc(Waypoint, waypoint_count);

    for (0..waypoint_count) |i| {
        waypoints[i] = .{
            .position = .{
                positions[i * 3 + 0],
                positions[i * 3 + 1],
                positions[i * 3 + 2],
            },
            .flags = flags[i],
            .poly_ref = poly_refs[i],
        };
    }

    return waypoints;
}
```

---

## Step 5: Complete Pathfinding Pipeline

```zig
pub fn findCompletePath(
    query: *NavMeshQuery,
    start_pos: [3]f32,
    end_pos: [3]f32,
    allocator: Allocator,
) ![]Waypoint {
    std.debug.print("=== Finding Path ===\n", .{});
    std.debug.print("Start: ({d:.2}, {d:.2}, {d:.2})\n", .{ start_pos[0], start_pos[1], start_pos[2] });
    std.debug.print("End:   ({d:.2}, {d:.2}, {d:.2})\n", .{ end_pos[0], end_pos[1], end_pos[2] });

    // Step 1: Find polygon path
    var path_result = try findPathDetailed(query, start_pos, end_pos, allocator);
    defer path_result.deinit(allocator);

    if (!path_result.complete) {
        std.debug.print("⚠️ Partial path (destination unreachable)\n", .{});
    }

    // Step 2: Convert to waypoints
    const waypoints = try findWaypointsWithMetadata(
        query,
        start_pos,
        end_pos,
        path_result.path,
        allocator,
    );

    std.debug.print("✅ Path found: {d} waypoints\n", .{waypoints.len});

    return waypoints;
}
```

---

## Step 6: Custom Filters & Costs

### Area Cost Modification

```zig
pub fn setupCustomFilter() QueryFilter {
    var filter = QueryFilter.init();

    // Area types (from Recast)
    const AREA_GROUND: usize = 0;
    const AREA_WATER: usize = 1;
    const AREA_ROAD: usize = 2;
    const AREA_GRASS: usize = 3;

    // Set area costs
    filter.setAreaCost(AREA_GROUND, 1.0);  // Normal cost
    filter.setAreaCost(AREA_WATER, 10.0);  // Avoid water (10x cost)
    filter.setAreaCost(AREA_ROAD, 0.5);    // Prefer roads (0.5x cost)
    filter.setAreaCost(AREA_GRASS, 2.0);   // Slightly avoid grass

    std.debug.print("Custom filter configured:\n", .{});
    std.debug.print("  Water: 10x cost\n", .{});
    std.debug.print("  Road: 0.5x cost\n", .{});

    return filter;
}
```

### Exclude Flags

```zig
pub const PolyFlags = struct {
    pub const WALK: u16 = 0x01;
    pub const SWIM: u16 = 0x02;
    pub const DOOR: u16 = 0x04;
    pub const JUMP: u16 = 0x08;
    pub const DISABLED: u16 = 0x10;
};

pub fn setupWalkOnlyFilter() QueryFilter {
    var filter = QueryFilter.init();

    // Include only WALK polygons
    filter.setIncludeFlags(PolyFlags.WALK);

    // Exclude DISABLED polygons
    filter.setExcludeFlags(PolyFlags.DISABLED);

    return filter;
}

pub fn setupSwimmerFilter() QueryFilter {
    var filter = QueryFilter.init();

    // Include both WALK and SWIM
    filter.setIncludeFlags(PolyFlags.WALK | PolyFlags.SWIM);

    // Water is cheaper for swimmer
    filter.setAreaCost(1, 0.5);  // AREA_WATER

    return filter;
}
```

---

## Step 7: Path Following

### Simple Path Follower

```zig
pub const PathFollower = struct {
    waypoints: []Waypoint,
    current_waypoint: usize,
    reached_threshold: f32,

    pub fn init(waypoints: []Waypoint) PathFollower {
        return .{
            .waypoints = waypoints,
            .current_waypoint = 0,
            .reached_threshold = 0.5,  // 0.5 meters
        };
    }

    pub fn update(self: *PathFollower, current_pos: [3]f32) ?[3]f32 {
        if (self.current_waypoint >= self.waypoints.len) {
            return null;  // Path complete
        }

        const target = self.waypoints[self.current_waypoint].position;

        // Check if reached current waypoint
        const dist = distance2D(&current_pos, &target);
        if (dist < self.reached_threshold) {
            self.current_waypoint += 1;

            if (self.current_waypoint >= self.waypoints.len) {
                std.debug.print("✅ Reached destination\n", .{});
                return null;
            }

            std.debug.print("Waypoint {d}/{d} reached\n", .{
                self.current_waypoint,
                self.waypoints.len,
            });

            return self.waypoints[self.current_waypoint].position;
        }

        return target;
    }

    pub fn getProgress(self: *const PathFollower) f32 {
        if (self.waypoints.len == 0) return 1.0;
        return @as(f32, @floatFromInt(self.current_waypoint)) /
            @as(f32, @floatFromInt(self.waypoints.len));
    }
};

fn distance2D(a: *const [3]f32, b: *const [3]f32) f32 {
    const dx = b[0] - a[0];
    const dz = b[2] - a[2];
    return @sqrt(dx * dx + dz * dz);
}
```

### Advanced Path Follower

```zig
pub const AdvancedPathFollower = struct {
    waypoints: []Waypoint,
    current_waypoint: usize,
    lookahead_distance: f32,
    query: *NavMeshQuery,
    allocator: Allocator,

    pub fn init(
        waypoints: []Waypoint,
        query: *NavMeshQuery,
        allocator: Allocator,
    ) AdvancedPathFollower {
        return .{
            .waypoints = waypoints,
            .current_waypoint = 0,
            .lookahead_distance = 2.0,
            .query = query,
            .allocator = allocator,
        };
    }

    pub fn update(
        self: *AdvancedPathFollower,
        current_pos: [3]f32,
    ) !?[3]f32 {
        if (self.current_waypoint >= self.waypoints.len) {
            return null;
        }

        // Look ahead to skip intermediate waypoints
        var target_idx = self.current_waypoint;

        while (target_idx + 1 < self.waypoints.len) {
            const next_waypoint = self.waypoints[target_idx + 1].position;
            const dist = distance2D(&current_pos, &next_waypoint);

            if (dist > self.lookahead_distance) break;

            // Can reach next waypoint directly
            target_idx += 1;
        }

        self.current_waypoint = target_idx;

        return self.waypoints[target_idx].position;
    }

    pub fn replan(
        self: *AdvancedPathFollower,
        current_pos: [3]f32,
        new_end: [3]f32,
    ) !void {
        // Free old waypoints
        self.allocator.free(self.waypoints);

        // Find new path
        const new_waypoints = try findCompletePath(
            self.query,
            current_pos,
            new_end,
            self.allocator,
        );

        self.waypoints = new_waypoints;
        self.current_waypoint = 0;

        std.debug.print("✅ Path replanned: {d} waypoints\n", .{new_waypoints.len});
    }
};
```

---

## Complete Example

```zig
pub fn pathfindingExample(
    allocator: Allocator,
    navmesh: *const NavMesh,
) !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("   Pathfinding Example\n", .{});
    std.debug.print("========================================\n\n", .{});

    // Step 1: Setup query
    var query = try setupPathfinding(allocator, navmesh);
    defer query.deinit();

    // Step 2: Define start and end
    const start_pos = [3]f32{ -5.0, 0.0, -5.0 };
    const end_pos = [3]f32{ 5.0, 0.0, 5.0 };

    // Step 3: Find path
    const waypoints = try findCompletePath(query, start_pos, end_pos, allocator);
    defer allocator.free(waypoints);

    // Step 4: Print waypoints
    std.debug.print("\nWaypoints:\n", .{});
    for (waypoints, 0..) |wp, i| {
        std.debug.print("  {d}. ({d:.2}, {d:.2}, {d:.2})\n", .{
            i + 1,
            wp.position[0],
            wp.position[1],
            wp.position[2],
        });
    }

    // Step 5: Setup path follower
    var follower = PathFollower.init(waypoints);

    // Simulate movement
    var current_pos = start_pos;
    const move_speed: f32 = 1.0;  // 1 meter per step

    while (follower.update(current_pos)) |target| {
        // Move towards target
        const dir = normalize2D(subtract2D(&target, &current_pos));
        current_pos[0] += dir[0] * move_speed;
        current_pos[2] += dir[1] * move_speed;

        std.debug.print("Position: ({d:.2}, {d:.2}) - Progress: {d:.0}%\n", .{
            current_pos[0],
            current_pos[2],
            follower.getProgress() * 100,
        });
    }

    std.debug.print("\n✅ Navigation complete!\n", .{});
}

fn subtract2D(a: *const [3]f32, b: *const [3]f32) [2]f32 {
    return .{ a[0] - b[0], a[2] - b[2] };
}

fn normalize2D(v: [2]f32) [2]f32 {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
    if (len == 0) return .{ 0, 0 };
    return .{ v[0] / len, v[1] / len };
}
```

---

## Performance Tips

### 1. Node Pool Sizing

```zig
// Short paths (<100 polygons)
const max_nodes = 512;

// Medium paths (100-500 polygons)
const max_nodes = 2048;  // Default, recommended

// Long paths (>500 polygons)
const max_nodes = 8192;
```

### 2. Reuse Query Objects

```zig
// GOOD - reuse query
var query = try NavMeshQuery.init(allocator);
defer query.deinit();
try query.initQuery(navmesh, 2048);

for (agents) |agent| {
    _ = try query.findPath(...);  // Reuse
}

// BAD - create new query each time
for (agents) |agent| {
    var query = try NavMeshQuery.init(allocator);
    defer query.deinit();
    // Expensive!
}
```

### 3. Lazy Waypoint Generation

```zig
// Only generate waypoints when needed
const poly_path = try findPath(...);  // Cheap

// Later, when rendering or following:
const waypoints = try findStraightPath(...);  // More expensive
```

---

## Troubleshooting

### No path found

**Причины:**
- Start/end not on NavMesh
- Start and end in different disconnected regions

**Решение:**
```zig
// Larger search extents
const extents = [3]f32{ 10.0, 10.0, 10.0 };

// Check if polygons found
if (start_ref == 0) {
    std.debug.print("⚠️ Start position not on NavMesh\n", .{});
}
```

### Partial path

**Причина:** End position unreachable

**Решение:**
```zig
if (!path_result.complete) {
    std.debug.print("Partial path - going as close as possible\n", .{});
    // Use partial path anyway
}
```

---

## Next Steps

- 🎯 [Raycast Guide](raycast.md) - line-of-sight checks
- 👥 [Crowd Simulation](crowd-simulation.md) - multi-agent
- 🏗️ [Performance Guide](performance.md) - optimization

---

**Поздравляем!** Вы освоили pathfinding. 🎉
