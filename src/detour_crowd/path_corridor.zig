const std = @import("std");
const detour = @import("../detour.zig");
const math = @import("../math.zig");

const NavMeshQuery = detour.NavMeshQuery;
const QueryFilter = detour.QueryFilter;
const PolyRef = detour.PolyRef;

/// Represents a dynamic polygon corridor used to plan agent movement.
///
/// The corridor is a path of polygons with a current position and a target.
/// It provides methods to optimize and adjust the path as the agent moves.
pub const PathCorridor = struct {
    pos: [3]f32,
    target: [3]f32,
    path: []PolyRef,
    npath: usize,
    max_path: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a path corridor with a maximum path size
    pub fn init(allocator: std.mem.Allocator, max_path: usize) !Self {
        if (max_path == 0) return error.InvalidParam;

        const path = try allocator.alloc(PolyRef, max_path);
        errdefer allocator.free(path);

        return Self{
            .pos = [3]f32{ 0, 0, 0 },
            .target = [3]f32{ 0, 0, 0 },
            .path = path,
            .npath = 0,
            .max_path = max_path,
            .allocator = allocator,
        };
    }

    /// Free the corridor resources
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.path);
    }

    /// Reset the corridor to the specified position
    pub fn reset(self: *Self, ref: PolyRef, pos: *const [3]f32) void {
        math.vcopy(&self.pos, pos);
        math.vcopy(&self.target, pos);
        self.path[0] = ref;
        self.npath = 1;
    }

    /// Get the current position within the corridor (in the first polygon)
    pub fn getPos(self: *const Self) *const [3]f32 {
        return &self.pos;
    }

    /// Get the current target within the corridor (in the last polygon)
    pub fn getTarget(self: *const Self) *const [3]f32 {
        return &self.target;
    }

    /// Get the first polygon reference in the corridor
    pub fn getFirstPoly(self: *const Self) PolyRef {
        return if (self.npath > 0) self.path[0] else 0;
    }

    /// Get the last polygon reference in the corridor
    pub fn getLastPoly(self: *const Self) PolyRef {
        return if (self.npath > 0) self.path[self.npath - 1] else 0;
    }

    /// Get the corridor's path
    pub fn getPath(self: *const Self) []const PolyRef {
        return self.path[0..self.npath];
    }

    /// Get the number of polygons in the corridor path
    pub fn getPathCount(self: *const Self) usize {
        return self.npath;
    }

    /// Load a new path and target into the corridor
    pub fn setCorridor(self: *Self, target: *const [3]f32, polys: []const PolyRef) void {
        math.vcopy(&self.target, target);
        const copy_count = @min(polys.len, self.max_path);
        @memcpy(self.path[0..copy_count], polys[0..copy_count]);
        self.npath = copy_count;
    }

    /// Find the corners in the corridor from the position toward the target
    /// Returns the number of corners found
    pub fn findCorners(
        self: *const Self,
        corner_verts: []f32,
        corner_flags: ?[]u8,
        corner_polys: ?[]PolyRef,
        max_corners: usize,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !usize {
        const MIN_TARGET_DIST: f32 = 0.01;

        var n_corners: usize = 0;

        // Get straight path
        const straight_path = try allocator.alloc(f32, max_corners * 3);
        defer allocator.free(straight_path);

        var straight_path_flags_buf: ?[]u8 = null;
        if (corner_flags != null) {
            straight_path_flags_buf = try allocator.alloc(u8, max_corners);
        }
        defer if (straight_path_flags_buf != null) allocator.free(straight_path_flags_buf.?);

        var straight_path_refs_buf: ?[]PolyRef = null;
        if (corner_polys != null) {
            straight_path_refs_buf = try allocator.alloc(PolyRef, max_corners);
        }
        defer if (straight_path_refs_buf != null) allocator.free(straight_path_refs_buf.?);

        var straight_path_count: usize = 0;
        _ = try navquery.findStraightPath(
            &self.pos,
            &self.target,
            self.path[0..self.npath],
            straight_path,
            straight_path_flags_buf,
            straight_path_refs_buf,
            &straight_path_count,
            0,
        );
        _ = filter; // Not used here, but kept for API compatibility

        // Copy corners
        n_corners = @min(straight_path_count, max_corners);

        for (0..n_corners) |i| {
            corner_verts[i * 3 + 0] = straight_path[i * 3 + 0];
            corner_verts[i * 3 + 1] = straight_path[i * 3 + 1];
            corner_verts[i * 3 + 2] = straight_path[i * 3 + 2];

            if (corner_flags) |flags| {
                if (straight_path_flags_buf) |sp_flags| {
                    flags[i] = sp_flags[i];
                }
            }

            if (corner_polys) |polys| {
                if (straight_path_refs_buf) |sp_refs| {
                    polys[i] = sp_refs[i];
                }
            }
        }

        // Prune points in the beginning of the path which are too close
        while (n_corners > 0) {
            const corner = corner_verts[0..3];
            if ((corner[0] - self.pos[0]) * (corner[0] - self.pos[0]) +
                (corner[2] - self.pos[2]) * (corner[2] - self.pos[2]) > MIN_TARGET_DIST * MIN_TARGET_DIST)
            {
                break;
            }

            n_corners -= 1;
            if (n_corners > 0) {
                // Shift corners down
                std.mem.copyForwards(f32, corner_verts[0 .. n_corners * 3], corner_verts[3 .. (n_corners + 1) * 3]);

                if (corner_flags) |flags| {
                    std.mem.copyForwards(u8, flags[0..n_corners], flags[1 .. n_corners + 1]);
                }

                if (corner_polys) |polys| {
                    std.mem.copyForwards(PolyRef, polys[0..n_corners], polys[1 .. n_corners + 1]);
                }
            }
        }

        return n_corners;
    }

    /// Checks if the corridor path is valid
    pub fn isValid(
        self: *const Self,
        max_look_ahead: usize,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
    ) bool {
        const n = @min(self.npath, max_look_ahead);
        for (0..n) |i| {
            if (!navquery.isValidPolyRef(self.path[i], filter)) {
                return false;
            }
        }
        return true;
    }

    /// Moves the position along the corridor
    pub fn movePosition(
        self: *Self,
        npos: *const [3]f32,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !bool {
        const MAX_VISITED = 16;

        var result = [3]f32{ 0, 0, 0 };
        var visited = try allocator.alloc(PolyRef, MAX_VISITED);
        defer allocator.free(visited);
        var nvisited: usize = 0;

        const status = try navquery.moveAlongSurface(
            self.path[0],
            &self.pos,
            npos,
            filter,
            &result,
            visited,
            &nvisited,
        );

        if (!status.isSuccess()) {
            return false;
        }

        self.npath = mergeCorridorStartMoved(self.path, self.npath, self.max_path, visited[0..nvisited]);

        // Adjust position to stay on top of navmesh
        var h: f32 = self.pos[1];
        _ = navquery.getPolyHeight(self.path[0], &result, &h) catch {
            h = result[1];
        };
        result[1] = h;
        math.vcopy(&self.pos, &result);

        return true;
    }

    /// Moves the target along the corridor
    pub fn moveTargetPosition(
        self: *Self,
        npos: *const [3]f32,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !bool {
        const MAX_VISITED = 16;

        var result = [3]f32{ 0, 0, 0 };
        var visited = try allocator.alloc(PolyRef, MAX_VISITED);
        defer allocator.free(visited);
        var nvisited: usize = 0;

        const status = try navquery.moveAlongSurface(
            self.path[self.npath - 1],
            &self.target,
            npos,
            filter,
            &result,
            visited,
            &nvisited,
            MAX_VISITED,
        );

        if (!status.isSuccess()) {
            return false;
        }

        self.npath = mergeCorridorEndMoved(self.path, self.npath, self.max_path, visited[0..nvisited]);
        math.vcopy(&self.target, &result);

        return true;
    }

    /// Optimizes path visibility using raycast
    pub fn optimizePathVisibility(
        self: *Self,
        next: *const [3]f32,
        path_optimization_range: f32,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !void {
        // Clamp the ray to max distance
        var goal = [3]f32{ next[0], next[1], next[2] };
        var dist = math.vdist2D(&self.pos, &goal);

        // If too close to the goal, do not try to optimize
        if (dist < 0.01) {
            return;
        }

        // Overshoot a little to optimize open fields in tiled meshes
        dist = @min(dist + 0.01, path_optimization_range);

        // Adjust ray length
        var delta = [3]f32{ 0, 0, 0 };
        math.vsub(&delta, &goal, &self.pos);
        math.vmad(&goal, &self.pos, &delta, path_optimization_range / dist);

        const MAX_RES = 32;
        const res = try allocator.alloc(PolyRef, MAX_RES);
        defer allocator.free(res);

        const query_mod = @import("../detour/query.zig");
        var hit = query_mod.RaycastHit.init(res);

        _ = try navquery.raycast(
            self.path[0],
            &self.pos,
            &goal,
            filter,
            0, // options
            &hit,
            0, // prev_ref
        );

        if (hit.path_count > 1 and hit.t > 0.99) {
            self.npath = mergeCorridorStartShortcut(self.path, self.npath, self.max_path, hit.path[0..hit.path_count]);
        }
    }

    /// Optimize the path using a local area search (partial replanning)
    /// Uses sliced pathfinding to find a better path through the corridor
    /// Returns: true if optimization was successful
    pub fn optimizePathTopology(
        self: *Self,
        navquery: *NavMeshQuery,
        filter: *const QueryFilter,
        allocator: std.mem.Allocator,
    ) !bool {
        if (self.npath < 3) return false;

        const MAX_ITER: u32 = 32;
        const MAX_RES: usize = 32;

        var res = try allocator.alloc(PolyRef, MAX_RES);
        defer allocator.free(res);

        // Init sliced pathfinding from start to end of corridor
        var status = navquery.initSlicedFindPath(
            self.path[0],
            self.path[self.npath - 1],
            &self.pos,
            &self.target,
            filter,
            0, // options
        );

        if (status.failure) return false;

        // Update pathfinding for MAX_ITER iterations
        status = navquery.updateSlicedFindPath(MAX_ITER, null);
        if (status.failure) return false;

        // Finalize with partial path support
        var nres: usize = 0;
        status = navquery.finalizeSlicedFindPathPartial(
            self.path[0..self.npath],
            res,
            &nres,
        );

        if (status.success and nres > 0) {
            self.npath = mergeCorridorStartShortcut(self.path, self.npath, self.max_path, res[0..nres]);
            return true;
        }

        return false;
    }

    /// Fixes the path start to a safe polygon
    pub fn fixPathStart(self: *Self, safe_ref: PolyRef, safe_pos: *const [3]f32) bool {
        math.vcopy(&self.pos, safe_pos);
        if (self.npath < 3 and self.npath > 0) {
            self.path[2] = self.path[self.npath - 1];
            self.path[0] = safe_ref;
            self.path[1] = 0;
            self.npath = 3;
        } else {
            self.path[0] = safe_ref;
            self.path[1] = 0;
        }
        return true;
    }

    /// Trims invalid polygons from the path
    pub fn trimInvalidPath(
        self: *Self,
        safe_ref: PolyRef,
        safe_pos: *const [3]f32,
        navquery: *const NavMeshQuery,
        filter: *const QueryFilter,
    ) !bool {
        // Keep valid path as far as possible
        var n: usize = 0;
        while (n < self.npath and navquery.isValidPolyRef(self.path[n], filter)) {
            n += 1;
        }

        if (n == self.npath) {
            // All valid, no need to fix
            return true;
        } else if (n == 0) {
            // The first polyref is bad, use current safe values
            math.vcopy(&self.pos, safe_pos);
            self.path[0] = safe_ref;
            self.npath = 1;
        } else {
            // The path is partially usable
            self.npath = n;
        }

        // Clamp target pos to last poly
        var tgt = [3]f32{ self.target[0], self.target[1], self.target[2] };
        _ = try navquery.closestPointOnPolyBoundary(self.path[self.npath - 1], &tgt, &self.target);

        return true;
    }

    /// Moves over an off-mesh connection
    pub fn moveOverOffmeshConnection(
        self: *Self,
        offmesh_con_ref: PolyRef,
        refs: *[2]PolyRef,
        start_pos: *[3]f32,
        end_pos: *[3]f32,
        navquery: *const NavMeshQuery,
    ) !bool {
        // Advance the path up to and over the off-mesh connection
        var prev_ref: PolyRef = 0;
        var poly_ref: PolyRef = self.path[0];
        var npos: usize = 0;

        while (npos < self.npath and poly_ref != offmesh_con_ref) {
            prev_ref = poly_ref;
            poly_ref = self.path[npos];
            npos += 1;
        }

        if (npos == self.npath) {
            // Could not find offMeshConRef
            return false;
        }

        // Prune path
        var i: usize = npos;
        while (i < self.npath) : (i += 1) {
            self.path[i - npos] = self.path[i];
        }
        self.npath -= npos;

        refs[0] = prev_ref;
        refs[1] = poly_ref;

        const nav = navquery.getAttachedNavMesh();
        const status = try nav.getOffMeshConnectionPolyEndPoints(refs[0], refs[1], start_pos, end_pos);

        if (status.isSuccess()) {
            math.vcopy(&self.pos, end_pos);
            return true;
        }

        return false;
    }
};

/// Merges corridor after start position moved
fn mergeCorridorStartMoved(path: []PolyRef, npath: usize, max_path: usize, visited: []const PolyRef) usize {
    var furthest_path: isize = -1;
    var furthest_visited: isize = -1;

    // Find furthest common polygon
    var i: isize = @as(isize, @intCast(npath)) - 1;
    while (i >= 0) : (i -= 1) {
        var found = false;
        var j: isize = @as(isize, @intCast(visited.len)) - 1;
        while (j >= 0) : (j -= 1) {
            if (path[@intCast(i)] == visited[@intCast(j)]) {
                furthest_path = i;
                furthest_visited = j;
                found = true;
            }
        }
        if (found) break;
    }

    // If no intersection found, return current path
    if (furthest_path == -1 or furthest_visited == -1) {
        return npath;
    }

    // Concatenate paths
    const fp: usize = @intCast(furthest_path);
    const fv: usize = @intCast(furthest_visited);
    const req = visited.len - fv;
    const orig = @min(fp + 1, npath);
    var size = if (npath > orig) npath - orig else 0;

    if (req + size > max_path) {
        size = max_path - req;
    }

    if (size > 0) {
        std.mem.copyBackwards(PolyRef, path[req .. req + size], path[orig .. orig + size]);
    }

    // Store visited in reverse order
    const copy_count = @min(req, max_path);
    for (0..copy_count) |k| {
        path[k] = visited[visited.len - 1 - k];
    }

    return req + size;
}

/// Merges corridor after end position moved
fn mergeCorridorEndMoved(path: []PolyRef, npath: usize, max_path: usize, visited: []const PolyRef) usize {
    var furthest_path: isize = -1;
    var furthest_visited: isize = -1;

    // Find furthest common polygon
    for (0..npath) |i| {
        var found = false;
        var j: isize = @as(isize, @intCast(visited.len)) - 1;
        while (j >= 0) : (j -= 1) {
            if (path[i] == visited[@intCast(j)]) {
                furthest_path = @intCast(i);
                furthest_visited = j;
                found = true;
            }
        }
        if (found) break;
    }

    // If no intersection found, return current path
    if (furthest_path == -1 or furthest_visited == -1) {
        return npath;
    }

    // Concatenate paths
    const fp: usize = @intCast(furthest_path);
    const fv: usize = @intCast(furthest_visited);
    const ppos = fp + 1;
    const vpos = fv + 1;
    const count = @min(visited.len - vpos, max_path - ppos);

    if (count > 0) {
        @memcpy(path[ppos .. ppos + count], visited[vpos .. vpos + count]);
    }

    return ppos + count;
}

/// Merges corridor using visibility shortcut
fn mergeCorridorStartShortcut(path: []PolyRef, npath: usize, max_path: usize, visited: []const PolyRef) usize {
    var furthest_path: isize = -1;
    var furthest_visited: isize = -1;

    // Find furthest common polygon
    var i: isize = @as(isize, @intCast(npath)) - 1;
    while (i >= 0) : (i -= 1) {
        var found = false;
        var j: isize = @as(isize, @intCast(visited.len)) - 1;
        while (j >= 0) : (j -= 1) {
            if (path[@intCast(i)] == visited[@intCast(j)]) {
                furthest_path = i;
                furthest_visited = j;
                found = true;
            }
        }
        if (found) break;
    }

    // If no intersection found, return current path
    if (furthest_path == -1 or furthest_visited == -1) {
        return npath;
    }

    const fv: usize = @intCast(furthest_visited);
    const req = fv;

    if (req <= 0) {
        return npath;
    }

    const fp: usize = @intCast(furthest_path);
    const orig = fp;
    var size = if (npath > orig) npath - orig else 0;

    if (req + size > max_path) {
        size = max_path - req;
    }

    if (size > 0) {
        std.mem.copyBackwards(PolyRef, path[req .. req + size], path[orig .. orig + size]);
    }

    // Store visited
    for (0..req) |k| {
        path[k] = visited[k];
    }

    return req + size;
}

test "PathCorridor basic" {
    const allocator = std.testing.allocator;

    var corridor = try PathCorridor.init(allocator, 256);
    defer corridor.deinit();

    const start_pos = [3]f32{ 0, 0, 0 };
    corridor.reset(1, &start_pos);

    try std.testing.expectEqual(@as(usize, 1), corridor.getPathCount());
    try std.testing.expectEqual(@as(PolyRef, 1), corridor.getFirstPoly());
    try std.testing.expectEqual(@as(PolyRef, 1), corridor.getLastPoly());
}
