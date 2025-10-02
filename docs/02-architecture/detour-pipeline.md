# Detour Pipeline

Детальный разбор runtime navigation queries и pathfinding через Detour.

---

## Overview

Detour - это runtime navigation library для выполнения queries на NavMesh:

```
NavMesh Data → NavMesh → NavMeshQuery → Pathfinding/Raycast/Queries
```

**Основные компоненты:**
- **NavMesh** - runtime navigation mesh structure
- **NavMeshQuery** - query engine для pathfinding
- **QueryFilter** - filtering и cost модификация
- **A* Pathfinding** - optimal path search
- **Raycast** - line-of-sight checks

---

## Pipeline Stages

### Stage 1: NavMesh Data Creation

**Цель:** Создать binary NavMesh data из Recast output

**Процесс:**
```zig
// 1. Setup creation parameters
var params = nav.detour.builder.NavMeshCreateParams{
    .verts = poly_mesh.verts,
    .vert_count = poly_mesh.vert_count,
    .polys = poly_mesh.polys,
    .poly_flags = poly_mesh.flags,
    .poly_areas = poly_mesh.areas,
    .poly_count = poly_mesh.poly_count,
    .nvp = poly_mesh.nvp,

    // Detail mesh
    .detail_meshes = detail_mesh.meshes,
    .detail_verts = detail_mesh.verts,
    .detail_vert_count = detail_mesh.vert_count,
    .detail_tris = detail_mesh.tris,
    .detail_tri_count = detail_mesh.tri_count,

    // Agent parameters
    .walk_height = walkable_height * ch,
    .walk_radius = walkable_radius * cs,
    .walk_climb = walkable_climb * ch,

    // Bounds
    .bmin = poly_mesh.bmin,
    .bmax = poly_mesh.bmax,
    .cs = cs,
    .ch = ch,

    .build_bv_tree = true,
};

// 2. Create NavMesh data
const nav_data = try nav.detour.builder.createNavMeshData(allocator, &params);
defer allocator.free(nav_data);
```

**Что происходит:**
1. **Validate input** - проверка параметров
2. **Calculate sizes** - вычисление размеров структур
3. **Allocate memory** - выделение памяти для NavMesh data
4. **Store vertices** - копирование vertex data
5. **Store polygons** - копирование polygon data
6. **Build BVH tree** - построение spatial acceleration structure
7. **Build links** - создание polygon connectivity
8. **Store detail mesh** - копирование detail triangulation
9. **Serialize** - упаковка в binary format

**NavMesh Data Format:**
```
Header (88 bytes)
├─ Magic: 'D' 'N' 'A' 'V' (4 bytes)
├─ Version: 7 (4 bytes)
├─ Bounds, Cell size, etc.
└─ Counts (verts, polys, links, etc.)

Vertex Data (verts * 12 bytes)
Polygon Data (polys * sizeof(Poly))
Link Data (links * sizeof(Link))
Detail Mesh Data
BVH Tree (if enabled)
Off-mesh Connections (if any)
```

**BVH Tree Construction:**
```zig
// BVH (Bounding Volume Hierarchy) для быстрого spatial lookup
fn buildBVTree(
    allocator: Allocator,
    verts: []const f32,
    polys: []const u16,
    poly_count: usize,
    nvp: usize,
    cs: f32,
    ch: f32,
) ![]BVNode {
    // 1. Create items for each polygon
    var items = try allocator.alloc(BVItem, poly_count);
    defer allocator.free(items);

    for (0..poly_count) |i| {
        const poly = polys[i * nvp * 2 .. (i + 1) * nvp * 2];

        // Calculate polygon AABB
        items[i] = calcPolyBounds(verts, poly, nvp, cs, ch);
    }

    // 2. Recursively subdivide
    var nodes = try allocator.alloc(BVNode, poly_count * 2);
    _ = try subdivide(items, 0, poly_count, nodes, 0);

    return nodes;
}

// Recursive subdivision
fn subdivide(
    items: []BVItem,
    imin: usize,
    imax: usize,
    nodes: []BVNode,
    node_idx: usize,
) usize {
    const inum = imax - imin;

    // Leaf node
    if (inum <= 1) {
        nodes[node_idx].i = @intCast(items[imin].i);
        return node_idx;
    }

    // Split axis selection (longest axis)
    const axis = selectSplitAxis(items[imin..imax]);

    // Sort along axis
    std.sort.pdq(BVItem, items[imin..imax], {}, compareItemByAxis(axis));

    // Split at median
    const isplit = imin + inum / 2;

    // Create node
    nodes[node_idx] = calcBounds(items[imin..imax]);
    nodes[node_idx].i = @intCast(node_idx + 1);

    // Recurse left
    const left_idx = subdivide(items, imin, isplit, nodes, node_idx + 1);

    // Recurse right
    const right_idx = subdivide(items, isplit, imax, nodes, left_idx + 1);

    return right_idx;
}
```

---

### Stage 2: NavMesh Initialization

**Цель:** Загрузить NavMesh data в runtime structure

**Процесс:**
```zig
// 1. Create NavMesh
var navmesh = try nav.detour.NavMesh.init(allocator);
defer navmesh.deinit();

// 2. Add tile (single-tile navmesh)
const AddTileOptions = struct {
    flags: u32 = 0,
    last_ref: u64 = 0,
    result: ?*u64 = null,
};

try navmesh.addTile(nav_data, .{});
```

**Что происходит:**
1. **Allocate NavMesh** - создание NavMesh structure
2. **Parse header** - чтение header из nav_data
3. **Validate data** - проверка magic, version, checksum
4. **Create tile** - создание MeshTile structure
5. **Map memory** - mapping data pointers к tile
6. **Initialize tile** - setup tile state
7. **Connect neighbors** - если tiled mesh

**NavMesh Structure:**
```zig
pub const NavMesh = struct {
    allocator: Allocator,
    params: NavMeshParams,      // NavMesh parameters
    orig: [3]f32,               // Origin
    tile_width: f32,            // Tile width
    tile_height: f32,           // Tile height
    max_tiles: u32,             // Max tiles
    tile_lookup_size: u32,      // Tile hash size
    tile_bits: u32,             // Tile ID bits
    poly_bits: u32,             // Polygon ID bits
    salt_bits: u32,             // Salt bits
    tiles: []MeshTile,          // Tile array
    pos_lookup: ?*TileHash,     // Tile hash (for multi-tile)
    next_free: ?*MeshTile,      // Free tile list
    avail_tiles: []?*MeshTile,  // Available tiles
    tile_count: u32,            // Current tile count
};

pub const MeshTile = struct {
    salt: u32,                  // Tile salt (для versioning)
    link_free_list: u32,        // Free link list
    header: ?*MeshHeader,       // Tile header
    polys: []Poly,              // Polygons
    verts: []f32,               // Vertices
    links: []Link,              // Links
    detail_meshes: []PolyDetail,// Detail meshes
    detail_verts: []f32,        // Detail vertices
    detail_tris: []u8,          // Detail triangles
    bv_tree: []BVNode,          // BVH tree
    off_mesh_cons: []OffMeshConnection, // Off-mesh connections
    data: []const u8,           // Raw data
    data_size: usize,           // Data size
    flags: u32,                 // Tile flags
    next: ?*MeshTile,           // Next tile (в списке)
};
```

**PolyRef System:**

Polygon reference encoding (64-bit):
```
┌─────────────┬──────────────┬────────────────────┐
│ Salt (16)   │ Tile ID (?)  │ Polygon ID (?)     │
└─────────────┴──────────────┴────────────────────┘
  63       48  47          ?   ?                  0

Salt: version для detecting stale references
Tile ID: tile index в NavMesh
Polygon ID: polygon index в tile
```

**Encoding/Decoding:**
```zig
// Encode PolyRef
pub fn encodePolyId(salt: u32, tile_idx: u32, poly_idx: u32) PolyRef {
    return (@as(u64, salt) << (poly_bits + tile_bits)) |
           (@as(u64, tile_idx) << poly_bits) |
           @as(u64, poly_idx);
}

// Decode PolyRef
pub fn decodePolyId(ref: PolyRef) struct { salt: u32, tile_idx: u32, poly_idx: u32 } {
    const salt_mask = (1 << salt_bits) - 1;
    const tile_mask = (1 << tile_bits) - 1;
    const poly_mask = (1 << poly_bits) - 1;

    return .{
        .salt = @intCast((ref >> (poly_bits + tile_bits)) & salt_mask),
        .tile_idx = @intCast((ref >> poly_bits) & tile_mask),
        .poly_idx = @intCast(ref & poly_mask),
    };
}
```

---

### Stage 3: NavMeshQuery Initialization

**Цель:** Создать query engine для pathfinding

**Процесс:**
```zig
// Create query
var query = try nav.detour.NavMeshQuery.init(allocator, &navmesh, 2048);
defer query.deinit();
```

**Что происходит:**
1. **Allocate query** - создание query structure
2. **Create node pools** - main pool (2048 nodes) + tiny pool (64 nodes)
3. **Create open list** - priority queue для A*
4. **Initialize filter** - default QueryFilter

**NavMeshQuery Structure:**
```zig
pub const NavMeshQuery = struct {
    allocator: Allocator,
    nav: ?*const NavMesh,
    node_pool: ?*NodePool,          // Main node pool (for A*)
    tiny_node_pool: ?*NodePool,     // Tiny pool (for small queries)
    open_list: ?*NodeQueue,         // Priority queue
    query: QueryData,                // Sliced query state
    filter: QueryFilter,             // Default filter
};
```

**Node Pool:**
```zig
pub const Node = struct {
    pos: [3]f32,        // Position
    cost: f32,          // Cost from start
    total: f32,         // cost + heuristic
    pidx: u32,          // Parent node index
    state: u8,          // OPEN/CLOSED
    flags: u8,          // Flags
    id: PolyRef,        // Polygon ref
};

pub const NodePool = struct {
    nodes: []Node,      // Node array
    first: []u32,       // Hash table
    next: []u32,        // Next in hash chain
    max_nodes: u32,
    hash_size: u32,
    node_count: u32,
};
```

**Open List (Priority Queue):**
```zig
pub const NodeQueue = struct {
    heap: []*Node,      // Min-heap
    capacity: usize,
    size: usize,

    // Push with O(log n)
    pub fn push(self: *Self, node: *Node) void {
        self.heap[self.size] = node;
        self.bubbleUp(self.size, node);
        self.size += 1;
    }

    // Pop with O(log n)
    pub fn pop(self: *Self) ?*Node {
        if (self.size == 0) return null;
        const top = self.heap[0];
        self.size -= 1;
        self.trickleDown(0, self.heap[self.size]);
        return top;
    }
};
```

---

### Stage 4: Spatial Queries

**Цель:** Найти polygons в области

#### 4.1 Find Nearest Polygon

```zig
pub fn findNearestPoly(
    self: *const NavMeshQuery,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    filter: *const QueryFilter,
    nearest_ref: *PolyRef,
    nearest_pt: ?*[3]f32,
) !void {
    // 1. Query polygons in AABB
    var polys: [128]PolyRef = undefined;
    var poly_count: usize = 0;
    try self.queryPolygons(center, half_extents, filter, &polys, &poly_count);

    // 2. Find nearest among candidates
    var nearest_dist_sqr: f32 = std.math.floatMax(f32);

    for (0..poly_count) |i| {
        const ref = polys[i];
        var closest_pt: [3]f32 = undefined;
        var pos_over_poly: bool = false;

        // Closest point on polygon
        nav.closestPointOnPoly(ref, center, &closest_pt, &pos_over_poly) catch continue;

        // Calculate distance
        const d = if (pos_over_poly)
            verticalDistanceWithClimb(center, &closest_pt, climb)
        else
            euclideanDistanceSqr(center, &closest_pt);

        if (d < nearest_dist_sqr) {
            nearest_dist_sqr = d;
            nearest_ref.* = ref;
            if (nearest_pt) |pt| pt.* = closest_pt;
        }
    }
}
```

#### 4.2 Query Polygons (BVH Traversal)

```zig
fn queryPolygons(
    self: *const NavMeshQuery,
    center: *const [3]f32,
    half_extents: *const [3]f32,
    filter: *const QueryFilter,
    polys: []PolyRef,
    poly_count: *usize,
) !void {
    // Query AABB
    const qmin = [3]f32{
        center[0] - half_extents[0],
        center[1] - half_extents[1],
        center[2] - half_extents[2],
    };
    const qmax = [3]f32{
        center[0] + half_extents[0],
        center[1] + half_extents[1],
        center[2] + half_extents[2],
    };

    // For each tile
    for (nav.tiles) |*tile| {
        if (tile.header == null) continue;

        // Query BVH tree
        try queryPolygonsInTile(tile, &qmin, &qmax, filter, polys, poly_count);
    }
}

fn queryPolygonsInTile(
    tile: *const MeshTile,
    qmin: *const [3]f32,
    qmax: *const [3]f32,
    filter: *const QueryFilter,
    polys: []PolyRef,
    poly_count: *usize,
) !void {
    if (tile.bv_tree.len == 0) {
        // No BVH - linear search
        for (0..tile.header.?.poly_count) |i| {
            // Check filter and bounds
            // ...
        }
        return;
    }

    // BVH tree traversal (depth-first)
    const base_ref = nav.getPolyRefBase(tile);
    var node_idx: usize = 0;

    while (node_idx < tile.bv_tree.len) {
        const node = &tile.bv_tree[node_idx];

        // Check AABB overlap
        const overlap = overlapQuantBounds(qmin, qmax, node.bmin, node.bmax);

        if (overlap) {
            if (node.i >= 0) {
                // Leaf - check polygon
                const ref = base_ref | @as(u64, @intCast(node.i));

                if (filter.passFilter(ref, tile, &tile.polys[node.i])) {
                    if (poly_count.* < polys.len) {
                        polys[poly_count.*] = ref;
                        poly_count.* += 1;
                    }
                }

                node_idx += 1;
            } else {
                // Internal node - descend left
                node_idx = @intCast(-node.i);
            }
        } else {
            // No overlap - skip subtree
            node_idx = escapeNode(node_idx, node);
        }
    }
}
```

---

### Stage 5: A* Pathfinding

**Цель:** Найти optimal path между двумя точками

**A* Algorithm:**
```zig
pub fn findPath(
    self: *NavMeshQuery,
    start_ref: PolyRef,
    end_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    path: []PolyRef,
) !usize {
    // 1. Validate input
    if (start_ref == 0 or end_ref == 0) return 0;

    // 2. Initialize
    const node_pool = self.node_pool.?;
    const open_list = self.open_list.?;

    node_pool.clear();
    open_list.clear();

    // 3. Add start node
    var start_node = node_pool.getNode(start_ref);
    start_node.pos = start_pos.*;
    start_node.pidx = 0;
    start_node.cost = 0;
    start_node.total = heuristic(start_pos, end_pos);
    start_node.id = start_ref;
    start_node.flags = NODE_OPEN;

    open_list.push(start_node);

    var last_best_node = start_node;
    var last_best_node_cost = start_node.total;

    // 4. A* main loop
    while (!open_list.isEmpty()) {
        // Get node with minimum f = g + h
        const best_node = open_list.pop().?;
        best_node.flags &= ~NODE_OPEN;
        best_node.flags |= NODE_CLOSED;

        // Found goal
        if (best_node.id == end_ref) {
            last_best_node = best_node;
            break;
        }

        // Get polygon
        const result = nav.getTileAndPolyByRef(best_node.id) catch continue;
        const tile = result.tile;
        const poly = result.poly;

        // Expand neighbors
        var i = poly.first_link;
        while (i != NULL_LINK) : (i = tile.links[i].next) {
            const link = &tile.links[i];
            const neighbor_ref = link.ref;

            // Skip if filtered
            if (!filter.passFilter(neighbor_ref, ...)) continue;

            const neighbor_node = node_pool.getNode(neighbor_ref);

            // Calculate cost
            const edge_midpoint = calculateEdgeMidpoint(tile, poly, link.edge);
            const cost_to_neighbor = best_node.cost +
                filter.getCost(&best_node.pos, &edge_midpoint, ...);

            // Better path found?
            if ((neighbor_node.flags & NODE_CLOSED) == 0 or
                cost_to_neighbor < neighbor_node.cost)
            {
                neighbor_node.pidx = node_pool.getNodeIdx(best_node);
                neighbor_node.cost = cost_to_neighbor;
                neighbor_node.total = cost_to_neighbor +
                    heuristic(&edge_midpoint, end_pos);
                neighbor_node.id = neighbor_ref;
                neighbor_node.pos = edge_midpoint;

                if ((neighbor_node.flags & NODE_OPEN) != 0) {
                    // Already in open list - update
                    open_list.modify(neighbor_node);
                } else {
                    // Add to open list
                    neighbor_node.flags |= NODE_OPEN;
                    open_list.push(neighbor_node);
                }

                // Track best node
                if (neighbor_node.total < last_best_node_cost) {
                    last_best_node = neighbor_node;
                    last_best_node_cost = neighbor_node.total;
                }
            }
        }
    }

    // 5. Reconstruct path
    return reconstructPath(last_best_node, node_pool, path);
}

// Heuristic: Euclidean distance
fn heuristic(pos1: *const [3]f32, pos2: *const [3]f32) f32 {
    const dx = pos2[0] - pos1[0];
    const dy = pos2[1] - pos1[1];
    const dz = pos2[2] - pos1[2];
    return @sqrt(dx * dx + dy * dy + dz * dz);
}
```

**Path Reconstruction:**
```zig
fn reconstructPath(
    end_node: *Node,
    node_pool: *NodePool,
    path: []PolyRef,
) usize {
    // Count path length
    var cur_node: ?*Node = end_node;
    var length: usize = 0;

    while (cur_node != null) {
        length += 1;
        const pidx = cur_node.?.pidx;
        if (pidx == 0) break;
        cur_node = node_pool.getNodeAtIdx(pidx);
    }

    // Write path in reverse
    cur_node = end_node;
    var i: usize = @min(length, path.len);

    while (i > 0) {
        i -= 1;
        path[i] = cur_node.?.id;
        const pidx = cur_node.?.pidx;
        if (pidx == 0) break;
        cur_node = node_pool.getNodeAtIdx(pidx);
    }

    return @min(length, path.len);
}
```

---

### Stage 6: String Pulling (Straight Path)

**Цель:** Преобразовать polygon path в waypoint path

**String Pulling Algorithm:**
```zig
pub fn findStraightPath(
    self: *const NavMeshQuery,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    path: []const PolyRef,
    straight_path: []f32,
    straight_path_flags: ?[]u8,
    straight_path_refs: ?[]PolyRef,
    straight_path_count: *usize,
    options: u32,
) !void {
    straight_path_count.* = 0;

    // Start position
    straight_path[0..3].* = start_pos.*;
    if (straight_path_flags) |flags| flags[0] = DT_STRAIGHTPATH_START;
    if (straight_path_refs) |refs| refs[0] = path[0];
    var n_straight: usize = 1;

    // Portal funnel algorithm
    var portal_apex = start_pos.*;
    var portal_left = start_pos.*;
    var portal_right = start_pos.*;
    var apex_index: usize = 0;
    var left_index: usize = 0;
    var right_index: usize = 0;

    for (0..path.len) |i| {
        var left: [3]f32 = undefined;
        var right: [3]f32 = undefined;

        if (i + 1 < path.len) {
            // Get portal points
            try self.getPortalPoints(path[i], path[i + 1], &left, &right, ...);
        } else {
            // Last segment - use end position
            left = end_pos.*;
            right = end_pos.*;
        }

        // Right vertex
        if (triArea2D(&portal_apex, &portal_right, &right) <= 0.0) {
            if (vequal(&portal_apex, &portal_right) or
                triArea2D(&portal_apex, &portal_left, &right) > 0.0)
            {
                // Tighten the funnel
                portal_right = right;
                right_index = i;
            } else {
                // Right over left - insert left to path and restart
                appendVertex(&straight_path, &n_straight, &portal_left, ...);

                // Restart from left
                portal_apex = portal_left;
                apex_index = left_index;
                portal_left = portal_apex;
                portal_right = portal_apex;
                left_index = apex_index;
                right_index = apex_index;
                continue;
            }
        }

        // Left vertex (symmetric)
        if (triArea2D(&portal_apex, &portal_left, &left) >= 0.0) {
            if (vequal(&portal_apex, &portal_left) or
                triArea2D(&portal_apex, &portal_right, &left) < 0.0)
            {
                portal_left = left;
                left_index = i;
            } else {
                // Left over right - insert right to path and restart
                appendVertex(&straight_path, &n_straight, &portal_right, ...);

                portal_apex = portal_right;
                apex_index = right_index;
                portal_left = portal_apex;
                portal_right = portal_apex;
                left_index = apex_index;
                right_index = apex_index;
                continue;
            }
        }
    }

    // Append end position
    appendVertex(&straight_path, &n_straight, end_pos, ...);

    straight_path_count.* = n_straight;
}

// 2D triangle area (для orientation test)
fn triArea2D(a: *const [3]f32, b: *const [3]f32, c: *const [3]f32) f32 {
    const abx = b[0] - a[0];
    const abz = b[2] - a[2];
    const acx = c[0] - a[0];
    const acz = c[2] - a[2];
    return acx * abz - abx * acz;
}
```

---

### Stage 7: Raycast

**Цель:** Line-of-sight check и hit detection

**Raycast Algorithm:**
```zig
pub fn raycast(
    self: *const NavMeshQuery,
    start_ref: PolyRef,
    start_pos: *const [3]f32,
    end_pos: *const [3]f32,
    filter: *const QueryFilter,
    options: u32,
    hit: *RaycastHit,
    prev_ref: PolyRef,
) !Status {
    hit.t = 0;
    hit.path_count = 0;
    hit.path_cost = 0;

    // Ray direction
    const dir = [3]f32{
        end_pos[0] - start_pos[0],
        end_pos[1] - start_pos[1],
        end_pos[2] - start_pos[2],
    };

    var cur_ref = start_ref;

    // Traverse polygons along ray
    while (cur_ref != 0) {
        const result = try nav.getTileAndPolyByRef(cur_ref);
        const tile = result.tile;
        const poly = result.poly;

        // Get polygon vertices
        var verts: [MAX_VERTS * 3]f32 = undefined;
        const nv = poly.vert_count;
        for (0..nv) |i| {
            const v_idx = poly.verts[i] * 3;
            verts[i * 3 .. i * 3 + 3].* = tile.verts[v_idx .. v_idx + 3].*;
        }

        // Intersect ray with polygon
        var tmin: f32 = undefined;
        var tmax: f32 = undefined;
        var seg_min: i32 = undefined;
        var seg_max: i32 = undefined;

        const intersect = intersectSegmentPoly2D(
            start_pos, end_pos, verts[0..nv*3], nv,
            &tmin, &tmax, &seg_min, &seg_max
        );

        if (!intersect) {
            // Ray does not intersect - report hit
            hit.path_count = n;
            return .{ .success = true };
        }

        // Update furthest t
        if (tmax > hit.t) {
            hit.t = tmax;
        }

        // Store visited polygon
        hit.path[n] = cur_ref;
        n += 1;

        // Ray end inside polygon?
        if (seg_max == -1) {
            hit.t = std.math.floatMax(f32);  // No hit
            hit.path_count = n;
            return .{ .success = true };
        }

        // Calculate hit normal
        calculateHitNormal(verts[0..nv*3], seg_max, &hit.hit_normal);

        // Find next polygon
        var next_ref: PolyRef = 0;
        var i = poly.first_link;

        while (i != NULL_LINK) : (i = tile.links[i].next) {
            const link = &tile.links[i];

            // Link contains hit edge?
            if (@as(i32, link.edge) == seg_max) {
                const next_result = try nav.getTileAndPolyByRef(link.ref);

                // Skip off-mesh connections
                if (next_result.poly.getType() == .offmesh_connection) continue;

                // Skip filtered
                if (!filter.passFilter(link.ref, next_result.tile, next_result.poly)) continue;

                next_ref = link.ref;
                break;
            }
        }

        // Move to next polygon
        prev_ref = cur_ref;
        cur_ref = next_ref;
    }

    // Hit boundary
    hit.path_count = n;
    return .{ .success = true };
}
```

**Hit Normal Calculation:**
```zig
fn calculateHitNormal(
    verts: []const f32,
    seg: i32,
    normal: *[3]f32,
) void {
    const v0_idx = @as(usize, @intCast(seg)) * 3;
    const v1_idx = @as(usize, @intCast((seg + 1) % (verts.len / 3))) * 3;

    const v0 = verts[v0_idx .. v0_idx + 3];
    const v1 = verts[v1_idx .. v1_idx + 3];

    // Edge vector
    const dx = v1[0] - v0[0];
    const dz = v1[2] - v0[2];

    // Normal (perpendicular in XZ plane, pointing outward)
    normal[0] = dz;
    normal[1] = 0;
    normal[2] = -dx;

    // Normalize
    const len = @sqrt(normal[0] * normal[0] + normal[2] * normal[2]);
    if (len > 0) {
        normal[0] /= len;
        normal[2] /= len;
    }
}
```

---

## QueryFilter & Cost Modification

**QueryFilter:**
```zig
pub const QueryFilter = struct {
    area_cost: [MAX_AREAS]f32,  // Cost multiplier per area
    include_flags: u16,          // Include polygons with these flags
    exclude_flags: u16,          // Exclude polygons with these flags

    pub fn init() QueryFilter {
        var filter = QueryFilter{
            .area_cost = undefined,
            .include_flags = 0xffff,
            .exclude_flags = 0,
        };
        // Default area costs = 1.0
        for (0..MAX_AREAS) |i| {
            filter.area_cost[i] = 1.0;
        }
        return filter;
    }

    pub fn passFilter(
        self: *const QueryFilter,
        ref: PolyRef,
        tile: *const MeshTile,
        poly: *const Poly,
    ) bool {
        // Check include flags
        if ((poly.flags & self.include_flags) == 0) return false;

        // Check exclude flags
        if ((poly.flags & self.exclude_flags) != 0) return false;

        return true;
    }

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
        // Euclidean distance
        const dx = pb[0] - pa[0];
        const dy = pb[1] - pa[1];
        const dz = pb[2] - pa[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);

        // Apply area cost
        return dist * self.area_cost[cur_poly.getArea()];
    }
};
```

**Custom Filter Example:**
```zig
// Custom filter для избежания water
var filter = QueryFilter.init();

// Water area (ID = 10) имеет высокую стоимость
filter.setAreaCost(10, 10.0);  // 10x cost

// Grass area (ID = 5) дешевле
filter.setAreaCost(5, 0.5);    // 0.5x cost

// Exclude polygons with DISABLED flag
filter.setExcludeFlags(POLYFLAGS_DISABLED);
```

---

## Performance Characteristics

### Time Complexity

| Operation | Complexity | Notes |
|-----------|------------|-------|
| findNearestPoly | O(log N + K) | N=polys in tile, K=candidates |
| queryPolygons | O(log N + M) | BVH traversal, M=results |
| findPath | O(E × log V) | E=edges, V=visited nodes |
| findStraightPath | O(P) | P=polygon path length |
| raycast | O(T) | T=traversed polygons |

### Memory Usage

| Structure | Size | Notes |
|-----------|------|-------|
| NavMesh (single tile) | ~100-500 KB | Depends on poly count |
| NavMeshQuery | ~100-200 KB | 2048 nodes pool |
| Node | 44 bytes | A* node |
| NodePool (2048) | ~90 KB | Main pool |

### A* Performance

```
Typical pathfinding:
- 10-100 polygons visited
- <1ms on modern CPU
- ~50-200 nodes allocated

Long paths:
- 500-2000 polygons
- 1-5ms
- Limited by node pool size (2048)
```

---

## Best Practices

### 1. Node Pool Sizing

```zig
// Small environments
const max_nodes = 512;

// Medium environments
const max_nodes = 2048;  // Default

// Large open worlds
const max_nodes = 8192;
```

### 2. Filter Configuration

```zig
// Optimize for specific agent types
var filter = QueryFilter.init();

// Flying unit - ignore ground costs
filter.setAreaCost(AREA_GROUND, 1.0);
filter.setAreaCost(AREA_WATER, 1.0);

// Ground unit - avoid water
filter.setAreaCost(AREA_WATER, 100.0);
```

### 3. Query Extents

```zig
// Tight extents для precision
const extents = [3]f32{ 0.5, 2.0, 0.5 };

// Loose extents для tolerance
const extents = [3]f32{ 5.0, 10.0, 5.0 };
```

### 4. Straight Path Options

```zig
// Include start/end
const options = DT_STRAIGHTPATH_ALL_CROSSINGS;

// Only waypoints
const options = DT_STRAIGHTPATH_AREA_CROSSINGS;
```

---

## Common Patterns

### Pattern 1: Basic Pathfinding

```zig
// 1. Find start/end polygons
var start_ref: PolyRef = 0;
var end_ref: PolyRef = 0;
try query.findNearestPoly(&start_pos, &extents, &filter, &start_ref, null);
try query.findNearestPoly(&end_pos, &extents, &filter, &end_ref, null);

// 2. Find polygon path
var poly_path: [256]PolyRef = undefined;
const poly_count = try query.findPath(
    start_ref, end_ref, &start_pos, &end_pos, &filter, &poly_path
);

// 3. Convert to waypoints
var waypoints: [256 * 3]f32 = undefined;
var waypoint_count: usize = 0;
_ = try query.findStraightPath(
    &start_pos, &end_pos, poly_path[0..poly_count],
    &waypoints, null, null, &waypoint_count, 0
);
```

### Pattern 2: Raycast for Vision

```zig
var hit = RaycastHit{
    .t = 0,
    .hit_normal = .{ 0, 0, 0 },
    .path = undefined,
    .path_count = 0,
    .path_cost = 0,
    .hit_edge_index = 0,
};

const status = try query.raycast(
    start_ref, &start_pos, &end_pos, &filter, 0, &hit, 0
);

if (hit.t == std.math.floatMax(f32)) {
    // No hit - line of sight clear
} else {
    // Hit at t, blocked
    const hit_pos = [3]f32{
        start_pos[0] + hit.t * (end_pos[0] - start_pos[0]),
        start_pos[1] + hit.t * (end_pos[1] - start_pos[1]),
        start_pos[2] + hit.t * (end_pos[2] - start_pos[2]),
    };
}
```

### Pattern 3: Query Nearby Entities

```zig
var nearby: [128]PolyRef = undefined;
var nearby_count: usize = 0;

try query.queryPolygons(
    &center, &search_radius, &filter, &nearby, &nearby_count
);

// Process nearby polygons
for (nearby[0..nearby_count]) |poly_ref| {
    // Check entity positions in this polygon
}
```

---

## Debugging Tips

### Visualize Queries

```zig
// Log polygon path
std.debug.print("Path: ", .{});
for (poly_path[0..poly_count]) |ref| {
    std.debug.print("{} → ", .{ref});
}
std.debug.print("END\n", .{});

// Log waypoints
for (0..waypoint_count) |i| {
    const idx = i * 3;
    std.debug.print("Waypoint {}: ({d:.2}, {d:.2}, {d:.2})\n", .{
        i,
        waypoints[idx],
        waypoints[idx + 1],
        waypoints[idx + 2],
    });
}
```

### Common Issues

**Empty path:**
- Start/end refs are 0 (not found)
- Start and end are in different unconnected regions
- Filter excludes path polygons

**Path too long:**
- Increase node pool size
- Add area costs to guide A*
- Use sliced pathfinding for very long paths

**Raycast misses:**
- Check polygon winding order
- Verify start_ref is correct
- Inspect perp2D calculation (bug #3 from raycast-fix)

---

## Next Steps

- 📖 [Memory Model](memory-model.md) - управление памятью в Detour
- 🔍 [Pathfinding Guide](../04-guides/pathfinding.md) - практическое руководство
- 🎯 [Raycast Guide](../04-guides/raycast.md) - raycast использование

---

## References

- [A* Algorithm](https://en.wikipedia.org/wiki/A*_search_algorithm)
- [Simple Stupid Funnel Algorithm](http://digestingduck.blogspot.com/2010/03/simple-stupid-funnel-algorithm.html)
- [BVH Trees](https://en.wikipedia.org/wiki/Bounding_volume_hierarchy)
