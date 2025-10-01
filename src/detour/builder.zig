// NavMesh builder for Detour
const std = @import("std");
const common = @import("common.zig");
const navmesh = @import("navmesh.zig");
const math = @import("../math.zig");

const Vec3 = math.Vec3;

const MeshHeader = navmesh.MeshHeader;
const Poly = navmesh.Poly;
const PolyDetail = navmesh.PolyDetail;
const BVNode = navmesh.BVNode;
const OffMeshConnection = navmesh.OffMeshConnection;
const Link = navmesh.Link;

// Constants
const DT_NAVMESH_MAGIC = common.NAVMESH_MAGIC;
const DT_NAVMESH_VERSION = common.NAVMESH_VERSION;
const DT_VERTS_PER_POLYGON = common.VERTS_PER_POLYGON;
const DT_EXT_LINK = common.EXT_LINK;
const PolyType = common.PolyType;
const MESH_NULL_IDX: u16 = 0xffff;

/// Off-mesh connection flag - bidirectional
pub const DT_OFFMESH_CON_BIDIR: u8 = 1;

/// NavMesh creation parameters
pub const NavMeshCreateParams = struct {
    // Polygon mesh data
    verts: []const u16, // Vertex data (x, y, z) triplets
    vert_count: usize,
    polys: []const u16, // Polygon data (verts + neighbors)
    poly_flags: []const u16, // Polygon flags
    poly_areas: []const u8, // Polygon area IDs
    poly_count: usize,
    nvp: usize, // Max verts per polygon

    // Detail mesh data (optional)
    detail_meshes: ?[]const u32 = null, // Detail mesh data (vert base, vert count, tri base, tri count)
    detail_verts: ?[]const f32 = null, // Detail vertex positions
    detail_verts_count: usize = 0,
    detail_tris: ?[]const u8 = null, // Detail triangle data
    detail_tri_count: usize = 0,

    // Off-mesh connections (optional)
    off_mesh_con_verts: ?[]const f32 = null, // Off-mesh connection vertices (2 per connection)
    off_mesh_con_rad: ?[]const f32 = null, // Off-mesh connection radii
    off_mesh_con_flags: ?[]const u16 = null, // Off-mesh connection flags
    off_mesh_con_areas: ?[]const u8 = null, // Off-mesh connection area IDs
    off_mesh_con_dir: ?[]const u8 = null, // Off-mesh connection directions (0=one-way, 1=bidirectional)
    off_mesh_con_user_id: ?[]const u32 = null, // Off-mesh connection user IDs
    off_mesh_con_count: usize = 0,

    // Tile location
    tile_x: i32 = 0,
    tile_y: i32 = 0,
    tile_layer: i32 = 0,

    // Bounds
    bmin: [3]f32,
    bmax: [3]f32,

    // Agent parameters
    walkable_height: f32,
    walkable_radius: f32,
    walkable_climb: f32,

    // Cell size
    cs: f32, // XZ plane cell size
    ch: f32, // Y-axis cell size

    // Build flags
    build_bv_tree: bool = true,

    // User data
    user_id: u32 = 0,
};

// ============================================================================
// BVTree building
// ============================================================================

/// BV item for tree construction
const BVItem = struct {
    bmin: [3]u16,
    bmax: [3]u16,
    i: i32,
};

/// Compare BV items by X coordinate
fn compareItemX(_: void, a: BVItem, b: BVItem) bool {
    return a.bmin[0] < b.bmin[0];
}

/// Compare BV items by Y coordinate
fn compareItemY(_: void, a: BVItem, b: BVItem) bool {
    return a.bmin[1] < b.bmin[1];
}

/// Compare BV items by Z coordinate
fn compareItemZ(_: void, a: BVItem, b: BVItem) bool {
    return a.bmin[2] < b.bmin[2];
}

/// Calculate extends for BV items
fn calcExtends(items: []const BVItem, imin: usize, imax: usize, bmin: *[3]u16, bmax: *[3]u16) void {
    bmin.* = items[imin].bmin;
    bmax.* = items[imin].bmax;

    for (items[imin + 1 .. imax]) |it| {
        bmin[0] = @min(bmin[0], it.bmin[0]);
        bmin[1] = @min(bmin[1], it.bmin[1]);
        bmin[2] = @min(bmin[2], it.bmin[2]);

        bmax[0] = @max(bmax[0], it.bmax[0]);
        bmax[1] = @max(bmax[1], it.bmax[1]);
        bmax[2] = @max(bmax[2], it.bmax[2]);
    }
}

/// Find longest axis
inline fn longestAxis(x: u16, y: u16, z: u16) usize {
    var axis: usize = 0;
    var max_val = x;
    if (y > max_val) {
        axis = 1;
        max_val = y;
    }
    if (z > max_val) {
        axis = 2;
    }
    return axis;
}

/// Subdivide BV tree recursively
fn subdivide(items: []BVItem, imin: usize, imax: usize, cur_node: *usize, nodes: []BVNode) void {
    const inum = imax - imin;
    const icur = cur_node.*;

    var node = &nodes[cur_node.*];
    cur_node.* += 1;

    if (inum == 1) {
        // Leaf
        node.bmin = items[imin].bmin;
        node.bmax = items[imin].bmax;
        node.i = items[imin].i;
    } else {
        // Split
        calcExtends(items, imin, imax, &node.bmin, &node.bmax);

        const axis = longestAxis(
            node.bmax[0] -% node.bmin[0],
            node.bmax[1] -% node.bmin[1],
            node.bmax[2] -% node.bmin[2],
        );

        if (axis == 0) {
            std.mem.sort(BVItem, items[imin..imax], {}, compareItemX);
        } else if (axis == 1) {
            std.mem.sort(BVItem, items[imin..imax], {}, compareItemY);
        } else {
            std.mem.sort(BVItem, items[imin..imax], {}, compareItemZ);
        }

        const isplit = imin + inum / 2;

        // Left
        subdivide(items, imin, isplit, cur_node, nodes);
        // Right
        subdivide(items, isplit, imax, cur_node, nodes);

        const iescape: i32 = @intCast(cur_node.* - icur);
        node.i = -iescape;
    }
}

/// Create BV tree for navigation mesh
fn createBVTree(params: *const NavMeshCreateParams, nodes: []BVNode, items: []BVItem) usize {
    const quant_factor = 1.0 / params.cs;

    // Build items
    for (0..params.poly_count) |i| {
        var it = &items[i];
        it.i = @intCast(i);

        // Calculate polygon bounds
        if (params.detail_meshes) |detail_meshes| {
            const vb = detail_meshes[i * 4 + 0];
            const ndv = detail_meshes[i * 4 + 1];

            const detail_verts = params.detail_verts.?;
            var bmin = [3]f32{
                detail_verts[vb * 3 + 0],
                detail_verts[vb * 3 + 1],
                detail_verts[vb * 3 + 2],
            };
            var bmax = bmin;

            for (1..ndv) |j| {
                const idx = (vb + j) * 3;
                bmin[0] = @min(bmin[0], detail_verts[idx + 0]);
                bmin[1] = @min(bmin[1], detail_verts[idx + 1]);
                bmin[2] = @min(bmin[2], detail_verts[idx + 2]);

                bmax[0] = @max(bmax[0], detail_verts[idx + 0]);
                bmax[1] = @max(bmax[1], detail_verts[idx + 1]);
                bmax[2] = @max(bmax[2], detail_verts[idx + 2]);
            }

            it.bmin[0] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmin[0] - params.bmin[0]) * quant_factor)), 0, 0xffff));
            it.bmin[1] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmin[1] - params.bmin[1]) * quant_factor)), 0, 0xffff));
            it.bmin[2] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmin[2] - params.bmin[2]) * quant_factor)), 0, 0xffff));

            it.bmax[0] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmax[0] - params.bmin[0]) * quant_factor)), 0, 0xffff));
            it.bmax[1] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmax[1] - params.bmin[1]) * quant_factor)), 0, 0xffff));
            it.bmax[2] = @intCast(std.math.clamp(@as(i32, @intFromFloat((bmax[2] - params.bmin[2]) * quant_factor)), 0, 0xffff));
        } else {
            const p = params.polys[i * params.nvp * 2 ..];
            const v0_idx = p[0] * 3;
            it.bmin[0] = params.verts[v0_idx + 0];
            it.bmin[1] = params.verts[v0_idx + 1];
            it.bmin[2] = params.verts[v0_idx + 2];
            it.bmax = it.bmin;

            for (1..params.nvp) |j| {
                if (p[j] == MESH_NULL_IDX) break;
                const v_idx = p[j] * 3;
                const x = params.verts[v_idx + 0];
                const y = params.verts[v_idx + 1];
                const z = params.verts[v_idx + 2];

                it.bmin[0] = @min(it.bmin[0], x);
                it.bmin[1] = @min(it.bmin[1], y);
                it.bmin[2] = @min(it.bmin[2], z);

                it.bmax[0] = @max(it.bmax[0], x);
                it.bmax[1] = @max(it.bmax[1], y);
                it.bmax[2] = @max(it.bmax[2], z);
            }

            // Remap y
            it.bmin[1] = @intFromFloat(@floor(@as(f32, @floatFromInt(it.bmin[1])) * params.ch / params.cs));
            it.bmax[1] = @intFromFloat(@ceil(@as(f32, @floatFromInt(it.bmax[1])) * params.ch / params.cs));
        }
    }

    var cur_node: usize = 0;
    subdivide(items, 0, params.poly_count, &cur_node, nodes);

    return cur_node;
}

// ============================================================================
// Off-mesh connection classification
// ============================================================================

/// Classify off-mesh connection point
fn classifyOffMeshPoint(pt: *const [3]f32, bmin: *const [3]f32, bmax: *const [3]f32) u8 {
    const XP: u8 = 1 << 0;
    const ZP: u8 = 1 << 1;
    const XM: u8 = 1 << 2;
    const ZM: u8 = 1 << 3;

    var outcode: u8 = 0;
    if (pt[0] >= bmax[0]) outcode |= XP;
    if (pt[2] >= bmax[2]) outcode |= ZP;
    if (pt[0] < bmin[0]) outcode |= XM;
    if (pt[2] < bmin[2]) outcode |= ZM;

    return switch (outcode) {
        XP => 0,
        XP | ZP => 1,
        ZP => 2,
        XM | ZP => 3,
        XM => 4,
        XM | ZM => 5,
        ZM => 6,
        XP | ZM => 7,
        else => 0xff,
    };
}

// ============================================================================
// Main NavMesh creation
// ============================================================================

/// Align to 4-byte boundary
inline fn align4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

/// Create navigation mesh data from input geometry
pub fn createNavMeshData(
    params: *const NavMeshCreateParams,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (params.nvp > DT_VERTS_PER_POLYGON) return error.TooManyVertsPerPoly;
    if (params.vert_count >= 0xffff) return error.TooManyVerts;
    if (params.vert_count == 0 or params.verts.len == 0) return error.NoVerts;
    if (params.poly_count == 0 or params.polys.len == 0) return error.NoPolys;

    const nvp = params.nvp;

    // Classify off-mesh connections
    var off_mesh_con_class_buf: [1024]u8 = undefined;
    var off_mesh_con_class: []u8 = &[_]u8{};
    var stored_off_mesh_con_count: usize = 0;
    var off_mesh_con_link_count: usize = 0;

    if (params.off_mesh_con_count > 0) {
        if (params.off_mesh_con_count * 2 > off_mesh_con_class_buf.len) {
            off_mesh_con_class = try allocator.alloc(u8, params.off_mesh_con_count * 2);
        } else {
            off_mesh_con_class = off_mesh_con_class_buf[0 .. params.off_mesh_con_count * 2];
        }
        defer if (off_mesh_con_class.ptr != &off_mesh_con_class_buf) allocator.free(off_mesh_con_class);

        // Find tight height bounds
        var hmin: f32 = std.math.floatMax(f32);
        var hmax: f32 = -std.math.floatMax(f32);

        if (params.detail_verts != null and params.detail_verts_count > 0) {
            const detail_verts = params.detail_verts.?;
            for (0..params.detail_verts_count) |i| {
                const h = detail_verts[i * 3 + 1];
                hmin = @min(hmin, h);
                hmax = @max(hmax, h);
            }
        } else {
            for (0..params.vert_count) |i| {
                const iv = params.verts[i * 3 ..];
                const h = params.bmin[1] + @as(f32, @floatFromInt(iv[1])) * params.ch;
                hmin = @min(hmin, h);
                hmax = @max(hmax, h);
            }
        }

        hmin -= params.walkable_climb;
        hmax += params.walkable_climb;

        var bmin = params.bmin;
        var bmax = params.bmax;
        bmin[1] = hmin;
        bmax[1] = hmax;

        const off_mesh_verts = params.off_mesh_con_verts.?;
        for (0..params.off_mesh_con_count) |i| {
            const p0 = off_mesh_verts[(i * 2 + 0) * 3 ..][0..3];
            const p1 = off_mesh_verts[(i * 2 + 1) * 3 ..][0..3];

            off_mesh_con_class[i * 2 + 0] = classifyOffMeshPoint(p0, &bmin, &bmax);
            off_mesh_con_class[i * 2 + 1] = classifyOffMeshPoint(p1, &bmin, &bmax);

            // Zero out positions not touching the mesh
            if (off_mesh_con_class[i * 2 + 0] == 0xff) {
                if (p0[1] < bmin[1] or p0[1] > bmax[1]) {
                    off_mesh_con_class[i * 2 + 0] = 0;
                }
            }

            // Count links
            if (off_mesh_con_class[i * 2 + 0] == 0xff) off_mesh_con_link_count += 1;
            if (off_mesh_con_class[i * 2 + 1] == 0xff) off_mesh_con_link_count += 1;

            if (off_mesh_con_class[i * 2 + 0] == 0xff) stored_off_mesh_con_count += 1;
        }
    }

    // Off-mesh connections stored as polygons
    const tot_poly_count = params.poly_count + stored_off_mesh_con_count;
    const tot_vert_count = params.vert_count + stored_off_mesh_con_count * 2;

    // Find portal edges at tile borders
    var edge_count: usize = 0;
    var portal_count: usize = 0;

    for (0..params.poly_count) |i| {
        const p = params.polys[i * 2 * nvp ..];
        for (0..nvp) |j| {
            if (p[j] == MESH_NULL_IDX) break;
            edge_count += 1;

            if ((p[nvp + j] & 0x8000) != 0) {
                const dir = p[nvp + j] & 0xf;
                if (dir != 0xf) {
                    portal_count += 1;
                }
            }
        }
    }

    const max_link_count = edge_count + portal_count * 2 + off_mesh_con_link_count * 2;

    // Find unique detail vertices
    var unique_detail_vert_count: usize = 0;
    var detail_tri_count: usize = 0;

    if (params.detail_meshes) |detail_meshes| {
        detail_tri_count = params.detail_tri_count;
        for (0..params.poly_count) |i| {
            const p = params.polys[i * nvp * 2 ..];
            const ndv = detail_meshes[i * 4 + 1];
            var nv: usize = 0;
            for (0..nvp) |j| {
                if (p[j] == MESH_NULL_IDX) break;
                nv += 1;
            }
            unique_detail_vert_count += ndv - nv;
        }
    } else {
        for (0..params.poly_count) |i| {
            const p = params.polys[i * nvp * 2 ..];
            var nv: usize = 0;
            for (0..nvp) |j| {
                if (p[j] == MESH_NULL_IDX) break;
                nv += 1;
            }
            detail_tri_count += nv - 2;
        }
    }

    // Calculate data sizes
    const header_size = align4(@sizeOf(MeshHeader));
    const verts_size = align4(@sizeOf(f32) * 3 * tot_vert_count);
    const polys_size = align4(@sizeOf(Poly) * tot_poly_count);
    const links_size = align4(@sizeOf(Link) * max_link_count);
    const detail_meshes_size = align4(@sizeOf(PolyDetail) * params.poly_count);
    const detail_verts_size = align4(@sizeOf(f32) * 3 * unique_detail_vert_count);
    const detail_tris_size = align4(@sizeOf(u8) * 4 * detail_tri_count);
    const bv_tree_size = if (params.build_bv_tree) align4(@sizeOf(BVNode) * params.poly_count * 2) else 0;
    const off_mesh_cons_size = align4(@sizeOf(OffMeshConnection) * stored_off_mesh_con_count);

    const data_size = header_size + verts_size + polys_size + links_size +
        detail_meshes_size + detail_verts_size + detail_tris_size +
        bv_tree_size + off_mesh_cons_size;

    const data = try allocator.alloc(u8, data_size);
    @memset(data, 0);

    // Get pointers to different sections
    var d: [*]u8 = data.ptr;
    const header: *MeshHeader = @ptrCast(@alignCast(d));
    d += header_size;
    const nav_verts: [*]f32 = @ptrCast(@alignCast(d));
    d += verts_size;
    const nav_polys: [*]Poly = @ptrCast(@alignCast(d));
    d += polys_size;
    d += links_size; // Skip links, created on tile add
    const nav_d_meshes: [*]PolyDetail = @ptrCast(@alignCast(d));
    d += detail_meshes_size;
    const nav_d_verts: [*]f32 = @ptrCast(@alignCast(d));
    d += detail_verts_size;
    const nav_d_tris: [*]u8 = @ptrCast(@alignCast(d));
    d += detail_tris_size;
    const nav_bvtree: [*]BVNode = if (bv_tree_size > 0) @ptrCast(@alignCast(d)) else undefined;
    d += bv_tree_size;
    const off_mesh_cons: [*]OffMeshConnection = if (off_mesh_cons_size > 0) @ptrCast(@alignCast(d)) else undefined;

    // Store header
    header.* = .{
        .magic = DT_NAVMESH_MAGIC,
        .version = DT_NAVMESH_VERSION,
        .x = params.tile_x,
        .y = params.tile_y,
        .layer = params.tile_layer,
        .user_id = params.user_id,
        .poly_count = @intCast(tot_poly_count),
        .vert_count = @intCast(tot_vert_count),
        .max_link_count = @intCast(max_link_count),
        .bmin = Vec3.fromArray(&params.bmin),
        .bmax = Vec3.fromArray(&params.bmax),
        .detail_mesh_count = @intCast(params.poly_count),
        .detail_vert_count = @intCast(unique_detail_vert_count),
        .detail_tri_count = @intCast(detail_tri_count),
        .bv_quant_factor = 1.0 / params.cs,
        .off_mesh_base = @intCast(params.poly_count),
        .walkable_height = params.walkable_height,
        .walkable_radius = params.walkable_radius,
        .walkable_climb = params.walkable_climb,
        .off_mesh_con_count = @intCast(stored_off_mesh_con_count),
        .bv_node_count = if (params.build_bv_tree) @intCast(params.poly_count * 2) else 0,
    };

    const off_mesh_verts_base = params.vert_count;
    const off_mesh_poly_base = params.poly_count;

    // Store vertices
    // Mesh vertices
    for (0..params.vert_count) |i| {
        const iv = params.verts[i * 3 ..];
        const v = nav_verts[i * 3 ..];
        v[0] = params.bmin[0] + @as(f32, @floatFromInt(iv[0])) * params.cs;
        v[1] = params.bmin[1] + @as(f32, @floatFromInt(iv[1])) * params.ch;
        v[2] = params.bmin[2] + @as(f32, @floatFromInt(iv[2])) * params.cs;
    }

    // Off-mesh connection vertices
    var n: usize = 0;
    for (0..params.off_mesh_con_count) |i| {
        if (off_mesh_con_class[i * 2 + 0] == 0xff) {
            const linkv = params.off_mesh_con_verts.?;
            const v = nav_verts[(off_mesh_verts_base + n * 2) * 3 ..];
            // Copy start point
            v[0] = linkv[(i * 2 + 0) * 3 + 0];
            v[1] = linkv[(i * 2 + 0) * 3 + 1];
            v[2] = linkv[(i * 2 + 0) * 3 + 2];
            // Copy end point
            v[3] = linkv[(i * 2 + 1) * 3 + 0];
            v[4] = linkv[(i * 2 + 1) * 3 + 1];
            v[5] = linkv[(i * 2 + 1) * 3 + 2];
            n += 1;
        }
    }

    // Store polygons
    // Mesh polygons
    var src = params.polys;
    for (0..params.poly_count) |i| {
        var p = &nav_polys[i];
        p.vert_count = 0;
        p.flags = params.poly_flags[i];
        p.setArea(params.poly_areas[i]);
        p.setType(.ground);

        for (0..nvp) |j| {
            if (src[j] == MESH_NULL_IDX) break;
            p.verts[j] = src[j];

            if ((src[nvp + j] & 0x8000) != 0) {
                // Border or portal edge
                const dir = src[nvp + j] & 0xf;
                if (dir == 0xf) {
                    // Border
                    p.neis[j] = 0;
                } else if (dir == 0) {
                    // Portal x-
                    p.neis[j] = DT_EXT_LINK | 4;
                } else if (dir == 1) {
                    // Portal z+
                    p.neis[j] = DT_EXT_LINK | 2;
                } else if (dir == 2) {
                    // Portal x+
                    p.neis[j] = DT_EXT_LINK | 0;
                } else if (dir == 3) {
                    // Portal z-
                    p.neis[j] = DT_EXT_LINK | 6;
                }
            } else {
                // Normal connection
                p.neis[j] = src[nvp + j] + 1;
            }

            p.vert_count += 1;
        }
        src = src[nvp * 2 ..];
    }

    // Off-mesh connection polygons
    n = 0;
    for (0..params.off_mesh_con_count) |i| {
        if (off_mesh_con_class[i * 2 + 0] == 0xff) {
            var p = &nav_polys[off_mesh_poly_base + n];
            p.vert_count = 2;
            p.verts[0] = @intCast(off_mesh_verts_base + n * 2 + 0);
            p.verts[1] = @intCast(off_mesh_verts_base + n * 2 + 1);
            p.flags = params.off_mesh_con_flags.?[i];
            p.setArea(params.off_mesh_con_areas.?[i]);
            p.setType(.offmesh_connection);
            n += 1;
        }
    }

    // Store detail meshes and vertices
    if (params.detail_meshes) |detail_meshes| {
        // Compress mesh data by skipping nav poly vertices
        var vbase: u16 = 0;
        for (0..params.poly_count) |i| {
            var dtl = &nav_d_meshes[i];
            const vb = detail_meshes[i * 4 + 0];
            const ndv = detail_meshes[i * 4 + 1];
            const nv: usize = @intCast(nav_polys[i].vert_count);
            dtl.vert_base = vbase;
            dtl.vert_count = @intCast(ndv - nv);
            dtl.tri_base = detail_meshes[i * 4 + 2];
            dtl.tri_count = @intCast(detail_meshes[i * 4 + 3]);

            // Copy vertices except first 'nv' verts (equal to nav poly verts)
            if (ndv > nv) {
                const detail_verts = params.detail_verts.?;
                const src_idx = (vb + nv) * 3;
                const count = (ndv - nv) * 3;
                @memcpy(nav_d_verts[vbase * 3 .. vbase * 3 + count], detail_verts[src_idx .. src_idx + count]);
                vbase += @intCast(ndv - nv);
            }
        }

        // Store triangles
        const detail_tris = params.detail_tris.?;
        @memcpy(nav_d_tris[0 .. detail_tri_count * 4], detail_tris[0 .. detail_tri_count * 4]);
    } else {
        // Create dummy detail mesh by triangulating polygons
        var tbase: usize = 0;
        for (0..params.poly_count) |i| {
            var dtl = &nav_d_meshes[i];
            const nv: usize = @intCast(nav_polys[i].vert_count);
            dtl.vert_base = 0;
            dtl.vert_count = 0;
            dtl.tri_base = @intCast(tbase);
            dtl.tri_count = @intCast(nv - 2);

            // Triangulate polygon (local indices)
            for (2..nv) |j| {
                const t = nav_d_tris[tbase * 4 ..];
                t[0] = 0;
                t[1] = @intCast(j - 1);
                t[2] = @intCast(j);
                // Bit for each edge that belongs to poly boundary
                t[3] = (1 << 2);
                if (j == 2) t[3] |= (1 << 0);
                if (j == nv - 1) t[3] |= (1 << 4);
                tbase += 1;
            }
        }
    }

    // Store and create BV tree
    if (params.build_bv_tree) {
        const items = try allocator.alloc(BVItem, params.poly_count);
        defer allocator.free(items);
        const nodes = nav_bvtree[0 .. params.poly_count * 2];
        const node_count = createBVTree(params, nodes, items);
        header.bv_node_count = @intCast(node_count);
    }

    // Store off-mesh connections
    n = 0;
    for (0..params.off_mesh_con_count) |i| {
        if (off_mesh_con_class[i * 2 + 0] == 0xff) {
            var con = &off_mesh_cons[n];
            con.poly = @intCast(off_mesh_poly_base + n);

            // Copy connection end-points
            const end_pts = params.off_mesh_con_verts.?;
            con.pos[0] = end_pts[(i * 2 + 0) * 3 + 0];
            con.pos[1] = end_pts[(i * 2 + 0) * 3 + 1];
            con.pos[2] = end_pts[(i * 2 + 0) * 3 + 2];
            con.pos[3] = end_pts[(i * 2 + 1) * 3 + 0];
            con.pos[4] = end_pts[(i * 2 + 1) * 3 + 1];
            con.pos[5] = end_pts[(i * 2 + 1) * 3 + 2];

            con.rad = params.off_mesh_con_rad.?[i];
            con.flags = if (params.off_mesh_con_dir.?[i] != 0) DT_OFFMESH_CON_BIDIR else 0;
            con.side = off_mesh_con_class[i * 2 + 1];
            if (params.off_mesh_con_user_id) |user_ids| {
                con.user_id = user_ids[i];
            }
            n += 1;
        }
    }

    return data;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "align4 - already aligned" {
    try testing.expectEqual(@as(usize, 4), align4(4));
    try testing.expectEqual(@as(usize, 8), align4(8));
}

test "align4 - needs alignment" {
    try testing.expectEqual(@as(usize, 4), align4(1));
    try testing.expectEqual(@as(usize, 4), align4(2));
    try testing.expectEqual(@as(usize, 4), align4(3));
    try testing.expectEqual(@as(usize, 8), align4(5));
}

test "longestAxis - X longest" {
    try testing.expectEqual(@as(usize, 0), longestAxis(10, 5, 3));
}

test "longestAxis - Y longest" {
    try testing.expectEqual(@as(usize, 1), longestAxis(5, 10, 3));
}

test "longestAxis - Z longest" {
    try testing.expectEqual(@as(usize, 2), longestAxis(5, 3, 10));
}

test "classifyOffMeshPoint - center" {
    const pt = [3]f32{ 5, 5, 5 };
    const bmin = [3]f32{ 0, 0, 0 };
    const bmax = [3]f32{ 10, 10, 10 };
    try testing.expectEqual(@as(u8, 0xff), classifyOffMeshPoint(&pt, &bmin, &bmax));
}

test "classifyOffMeshPoint - XP" {
    const pt = [3]f32{ 15, 5, 5 };
    const bmin = [3]f32{ 0, 0, 0 };
    const bmax = [3]f32{ 10, 10, 10 };
    try testing.expectEqual(@as(u8, 0), classifyOffMeshPoint(&pt, &bmin, &bmax));
}

test "createNavMeshData - simple quad" {
    const allocator = testing.allocator;

    // Create a simple quad (2 triangles)
    const verts = [_]u16{
        0, 0, 0, // Vertex 0
        100, 0, 0, // Vertex 1
        100, 0, 100, // Vertex 2
        0, 0, 100, // Vertex 3
    };

    const nvp = 4;
    const polys = [_]u16{
        0, 1, 2, 3, MESH_NULL_IDX, MESH_NULL_IDX, // Vertices
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, // Neighbors
    };

    const poly_flags = [_]u16{0x01};
    const poly_areas = [_]u8{0};

    const params = NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 4,
        .polys = &polys,
        .poly_flags = &poly_flags,
        .poly_areas = &poly_areas,
        .poly_count = 1,
        .nvp = nvp,
        .bmin = .{ 0.0, 0.0, 0.0 },
        .bmax = .{ 10.0, 1.0, 10.0 },
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .cs = 0.1,
        .ch = 0.1,
        .build_bv_tree = true,
    };

    const data = try createNavMeshData(&params, allocator);
    defer allocator.free(data);

    // Verify header
    const header: *const MeshHeader = @ptrCast(@alignCast(data.ptr));
    try testing.expectEqual(DT_NAVMESH_MAGIC, header.magic);
    try testing.expectEqual(DT_NAVMESH_VERSION, header.version);
    try testing.expectEqual(@as(i32, 1), header.poly_count);
    try testing.expectEqual(@as(i32, 4), header.vert_count);
    try testing.expect(header.bv_node_count > 0);
}

test "createNavMeshData - with off-mesh connections" {
    const allocator = testing.allocator;

    // Simple triangle
    const verts = [_]u16{
        0, 0, 0,
        100, 0, 0,
        50, 0, 100,
    };

    const nvp = 3;
    const polys = [_]u16{
        0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
        MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX,
    };

    const poly_flags = [_]u16{0x01};
    const poly_areas = [_]u8{0};

    // Off-mesh connection
    const off_mesh_verts = [_]f32{
        1.0, 0.1, 1.0, // Start point
        8.0, 0.1, 8.0, // End point
    };
    const off_mesh_rad = [_]f32{0.5};
    const off_mesh_flags = [_]u16{0x01};
    const off_mesh_areas = [_]u8{0};
    const off_mesh_dir = [_]u8{1}; // Bidirectional

    const params = NavMeshCreateParams{
        .verts = &verts,
        .vert_count = 3,
        .polys = &polys,
        .poly_flags = &poly_flags,
        .poly_areas = &poly_areas,
        .poly_count = 1,
        .nvp = nvp,
        .off_mesh_con_verts = &off_mesh_verts,
        .off_mesh_con_rad = &off_mesh_rad,
        .off_mesh_con_flags = &off_mesh_flags,
        .off_mesh_con_areas = &off_mesh_areas,
        .off_mesh_con_dir = &off_mesh_dir,
        .off_mesh_con_count = 1,
        .bmin = .{ 0.0, 0.0, 0.0 },
        .bmax = .{ 10.0, 1.0, 10.0 },
        .walkable_height = 2.0,
        .walkable_radius = 0.6,
        .walkable_climb = 0.9,
        .cs = 0.1,
        .ch = 0.1,
        .build_bv_tree = false,
    };

    const data = try createNavMeshData(&params, allocator);
    defer allocator.free(data);

    // Verify header
    const header: *const MeshHeader = @ptrCast(@alignCast(data.ptr));
    try testing.expectEqual(DT_NAVMESH_MAGIC, header.magic);
    try testing.expectEqual(@as(i32, 2), header.poly_count); // 1 mesh poly + 1 off-mesh poly
    try testing.expectEqual(@as(i32, 5), header.vert_count); // 3 mesh verts + 2 off-mesh verts
    try testing.expectEqual(@as(i32, 1), header.off_mesh_con_count);
}
