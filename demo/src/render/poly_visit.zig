//! Demo-side navmesh fill pass that colours each polygon by the active colour
//! scheme (foundation render layer, §3.c). The faithful core `debugDrawNavMesh`
//! can only colour by area (its sole input is the area_to_col hook), so this
//! replicates the detail-triangle fill of `drawMeshTile` and applies
//! `color_scheme.colorForPoly` per polygon. Boundaries/off-mesh stay with the
//! core draw.

const std = @import("std");
const recast = @import("recast-nav");
const dt = recast.detour;
const dbg = recast.debug;
const sample = @import("../sample.zig");
const cs = @import("color_scheme.zig");

const NavMesh = dt.NavMesh;

fn polyHeight(tile: *const dt.MeshTile, p: *const dt.Poly) f32 {
    var sum: f32 = 0;
    for (0..p.vert_count) |k| {
        sum += tile.verts[@as(usize, p.verts[k]) * 3 + 1];
    }
    return if (p.vert_count == 0) 0 else sum / @as(f32, @floatFromInt(p.vert_count));
}

const HeightRange = struct { lo: f32, hi: f32 };

fn heightRange(mesh: *const NavMesh) HeightRange {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var found = false;
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        const hdr = tile.header orelse continue;
        for (0..@intCast(hdr.poly_count)) |pi| {
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;
            const h = polyHeight(tile, p);
            lo = @min(lo, h);
            hi = @max(hi, h);
            found = true;
        }
    }
    return if (found) .{ .lo = lo, .hi = hi } else .{ .lo = 0, .hi = 0 };
}

pub fn fillNavMesh(dd: dbg.DebugDraw, mesh: *const NavMesh, scheme: cs.ColorScheme) void {
    // Height range needs a full extra traversal; only pay it for the height ramp.
    const hr: HeightRange = if (scheme == .height) heightRange(mesh) else .{ .lo = 0, .hi = 0 };

    dd.depthMask(false);
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.max_tiles)) |ti| {
        const tile = &mesh.tiles[ti];
        const hdr = tile.header orelse continue;

        for (0..@intCast(hdr.poly_count)) |i| {
            const p = &tile.polys[i];
            if (p.getType() == .offmesh_connection) continue;
            const pd = &tile.detail_meshes[i];

            const ctx = cs.PolyColorCtx{
                .area_col = sample.sampleAreaToCol(p.getArea()),
                .flags = p.flags,
                .height = polyHeight(tile, p),
                .height_min = hr.lo,
                .height_max = hr.hi,
            };
            const col = cs.colorForPoly(scheme, ctx);

            for (0..@as(usize, pd.tri_count)) |j| {
                const t_idx = (pd.tri_base + @as(u32, @intCast(j))) * 4;
                const t = tile.detail_tris[t_idx .. t_idx + 4];
                for (0..3) |k| {
                    if (t[k] < p.vert_count) {
                        const v_idx = @as(usize, p.verts[t[k]]) * 3;
                        dd.vertex(@ptrCast(&tile.verts[v_idx]), col);
                    } else {
                        const d_idx = (@as(usize, pd.vert_base) + @as(usize, t[k] - p.vert_count)) * 3;
                        dd.vertex(@ptrCast(&tile.detail_verts[d_idx]), col);
                    }
                }
            }
        }
    }

    dd.end();
    dd.depthMask(true);
}
