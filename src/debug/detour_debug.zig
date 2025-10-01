const std = @import("std");
const detour = @import("../detour.zig");
const dd_mod = @import("debug_draw.zig");
const math = @import("../math.zig");

const DebugDraw = dd_mod.DebugDraw;
const DebugDrawPrimitives = dd_mod.DebugDrawPrimitives;
const NavMesh = detour.NavMesh;
const NavMeshQuery = detour.NavMeshQuery;
const MeshTile = detour.MeshTile;
const Poly = detour.Poly;
const PolyRef = detour.PolyRef;

/// Draw NavMesh flags
pub const DrawNavMeshFlags = packed struct {
    offmesh_cons: bool = false,
    closed_list: bool = false,
    color_tiles: bool = false,
    _padding: u5 = 0,

    pub fn fromByte(byte: u8) DrawNavMeshFlags {
        return @bitCast(byte);
    }
};

const OFFMESH_CONS: u8 = 0x01;
const CLOSEDLIST: u8 = 0x02;
const COLOR_TILES: u8 = 0x04;

/// Draw entire navigation mesh
pub fn debugDrawNavMesh(dd: DebugDraw, mesh: *const NavMesh, flags: u8) void {
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        if (tile.header == null) continue;
        drawMeshTile(dd, mesh, null, tile, flags);
    }
}

/// Draw navigation mesh with closed list from query
pub fn debugDrawNavMeshWithClosedList(dd: DebugDraw, mesh: *const NavMesh, query: *const NavMeshQuery, flags: u8) void {
    const q = if ((flags & CLOSEDLIST) != 0) query else null;

    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        if (tile.header == null) continue;
        drawMeshTile(dd, mesh, q, tile, flags);
    }
}

/// Draw navigation mesh nodes from query (pathfinding visualization)
pub fn debugDrawNavMeshNodes(dd: DebugDraw, query: *const NavMeshQuery) void {
    const pool = &query.node_pool;
    const off: f32 = 0.5;

    // Draw nodes
    dd.begin(.points, 4.0);

    for (0..pool.hash_size) |i| {
        var j = pool.getFirst(@intCast(i));
        while (j != detour.NULL_IDX) {
            const node = pool.getNodeAtIdx(j + 1) orelse {
                j = pool.getNext(j);
                continue;
            };
            dd.vertexXYZ(node.pos[0], node.pos[1] + off, node.pos[2], dd_mod.rgba(255, 192, 0, 255));
            j = pool.getNext(j);
        }
    }

    dd.end();

    // Draw connections to parents
    dd.begin(.lines, 2.0);

    for (0..pool.hash_size) |i| {
        var j = pool.getFirst(@intCast(i));
        while (j != detour.NULL_IDX) {
            const node = pool.getNodeAtIdx(j + 1) orelse {
                j = pool.getNext(j);
                continue;
            };
            if (node.pidx == 0) {
                j = pool.getNext(j);
                continue;
            }

            const parent = pool.getNodeAtIdx(node.pidx) orelse {
                j = pool.getNext(j);
                continue;
            };

            dd.vertexXYZ(node.pos[0], node.pos[1] + off, node.pos[2], dd_mod.rgba(255, 192, 0, 128));
            dd.vertexXYZ(parent.pos[0], parent.pos[1] + off, parent.pos[2], dd_mod.rgba(255, 192, 0, 128));
            j = pool.getNext(j);
        }
    }

    dd.end();
}

/// Draw BVTree for spatial queries
pub fn debugDrawNavMeshBVTree(dd: DebugDraw, mesh: *const NavMesh) void {
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        if (tile.header == null) continue;
        drawMeshTileBVTree(dd, tile);
    }
}

/// Draw portals between tiles
pub fn debugDrawNavMeshPortals(dd: DebugDraw, mesh: *const NavMesh) void {
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        if (tile.header == null) continue;
        drawMeshTilePortal(dd, tile);
    }
}

/// Draw polygons with specific flags
pub fn debugDrawNavMeshPolysWithFlags(dd: DebugDraw, mesh: *const NavMesh, poly_flags: u16, col: u32) void {
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        if (tile.header == null) continue;

        const base = mesh.getPolyRefBase(tile);

        for (0..@intCast(tile.header.?.poly_count)) |j| {
            const p = &tile.polys[j];
            if ((p.flags & poly_flags) == 0) continue;
            const ref = base | @as(PolyRef, @intCast(j));
            debugDrawNavMeshPoly(dd, mesh, ref, col);
        }
    }
}

/// Draw single polygon
pub fn debugDrawNavMeshPoly(dd: DebugDraw, mesh: *const NavMesh, ref: PolyRef, col: u32) void {
    const decoded = mesh.decodePolyId(ref);
    if (decoded.tile >= @as(u32, @intCast(mesh.max_tiles))) return;

    const tile = &mesh.tiles[decoded.tile];
    if (tile.header == null) return;
    if (decoded.poly >= @as(u32, @intCast(tile.header.?.poly_count))) return;

    const poly = &tile.polys[decoded.poly];
    const pd = &tile.detail_meshes[decoded.poly];

    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(pd.tri_count)) |i| {
        const t_idx = (pd.tri_base + @as(u32, @intCast(i))) * 4;
        const t = tile.detail_tris[t_idx .. t_idx + 4];

        for (0..3) |j| {
            if (t[j] < poly.vert_count) {
                const v_idx = poly.verts[t[j]] * 3;
                dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
            } else {
                const d_idx = (pd.vert_base + (t[j] - poly.vert_count)) * 3;
                dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
            }
        }
    }

    dd.end();
    dd.depthMask(true);

    // Draw polygon boundaries
    const pcol = dd_mod.rgba(0, 0, 0, 64);
    dd.begin(.lines, 1.0);

    for (0..poly.vert_count) |i| {
        const j = (i + 1) % poly.vert_count;
        const v0 = &tile.verts[poly.verts[i] * 3];
        const v1 = &tile.verts[poly.verts[j] * 3];

        dd.vertex(@ptrCast(v0[0..3]), pcol);
        dd.vertex(@ptrCast(v1[0..3]), pcol);
    }

    dd.end();
}

// ============================================================================
// Internal Helper Functions
// ============================================================================

fn drawMeshTile(dd: DebugDraw, mesh: *const NavMesh, query: ?*const NavMeshQuery, tile: *const MeshTile, flags: u8) void {
    const base = mesh.getPolyRefBase(tile);
    const tile_num = mesh.decodePolyIdTile(base);
    const tile_color = dd_mod.intToCol(@intCast(tile_num), 128);

    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(tile.header.?.poly_count)) |i| {
        const p = &tile.polys[i];
        if (p.getType() == .offmesh_connection) continue;

        const pd = &tile.detail_meshes[i];

        var col: u32 = undefined;
        if (query) |q| {
            if (q.isInClosedList(base | @as(PolyRef, @intCast(i)))) {
                col = dd_mod.rgba(255, 196, 0, 64);
            } else {
                col = if ((flags & COLOR_TILES) != 0)
                    tile_color
                else
                    dd_mod.transCol(dd.areaToCol(p.getArea()), 64);
            }
        } else {
            col = if ((flags & COLOR_TILES) != 0)
                tile_color
            else
                dd_mod.transCol(dd.areaToCol(p.getArea()), 64);
        }

        for (0..@intCast(pd.tri_count)) |j| {
            const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
            const t = tile.detail_tris[t_idx .. t_idx + 4];

            for (0..3) |k| {
                if (t[k] < p.vert_count) {
                    const v_idx = p.verts[t[k]] * 3;
                    dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                } else {
                    const d_idx = (pd.vert_base + (t[k] - p.vert_count)) * 3;
                    dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                }
            }
        }
    }

    dd.end();
    dd.depthMask(true);

    // Draw boundaries
    drawPolyBoundaries(dd, tile, dd_mod.rgba(0, 48, 64, 220), 1.5, false);
    drawPolyBoundaries(dd, tile, dd_mod.rgba(0, 48, 64, 64), 1.0, true);

    // Draw off-mesh connections
    if ((flags & OFFMESH_CONS) != 0) {
        drawOffMeshConnections(dd, tile);
    }
}

fn drawPolyBoundaries(dd: DebugDraw, tile: *const MeshTile, col: u32, linew: f32, inner: bool) void {
    const thr: f32 = 0.01 * 0.01;

    dd.begin(.lines, linew);

    for (0..@intCast(tile.header.?.poly_count)) |i| {
        const p = &tile.polys[i];
        if (p.getType() == .offmesh_connection) continue;

        const pd = &tile.detail_meshes[i];

        for (0..p.vert_count) |j| {
            var c = col;
            if (inner) {
                if (p.neis[j] == 0) continue;
                if ((p.neis[j] & detour.EXT_LINK) != 0) {
                    var con = false;
                    var k = p.first_link;
                    while (k != detour.NULL_LINK) {
                        if (tile.links[k].edge == j) {
                            con = true;
                            break;
                        }
                        k = tile.links[k].next;
                    }
                    c = if (con) dd_mod.rgba(255, 255, 255, 48) else dd_mod.rgba(0, 0, 0, 48);
                } else {
                    c = dd_mod.rgba(0, 48, 64, 32);
                }
            } else {
                if (p.neis[j] != 0) continue;
            }

            const v0 = &tile.verts[p.verts[j] * 3];
            const nj = (j + 1) % p.vert_count;
            const v1 = &tile.verts[p.verts[nj] * 3];

            // Draw detail mesh edges which align with the actual poly edge
            for (0..@intCast(pd.tri_count)) |k| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(k))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];

                var tv: [3]*const f32 = undefined;
                for (0..3) |m| {
                    if (t[m] < p.vert_count) {
                        tv[m] = &tile.verts[p.verts[t[m]] * 3];
                    } else {
                        tv[m] = &tile.detail_verts[(pd.vert_base + (t[m] - p.vert_count)) * 3];
                    }
                }

                var m: usize = 0;
                var n: usize = 2;
                while (m < 3) : ({
                    n = m;
                    m += 1;
                }) {
                    if ((detour.getDetailTriEdgeFlags(t[3], n) & detour.DETAIL_EDGE_BOUNDARY) == 0) continue;

                    if (distancePtLine2d(@ptrCast(tv[n]), v0[0..3], v1[0..3]) < thr and
                        distancePtLine2d(@ptrCast(tv[m]), v0[0..3], v1[0..3]) < thr)
                    {
                        dd.vertex(@ptrCast(tv[n]), c);
                        dd.vertex(@ptrCast(tv[m]), c);
                    }
                }
            }
        }
    }

    dd.end();
}

fn distancePtLine2d(pt: *const [3]f32, p: *const [3]f32, q: *const [3]f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    const dx = pt[0] - p[0];
    const dz = pt[2] - p[2];
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d != 0) t /= d;
    const dx2 = p[0] + t * pqx - pt[0];
    const dz2 = p[2] + t * pqz - pt[2];
    return dx2 * dx2 + dz2 * dz2;
}

fn drawOffMeshConnections(dd: DebugDraw, tile: *const MeshTile) void {
    const off: f32 = 0.5;

    dd.begin(.lines, 2.0);

    for (0..@intCast(tile.header.?.poly_count)) |i| {
        const p = &tile.polys[i];
        if (p.getType() != .offmesh_connection) continue;

        const col = if (p.getArea() == 0)
            dd_mod.rgba(0, 0, 0, 128)
        else
            dd_mod.darkenCol(dd_mod.intToCol(@intCast(p.getArea()), 220));

        const v0 = &tile.verts[p.verts[0] * 3];
        const v1 = &tile.verts[p.verts[1] * 3];

        dd.vertexXYZ(v0[0], v0[1], v0[2], col);
        dd.vertexXYZ(v1[0], v1[1], v1[2], col);

        // Draw circle at endpoints
        dd_mod.appendCircle(dd, v0[0], v0[1] + off, v0[2], 0.1, col);
        dd_mod.appendCircle(dd, v1[0], v1[1] + off, v1[2], 0.1, col);
    }

    dd.end();
}

fn drawMeshTileBVTree(dd: DebugDraw, tile: *const MeshTile) void {
    if (tile.bv_tree.len == 0) return;

    const cs = 1.0 / tile.header.?.bv_quant_factor;

    dd.begin(.lines, 1.0);

    for (tile.bv_tree) |n| {
        if (n.i < 0) continue; // Leaf

        const minx = tile.header.?.bmin[0] + @as(f32, @floatFromInt(n.bmin[0])) * cs;
        const miny = tile.header.?.bmin[1] + @as(f32, @floatFromInt(n.bmin[1])) * cs;
        const minz = tile.header.?.bmin[2] + @as(f32, @floatFromInt(n.bmin[2])) * cs;
        const maxx = tile.header.?.bmin[0] + @as(f32, @floatFromInt(n.bmax[0])) * cs;
        const maxy = tile.header.?.bmin[1] + @as(f32, @floatFromInt(n.bmax[1])) * cs;
        const maxz = tile.header.?.bmin[2] + @as(f32, @floatFromInt(n.bmax[2])) * cs;

        appendBoxWire(dd, minx, miny, minz, maxx, maxy, maxz, dd_mod.rgba(255, 255, 255, 128));
    }

    dd.end();
}

fn drawMeshTilePortal(dd: DebugDraw, tile: *const MeshTile) void {
    const col = dd_mod.rgba(255, 255, 255, 255);
    const pad_x = 0.01;
    const pad_z = 0.01;

    dd.begin(.lines, 2.0);

    for (0..@intCast(tile.header.?.poly_count)) |i| {
        const p = &tile.polys[i];
        if (p.getType() != .ground) continue;

        for (0..p.vert_count) |j| {
            if ((p.neis[j] & detour.EXT_LINK) == 0) continue;

            const nj = (j + 1) % p.vert_count;
            const v0 = &tile.verts[p.verts[j] * 3];
            const v1 = &tile.verts[p.verts[nj] * 3];

            const seg_dir = .{
                v1[0] - v0[0],
                0,
                v1[2] - v0[2],
            };
            const len = @sqrt(seg_dir[0] * seg_dir[0] + seg_dir[2] * seg_dir[2]);
            if (len < 0.001) continue;

            const norm_x = seg_dir[2] / len;
            const norm_z = -seg_dir[0] / len;

            const px0 = v0[0] + pad_x * norm_x;
            const pz0 = v0[2] + pad_z * norm_z;
            const px1 = v1[0] + pad_x * norm_x;
            const pz1 = v1[2] + pad_z * norm_z;

            dd.vertexXYZ(px0, v0[1], pz0, col);
            dd.vertexXYZ(px1, v1[1], pz1, col);
        }
    }

    dd.end();
}

fn appendBoxWire(dd: DebugDraw, minx: f32, miny: f32, minz: f32, maxx: f32, maxy: f32, maxz: f32, col: u32) void {
    // Bottom
    dd.vertexXYZ(minx, miny, minz, col);
    dd.vertexXYZ(maxx, miny, minz, col);
    dd.vertexXYZ(maxx, miny, minz, col);
    dd.vertexXYZ(maxx, miny, maxz, col);
    dd.vertexXYZ(maxx, miny, maxz, col);
    dd.vertexXYZ(minx, miny, maxz, col);
    dd.vertexXYZ(minx, miny, maxz, col);
    dd.vertexXYZ(minx, miny, minz, col);

    // Top
    dd.vertexXYZ(minx, maxy, minz, col);
    dd.vertexXYZ(maxx, maxy, minz, col);
    dd.vertexXYZ(maxx, maxy, minz, col);
    dd.vertexXYZ(maxx, maxy, maxz, col);
    dd.vertexXYZ(maxx, maxy, maxz, col);
    dd.vertexXYZ(minx, maxy, maxz, col);
    dd.vertexXYZ(minx, maxy, maxz, col);
    dd.vertexXYZ(minx, maxy, minz, col);

    // Sides
    dd.vertexXYZ(minx, miny, minz, col);
    dd.vertexXYZ(minx, maxy, minz, col);
    dd.vertexXYZ(maxx, miny, minz, col);
    dd.vertexXYZ(maxx, maxy, minz, col);
    dd.vertexXYZ(maxx, miny, maxz, col);
    dd.vertexXYZ(maxx, maxy, maxz, col);
    dd.vertexXYZ(minx, miny, maxz, col);
    dd.vertexXYZ(minx, maxy, maxz, col);
}
