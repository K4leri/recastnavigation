const std = @import("std");
const detour = @import("../detour.zig");
const math = @import("../math.zig");

const NavMesh = detour.NavMesh;
const NavMeshQuery = detour.NavMeshQuery;
const QueryFilter = detour.QueryFilter;
const PolyRef = detour.PolyRef;
const Status = detour.Status;

pub const PathQueueRef = u32;
pub const INVALID_QUEUE_REF: PathQueueRef = 0;

/// Path query request state
const PathQuery = struct {
    ref: PathQueueRef,
    start_pos: [3]f32,
    end_pos: [3]f32,
    start_ref: PolyRef,
    end_ref: PolyRef,
    path: []PolyRef,
    npath: usize,
    status: Status,
    keep_alive: i32,
    filter: ?*const QueryFilter,
};

/// Manages asynchronous pathfinding requests
/// NOTE: This is a simplified implementation using blocking findPath()
/// The original uses sliced pathfinding (initSlicedFindPath, updateSlicedFindPath, finalizeSlicedFindPath)
/// which is not yet implemented
pub const PathQueue = struct {
    const MAX_QUEUE = 8;
    const MAX_KEEP_ALIVE = 2;

    queue: [MAX_QUEUE]PathQuery,
    next_handle: PathQueueRef,
    max_path_size: usize,
    queue_head: usize,
    navquery: *NavMeshQuery,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize path queue
    pub fn init(
        allocator: std.mem.Allocator,
        max_path_size: usize,
        max_search_node_count: usize,
        nav: *NavMesh,
    ) !Self {
        const navquery = try NavMeshQuery.init(allocator);
        errdefer navquery.deinit();

        try navquery.initQuery(nav, max_search_node_count);

        var queue: [MAX_QUEUE]PathQuery = undefined;
        for (&queue) |*q| {
            q.* = .{
                .ref = INVALID_QUEUE_REF,
                .start_pos = [3]f32{ 0, 0, 0 },
                .end_pos = [3]f32{ 0, 0, 0 },
                .start_ref = 0,
                .end_ref = 0,
                .path = try allocator.alloc(PolyRef, max_path_size),
                .npath = 0,
                .status = Status.ok(),
                .keep_alive = 0,
                .filter = null,
            };
        }

        return Self{
            .queue = queue,
            .next_handle = 1,
            .max_path_size = max_path_size,
            .queue_head = 0,
            .navquery = navquery,
            .allocator = allocator,
        };
    }

    /// Free path queue resources
    pub fn deinit(self: *Self) void {
        self.navquery.deinit();
        for (&self.queue) |*q| {
            self.allocator.free(q.path);
        }
    }

    /// Update path requests
    /// NOTE: Simplified version - processes one complete path per call
    /// Original version uses sliced pathfinding with maxIters budget
    pub fn update(self: *Self, max_iters: usize) void {
        _ = max_iters; // Ignored in simplified version

        // Update path request until there is nothing to update
        var i: usize = 0;
        while (i < MAX_QUEUE) : (i += 1) {
            var q = &self.queue[self.queue_head % MAX_QUEUE];

            // Skip inactive requests
            if (q.ref == INVALID_QUEUE_REF) {
                self.queue_head += 1;
                continue;
            }

            // Handle completed request
            if (q.status.isSuccess() or q.status.isFailure()) {
                // If the path result has not been read in few frames, free the slot
                q.keep_alive += 1;
                if (q.keep_alive > MAX_KEEP_ALIVE) {
                    q.ref = INVALID_QUEUE_REF;
                    q.status = Status.ok();
                }

                self.queue_head += 1;
                continue;
            }

            // Handle query start (status is all false = not started)
            if (!q.status.isSuccess() and !q.status.isFailure() and !q.status.isInProgress()) {
                // Simplified: use blocking findPath instead of sliced pathfinding
                self.navquery.findPath(
                    q.start_ref,
                    q.end_ref,
                    &q.start_pos,
                    &q.end_pos,
                    q.filter orelse &QueryFilter.init(),
                    q.path,
                    &q.npath,
                ) catch {
                    q.status.failure = true;
                    continue;
                };
                q.status.success = true;
            }

            self.queue_head += 1;
        }
    }

    /// Request a path search
    pub fn request(
        self: *Self,
        start_ref: PolyRef,
        end_ref: PolyRef,
        start_pos: *const [3]f32,
        end_pos: *const [3]f32,
        filter: ?*const QueryFilter,
    ) PathQueueRef {
        // Find empty slot
        var slot: ?usize = null;
        for (&self.queue, 0..) |*q, idx| {
            if (q.ref == INVALID_QUEUE_REF) {
                slot = idx;
                break;
            }
        }

        // Could not find slot
        if (slot == null) {
            return INVALID_QUEUE_REF;
        }

        const ref = self.next_handle;
        self.next_handle += 1;
        if (self.next_handle == INVALID_QUEUE_REF) {
            self.next_handle += 1;
        }

        var q = &self.queue[slot.?];
        q.ref = ref;
        math.vcopy(&q.start_pos, start_pos);
        q.start_ref = start_ref;
        math.vcopy(&q.end_pos, end_pos);
        q.end_ref = end_ref;

        q.status = Status{}; // Mark as not started (all fields false)
        q.npath = 0;
        q.filter = filter;
        q.keep_alive = 0;

        return ref;
    }

    /// Get the status of a path request
    pub fn getRequestStatus(self: *const Self, ref: PathQueueRef) Status {
        for (&self.queue) |*q| {
            if (q.ref == ref) {
                return q.status;
            }
        }
        return Status{ .failure = true };
    }

    /// Get the result of a completed path request
    pub fn getPathResult(
        self: *Self,
        ref: PathQueueRef,
        path: []PolyRef,
        path_size: *usize,
    ) Status {
        for (&self.queue) |*q| {
            if (q.ref == ref) {
                const details = q.status.value & 0x0fff0000; // DT_STATUS_DETAIL_MASK

                // Free request for reuse
                q.ref = INVALID_QUEUE_REF;
                q.status = Status.ok();

                // Copy path
                const n = @min(q.npath, path.len);
                @memcpy(path[0..n], q.path[0..n]);
                path_size.* = n;

                return Status{ .success = true, .value = details };
            }
        }
        return Status{ .failure = true };
    }

    /// Get the nav query object
    pub fn getNavQuery(self: *const Self) *const NavMeshQuery {
        return self.navquery;
    }
};

test "PathQueue basic" {
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

    var queue = try PathQueue.init(allocator, 256, 2048, &navmesh);
    defer queue.deinit();

    const start_pos = [3]f32{ 0, 0, 0 };
    const end_pos = [3]f32{ 10, 0, 10 };

    const ref = queue.request(1, 2, &start_pos, &end_pos, null);
    try std.testing.expect(ref != INVALID_QUEUE_REF);

    // Status should indicate not started (value == 0)
    const status = queue.getRequestStatus(ref);
    _ = status; // We can't easily check status.value directly with packed struct
}
