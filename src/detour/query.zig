// Detour NavMesh Query - Pathfinding and navigation queries
const std = @import("std");
const common = @import("common.zig");
const navmesh = @import("navmesh.zig");
const math = @import("../math.zig");

const Vec3 = math.Vec3;
const NavMesh = navmesh.NavMesh;
const MeshTile = navmesh.MeshTile;
const Poly = navmesh.Poly;
const PolyRef = common.PolyRef;
const Status = common.Status;
const Error = common.Error;

/// Polygon filtering and traversal costs for navigation mesh query operations
pub const QueryFilter = struct {
    area_cost: [common.MAX_AREAS]f32,
    include_flags: u16,
    exclude_flags: u16,

    pub fn init() QueryFilter {
        var filter = QueryFilter{
            .area_cost = undefined,
            .include_flags = 0xffff,
            .exclude_flags = 0,
        };
        // Initialize all area costs to 1.0
        for (0..common.MAX_AREAS) |i| {
            filter.area_cost[i] = 1.0;
        }
        return filter;
    }

    /// Returns true if the polygon can be visited (is traversable)
    pub fn passFilter(self: *const QueryFilter, ref: PolyRef, tile: *const MeshTile, poly: *const Poly) bool {
        _ = ref; // unused
        _ = tile; // unused

        // Check if polygon has any of the include flags
        if ((poly.flags & self.include_flags) == 0) return false;

        // Check if polygon has any of the exclude flags
        if ((poly.flags & self.exclude_flags) != 0) return false;

        return true;
    }

    /// Returns cost to move from the beginning to the end of a line segment
    pub fn getCost(
        self: *const QueryFilter,
        pa: *const [3]f32,
        pb: *const [3]f32,
        prev_ref: PolyRef,
        prev_tile: ?*const MeshTile,
        prev_poly: ?*const Poly,
        cur_ref: PolyRef,
        cur_tile: *const MeshTile,
        cur_poly: *const Poly,
        next_ref: PolyRef,
        next_tile: ?*const MeshTile,
        next_poly: ?*const Poly,
    ) f32 {
        _ = prev_ref;
        _ = prev_tile;
        _ = prev_poly;
        _ = cur_ref;
        _ = cur_tile;
        _ = next_ref;
        _ = next_tile;
        _ = next_poly;

        // Calculate Euclidean distance
        const dx = pb[0] - pa[0];
        const dy = pb[1] - pa[1];
        const dz = pb[2] - pa[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);

        // Apply area cost
        return dist * self.area_cost[cur_poly.getArea()];
    }

    /// Get traversal cost of an area
    pub inline fn getAreaCost(self: *const QueryFilter, area: usize) f32 {
        return self.area_cost[area];
    }

    /// Set traversal cost of an area
    pub inline fn setAreaCost(self: *QueryFilter, area: usize, cost: f32) void {
        self.area_cost[area] = cost;
    }

    /// Get include flags
    pub inline fn getIncludeFlags(self: *const QueryFilter) u16 {
        return self.include_flags;
    }

    /// Set include flags
    pub inline fn setIncludeFlags(self: *QueryFilter, flags: u16) void {
        self.include_flags = flags;
    }

    /// Get exclude flags
    pub inline fn getExcludeFlags(self: *const QueryFilter) u16 {
        return self.exclude_flags;
    }

    /// Set exclude flags
    pub inline fn setExcludeFlags(self: *QueryFilter, flags: u16) void {
        self.exclude_flags = flags;
    }
};

/// Raycast hit information
pub const RaycastHit = struct {
    t: f32, // Hit parameter (FLT_MAX if no wall hit)
    hit_normal: [3]f32, // Normal of the nearest wall hit
    hit_edge_index: i32, // Index of the edge on the final polygon
    path: []PolyRef, // Reference ids of visited polygons
    path_count: usize, // Number of visited polygons
    max_path: usize, // Maximum number of polygons the path array can hold
    path_cost: f32, // Cost of the path until hit

    pub fn init(path_buffer: []PolyRef) RaycastHit {
        return .{
            .t = std.math.floatMax(f32),
            .hit_normal = .{ 0, 0, 0 },
            .hit_edge_index = -1,
            .path = path_buffer,
            .path_count = 0,
            .max_path = path_buffer.len,
            .path_cost = 0,
        };
    }
};

test "QueryFilter initialization" {
    const filter = QueryFilter.init();

    try std.testing.expectEqual(@as(u16, 0xffff), filter.include_flags);
    try std.testing.expectEqual(@as(u16, 0), filter.exclude_flags);
    try std.testing.expectEqual(@as(f32, 1.0), filter.area_cost[0]);
}

test "RaycastHit initialization" {
    var path_buffer: [128]PolyRef = undefined;
    const hit = RaycastHit.init(&path_buffer);

    try std.testing.expectEqual(std.math.floatMax(f32), hit.t);
    try std.testing.expectEqual(@as(usize, 0), hit.path_count);
    try std.testing.expectEqual(@as(usize, 128), hit.max_path);
}

/// Node flags for A* pathfinding
pub const NodeFlags = packed struct(u3) {
    open: bool = false,
    closed: bool = false,
    parent_detached: bool = false, // Parent is not adjacent, found using raycast
};

pub const NodeIndex = u16;
pub const NULL_IDX: NodeIndex = std.math.maxInt(NodeIndex);

const NODE_PARENT_BITS = 24;
const NODE_STATE_BITS = 2;
pub const MAX_STATES_PER_NODE = 1 << NODE_STATE_BITS;

/// A* pathfinding node
pub const Node = struct {
    pos: [3]f32, // Position of the node
    cost: f32, // Cost from previous node to current node
    total: f32, // Total cost from start to this node
    pidx: u24, // Index to parent node (24 bits)
    state: u2, // Extra state information (2 bits)
    flags: NodeFlags, // Node flags (3 bits)
    id: PolyRef, // Polygon ref the node corresponds to

    pub fn init() Node {
        return .{
            .pos = .{ 0, 0, 0 },
            .cost = 0,
            .total = 0,
            .pidx = 0,
            .state = 0,
            .flags = .{},
            .id = 0,
        };
    }
};

/// Node pool for A* pathfinding
pub const NodePool = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    first: []NodeIndex, // Hash table buckets
    next: []NodeIndex, // Next node in the same bucket
    max_nodes: usize,
    hash_size: usize,
    node_count: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_nodes: usize, hash_size: usize) !*Self {
        const pool = try allocator.create(Self);
        errdefer allocator.destroy(pool);

        const nodes = try allocator.alloc(Node, max_nodes);
        errdefer allocator.free(nodes);

        const first = try allocator.alloc(NodeIndex, hash_size);
        errdefer allocator.free(first);

        const next = try allocator.alloc(NodeIndex, max_nodes);
        errdefer allocator.free(next);

        pool.* = .{
            .allocator = allocator,
            .nodes = nodes,
            .first = first,
            .next = next,
            .max_nodes = max_nodes,
            .hash_size = hash_size,
            .node_count = 0,
        };

        pool.clear();
        return pool;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.next);
        self.allocator.free(self.first);
        self.allocator.free(self.nodes);
        self.allocator.destroy(self);
    }

    pub fn clear(self: *Self) void {
        @memset(self.first, NULL_IDX);
        self.node_count = 0;
    }

    /// Get or allocate a node for the given poly ref and state
    pub fn getNode(self: *Self, id: PolyRef, state: u8) ?*Node {
        const bucket = self.hashFunc(id);
        var i = self.first[bucket];

        // Search for existing node
        while (i != NULL_IDX) : (i = self.next[i]) {
            if (self.nodes[i].id == id and self.nodes[i].state == state) {
                return &self.nodes[i];
            }
        }

        // Allocate new node if not found
        if (self.node_count >= self.max_nodes) return null;

        i = @intCast(self.node_count);
        self.node_count += 1;

        // Initialize node
        self.nodes[i] = Node.init();
        self.nodes[i].id = id;
        self.nodes[i].state = @intCast(state);

        // Add to hash table
        self.next[i] = self.first[bucket];
        self.first[bucket] = i;

        return &self.nodes[i];
    }

    /// Find an existing node (don't allocate)
    pub fn findNode(self: *Self, id: PolyRef, state: u8) ?*Node {
        const bucket = self.hashFunc(id);
        var i = self.first[bucket];

        while (i != NULL_IDX) : (i = self.next[i]) {
            if (self.nodes[i].id == id and self.nodes[i].state == state) {
                return &self.nodes[i];
            }
        }

        return null;
    }

    /// Find all nodes with the given id
    pub fn findNodes(self: *Self, id: PolyRef, nodes: []*Node, max_nodes: usize) usize {
        var n: usize = 0;
        const bucket = self.hashFunc(id);
        var i = self.first[bucket];

        while (i != NULL_IDX and n < max_nodes) : (i = self.next[i]) {
            if (self.nodes[i].id == id) {
                nodes[n] = &self.nodes[i];
                n += 1;
            }
        }

        return n;
    }

    /// Get node index from node pointer
    pub fn getNodeIdx(self: *const Self, node: ?*const Node) u32 {
        if (node == null) return 0;
        const idx = (@intFromPtr(node.?) - @intFromPtr(self.nodes.ptr)) / @sizeOf(Node);
        return @intCast(idx + 1);
    }

    /// Get node at index
    pub fn getNodeAtIdx(self: *Self, idx: u32) ?*Node {
        if (idx == 0) return null;
        return &self.nodes[idx - 1];
    }

    /// Get node at index (const version)
    pub fn getNodeAtIdxConst(self: *const Self, idx: u32) ?*const Node {
        if (idx == 0) return null;
        return &self.nodes[idx - 1];
    }

    /// Get number of nodes in use
    pub fn getNodeCount(self: *const Self) usize {
        return self.node_count;
    }

    /// Get maximum number of nodes
    pub fn getMaxNodes(self: *const Self) usize {
        return self.max_nodes;
    }

    /// Get hash table size
    pub fn getHashSize(self: *const Self) usize {
        return self.hash_size;
    }

    /// Hash function for poly ref
    inline fn hashFunc(self: *const Self, id: PolyRef) usize {
        const hash = id *% 2654435761; // Knuth multiplicative hash
        return @intCast(hash & (self.hash_size - 1));
    }
};

/// Priority queue for A* open list (min-heap based on total cost)
pub const NodeQueue = struct {
    allocator: std.mem.Allocator,
    heap: []*Node,
    capacity: usize,
    size: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*Self {
        const queue = try allocator.create(Self);
        errdefer allocator.destroy(queue);

        const heap = try allocator.alloc(*Node, capacity);
        errdefer allocator.free(heap);

        queue.* = .{
            .allocator = allocator,
            .heap = heap,
            .capacity = capacity,
            .size = 0,
        };

        return queue;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.heap);
        self.allocator.destroy(self);
    }

    pub fn clear(self: *Self) void {
        self.size = 0;
    }

    pub fn empty(self: *const Self) bool {
        return self.size == 0;
    }

    pub fn top(self: *const Self) ?*Node {
        if (self.size == 0) return null;
        return self.heap[0];
    }

    pub fn pop(self: *Self) ?*Node {
        if (self.size == 0) return null;

        const result = self.heap[0];
        self.size -= 1;
        if (self.size > 0) {
            self.trickleDown(0, self.heap[self.size]);
        }
        return result;
    }

    pub fn push(self: *Self, node: *Node) void {
        self.size += 1;
        self.bubbleUp(self.size - 1, node);
    }

    pub fn modify(self: *Self, node: *Node) void {
        for (0..self.size) |i| {
            if (self.heap[i] == node) {
                self.bubbleUp(i, node);
                return;
            }
        }
    }

    pub fn getCapacity(self: *const Self) usize {
        return self.capacity;
    }

    fn bubbleUp(self: *Self, i_input: usize, node: *Node) void {
        var i = i_input;

        // While not at root and node is better than parent
        while (i > 0) {
            const parent_i = (i - 1) / 2;
            const parent = self.heap[parent_i];
            if (node.total >= parent.total) break;

            self.heap[i] = parent;
            i = parent_i;
        }

        self.heap[i] = node;
    }

    fn trickleDown(self: *Self, i_input: usize, node: *Node) void {
        var i = i_input;

        while (true) {
            const child1 = 2 * i + 1;
            if (child1 >= self.size) break;

            const child2 = child1 + 1;

            // Find the child with minimum total cost
            var min_child = child1;
            if (child2 < self.size) {
                if (self.heap[child2].total < self.heap[child1].total) {
                    min_child = child2;
                }
            }

            // If node is better than best child, we're done
            if (node.total <= self.heap[min_child].total) break;

            self.heap[i] = self.heap[min_child];
            i = min_child;
        }

        self.heap[i] = node;
    }
};

/// Query data for sliced pathfinding
const QueryData = struct {
    status: Status,
    last_best_node: ?*Node,
    last_best_node_cost: f32,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: [3]f32,
    end_pos: [3]f32,
    filter: ?*const QueryFilter,
    options: u32,
    raycast_limit_sqr: f32,

    fn init() QueryData {
        return .{
            .status = .{},
            .last_best_node = null,
            .last_best_node_cost = std.math.floatMax(f32),
            .start_ref = 0,
            .end_ref = 0,
            .start_pos = .{ 0, 0, 0 },
            .end_pos = .{ 0, 0, 0 },
            .filter = null,
            .options = 0,
            .raycast_limit_sqr = std.math.floatMax(f32),
        };
    }
};

/// Navigation mesh query object for pathfinding and spatial queries
pub const NavMeshQuery = struct {
    allocator: std.mem.Allocator,
    nav: ?*const NavMesh,
    node_pool: ?*NodePool,
    tiny_node_pool: ?*NodePool,
    open_list: ?*NodeQueue,
    query: QueryData,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const query = try allocator.create(Self);
        query.* = .{
            .allocator = allocator,
            .nav = null,
            .node_pool = null,
            .tiny_node_pool = null,
            .open_list = null,
            .query = QueryData.init(),
        };
        return query;
    }

    pub fn deinit(self: *Self) void {
        if (self.open_list) |ol| ol.deinit();
        if (self.tiny_node_pool) |tnp| tnp.deinit();
        if (self.node_pool) |np| np.deinit();
        self.allocator.destroy(self);
    }

    /// Initialize the query object with a navmesh and maximum node count
    pub fn initQuery(self: *Self, nav: *const NavMesh, max_nodes: usize) !void {
        // Validate max_nodes
        if (max_nodes > NULL_IDX or max_nodes > ((1 << NODE_PARENT_BITS) - 1)) {
            return error.InvalidParam;
        }

        self.nav = nav;

        // Create or resize main node pool
        const hash_size = math.nextPow2(@as(u32, @intCast(max_nodes / 4)));
        if (self.node_pool) |np| {
            if (np.getMaxNodes() < max_nodes) {
                np.deinit();
                self.node_pool = try NodePool.init(self.allocator, max_nodes, hash_size);
            } else {
                np.clear();
            }
        } else {
            self.node_pool = try NodePool.init(self.allocator, max_nodes, hash_size);
        }

        // Create or clear tiny node pool (64 nodes, hash size 32)
        if (self.tiny_node_pool) |tnp| {
            tnp.clear();
        } else {
            self.tiny_node_pool = try NodePool.init(self.allocator, 64, 32);
        }

        // Create or resize open list
        if (self.open_list) |ol| {
            if (ol.getCapacity() < max_nodes) {
                ol.deinit();
                self.open_list = try NodeQueue.init(self.allocator, max_nodes);
            } else {
                ol.clear();
            }
        } else {
            self.open_list = try NodeQueue.init(self.allocator, max_nodes);
        }
    }

    /// Get the attached navmesh
    pub fn getAttachedNavMesh(self: *const Self) ?*const NavMesh {
        return self.nav;
    }

    /// Get the node pool
    pub fn getNodePool(self: *const Self) ?*NodePool {
        return self.node_pool;
    }

    /// Check if a polygon reference is valid
    pub fn isValidPolyRef(self: *const Self, ref: PolyRef, filter: *const QueryFilter) bool {
        const nav = self.nav orelse return false;

        const result = nav.getTileAndPolyByRef(ref) catch return false;
        const tile = result.tile;
        const poly = result.poly;

        // Check filter
        return filter.passFilter(ref, tile, poly);
    }

    /// Check if a polygon is in the closed list
    pub fn isInClosedList(self: *const Self, ref: PolyRef) bool {
        const node_pool = self.node_pool orelse return false;

        var nodes: [MAX_STATES_PER_NODE]*Node = undefined;
        const n = node_pool.findNodes(ref, &nodes, MAX_STATES_PER_NODE);

        for (0..n) |i| {
            if (nodes[i].flags.closed) return true;
        }

        return false;
    }

    /// Query polygons within a bounding box
    pub fn queryPolygons(
        self: *const Self,
        center: *const [3]f32,
        half_extents: *const [3]f32,
        filter: *const QueryFilter,
        polys: []PolyRef,
        poly_count: *usize,
    ) !void {
        const nav = self.nav orelse return error.NoNavMesh;

        // Calculate bounding box
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        for (0..3) |i| {
            bmin[i] = center[i] - half_extents[i];
            bmax[i] = center[i] + half_extents[i];
        }

        // Find tiles the query touches
        const min_loc = nav.calcTileLoc(Vec3.fromArray(&bmin));
        const max_loc = nav.calcTileLoc(Vec3.fromArray(&bmax));

        const MAX_NEIS = 32;
        var n: usize = 0;

        var y = min_loc.y;
        while (y <= max_loc.y) : (y += 1) {
            var x = min_loc.x;
            while (x <= max_loc.x) : (x += 1) {
                // Get tiles at this location
                var temp_tiles: [MAX_NEIS]*MeshTile = undefined;
                const nneis = nav.getTilesAt(x, y, &temp_tiles, MAX_NEIS);

                for (0..nneis) |j| {
                    // Query polygons in this tile
                    const tile = @as(*const MeshTile, @ptrCast(temp_tiles[j]));
                    const base = nav.getPolyRefBase(tile);

                    for (0..@as(usize, @intCast(tile.header.?.poly_count))) |i| {
                        const poly = &tile.polys[i];

                        // Check if poly passes filter
                        const ref = base | @as(PolyRef, @intCast(i));
                        if (!filter.passFilter(ref, tile, poly)) continue;

                        // Calculate poly bounding box
                        var poly_bmin = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
                        var poly_bmax = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };

                        for (0..poly.vert_count) |v| {
                            const idx = poly.verts[v] * 3;
                            poly_bmin[0] = @min(poly_bmin[0], tile.verts[idx + 0]);
                            poly_bmin[1] = @min(poly_bmin[1], tile.verts[idx + 1]);
                            poly_bmin[2] = @min(poly_bmin[2], tile.verts[idx + 2]);
                            poly_bmax[0] = @max(poly_bmax[0], tile.verts[idx + 0]);
                            poly_bmax[1] = @max(poly_bmax[1], tile.verts[idx + 1]);
                            poly_bmax[2] = @max(poly_bmax[2], tile.verts[idx + 2]);
                        }

                        // Check if poly bbox overlaps query bbox
                        var overlap = true;
                        for (0..3) |axis| {
                            if (poly_bmin[axis] > bmax[axis] or poly_bmax[axis] < bmin[axis]) {
                                overlap = false;
                                break;
                            }
                        }

                        if (overlap) {
                            if (n < polys.len) {
                                polys[n] = ref;
                                n += 1;
                            }
                        }
                    }
                }
            }
        }

        poly_count.* = n;
    }

    /// A* pathfinding: find polygon path from start to end
    pub fn findPath(
        self: *Self,
        start_ref: PolyRef,
        end_ref: PolyRef,
        start_pos: *const [3]f32,
        end_pos: *const [3]f32,
        filter: *const QueryFilter,
        path: []PolyRef,
        path_count: *usize,
    ) !void {
        const nav = self.nav orelse return error.NoNavMesh;
        const node_pool = self.node_pool orelse return error.NoNodePool;
        const open_list = self.open_list orelse return error.NoOpenList;

        path_count.* = 0;

        // Validate input
        if (!self.isValidPolyRef(start_ref, filter) or !self.isValidPolyRef(end_ref, filter)) {
            return error.InvalidParam;
        }

        // Special case: start == end
        if (start_ref == end_ref) {
            path[0] = start_ref;
            path_count.* = 1;
            return;
        }

        // Clear pools
        node_pool.clear();
        open_list.clear();

        const H_SCALE = 0.999; // Heuristic scale

        // Initialize start node
        var start_node = node_pool.getNode(start_ref, 0) orelse return error.OutOfNodes;
        math.vcopy(&start_node.pos, start_pos);
        start_node.pidx = 0;
        start_node.cost = 0;

        // Calculate heuristic distance
        const dx = end_pos[0] - start_pos[0];
        const dy = end_pos[1] - start_pos[1];
        const dz = end_pos[2] - start_pos[2];
        start_node.total = @sqrt(dx * dx + dy * dy + dz * dz) * H_SCALE;
        start_node.id = start_ref;
        start_node.flags.open = true;
        open_list.push(start_node);

        var last_best_node = start_node;
        var last_best_node_cost = start_node.total;

        // A* main loop
        while (!open_list.empty()) {
            // Get node with lowest f-cost
            var best_node = open_list.pop() orelse break;
            best_node.flags.open = false;
            best_node.flags.closed = true;

            // Reached the goal
            if (best_node.id == end_ref) {
                last_best_node = best_node;
                break;
            }

            // Get current poly and tile
            const best_ref = best_node.id;
            var best_tile: ?*const MeshTile = null;
            var best_poly: ?*const Poly = null;
            nav.getTileAndPolyByRefUnsafe(best_ref, &best_tile, &best_poly);

            // Get parent poly
            var parent_ref: PolyRef = 0;
            var parent_tile: ?*const MeshTile = null;
            var parent_poly: ?*const Poly = null;
            if (best_node.pidx != 0) {
                const parent_node = node_pool.getNodeAtIdx(best_node.pidx);
                if (parent_node) |pn| {
                    parent_ref = pn.id;
                    nav.getTileAndPolyByRefUnsafe(parent_ref, &parent_tile, &parent_poly);
                }
            }

            // Expand neighbors
            var i = best_poly.?.first_link;
            while (i != common.NULL_LINK) : (i = best_tile.?.links[i].next) {
                const neighbour_ref = best_tile.?.links[i].ref;

                // Skip invalid and parent
                if (neighbour_ref == 0 or neighbour_ref == parent_ref) continue;

                // Get neighbour poly and tile
                var neighbour_tile: ?*const MeshTile = null;
                var neighbour_poly: ?*const Poly = null;
                nav.getTileAndPolyByRefUnsafe(neighbour_ref, &neighbour_tile, &neighbour_poly);

                // Check filter
                if (!filter.passFilter(neighbour_ref, neighbour_tile.?, neighbour_poly.?)) continue;

                // Handle tile boundaries
                var cross_side: u8 = 0;
                if (best_tile.?.links[i].side != 0xff) {
                    cross_side = best_tile.?.links[i].side >> 1;
                }

                // Get or create neighbour node
                var neighbour_node = node_pool.getNode(neighbour_ref, cross_side) orelse {
                    continue; // Out of nodes
                };

                // Calculate node position if visited first time
                if (neighbour_node.flags.open == false and neighbour_node.flags.closed == false) {
                    nav.getEdgeMidPoint(
                        best_ref,
                        best_poly.?,
                        best_tile.?,
                        neighbour_ref,
                        neighbour_poly.?,
                        neighbour_tile.?,
                        &neighbour_node.pos,
                    ) catch continue;
                }

                // Calculate cost and heuristic
                var cost: f32 = 0;
                var heuristic: f32 = 0;

                if (neighbour_ref == end_ref) {
                    // Special case for end node
                    const cur_cost = filter.getCost(
                        &best_node.pos,
                        &neighbour_node.pos,
                        parent_ref,
                        parent_tile,
                        parent_poly,
                        best_ref,
                        best_tile.?,
                        best_poly.?,
                        neighbour_ref,
                        neighbour_tile,
                        neighbour_poly,
                    );

                    const end_cost = filter.getCost(
                        &neighbour_node.pos,
                        end_pos,
                        best_ref,
                        best_tile.?,
                        best_poly.?,
                        neighbour_ref,
                        neighbour_tile.?,
                        neighbour_poly.?,
                        0,
                        null,
                        null,
                    );

                    cost = best_node.cost + cur_cost + end_cost;
                    heuristic = 0;
                } else {
                    // Regular node
                    const cur_cost = filter.getCost(
                        &best_node.pos,
                        &neighbour_node.pos,
                        parent_ref,
                        parent_tile,
                        parent_poly,
                        best_ref,
                        best_tile.?,
                        best_poly.?,
                        neighbour_ref,
                        neighbour_tile.?,
                        neighbour_poly.?,
                    );

                    cost = best_node.cost + cur_cost;

                    const ndx = neighbour_node.pos[0] - end_pos[0];
                    const ndy = neighbour_node.pos[1] - end_pos[1];
                    const ndz = neighbour_node.pos[2] - end_pos[2];
                    heuristic = @sqrt(ndx * ndx + ndy * ndy + ndz * ndz) * H_SCALE;
                }

                const total = cost + heuristic;

                // Skip if worse than existing
                if (neighbour_node.flags.open and total >= neighbour_node.total) continue;
                if (neighbour_node.flags.closed and total >= neighbour_node.total) continue;

                // Update node
                neighbour_node.pidx = @intCast(node_pool.getNodeIdx(best_node));
                neighbour_node.id = neighbour_ref;
                neighbour_node.flags.closed = false;
                neighbour_node.cost = cost;
                neighbour_node.total = total;

                if (neighbour_node.flags.open) {
                    // Already in open list, update position
                    open_list.modify(neighbour_node);
                } else {
                    // Add to open list
                    neighbour_node.flags.open = true;
                    open_list.push(neighbour_node);
                }

                // Update nearest node to target
                if (heuristic < last_best_node_cost) {
                    last_best_node_cost = heuristic;
                    last_best_node = neighbour_node;
                }
            }
        }

        // Extract path
        try self.getPathToNode(last_best_node, path, path_count);
    }

    /// Extract path from A* node tree
    fn getPathToNode(
        self: *const Self,
        end_node: *Node,
        path: []PolyRef,
        path_count: *usize,
    ) !void {
        const node_pool = self.node_pool orelse return error.NoNodePool;

        // Find the length of the entire path
        var cur_node: ?*Node = end_node;
        var length: usize = 0;
        while (cur_node != null) {
            length += 1;
            const pidx = cur_node.?.pidx;
            if (pidx == 0) break;
            cur_node = node_pool.getNodeAtIdx(pidx);
        }

        // If the path cannot be fully stored, advance to last node we can store
        cur_node = end_node;
        var write_count = length;
        while (write_count > path.len) : (write_count -= 1) {
            const pidx = cur_node.?.pidx;
            if (pidx == 0) break;
            cur_node = node_pool.getNodeAtIdx(pidx);
        }

        // Write path in reverse order
        var i: usize = write_count;
        while (i > 0) {
            i -= 1;
            if (cur_node) |node| {
                path[i] = node.id;
                const pidx = node.pidx;
                if (pidx == 0) {
                    cur_node = null;
                } else {
                    cur_node = node_pool.getNodeAtIdx(pidx);
                }
            }
        }

        path_count.* = @min(length, path.len);
    }

    /// Find the nearest polygon to a point
    pub fn findNearestPoly(
        self: *const Self,
        center: *const [3]f32,
        half_extents: *const [3]f32,
        filter: *const QueryFilter,
        nearest_ref: *PolyRef,
        nearest_pt: ?*[3]f32,
    ) !void {
        const nav = self.nav orelse return error.NoNavMesh;

        // Query nearby polygons
        var polys: [128]PolyRef = undefined;
        var poly_count: usize = 0;
        try self.queryPolygons(center, half_extents, filter, &polys, &poly_count);

        // Find nearest among the candidates
        var nearest: PolyRef = 0;
        var nearest_dist_sqr: f32 = std.math.floatMax(f32);
        var temp_nearest_pt: [3]f32 = undefined;

        for (0..poly_count) |i| {
            const ref = polys[i];
            var closest_pt: [3]f32 = undefined;
            var pos_over_poly: bool = false;

            nav.closestPointOnPoly(ref, center, &closest_pt, &pos_over_poly) catch continue;

            // Calculate distance
            var diff: [3]f32 = undefined;
            for (0..3) |j| {
                diff[j] = center[j] - closest_pt[j];
            }

            var d: f32 = undefined;
            if (pos_over_poly) {
                // Point is over polygon - use vertical distance with climb height adjustment
                const result = nav.getTileAndPolyByRef(ref) catch continue;

                const climb = result.tile.header.?.walkable_climb;
                d = @abs(diff[1]) - climb;
                d = if (d > 0) d * d else 0;
            } else {
                // Use Euclidean distance
                d = diff[0] * diff[0] + diff[1] * diff[1] + diff[2] * diff[2];
            }

            if (d < nearest_dist_sqr) {
                temp_nearest_pt = closest_pt;
                nearest_dist_sqr = d;
                nearest = ref;
            }
        }

        nearest_ref.* = nearest;
        if (nearest_pt) |npt| {
            if (nearest != 0) {
                npt.* = temp_nearest_pt;
            }
        }
    }

    /// Get portal points between two polygons with poly type information
    pub fn getPortalPoints(
        self: *const Self,
        from: PolyRef,
        to: PolyRef,
        left: *[3]f32,
        right: *[3]f32,
        from_type: *u8,
        to_type: *u8,
    ) !void {
        const nav = self.nav orelse return error.NoNavMesh;

        const from_result = try nav.getTileAndPolyByRef(from);
        const from_tile = from_result.tile;
        const from_poly = from_result.poly;
        from_type.* = @intFromEnum(from_poly.getType());

        const to_result = try nav.getTileAndPolyByRef(to);
        const to_tile = to_result.tile;
        const to_poly = to_result.poly;
        to_type.* = @intFromEnum(to_poly.getType());

        try nav.getPortalPoints(from, from_poly, from_tile, to, to_poly, to_tile, left, right);
    }

    /// Find the straight path from start to end position using string pulling
    /// This performs 'string pulling' to create a sequence of waypoints from a polygon path
    pub fn findStraightPath(
        self: *const Self,
        start_pos: *const [3]f32,
        end_pos: *const [3]f32,
        path: []const PolyRef,
        straight_path: []f32,
        straight_path_flags: ?[]u8,
        straight_path_refs: ?[]PolyRef,
        straight_path_count: *usize,
        options: u32,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;

        straight_path_count.* = 0;

        if (!math.Vec3.fromArray(start_pos).isFinite() or
            !math.Vec3.fromArray(end_pos).isFinite() or
            path.len == 0 or
            path[0] == 0 or
            straight_path.len < 3)
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        const max_straight_path = straight_path.len / 3;

        // Clamp start position to first polygon
        var closest_start_pos: [3]f32 = undefined;
        try nav.closestPointOnPolyBoundary(path[0], start_pos, &closest_start_pos);

        // Clamp end position to last polygon
        var closest_end_pos: [3]f32 = undefined;
        try nav.closestPointOnPolyBoundary(path[path.len - 1], end_pos, &closest_end_pos);

        // Add start point
        var stat = appendVertex(&closest_start_pos, common.STRAIGHTPATH_START, path[0], straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);
        if (!stat.isInProgress()) {
            return stat;
        }

        if (path.len > 1) {
            var portal_apex: [3]f32 = undefined;
            var portal_left: [3]f32 = undefined;
            var portal_right: [3]f32 = undefined;

            math.vcopy(&portal_apex, &closest_start_pos);
            math.vcopy(&portal_left, &portal_apex);
            math.vcopy(&portal_right, &portal_apex);

            var apex_index: usize = 0;
            var left_index: usize = 0;
            var right_index: usize = 0;

            var left_poly_type: u8 = 0;
            var right_poly_type: u8 = 0;

            var left_poly_ref: PolyRef = path[0];
            var right_poly_ref: PolyRef = path[0];

            var i: usize = 0;
            while (i < path.len) : (i += 1) {
                var left: [3]f32 = undefined;
                var right: [3]f32 = undefined;
                var to_type: u8 = 0;

                if (i + 1 < path.len) {
                    var from_type: u8 = undefined;
                    // Next portal
                    self.getPortalPoints(path[i], path[i + 1], &left, &right, &from_type, &to_type) catch {
                        // Failed to get portal - clamp end and return partial path
                        nav.closestPointOnPolyBoundary(path[i], end_pos, &closest_end_pos) catch {
                            return common.Status{ .failure = true, .invalid_param = true };
                        };

                        // Append portals along current segment
                        if ((options & (common.STRAIGHTPATH_AREA_CROSSINGS | common.STRAIGHTPATH_ALL_CROSSINGS)) != 0) {
                            _ = try self.appendPortals(apex_index, i, &closest_end_pos, path, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path, options);
                        }

                        _ = appendVertex(&closest_end_pos, 0, path[i], straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);

                        const result = if (straight_path_count.* >= max_straight_path)
                            common.Status{ .success = true, .partial_result = true, .buffer_too_small = true }
                        else
                            common.Status{ .success = true, .partial_result = true };
                        return result;
                    };

                    // Skip if very close to the portal
                    if (i == 0) {
                        var t: f32 = undefined;
                        if (math.distancePtSegSqr2D(&portal_apex, &left, &right, &t) < math.sqr(f32, 0.001)) {
                            continue;
                        }
                    }
                } else {
                    // End of path
                    math.vcopy(&left, &closest_end_pos);
                    math.vcopy(&right, &closest_end_pos);
                    to_type = @intFromEnum(common.PolyType.ground);
                }

                // Right vertex
                if (math.triArea2D(math.Vec3.fromArray(&portal_apex), math.Vec3.fromArray(&portal_right), math.Vec3.fromArray(&right)) <= 0.0) {
                    if (math.Vec3.fromArray(&portal_apex).equal(math.Vec3.fromArray(&portal_right)) or
                        math.triArea2D(math.Vec3.fromArray(&portal_apex), math.Vec3.fromArray(&portal_left), math.Vec3.fromArray(&right)) > 0.0)
                    {
                        math.vcopy(&portal_right, &right);
                        right_poly_ref = if (i + 1 < path.len) path[i + 1] else 0;
                        right_poly_type = to_type;
                        right_index = i;
                    } else {
                        // Append portals along current segment
                        if ((options & (common.STRAIGHTPATH_AREA_CROSSINGS | common.STRAIGHTPATH_ALL_CROSSINGS)) != 0) {
                            stat = try self.appendPortals(apex_index, left_index, &portal_left, path, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path, options);
                            if (!stat.isInProgress()) {
                                return stat;
                            }
                        }

                        math.vcopy(&portal_apex, &portal_left);
                        apex_index = left_index;

                        var flags: u8 = 0;
                        if (left_poly_ref == 0) {
                            flags = common.STRAIGHTPATH_END;
                        } else if (left_poly_type == @intFromEnum(common.PolyType.offmesh_connection)) {
                            flags = common.STRAIGHTPATH_OFFMESH_CONNECTION;
                        }
                        const ref = left_poly_ref;

                        stat = appendVertex(&portal_apex, flags, ref, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);
                        if (!stat.isInProgress()) {
                            return stat;
                        }

                        math.vcopy(&portal_left, &portal_apex);
                        math.vcopy(&portal_right, &portal_apex);
                        left_index = apex_index;
                        right_index = apex_index;

                        // Restart
                        i = apex_index;
                        continue;
                    }
                }

                // Left vertex
                if (math.triArea2D(math.Vec3.fromArray(&portal_apex), math.Vec3.fromArray(&portal_left), math.Vec3.fromArray(&left)) >= 0.0) {
                    if (math.Vec3.fromArray(&portal_apex).equal(math.Vec3.fromArray(&portal_left)) or
                        math.triArea2D(math.Vec3.fromArray(&portal_apex), math.Vec3.fromArray(&portal_right), math.Vec3.fromArray(&left)) < 0.0)
                    {
                        math.vcopy(&portal_left, &left);
                        left_poly_ref = if (i + 1 < path.len) path[i + 1] else 0;
                        left_poly_type = to_type;
                        left_index = i;
                    } else {
                        // Append portals along current segment
                        if ((options & (common.STRAIGHTPATH_AREA_CROSSINGS | common.STRAIGHTPATH_ALL_CROSSINGS)) != 0) {
                            stat = try self.appendPortals(apex_index, right_index, &portal_right, path, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path, options);
                            if (!stat.isInProgress()) {
                                return stat;
                            }
                        }

                        math.vcopy(&portal_apex, &portal_right);
                        apex_index = right_index;

                        var flags: u8 = 0;
                        if (right_poly_ref == 0) {
                            flags = common.STRAIGHTPATH_END;
                        } else if (right_poly_type == @intFromEnum(common.PolyType.offmesh_connection)) {
                            flags = common.STRAIGHTPATH_OFFMESH_CONNECTION;
                        }
                        const ref = right_poly_ref;

                        stat = appendVertex(&portal_apex, flags, ref, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);
                        if (!stat.isInProgress()) {
                            return stat;
                        }

                        math.vcopy(&portal_left, &portal_apex);
                        math.vcopy(&portal_right, &portal_apex);
                        left_index = apex_index;
                        right_index = apex_index;

                        // Restart
                        i = apex_index;
                        continue;
                    }
                }
            }

            // Append portals along final segment
            if ((options & (common.STRAIGHTPATH_AREA_CROSSINGS | common.STRAIGHTPATH_ALL_CROSSINGS)) != 0) {
                stat = try self.appendPortals(apex_index, path.len - 1, &closest_end_pos, path, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path, options);
                if (!stat.isInProgress()) {
                    return stat;
                }
            }
        }

        // Always append end point
        _ = appendVertex(&closest_end_pos, common.STRAIGHTPATH_END, 0, straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);

        return if (straight_path_count.* >= max_straight_path)
            common.Status{ .success = true, .buffer_too_small = true }
        else
            common.Status.ok();
    }

    /// Move along the surface from start to end position
    /// This method is optimized for small delta movement and a small number of polygons
    pub fn moveAlongSurface(
        self: *const Self,
        start_ref: PolyRef,
        start_pos: *const [3]f32,
        end_pos: *const [3]f32,
        filter: *const QueryFilter,
        result_pos: *[3]f32,
        visited: []PolyRef,
        visited_count: *usize,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const tiny_pool = self.tiny_node_pool orelse return error.NoNodePool;

        visited_count.* = 0;

        if (!self.isValidPolyRef(start_ref, filter) or
            !math.Vec3.fromArray(start_pos).isFinite() or
            !math.Vec3.fromArray(end_pos).isFinite() or
            visited.len == 0)
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        var status = common.Status.ok();

        const MAX_STACK = 48;
        var stack: [MAX_STACK]?*Node = undefined;
        var nstack: usize = 0;

        tiny_pool.clear();

        // Initialize with start polygon
        var start_node = tiny_pool.getNode(start_ref, 0) orelse return error.OutOfNodes;
        start_node.pidx = 0;
        start_node.cost = 0;
        start_node.total = 0;
        start_node.id = start_ref;
        start_node.flags.closed = true;
        stack[nstack] = start_node;
        nstack += 1;

        var best_pos: [3]f32 = undefined;
        var best_dist: f32 = std.math.floatMax(f32);
        var best_node: ?*Node = null;
        math.vcopy(&best_pos, start_pos);

        // Search constraints
        var search_pos: [3]f32 = undefined;
        math.vlerp(&search_pos, start_pos, end_pos, 0.5);
        const half_dist = math.Vec3.fromArray(start_pos).dist(math.Vec3.fromArray(end_pos)) / 2.0 + 0.001;
        const search_rad_sqr = half_dist * half_dist;

        var verts: [common.VERTS_PER_POLYGON * 3]f32 = undefined;

        while (nstack > 0) {
            // Pop front (FIFO)
            const cur_node = stack[0].?;
            var i: usize = 0;
            while (i < nstack - 1) : (i += 1) {
                stack[i] = stack[i + 1];
            }
            nstack -= 1;

            // Get poly and tile
            const cur_ref = cur_node.id;
            var cur_tile: ?*const MeshTile = null;
            var cur_poly: ?*const Poly = null;
            nav.getTileAndPolyByRefUnsafe(cur_ref, &cur_tile, &cur_poly);

            // Collect vertices
            const nverts = cur_poly.?.vert_count;
            for (0..nverts) |vi| {
                const v_idx = cur_poly.?.verts[vi] * 3;
                math.vcopy(verts[vi * 3 .. vi * 3 + 3][0..3], cur_tile.?.verts[v_idx .. v_idx + 3][0..3]);
            }

            // If target is inside the poly, stop search
            const vert_slice = verts[0 .. nverts * 3];
            var vert_vec3s: [common.VERTS_PER_POLYGON]math.Vec3 = undefined;
            for (0..nverts) |vi| {
                vert_vec3s[vi] = math.Vec3.fromArray(vert_slice[vi * 3 .. vi * 3 + 3][0..3]);
            }
            if (math.pointInPolygon(math.Vec3.fromArray(end_pos), vert_vec3s[0..nverts])) {
                best_node = cur_node;
                math.vcopy(&best_pos, end_pos);
                break;
            }

            // Find wall edges and find nearest point inside the walls
            var j: usize = nverts - 1;
            i = 0;
            while (i < nverts) : ({
                j = i;
                i += 1;
            }) {
                // Find links to neighbours
                const MAX_NEIS = 8;
                var nneis: usize = 0;
                var neis: [MAX_NEIS]PolyRef = undefined;

                if ((cur_poly.?.neis[j] & common.EXT_LINK) != 0) {
                    // Tile border
                    var k = cur_poly.?.first_link;
                    while (k != common.NULL_LINK) : (k = cur_tile.?.links[k].next) {
                        const link = &cur_tile.?.links[k];
                        if (link.edge == j) {
                            if (link.ref != 0) {
                                var nei_tile: ?*const MeshTile = null;
                                var nei_poly: ?*const Poly = null;
                                nav.getTileAndPolyByRefUnsafe(link.ref, &nei_tile, &nei_poly);
                                if (filter.passFilter(link.ref, nei_tile.?, nei_poly.?)) {
                                    if (nneis < MAX_NEIS) {
                                        neis[nneis] = link.ref;
                                        nneis += 1;
                                    }
                                }
                            }
                        }
                    }
                } else if (cur_poly.?.neis[j] != 0) {
                    const idx = cur_poly.?.neis[j] - 1;
                    const ref = nav.getPolyRefBase(cur_tile.?) | idx;
                    if (filter.passFilter(ref, cur_tile.?, &cur_tile.?.polys[idx])) {
                        neis[nneis] = ref;
                        nneis += 1;
                    }
                }

                if (nneis == 0) {
                    // Wall edge, calc distance
                    const vj = verts[j * 3 .. j * 3 + 3][0..3];
                    const vi = verts[i * 3 .. i * 3 + 3][0..3];
                    var tseg: f32 = undefined;
                    const dist_sqr = math.distancePtSegSqr2D(end_pos, vj, vi, &tseg);
                    if (dist_sqr < best_dist) {
                        math.vlerp(&best_pos, vj, vi, tseg);
                        best_dist = dist_sqr;
                        best_node = cur_node;
                    }
                } else {
                    for (0..nneis) |ki| {
                        // Skip if no node can be allocated
                        var neighbour_node = tiny_pool.getNode(neis[ki], 0) orelse continue;
                        // Skip if already visited
                        if (neighbour_node.flags.closed) continue;

                        // Skip the link if too far from search constraint
                        const vj = verts[j * 3 .. j * 3 + 3][0..3];
                        const vi = verts[i * 3 .. i * 3 + 3][0..3];
                        var tseg: f32 = undefined;
                        const dist_sqr = math.distancePtSegSqr2D(&search_pos, vj, vi, &tseg);
                        if (dist_sqr > search_rad_sqr) continue;

                        // Mark as visited and push to queue
                        if (nstack < MAX_STACK) {
                            neighbour_node.pidx = @intCast(tiny_pool.getNodeIdx(cur_node));
                            neighbour_node.flags.closed = true;
                            stack[nstack] = neighbour_node;
                            nstack += 1;
                        }
                    }
                }
            }
        }

        // Build result path
        var n: usize = 0;
        if (best_node) |node| {
            // Reverse the path
            var prev: ?*Node = null;
            var cur: ?*Node = node;
            while (cur) |current| {
                const next = if (current.pidx != 0) tiny_pool.getNodeAtIdx(current.pidx) else null;
                current.pidx = @intCast(tiny_pool.getNodeIdx(prev));
                prev = current;
                cur = next;
            }

            // Store result
            cur = prev;
            while (cur) |current| {
                if (n < visited.len) {
                    visited[n] = current.id;
                    n += 1;
                } else {
                    status.buffer_too_small = true;
                    break;
                }
                cur = if (current.pidx != 0) tiny_pool.getNodeAtIdx(current.pidx) else null;
            }
        }

        math.vcopy(result_pos, &best_pos);
        visited_count.* = n;

        return status;
    }

    /// Cast a ray from start to end position
    /// This method is optimized for short distance line-of-sight checks
    pub fn raycast(
        self: *const Self,
        start_ref: PolyRef,
        start_pos: *const [3]f32,
        end_pos: *const [3]f32,
        filter: *const QueryFilter,
        options: u32,
        hit: *RaycastHit,
        prev_ref: PolyRef,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;

        hit.t = 0;
        hit.path_count = 0;
        hit.path_cost = 0;

        // Validate input
        if (!self.isValidPolyRef(start_ref, filter) or
            !math.Vec3.fromArray(start_pos).isFinite() or
            !math.Vec3.fromArray(end_pos).isFinite() or
            (prev_ref != 0 and !self.isValidPolyRef(prev_ref, filter)))
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        var dir: [3]f32 = undefined;
        var cur_pos: [3]f32 = undefined;
        var last_pos: [3]f32 = undefined;
        var verts: [common.VERTS_PER_POLYGON * 3 + 3]f32 = undefined;
        var n: usize = 0;

        math.vcopy(&cur_pos, start_pos);
        dir[0] = end_pos[0] - start_pos[0];
        dir[1] = end_pos[1] - start_pos[1];
        dir[2] = end_pos[2] - start_pos[2];
        hit.hit_normal = .{ 0, 0, 0 };

        var status = common.Status.ok();

        var prev_tile: ?*const MeshTile = null;
        var prev_poly: ?*const Poly = null;
        var tile: ?*const MeshTile = null;
        var poly: ?*const Poly = null;
        var next_tile: ?*const MeshTile = null;
        var next_poly: ?*const Poly = null;

        var prev_ref_mut = prev_ref;
        var cur_ref = start_ref;
        nav.getTileAndPolyByRefUnsafe(cur_ref, &tile, &poly);
        next_tile = tile;
        next_poly = poly;
        prev_tile = tile;
        prev_poly = poly;

        if (prev_ref != 0) {
            nav.getTileAndPolyByRefUnsafe(prev_ref, &prev_tile, &prev_poly);
        }

        while (cur_ref != 0) {
            // Cast ray against current polygon
            // Collect vertices
            var nv: usize = 0;
            for (0..poly.?.vert_count) |i| {
                const v_idx = poly.?.verts[i] * 3;
                math.vcopy(verts[nv * 3 .. nv * 3 + 3][0..3], tile.?.verts[v_idx .. v_idx + 3][0..3]);
                nv += 1;
            }

            var tmin: f32 = undefined;
            var tmax: f32 = undefined;
            var seg_min: i32 = undefined;
            var seg_max: i32 = undefined;

            if (!math.intersectSegmentPoly2D(start_pos, end_pos, verts[0 .. nv * 3], nv, &tmin, &tmax, &seg_min, &seg_max)) {
                // Could not hit the polygon, keep the old t and report hit
                hit.path_count = n;
                return status;
            }

            hit.hit_edge_index = @intCast(seg_max);

            // Keep track of furthest t so far
            if (tmax > hit.t) {
                hit.t = tmax;
            }

            // Store visited polygons
            if (n < hit.path.len) {
                hit.path[n] = cur_ref;
                n += 1;
            } else {
                status.buffer_too_small = true;
            }

            // Ray end is completely inside the polygon
            if (seg_max == -1) {
                hit.t = std.math.floatMax(f32);
                hit.path_count = n;

                // Add the cost
                if ((options & common.RAYCAST_USE_COSTS) != 0) {
                    hit.path_cost += filter.getCost(&cur_pos, end_pos, prev_ref_mut, prev_tile.?, prev_poly.?, cur_ref, tile.?, poly.?, cur_ref, tile.?, poly.?);
                }
                return status;
            }

            // Follow neighbours
            var next_ref: PolyRef = 0;

            var i = poly.?.first_link;
            while (i != common.NULL_LINK) : (i = tile.?.links[i].next) {
                const link = &tile.?.links[i];

                // Find link which contains this edge
                if (@as(i32, @intCast(link.edge)) != seg_max) {
                    continue;
                }

                // Get pointer to the next polygon
                nav.getTileAndPolyByRefUnsafe(link.ref, &next_tile, &next_poly);

                // Skip off-mesh connections
                if (next_poly.?.getType() == .offmesh_connection) {
                    continue;
                }

                // Skip links based on filter
                if (!filter.passFilter(link.ref, next_tile.?, next_poly.?)) {
                    continue;
                }

                // If the link is internal, just return the ref
                if (link.side == 0xff) {
                    next_ref = link.ref;
                    break;
                }

                // If the link is at tile boundary
                // Check if the link spans the whole edge, and accept
                if (link.bmin == 0 and link.bmax == 255) {
                    next_ref = link.ref;
                    break;
                }

                // Check for partial edge links
                const v0 = poly.?.verts[link.edge];
                const v1 = poly.?.verts[@mod(link.edge + 1, poly.?.vert_count)];
                const left = tile.?.verts[v0 * 3 .. v0 * 3 + 3][0..3];
                const right = tile.?.verts[v1 * 3 .. v1 * 3 + 3][0..3];

                // Check that the intersection lies inside the link portal
                if (link.side == 0 or link.side == 4) {
                    // Calculate link size
                    const s = 1.0 / 255.0;
                    var lmin = left[2] + (right[2] - left[2]) * (@as(f32, @floatFromInt(link.bmin)) * s);
                    var lmax = left[2] + (right[2] - left[2]) * (@as(f32, @floatFromInt(link.bmax)) * s);
                    if (lmin > lmax) {
                        const tmp = lmin;
                        lmin = lmax;
                        lmax = tmp;
                    }

                    // Find Z intersection
                    const z = start_pos[2] + (end_pos[2] - start_pos[2]) * tmax;
                    if (z >= lmin and z <= lmax) {
                        next_ref = link.ref;
                        break;
                    }
                } else if (link.side == 2 or link.side == 6) {
                    // Calculate link size
                    const s = 1.0 / 255.0;
                    var lmin = left[0] + (right[0] - left[0]) * (@as(f32, @floatFromInt(link.bmin)) * s);
                    var lmax = left[0] + (right[0] - left[0]) * (@as(f32, @floatFromInt(link.bmax)) * s);
                    if (lmin > lmax) {
                        const tmp = lmin;
                        lmin = lmax;
                        lmax = tmp;
                    }

                    // Find X intersection
                    const x = start_pos[0] + (end_pos[0] - start_pos[0]) * tmax;
                    if (x >= lmin and x <= lmax) {
                        next_ref = link.ref;
                        break;
                    }
                }
            }

            // Add the cost
            if ((options & common.RAYCAST_USE_COSTS) != 0) {
                // Compute the intersection point at the furthest end of the polygon
                // and correct the height (since the raycast moves in 2D)
                math.vcopy(&last_pos, &cur_pos);
                cur_pos[0] = start_pos[0] + dir[0] * hit.t;
                cur_pos[1] = start_pos[1] + dir[1] * hit.t;
                cur_pos[2] = start_pos[2] + dir[2] * hit.t;

                const e1 = verts[@as(usize, @intCast(seg_max)) * 3 .. @as(usize, @intCast(seg_max)) * 3 + 3][0..3];
                const e2 = verts[(@mod(@as(usize, @intCast(seg_max)) + 1, nv)) * 3 .. (@mod(@as(usize, @intCast(seg_max)) + 1, nv)) * 3 + 3][0..3];

                var e_dir: [3]f32 = undefined;
                e_dir[0] = e2[0] - e1[0];
                e_dir[1] = e2[1] - e1[1];
                e_dir[2] = e2[2] - e1[2];

                var diff: [3]f32 = undefined;
                diff[0] = cur_pos[0] - e1[0];
                diff[1] = cur_pos[1] - e1[1];
                diff[2] = cur_pos[2] - e1[2];

                const s = if (math.sqr(f32, e_dir[0]) > math.sqr(f32, e_dir[2]))
                    diff[0] / e_dir[0]
                else
                    diff[2] / e_dir[2];

                cur_pos[1] = e1[1] + e_dir[1] * s;

                hit.path_cost += filter.getCost(&last_pos, &cur_pos, prev_ref_mut, prev_tile.?, prev_poly.?, cur_ref, tile.?, poly.?, next_ref, next_tile.?, next_poly.?);
            }

            if (next_ref == 0) {
                // No neighbour, we hit a wall
                // Calculate hit normal
                const a = @as(usize, @intCast(seg_max));
                const b = if (seg_max + 1 < @as(i32, @intCast(nv))) @as(usize, @intCast(seg_max + 1)) else 0;
                const va = verts[a * 3 .. a * 3 + 3][0..3];
                const vb = verts[b * 3 .. b * 3 + 3][0..3];
                const dx = vb[0] - va[0];
                const dz = vb[2] - va[2];
                hit.hit_normal[0] = dz;
                hit.hit_normal[1] = 0;
                hit.hit_normal[2] = -dx;

                // Normalize
                const len = @sqrt(hit.hit_normal[0] * hit.hit_normal[0] + hit.hit_normal[2] * hit.hit_normal[2]);
                if (len > 0) {
                    hit.hit_normal[0] /= len;
                    hit.hit_normal[2] /= len;
                }

                hit.path_count = n;
                return status;
            }

            // No hit, advance to neighbour polygon
            prev_ref_mut = cur_ref;
            cur_ref = next_ref;
            prev_tile = tile;
            tile = next_tile;
            prev_poly = poly;
            poly = next_poly;

            if (status.buffer_too_small) {
                status.partial_result = true;
                break;
            }
        }

        hit.path_count = n;
        return status;
    }

    /// Find the distance from the specified position to the nearest polygon wall
    /// Uses Dijkstra search within maxRadius to find walls
    pub fn findDistanceToWall(
        self: *const Self,
        start_ref: PolyRef,
        center_pos: *const [3]f32,
        max_radius: f32,
        filter: *const QueryFilter,
        hit_dist: *f32,
        hit_pos: *[3]f32,
        hit_normal: *[3]f32,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const node_pool = self.node_pool orelse return error.NoNodePool;
        const open_list = self.open_list orelse return error.NoOpenList;

        // Validate input
        if (!self.isValidPolyRef(start_ref, filter) or
            !math.Vec3.fromArray(center_pos).isFinite() or
            max_radius < 0 or !std.math.isFinite(max_radius))
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        node_pool.clear();
        open_list.clear();

        var start_node = node_pool.getNode(start_ref, 0) orelse return error.OutOfNodes;
        math.vcopy(&start_node.pos, center_pos);
        start_node.pidx = 0;
        start_node.cost = 0;
        start_node.total = 0;
        start_node.id = start_ref;
        start_node.flags.open = true;
        open_list.push(start_node);

        var radius_sqr = max_radius * max_radius;
        var status = common.Status.ok();

        while (!open_list.empty()) {
            var best_node = open_list.pop() orelse break;
            best_node.flags.open = false;
            best_node.flags.closed = true;

            // Get poly and tile
            const best_ref = best_node.id;
            var best_tile: ?*const MeshTile = null;
            var best_poly: ?*const Poly = null;
            nav.getTileAndPolyByRefUnsafe(best_ref, &best_tile, &best_poly);

            // Get parent poly and tile
            var parent_ref: PolyRef = 0;
            var parent_tile: ?*const MeshTile = null;
            var parent_poly: ?*const Poly = null;
            if (best_node.pidx != 0) {
                const parent_node = node_pool.getNodeAtIdx(best_node.pidx) orelse null;
                if (parent_node) |pn| {
                    parent_ref = pn.id;
                }
            }
            if (parent_ref != 0) {
                nav.getTileAndPolyByRefUnsafe(parent_ref, &parent_tile, &parent_poly);
            }

            // Hit test walls
            var j: usize = best_poly.?.vert_count - 1;
            var i: usize = 0;
            while (i < best_poly.?.vert_count) : ({
                j = i;
                i += 1;
            }) {
                // Skip non-solid edges
                if ((best_poly.?.neis[j] & common.DT_EXT_LINK) != 0) {
                    // Tile border
                    var solid = true;
                    var k = best_poly.?.first_link;
                    while (k != common.NULL_LINK) : (k = best_tile.?.links[k].next) {
                        const link = &best_tile.?.links[k];
                        if (link.edge == j) {
                            if (link.ref != 0) {
                                var nei_tile: ?*const MeshTile = null;
                                var nei_poly: ?*const Poly = null;
                                nav.getTileAndPolyByRefUnsafe(link.ref, &nei_tile, &nei_poly);
                                if (filter.passFilter(link.ref, nei_tile.?, nei_poly.?)) {
                                    solid = false;
                                }
                            }
                            break;
                        }
                    }
                    if (!solid) continue;
                } else if (best_poly.?.neis[j] != 0) {
                    // Internal edge
                    const idx = best_poly.?.neis[j] - 1;
                    const ref = nav.getPolyRefBase(best_tile.?) | idx;
                    if (filter.passFilter(ref, best_tile.?, &best_tile.?.polys[idx])) {
                        continue;
                    }
                }

                // Calc distance to the edge
                const vj = best_tile.?.verts[best_poly.?.verts[j] * 3 .. best_poly.?.verts[j] * 3 + 3][0..3];
                const vi = best_tile.?.verts[best_poly.?.verts[i] * 3 .. best_poly.?.verts[i] * 3 + 3][0..3];
                var tseg: f32 = undefined;
                const dist_sqr = math.distancePtSegSqr2D(center_pos, vj, vi, &tseg);

                // Edge is too far, skip
                if (dist_sqr > radius_sqr) {
                    continue;
                }

                // Hit wall, update radius
                radius_sqr = dist_sqr;
                // Calculate hit pos
                hit_pos[0] = vj[0] + (vi[0] - vj[0]) * tseg;
                hit_pos[1] = vj[1] + (vi[1] - vj[1]) * tseg;
                hit_pos[2] = vj[2] + (vi[2] - vj[2]) * tseg;
            }

            // Expand to neighbours
            var link_idx = best_poly.?.first_link;
            while (link_idx != common.NULL_LINK) : (link_idx = best_tile.?.links[link_idx].next) {
                const link = &best_tile.?.links[link_idx];
                const neighbour_ref = link.ref;

                // Skip invalid neighbours and do not follow back to parent
                if (neighbour_ref == 0 or neighbour_ref == parent_ref) {
                    continue;
                }

                // Expand to neighbour
                var neighbour_tile: ?*const MeshTile = null;
                var neighbour_poly: ?*const Poly = null;
                nav.getTileAndPolyByRefUnsafe(neighbour_ref, &neighbour_tile, &neighbour_poly);

                // Skip off-mesh connections
                if (neighbour_poly.?.getType() == .offmesh_connection) {
                    continue;
                }

                // Calc distance to the edge
                const va = best_tile.?.verts[best_poly.?.verts[link.edge] * 3 .. best_poly.?.verts[link.edge] * 3 + 3][0..3];
                const vb = best_tile.?.verts[best_poly.?.verts[@mod(link.edge + 1, best_poly.?.vert_count)] * 3 .. best_poly.?.verts[@mod(link.edge + 1, best_poly.?.vert_count)] * 3 + 3][0..3];
                var tseg: f32 = undefined;
                const dist_sqr = math.distancePtSegSqr2D(center_pos, va, vb, &tseg);

                // If the circle is not touching the next polygon, skip it
                if (dist_sqr > radius_sqr) {
                    continue;
                }

                if (!filter.passFilter(neighbour_ref, neighbour_tile.?, neighbour_poly.?)) {
                    continue;
                }

                var neighbour_node = node_pool.getNode(neighbour_ref, 0) orelse {
                    status.out_of_nodes = true;
                    continue;
                };

                if (neighbour_node.flags.closed) {
                    continue;
                }

                // Cost
                if (neighbour_node.flags.asByte() == 0) {
                    try nav.getEdgeMidPoint(best_ref, best_poly.?, best_tile.?, neighbour_ref, neighbour_poly.?, neighbour_tile.?, &neighbour_node.pos);
                }

                const total = best_node.total + math.Vec3.fromArray(&best_node.pos).dist(math.Vec3.fromArray(&neighbour_node.pos));

                // The node is already in open list and the new result is worse, skip
                if (neighbour_node.flags.open and total >= neighbour_node.total) {
                    continue;
                }

                neighbour_node.id = neighbour_ref;
                neighbour_node.flags.closed = false;
                neighbour_node.pidx = @intCast(node_pool.getNodeIdx(best_node));
                neighbour_node.total = total;

                if (neighbour_node.flags.open) {
                    open_list.modify(neighbour_node);
                } else {
                    neighbour_node.flags.open = true;
                    open_list.push(neighbour_node);
                }
            }
        }

        // Calc hit normal
        hit_normal[0] = center_pos[0] - hit_pos[0];
        hit_normal[1] = center_pos[1] - hit_pos[1];
        hit_normal[2] = center_pos[2] - hit_pos[2];

        const len = @sqrt(hit_normal[0] * hit_normal[0] + hit_normal[1] * hit_normal[1] + hit_normal[2] * hit_normal[2]);
        if (len > 0) {
            hit_normal[0] /= len;
            hit_normal[1] /= len;
            hit_normal[2] /= len;
        }

        hit_dist.* = @sqrt(radius_sqr);

        return status;
    }

    /// Finds polygons within a radius that don't overlap with each other
    /// Useful for finding a local cluster of polygons around a point
    ///
    /// @param start_ref Reference to starting polygon
    /// @param center_pos Center position of search circle [x,y,z]
    /// @param radius Search radius
    /// @param filter Polygon filter
    /// @param result_ref Output array for polygon references
    /// @param result_parent Output array for parent polygon references (optional, can be null)
    /// @param result_count Output count of found polygons
    /// @param max_result Maximum number of polygons to return
    /// @return Status with success/failure and buffer_too_small if needed
    pub fn findLocalNeighbourhood(
        self: *const Self,
        start_ref: PolyRef,
        center_pos: *const [3]f32,
        radius: f32,
        filter: *const QueryFilter,
        result_ref: []PolyRef,
        result_parent: ?[]PolyRef,
        result_count: *usize,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const tiny_pool = self.tiny_node_pool orelse return error.NoNodePool;

        result_count.* = 0;

        // Validate input
        if (!self.isValidPolyRef(start_ref, filter) or
            !math.visfinite(center_pos) or
            radius < 0 or !math.isfinite(radius))
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        const max_result = result_ref.len;
        if (max_result <= 0) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        const MAX_STACK = 48;
        var stack: [MAX_STACK]?*Node = undefined;
        var nstack: usize = 0;

        tiny_pool.clear();

        var start_node = tiny_pool.getNode(start_ref, 0) orelse return common.Status{ .failure = true, .out_of_nodes = true };
        start_node.pidx = 0;
        start_node.id = start_ref;
        start_node.flags.closed = true;
        stack[nstack] = start_node;
        nstack += 1;

        const radius_sqr = radius * radius;

        var pa: [common.VERTS_PER_POLYGON * 3]f32 = undefined;
        var pb: [common.VERTS_PER_POLYGON * 3]f32 = undefined;

        var status = common.Status.ok();

        var n: usize = 0;
        if (n < max_result) {
            result_ref[n] = start_node.id;
            if (result_parent) |parents| {
                parents[n] = 0;
            }
            n += 1;
        } else {
            status.buffer_too_small = true;
        }

        while (nstack > 0) {
            // Pop front (FIFO)
            const cur_node = stack[0].?;
            var i: usize = 0;
            while (i < nstack - 1) : (i += 1) {
                stack[i] = stack[i + 1];
            }
            nstack -= 1;

            // Get poly and tile
            const cur_ref = cur_node.id;
            var cur_tile: ?*const MeshTile = null;
            var cur_poly: ?*const Poly = null;
            nav.getTileAndPolyByRefUnsafe(cur_ref, &cur_tile, &cur_poly);

            // Iterate through neighbours
            var link_idx = cur_poly.?.first_link;
            while (link_idx != common.NULL_LINK) {
                const link = &cur_tile.?.links[link_idx];
                const neighbour_ref = link.ref;
                link_idx = link.next;

                // Skip invalid neighbours
                if (neighbour_ref == 0) continue;

                // Skip if cannot allocate more nodes
                const neighbour_node = tiny_pool.getNode(neighbour_ref, 0) orelse continue;

                // Skip visited
                if (neighbour_node.flags.closed) continue;

                // Expand to neighbour
                var neighbour_tile: ?*const MeshTile = null;
                var neighbour_poly: ?*const Poly = null;
                nav.getTileAndPolyByRefUnsafe(neighbour_ref, &neighbour_tile, &neighbour_poly);

                // Skip off-mesh connections
                if (neighbour_poly.?.getType() == .offmesh_connection) continue;

                // Do not advance if the polygon is excluded by the filter
                if (!filter.passFilter(neighbour_ref, neighbour_tile.?, neighbour_poly.?)) continue;

                // Find edge and calc distance to the edge
                var va: [3]f32 = undefined;
                var vb: [3]f32 = undefined;
                var from_type: u8 = undefined;
                var to_type: u8 = undefined;
                self.getPortalPoints(cur_ref, neighbour_ref, &va, &vb, &from_type, &to_type) catch continue;

                // If the circle is not touching the next polygon, skip it
                var tseg: f32 = undefined;
                const dist_sqr = math.distancePtSegSqr2D(center_pos, &va, &vb, &tseg);
                if (dist_sqr > radius_sqr) continue;

                // Mark node visited, this is done before the overlap test so that
                // we will not visit the poly again if the test fails
                neighbour_node.flags.closed = true;
                neighbour_node.pidx = @intCast(tiny_pool.getNodeIdx(cur_node));

                // Check that the polygon does not collide with existing polygons

                // Collect vertices of the neighbour poly
                const npa = neighbour_poly.?.vert_count;
                for (0..npa) |k| {
                    const vert_idx = neighbour_poly.?.verts[k];
                    const src_verts = neighbour_tile.?.verts[vert_idx * 3 .. vert_idx * 3 + 3];
                    pa[k * 3 + 0] = src_verts[0];
                    pa[k * 3 + 1] = src_verts[1];
                    pa[k * 3 + 2] = src_verts[2];
                }

                var overlap = false;
                for (0..n) |j| {
                    const past_ref = result_ref[j];

                    // Connected polys do not overlap
                    var connected = false;
                    var check_link_idx = cur_poly.?.first_link;
                    while (check_link_idx != common.NULL_LINK) {
                        if (cur_tile.?.links[check_link_idx].ref == past_ref) {
                            connected = true;
                            break;
                        }
                        check_link_idx = cur_tile.?.links[check_link_idx].next;
                    }
                    if (connected) continue;

                    // Potentially overlapping
                    var past_tile: ?*const MeshTile = null;
                    var past_poly: ?*const Poly = null;
                    nav.getTileAndPolyByRefUnsafe(past_ref, &past_tile, &past_poly);

                    // Get vertices and test overlap
                    const npb = past_poly.?.vert_count;
                    for (0..npb) |k| {
                        const vert_idx = past_poly.?.verts[k];
                        const src_verts = past_tile.?.verts[vert_idx * 3 .. vert_idx * 3 + 3];
                        pb[k * 3 + 0] = src_verts[0];
                        pb[k * 3 + 1] = src_verts[1];
                        pb[k * 3 + 2] = src_verts[2];
                    }

                    if (math.overlapPolyPoly2D(&pa, npa, &pb, npb)) {
                        overlap = true;
                        break;
                    }
                }
                if (overlap) continue;

                // This poly is fine, store and advance to the poly
                if (n < max_result) {
                    result_ref[n] = neighbour_ref;
                    if (result_parent) |parents| {
                        parents[n] = cur_ref;
                    }
                    n += 1;
                } else {
                    status.buffer_too_small = true;
                }

                if (nstack < MAX_STACK) {
                    stack[nstack] = neighbour_node;
                    nstack += 1;
                }
            }
        }

        result_count.* = n;

        return status;
    }

    /// Gets the height of the polygon at the provided position using the detail mesh
    /// For off-mesh connections, interpolates the height along the connection segment
    ///
    /// @param ref Reference to polygon
    /// @param pos Position to get height at [x,y,z]
    /// @param height Output height value
    /// @return Status with success or failure
    pub fn getPolyHeight(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        height: *f32,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;

        // Get tile and poly
        const result = nav.getTileAndPolyByRef(ref) catch {
            return common.Status{ .failure = true, .invalid_param = true };
        };
        const tile = result.tile;
        const poly = result.poly;

        // Validate position
        if (!math.visfinite2D(pos)) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        // Special case for off-mesh connections
        // Interpolate height along the connection segment
        if (poly.getType() == .offmesh_connection) {
            const v0_slice = tile.verts[poly.verts[0] * 3 .. poly.verts[0] * 3 + 3];
            const v1_slice = tile.verts[poly.verts[1] * 3 .. poly.verts[1] * 3 + 3];
            const v0: [3]f32 = .{ v0_slice[0], v0_slice[1], v0_slice[2] };
            const v1: [3]f32 = .{ v1_slice[0], v1_slice[1], v1_slice[2] };
            var t: f32 = undefined;
            _ = math.distancePtSegSqr2D(pos, &v0, &v1, &t);
            height.* = v0[1] + (v1[1] - v0[1]) * t;
            return common.Status.ok();
        }

        // For regular polygons, use the navmesh getPolyHeight
        // Note: This is simplified - full version would use detail mesh
        nav.getPolyHeight(ref, pos, height) catch {
            return common.Status{ .failure = true, .invalid_param = true };
        };

        return common.Status.ok();
    }

    /// Finds the closest point on the specified polygon
    /// If the point is inside the polygon (in 2D), returns point with corrected height
    /// If outside, returns closest point on the polygon boundary
    ///
    /// @param ref Reference to polygon
    /// @param pos Position to find closest point for [x,y,z]
    /// @param closest Output closest point on polygon [x,y,z]
    /// @param pos_over_poly Optional output: true if point is over polygon, false otherwise
    /// @return Status with success or failure
    pub fn closestPointOnPoly(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        closest: *[3]f32,
        pos_over_poly: ?*bool,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;

        // Validate parameters
        if (!nav.isValidPolyRef(ref) or !math.visfinite(pos)) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        // Call navmesh implementation
        nav.closestPointOnPoly(ref, pos, closest, pos_over_poly) catch {
            return common.Status{ .failure = true, .invalid_param = true };
        };

        return common.Status.ok();
    }

    /// Finds the closest point on the polygon boundary
    /// Much faster than closestPointOnPoly() but only returns boundary points
    /// The height is from the polygon boundary, not from detail mesh
    ///
    /// @param ref Reference to polygon
    /// @param pos Position to find closest point for [x,y,z]
    /// @param closest Output closest point on boundary [x,y,z]
    /// @return Status with success or failure
    pub fn closestPointOnPolyBoundary(
        self: *const Self,
        ref: PolyRef,
        pos: *const [3]f32,
        closest: *[3]f32,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;

        // Get tile and poly to validate
        const result = nav.getTileAndPolyByRef(ref) catch {
            return common.Status{ .failure = true, .invalid_param = true };
        };
        _ = result.tile;
        _ = result.poly;

        // Validate position
        if (!math.visfinite(pos)) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        // Call navmesh implementation
        nav.closestPointOnPolyBoundary(ref, pos, closest) catch {
            return common.Status{ .failure = true, .invalid_param = true };
        };

        return common.Status.ok();
    }

    /// Finds all polygons within a circular search area using Dijkstra expansion
    /// Results are ordered from least to highest cost
    /// Useful for queries like "find all polys within X meters"
    ///
    /// @param start_ref Reference to starting polygon
    /// @param center_pos Center of search circle [x,y,z]
    /// @param radius Search radius
    /// @param filter Polygon filter
    /// @param result_ref Output array for polygon references
    /// @param result_parent Output array for parent references (optional)
    /// @param result_cost Output array for path costs (optional)
    /// @param result_count Output count of found polygons
    /// @return Status with success/failure and buffer_too_small if needed
    pub fn findPolysAroundCircle(
        self: *const Self,
        start_ref: PolyRef,
        center_pos: *const [3]f32,
        radius: f32,
        filter: *const QueryFilter,
        result_ref: []PolyRef,
        result_parent: ?[]PolyRef,
        result_cost: ?[]f32,
        result_count: *usize,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const node_pool = self.node_pool orelse return error.NoNodePool;
        const open_list = self.open_list orelse return error.NoOpenList;

        result_count.* = 0;

        // Validate input
        if (!nav.isValidPolyRef(start_ref) or
            !math.visfinite(center_pos) or
            radius < 0 or !math.isfinite(radius))
        {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        const max_result = result_ref.len;
        if (max_result <= 0) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        node_pool.clear();
        open_list.clear();

        var start_node = node_pool.getNode(start_ref, 0) orelse return common.Status{ .failure = true, .out_of_nodes = true };
        math.vcopy(&start_node.pos, center_pos);
        start_node.pidx = 0;
        start_node.cost = 0;
        start_node.total = 0;
        start_node.id = start_ref;
        start_node.flags = Node.OPEN;
        open_list.push(start_node);

        var status = common.Status.ok();

        var n: usize = 0;

        const radius_sqr = radius * radius;

        while (!open_list.empty()) {
            const best_node = open_list.pop().?;
            best_node.flags &= ~Node.OPEN;
            best_node.flags |= Node.CLOSED;

            // Get poly and tile
            const best_ref = best_node.id;
            const best_tile, const best_poly = nav.getTileAndPolyByRefUnsafe(best_ref);

            // Get parent poly and tile
            var parent_ref: PolyRef = 0;
            var parent_tile: ?*const MeshTile = null;
            var parent_poly: ?*const Poly = null;
            if (best_node.pidx != 0) {
                const parent_node = node_pool.getNodeAtIdxConst(best_node.pidx).?;
                parent_ref = parent_node.id;
                const pt, const pp = nav.getTileAndPolyByRefUnsafe(parent_ref);
                parent_tile = pt;
                parent_poly = pp;
            }

            // Add to result
            if (n < max_result) {
                result_ref[n] = best_ref;
                if (result_parent) |parents| {
                    parents[n] = parent_ref;
                }
                if (result_cost) |costs| {
                    costs[n] = best_node.total;
                }
                n += 1;
            } else {
                status.buffer_too_small = true;
            }

            // Expand to neighbors
            var link_idx = best_poly.firstLink;
            while (link_idx != common.NULL_LINK) {
                const link = &best_tile.links[link_idx];
                const neighbour_ref = link.ref;
                link_idx = link.next;

                // Skip invalid neighbours and do not follow back to parent
                if (neighbour_ref == 0 or neighbour_ref == parent_ref) continue;

                // Expand to neighbour
                var neighbour_tile: ?*const MeshTile = null;
                var neighbour_poly: ?*const Poly = null;
                nav.getTileAndPolyByRefUnsafe(neighbour_ref, &neighbour_tile, &neighbour_poly);

                // Do not advance if the polygon is excluded by the filter
                if (!filter.passFilter(neighbour_ref, neighbour_tile.?, neighbour_poly.?)) continue;

                // Find edge and calc distance to the edge
                var va: [3]f32 = undefined;
                var vb: [3]f32 = undefined;
                if (!self.getPortalPoints(best_ref, best_poly, best_tile, neighbour_ref, neighbour_poly, neighbour_tile, &va, &vb))
                    continue;

                // If the circle is not touching the next polygon, skip it
                var tseg: f32 = undefined;
                const dist_sqr = math.distancePtSegSqr2D(center_pos, &va, &vb, &tseg);
                if (dist_sqr > radius_sqr) continue;

                var neighbour_node = node_pool.getNode(neighbour_ref, 0) orelse {
                    status.out_of_nodes = true;
                    continue;
                };

                if ((neighbour_node.flags & Node.CLOSED) != 0) continue;

                // Cost - set position to edge midpoint on first visit
                if (neighbour_node.flags == 0) {
                    math.vlerp(&neighbour_node.pos, &va, &vb, 0.5);
                }

                const cost = filter.getCost(
                    &best_node.pos,
                    &neighbour_node.pos,
                    parent_ref,
                    parent_tile,
                    parent_poly,
                    best_ref,
                    best_tile,
                    best_poly,
                    neighbour_ref,
                    neighbour_tile,
                    neighbour_poly,
                );

                const total = best_node.total + cost;

                // The node is already in open list and the new result is worse, skip
                if ((neighbour_node.flags & Node.OPEN) != 0 and total >= neighbour_node.total) continue;

                neighbour_node.id = neighbour_ref;
                neighbour_node.pidx = node_pool.getNodeIdx(best_node);
                neighbour_node.total = total;

                if ((neighbour_node.flags & Node.OPEN) != 0) {
                    open_list.modify(neighbour_node);
                } else {
                    neighbour_node.flags = Node.OPEN;
                    open_list.push(neighbour_node);
                }
            }
        }

        result_count.* = n;

        return status;
    }

    /// Finds all polygons that intersect with a convex shape using Dijkstra expansion
    /// Results are ordered from least to highest cost
    /// Similar to findPolysAroundCircle but uses arbitrary convex polygon instead of circle
    ///
    /// @param start_ref Reference to starting polygon
    /// @param verts Shape vertices [x,y,z] * nverts (must be convex)
    /// @param nverts Number of vertices in shape (must be >= 3)
    /// @param filter Polygon filter
    /// @param result_ref Output array for polygon references
    /// @param result_parent Output array for parent references (optional)
    /// @param result_cost Output array for path costs (optional)
    /// @param result_count Output count of found polygons
    /// @return Status with success/failure and buffer_too_small if needed
    pub fn findPolysAroundShape(
        self: *const Self,
        start_ref: PolyRef,
        verts: []const f32,
        nverts: usize,
        filter: *const QueryFilter,
        result_ref: []PolyRef,
        result_parent: ?[]PolyRef,
        result_cost: ?[]f32,
        result_count: *usize,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const node_pool = self.node_pool orelse return error.NoNodePool;
        const open_list = self.open_list orelse return error.NoOpenList;

        result_count.* = 0;

        // Validate input
        if (!nav.isValidPolyRef(start_ref) or nverts < 3) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        const max_result = result_ref.len;
        if (max_result <= 0) {
            return common.Status{ .failure = true, .invalid_param = true };
        }

        node_pool.clear();
        open_list.clear();

        // Calculate center of shape
        var center_pos = [3]f32{ 0, 0, 0 };
        for (0..nverts) |i| {
            center_pos[0] += verts[i * 3 + 0];
            center_pos[1] += verts[i * 3 + 1];
            center_pos[2] += verts[i * 3 + 2];
        }
        const inv_nverts = 1.0 / @as(f32, @floatFromInt(nverts));
        center_pos[0] *= inv_nverts;
        center_pos[1] *= inv_nverts;
        center_pos[2] *= inv_nverts;

        var start_node = node_pool.getNode(start_ref, 0) orelse return common.Status{ .failure = true, .out_of_nodes = true };
        math.vcopy(&start_node.pos, &center_pos);
        start_node.pidx = 0;
        start_node.cost = 0;
        start_node.total = 0;
        start_node.id = start_ref;
        start_node.flags = Node.OPEN;
        open_list.push(start_node);

        var status = common.Status.ok();

        var n: usize = 0;

        while (!open_list.empty()) {
            const best_node = open_list.pop().?;
            best_node.flags &= ~Node.OPEN;
            best_node.flags |= Node.CLOSED;

            // Get poly and tile
            const best_ref = best_node.id;
            const best_tile, const best_poly = nav.getTileAndPolyByRefUnsafe(best_ref);

            // Get parent poly and tile
            var parent_ref: PolyRef = 0;
            var parent_tile: ?*const MeshTile = null;
            var parent_poly: ?*const Poly = null;
            if (best_node.pidx != 0) {
                const parent_node = node_pool.getNodeAtIdxConst(best_node.pidx).?;
                parent_ref = parent_node.id;
                const pt, const pp = nav.getTileAndPolyByRefUnsafe(parent_ref);
                parent_tile = pt;
                parent_poly = pp;
            }

            // Add to result
            if (n < max_result) {
                result_ref[n] = best_ref;
                if (result_parent) |parents| {
                    parents[n] = parent_ref;
                }
                if (result_cost) |costs| {
                    costs[n] = best_node.total;
                }
                n += 1;
            } else {
                status.buffer_too_small = true;
            }

            // Expand to neighbors
            var link_idx = best_poly.firstLink;
            while (link_idx != common.NULL_LINK) {
                const link = &best_tile.links[link_idx];
                const neighbour_ref = link.ref;
                link_idx = link.next;

                // Skip invalid neighbours and do not follow back to parent
                if (neighbour_ref == 0 or neighbour_ref == parent_ref) continue;

                // Expand to neighbour
                var neighbour_tile: ?*const MeshTile = null;
                var neighbour_poly: ?*const Poly = null;
                nav.getTileAndPolyByRefUnsafe(neighbour_ref, &neighbour_tile, &neighbour_poly);

                // Do not advance if the polygon is excluded by the filter
                if (!filter.passFilter(neighbour_ref, neighbour_tile.?, neighbour_poly.?)) continue;

                // Find edge and calc distance to the edge
                var va: [3]f32 = undefined;
                var vb: [3]f32 = undefined;
                if (!self.getPortalPoints(best_ref, best_poly, best_tile, neighbour_ref, neighbour_poly, neighbour_tile, &va, &vb))
                    continue;

                // If the portal is not intersecting the shape, skip it
                var tmin: f32 = undefined;
                var tmax: f32 = undefined;
                var seg_min: i32 = undefined;
                var seg_max: i32 = undefined;
                if (!math.intersectSegmentPoly2D(&va, &vb, verts, nverts, &tmin, &tmax, &seg_min, &seg_max))
                    continue;
                if (tmin > 1.0 or tmax < 0.0) continue;

                var neighbour_node = node_pool.getNode(neighbour_ref, 0) orelse {
                    status.out_of_nodes = true;
                    continue;
                };

                if ((neighbour_node.flags & Node.CLOSED) != 0) continue;

                // Cost - set position to edge midpoint on first visit
                if (neighbour_node.flags == 0) {
                    math.vlerp(&neighbour_node.pos, &va, &vb, 0.5);
                }

                const cost = filter.getCost(
                    &best_node.pos,
                    &neighbour_node.pos,
                    parent_ref,
                    parent_tile,
                    parent_poly,
                    best_ref,
                    best_tile,
                    best_poly,
                    neighbour_ref,
                    neighbour_tile,
                    neighbour_poly,
                );

                const total = best_node.total + cost;

                // The node is already in open list and the new result is worse, skip
                if ((neighbour_node.flags & Node.OPEN) != 0 and total >= neighbour_node.total) continue;

                neighbour_node.id = neighbour_ref;
                neighbour_node.pidx = node_pool.getNodeIdx(best_node);
                neighbour_node.total = total;

                if ((neighbour_node.flags & Node.OPEN) != 0) {
                    open_list.modify(neighbour_node);
                } else {
                    neighbour_node.flags = Node.OPEN;
                    open_list.push(neighbour_node);
                }
            }
        }

        result_count.* = n;

        return status;
    }

    /// Append a vertex to straight path
    /// Returns: Status with DT_IN_PROGRESS, DT_SUCCESS, or DT_SUCCESS | DT_BUFFER_TOO_SMALL
    fn appendVertex(
        pos: *const [3]f32,
        flags: u8,
        ref: PolyRef,
        straight_path: []f32,
        straight_path_flags: ?[]u8,
        straight_path_refs: ?[]PolyRef,
        straight_path_count: *usize,
        max_straight_path: usize,
    ) common.Status {
        if (straight_path_count.* > 0) {
            const last_idx = (straight_path_count.* - 1) * 3;
            if (math.vequal(straight_path[last_idx .. last_idx + 3][0..3], pos)) {
                // Vertices are equal, update flags and poly
                if (straight_path_flags) |spf| {
                    spf[straight_path_count.* - 1] = flags;
                }
                if (straight_path_refs) |spr| {
                    spr[straight_path_count.* - 1] = ref;
                }
                return common.Status{ .in_progress = true };
            }
        }

        // Append new vertex
        const idx = straight_path_count.* * 3;
        math.vcopy(straight_path[idx .. idx + 3][0..3], pos);
        if (straight_path_flags) |spf| {
            spf[straight_path_count.*] = flags;
        }
        if (straight_path_refs) |spr| {
            spr[straight_path_count.*] = ref;
        }
        straight_path_count.* += 1;

        // If no space to append more vertices, return
        if (straight_path_count.* >= max_straight_path) {
            return common.Status{ .success = true, .buffer_too_small = true };
        }

        // If reached end of path, return
        if (flags == common.STRAIGHTPATH_END) {
            return common.Status.ok();
        }

        return common.Status{ .in_progress = true };
    }

    /// Append portals along current straight path segment
    fn appendPortals(
        self: *const Self,
        start_idx: usize,
        end_idx: usize,
        end_pos: *const [3]f32,
        path: []const PolyRef,
        straight_path: []f32,
        straight_path_flags: ?[]u8,
        straight_path_refs: ?[]PolyRef,
        straight_path_count: *usize,
        max_straight_path: usize,
        options: u32,
    ) !common.Status {
        const nav = self.nav orelse return error.NoNavMesh;
        const start_pos_idx = (straight_path_count.* - 1) * 3;
        const start_pos = straight_path[start_pos_idx .. start_pos_idx + 3][0..3];

        var i = start_idx;
        while (i < end_idx) : (i += 1) {
            // Calculate portal
            const from = path[i];
            const from_result = try nav.getTileAndPolyByRef(from);
            const from_tile = from_result.tile;
            const from_poly = from_result.poly;

            const to = path[i + 1];
            const to_result = try nav.getTileAndPolyByRef(to);
            const to_tile = to_result.tile;
            const to_poly = to_result.poly;

            var left: [3]f32 = undefined;
            var right: [3]f32 = undefined;
            nav.getPortalPoints(from, from_poly, from_tile, to, to_poly, to_tile, &left, &right) catch break;

            if ((options & common.STRAIGHTPATH_AREA_CROSSINGS) != 0) {
                // Skip intersection if only area crossings are requested
                if (from_poly.getArea() == to_poly.getArea()) {
                    continue;
                }
            }

            // Append intersection
            var s: f32 = undefined;
            var t: f32 = undefined;
            if (math.intersectSegSeg2D(start_pos, end_pos, &left, &right, &s, &t)) {
                var pt: [3]f32 = undefined;
                math.vlerp(&pt, &left, &right, t);

                const stat = appendVertex(&pt, 0, path[i + 1], straight_path, straight_path_flags, straight_path_refs, straight_path_count, max_straight_path);
                if (!stat.isInProgress()) {
                    return stat;
                }
            }
        }

        return common.Status{ .in_progress = true };
    }
};

test "NodePool basic operations" {
    const allocator = std.testing.allocator;

    var pool = try NodePool.init(allocator, 128, 64);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 0), pool.getNodeCount());

    const node1 = pool.getNode(100, 0);
    try std.testing.expect(node1 != null);
    try std.testing.expectEqual(@as(PolyRef, 100), node1.?.id);
    try std.testing.expectEqual(@as(usize, 1), pool.getNodeCount());

    const node2 = pool.getNode(100, 0);
    try std.testing.expect(node2 != null);
    try std.testing.expect(node1 == node2); // Should return the same node

    pool.clear();
    try std.testing.expectEqual(@as(usize, 0), pool.getNodeCount());
}

test "NodeQueue operations" {
    const allocator = std.testing.allocator;

    var queue = try NodeQueue.init(allocator, 64);
    defer queue.deinit();

    try std.testing.expect(queue.empty());

    var node1 = Node.init();
    node1.total = 10.0;

    var node2 = Node.init();
    node2.total = 5.0;

    var node3 = Node.init();
    node3.total = 15.0;

    queue.push(&node1);
    queue.push(&node2);
    queue.push(&node3);

    try std.testing.expectEqual(@as(usize, 3), queue.size);

    const top = queue.top();
    try std.testing.expect(top != null);
    try std.testing.expectEqual(@as(f32, 5.0), top.?.total);

    _ = queue.pop();
    const top2 = queue.top();
    try std.testing.expectEqual(@as(f32, 10.0), top2.?.total);
}

test "NavMeshQuery initialization" {
    const allocator = std.testing.allocator;

    var query = try NavMeshQuery.init(allocator);
    defer query.deinit();

    try std.testing.expect(query.nav == null);
    try std.testing.expect(query.node_pool == null);
}

/// Segment interval for edge processing
const SegInterval = struct {
    ref: PolyRef,
    tmin: i16,
    tmax: i16,
};

/// Insert an interval into sorted interval array
fn insertInterval(ints: []SegInterval, nints: *usize, tmin: i16, tmax: i16, ref: PolyRef) void {
    if (nints.* + 1 > ints.len) return;

    // Find insertion point
    var idx: usize = 0;
    while (idx < nints.*) : (idx += 1) {
        if (tmax <= ints[idx].tmin) {
            break;
        }
    }

    // Move current results
    if (nints.* > idx) {
        const move_count = nints.* - idx;
        std.mem.copyBackwards(SegInterval, ints[idx + 1 .. idx + 1 + move_count], ints[idx .. idx + move_count]);
    }

    // Store
    ints[idx].ref = ref;
    ints[idx].tmin = tmin;
    ints[idx].tmax = tmax;
    nints.* += 1;
}

/// Get wall segments from a polygon
/// If segmentRefs is provided, returns all segments (portals + walls)
/// Otherwise returns only wall segments
pub fn getPolyWallSegments(
    self: *const NavMeshQuery,
    ref: PolyRef,
    filter: *const QueryFilter,
    segment_verts: []f32,
    segment_refs: ?[]PolyRef,
    segment_count: *usize,
    max_segments: usize,
) !common.Status {
    if (self.nav == null) {
        return common.Status{ .failure = true, .invalid_param = true };
    }

    segment_count.* = 0;

    const nav = self.nav.?;

    const result = nav.getTileAndPolyByRef(ref) catch {
        return common.Status{ .failure = true, .invalid_param = true };
    };
    const tile_ptr = result.tile;
    const poly_ptr = result.poly;

    var n: usize = 0;
    const MAX_INTERVAL = 16;
    var ints: [MAX_INTERVAL]SegInterval = undefined;
    var nints: usize = 0;

    const store_portals = segment_refs != null;
    var result_status = common.Status.ok();

    var j: usize = @intCast(poly_ptr.vert_count - 1);
    var i: usize = 0;
    while (i < poly_ptr.vert_count) : ({
        j = i;
        i += 1;
    }) {
        nints = 0;

        // Check if this is an external link
        if ((poly_ptr.neis[j] & common.EXT_LINK) != 0) {
            // Tile border - collect intervals from links
            var k = poly_ptr.first_link;
            while (k != common.NULL_LINK) {
                const link = &tile_ptr.links[k];
                if (link.edge == @as(u8, @intCast(j))) {
                    if (link.ref != 0) {
                        var nei_tile: ?*const navmesh.MeshTile = null;
                        var nei_poly: ?*const navmesh.Poly = null;
                        nav.getTileAndPolyByRefUnsafe(link.ref, &nei_tile, &nei_poly);

                        if (filter.passFilter(link.ref, nei_tile.?, nei_poly.?)) {
                            insertInterval(&ints, &nints, @intCast(link.bmin), @intCast(link.bmax), link.ref);
                        }
                    }
                }
                k = link.next;
            }
        } else {
            // Internal edge
            var nei_ref: PolyRef = 0;
            if (poly_ptr.neis[j] != 0) {
                const idx: u32 = poly_ptr.neis[j] - 1;
                nei_ref = nav.getPolyRefBase(tile_ptr) | idx;
                if (!filter.passFilter(nei_ref, tile_ptr, &tile_ptr.polys[idx])) {
                    nei_ref = 0;
                }
            }

            // If the edge leads to another polygon and portals are not stored, skip
            if (nei_ref != 0 and !store_portals) {
                continue;
            }

            // Store the segment
            if (n < max_segments) {
                const vj = tile_ptr.verts[poly_ptr.verts[j] * 3 .. poly_ptr.verts[j] * 3 + 3];
                const vi = tile_ptr.verts[poly_ptr.verts[i] * 3 .. poly_ptr.verts[i] * 3 + 3];
                const seg = segment_verts[n * 6 .. n * 6 + 6];
                seg[0] = vj[0];
                seg[1] = vj[1];
                seg[2] = vj[2];
                seg[3] = vi[0];
                seg[4] = vi[1];
                seg[5] = vi[2];
                if (segment_refs) |refs| {
                    refs[n] = nei_ref;
                }
                n += 1;
            } else {
                result_status.buffer_too_small = true;
            }

            continue;
        }

        // Add sentinels
        insertInterval(&ints, &nints, -1, 0, 0);
        insertInterval(&ints, &nints, 255, 256, 0);

        // Store segments
        const vj = tile_ptr.verts[poly_ptr.verts[j] * 3 .. poly_ptr.verts[j] * 3 + 3];
        const vi = tile_ptr.verts[poly_ptr.verts[i] * 3 .. poly_ptr.verts[i] * 3 + 3];

        var k: usize = 1;
        while (k < nints) : (k += 1) {
            // Portal segment
            if (store_portals and ints[k].ref != 0) {
                const tmin: f32 = @as(f32, @floatFromInt(ints[k].tmin)) / 255.0;
                const tmax: f32 = @as(f32, @floatFromInt(ints[k].tmax)) / 255.0;
                if (n < max_segments) {
                    const seg = segment_verts[n * 6 .. n * 6 + 6];
                    // vlerp for first point
                    seg[0] = vj[0] + (vi[0] - vj[0]) * tmin;
                    seg[1] = vj[1] + (vi[1] - vj[1]) * tmin;
                    seg[2] = vj[2] + (vi[2] - vj[2]) * tmin;
                    // vlerp for second point
                    seg[3] = vj[0] + (vi[0] - vj[0]) * tmax;
                    seg[4] = vj[1] + (vi[1] - vj[1]) * tmax;
                    seg[5] = vj[2] + (vi[2] - vj[2]) * tmax;
                    if (segment_refs) |refs| {
                        refs[n] = ints[k].ref;
                    }
                    n += 1;
                } else {
                    result_status.buffer_too_small = true;
                }
            }

            // Wall segment
            const imin = ints[k - 1].tmax;
            const imax = ints[k].tmin;
            if (imin != imax) {
                const tmin: f32 = @as(f32, @floatFromInt(imin)) / 255.0;
                const tmax: f32 = @as(f32, @floatFromInt(imax)) / 255.0;
                if (n < max_segments) {
                    const seg = segment_verts[n * 6 .. n * 6 + 6];
                    // vlerp for first point
                    seg[0] = vj[0] + (vi[0] - vj[0]) * tmin;
                    seg[1] = vj[1] + (vi[1] - vj[1]) * tmin;
                    seg[2] = vj[2] + (vi[2] - vj[2]) * tmin;
                    // vlerp for second point
                    seg[3] = vj[0] + (vi[0] - vj[0]) * tmax;
                    seg[4] = vj[1] + (vi[1] - vj[1]) * tmax;
                    seg[5] = vj[2] + (vi[2] - vj[2]) * tmax;
                    if (segment_refs) |refs| {
                        refs[n] = 0;
                    }
                    n += 1;
                } else {
                    result_status.buffer_too_small = true;
                }
            }
        }
    }

    segment_count.* = n;
    return result_status;
}
