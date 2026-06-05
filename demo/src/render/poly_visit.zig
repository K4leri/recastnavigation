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
const area_types = @import("../area_types.zig");
const cs = @import("color_scheme.zig");
const components = @import("components.zig");

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

/// Return the area-type cost for a given area id, falling back to 1.0 for
/// unknown/unregistered areas. Pure helper — no NavMesh traversal.
pub fn polyCost(area: u8) f32 {
    return area_types.costFor(@as(usize, area));
}

const CostRange = struct { lo: f32, hi: f32 };

fn costRange(mesh: *const NavMesh) CostRange {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var found = false;
    for (0..@intCast(mesh.max_tiles)) |i| {
        const tile = &mesh.tiles[i];
        const hdr = tile.header orelse continue;
        for (0..@intCast(hdr.poly_count)) |pi| {
            const p = &tile.polys[pi];
            if (p.getType() == .offmesh_connection) continue;
            const c = polyCost(p.getArea());
            lo = @min(lo, c);
            hi = @max(hi, c);
            found = true;
        }
    }
    return if (found) .{ .lo = lo, .hi = hi } else .{ .lo = 0, .hi = 0 };
}

pub fn fillNavMesh(dd: dbg.DebugDraw, mesh: *const NavMesh, scheme: cs.ColorScheme, alloc: std.mem.Allocator) void {
    // Height range needs a full extra traversal; only pay it for the height ramp.
    const hr: HeightRange = if (scheme == .height) heightRange(mesh) else .{ .lo = 0, .hi = 0 };
    // Cost range: scan every non-offmesh poly's area-type cost; only for .cost scheme.
    const cr: CostRange = if (scheme == .cost) costRange(mesh) else .{ .lo = 0, .hi = 0 };
    var comps: ?components.Components = if (scheme == .component) (components.compute(mesh, alloc) catch null) else null;
    defer if (comps) |*c| c.deinit();

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
                .component = if (comps) |*c| @as(i32, c.getByIndex(ti, i)) else 0,
                .cost = polyCost(p.getArea()),
                .cost_min = cr.lo,
                .cost_max = cr.hi,
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

test "polyCost: known area returns registry cost; unknown area -> 1.0" {
    area_types.resetToBuiltins();
    // Ground (id=0): cost 1.0
    try std.testing.expectEqual(@as(f32, 1.0), polyCost(0));
    // Water (id=1): cost 10.0
    try std.testing.expectEqual(@as(f32, 10.0), polyCost(1));
    // Grass (id=4): cost 2.0
    try std.testing.expectEqual(@as(f32, 2.0), polyCost(4));
    // Jump (id=5): cost 1.5
    try std.testing.expectEqual(@as(f32, 1.5), polyCost(5));
    // Unknown area (e.g. id=63, not seeded by builtins) -> 1.0
    try std.testing.expectEqual(@as(f32, 1.0), polyCost(63));
}
