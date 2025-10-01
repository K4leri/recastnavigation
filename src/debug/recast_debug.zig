const std = @import("std");
const recast = @import("../recast.zig");
const dd_mod = @import("debug_draw.zig");
const math = @import("../math.zig");

const DebugDraw = dd_mod.DebugDraw;
const DebugDrawPrimitives = dd_mod.DebugDrawPrimitives;
const Heightfield = recast.Heightfield;
const CompactHeightfield = recast.CompactHeightfield;
const HeightfieldLayerSet = recast.HeightfieldLayerSet;
const HeightfieldLayer = recast.HeightfieldLayer;
const ContourSet = recast.ContourSet;
const PolyMesh = recast.PolyMesh;
const PolyMeshDetail = recast.PolyMeshDetail;

// Color constants
const WALKABLE_AREA_COLOR = dd_mod.rgba(64, 128, 160, 255);
const NULL_AREA_COLOR = dd_mod.rgba(64, 64, 64, 255);
const WHITE = dd_mod.rgba(255, 255, 255, 255);

/// Draw heightfield as solid voxels
pub fn debugDrawHeightfieldSolid(dd: DebugDraw, hf: *const Heightfield) void {
    const orig = &hf.bmin;
    const cs = hf.cs;
    const ch = hf.ch;

    const w = hf.width;
    const h = hf.height;

    var fcol: [6]u32 = undefined;
    dd_mod.calcBoxColors(&fcol, WHITE, WHITE);

    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const fx = orig[0] + @as(f32, @floatFromInt(x)) * cs;
            const fz = orig[2] + @as(f32, @floatFromInt(y)) * cs;
            var s = hf.spans[x + y * w];
            while (s) |span| {
                const miny = orig[1] + @as(f32, @floatFromInt(span.smin)) * ch;
                const maxy = orig[1] + @as(f32, @floatFromInt(span.smax)) * ch;
                dd_mod.appendBox(dd, fx, miny, fz, fx + cs, maxy, fz + cs, &fcol);
                s = span.next;
            }
        }
    }

    dd.end();
}

/// Draw heightfield walkable areas
pub fn debugDrawHeightfieldWalkable(dd: DebugDraw, hf: *const Heightfield) void {
    const orig = &hf.bmin;
    const cs = hf.cs;
    const ch = hf.ch;

    const w = hf.width;
    const h = hf.height;

    var fcol: [6]u32 = undefined;
    dd_mod.calcBoxColors(&fcol, WHITE, dd_mod.rgba(217, 217, 217, 255));

    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const fx = orig[0] + @as(f32, @floatFromInt(x)) * cs;
            const fz = orig[2] + @as(f32, @floatFromInt(y)) * cs;
            var s = hf.spans[x + y * w];
            while (s) |span| {
                if (span.area == recast.WALKABLE_AREA) {
                    fcol[0] = WALKABLE_AREA_COLOR;
                } else if (span.area == recast.NULL_AREA) {
                    fcol[0] = NULL_AREA_COLOR;
                } else {
                    fcol[0] = dd_mod.multCol(dd.areaToCol(span.area), 200);
                }

                const miny = orig[1] + @as(f32, @floatFromInt(span.smin)) * ch;
                const maxy = orig[1] + @as(f32, @floatFromInt(span.smax)) * ch;
                dd_mod.appendBox(dd, fx, miny, fz, fx + cs, maxy, fz + cs, &fcol);
                s = span.next;
            }
        }
    }

    dd.end();
}

/// Draw compact heightfield as solid voxels
pub fn debugDrawCompactHeightfieldSolid(dd: DebugDraw, chf: *const CompactHeightfield) void {
    const cs = chf.cs;
    const ch = chf.ch;

    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < chf.height) : (y += 1) {
        var x: usize = 0;
        while (x < chf.width) : (x += 1) {
            const fx = chf.bmin[0] + @as(f32, @floatFromInt(x)) * cs;
            const fz = chf.bmin[2] + @as(f32, @floatFromInt(y)) * cs;
            const c = &chf.cells[x + y * chf.width];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = &chf.spans[i];
                const fy = chf.bmin[1] + @as(f32, @floatFromInt(s.y)) * ch;
                var color: u32 = undefined;

                if (s.area == recast.WALKABLE_AREA) {
                    color = WALKABLE_AREA_COLOR;
                } else if (s.area == recast.NULL_AREA) {
                    color = NULL_AREA_COLOR;
                } else {
                    color = dd.areaToCol(s.area);
                }

                dd.vertex(&.{ fx, fy, fz }, color);
                dd.vertex(&.{ fx, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz }, color);
            }
        }
    }

    dd.end();
}

/// Draw compact heightfield regions
pub fn debugDrawCompactHeightfieldRegions(dd: DebugDraw, chf: *const CompactHeightfield) void {
    const cs = chf.cs;
    const ch = chf.ch;

    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < chf.height) : (y += 1) {
        var x: usize = 0;
        while (x < chf.width) : (x += 1) {
            const fx = chf.bmin[0] + @as(f32, @floatFromInt(x)) * cs;
            const fz = chf.bmin[2] + @as(f32, @floatFromInt(y)) * cs;
            const c = &chf.cells[x + y * chf.width];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = &chf.spans[i];
                const fy = chf.bmin[1] + @as(f32, @floatFromInt(s.y)) * ch;
                const color = if (s.reg > 0)
                    dd_mod.intToCol(@intCast(s.reg), 255)
                else
                    dd_mod.rgba(0, 0, 0, 255);

                dd.vertex(&.{ fx, fy, fz }, color);
                dd.vertex(&.{ fx, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz }, color);
            }
        }
    }

    dd.end();
}

/// Draw compact heightfield distance field
pub fn debugDrawCompactHeightfieldDistance(dd: DebugDraw, chf: *const CompactHeightfield) void {
    const cs = chf.cs;
    const ch = chf.ch;

    // Find max distance
    var maxd: u16 = 0;
    for (chf.dist) |d| {
        maxd = @max(maxd, d);
    }

    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < chf.height) : (y += 1) {
        var x: usize = 0;
        while (x < chf.width) : (x += 1) {
            const fx = chf.bmin[0] + @as(f32, @floatFromInt(x)) * cs;
            const fz = chf.bmin[2] + @as(f32, @floatFromInt(y)) * cs;
            const c = &chf.cells[x + y * chf.width];

            var i: usize = c.index;
            const ni = c.index + c.count;
            while (i < ni) : (i += 1) {
                const s = &chf.spans[i];
                const fy = chf.bmin[1] + (@as(f32, @floatFromInt(s.y)) + 1.0) * ch;
                const cd: u32 = chf.dist[i];
                const d: u32 = if (maxd > 0) cd * 255 / maxd else 0;
                const color = dd_mod.rgba(@intCast(d), @intCast(d), @intCast(d), 255);

                dd.vertex(&.{ fx, fy, fz }, color);
                dd.vertex(&.{ fx, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz + cs }, color);
                dd.vertex(&.{ fx + cs, fy, fz }, color);
            }
        }
    }

    dd.end();
}

/// Draw heightfield layer
pub fn debugDrawHeightfieldLayer(dd: DebugDraw, layer: *const HeightfieldLayer, idx: i32) void {
    const cs = layer.cs;
    const ch = layer.ch;
    const w = layer.width;
    const h = layer.height;

    const color = dd_mod.intToCol(idx + 1, 255);

    // Layer bounds
    const bmin = [3]f32{
        layer.bmin[0] + @as(f32, @floatFromInt(layer.minx)) * cs,
        layer.bmin[1],
        layer.bmin[2] + @as(f32, @floatFromInt(layer.miny)) * cs,
    };
    const bmax = [3]f32{
        layer.bmin[0] + @as(f32, @floatFromInt(layer.maxx + 1)) * cs,
        layer.bmax[1],
        layer.bmin[2] + @as(f32, @floatFromInt(layer.maxy + 1)) * cs,
    };
    debugDrawBoxWire(dd, bmin[0], bmin[1], bmin[2], bmax[0], bmax[1], bmax[2], dd_mod.transCol(color, 128), 2.0);

    // Layer height
    dd.begin(.quads, 1.0);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const lidx = x + y * w;
            const lh: i32 = @intCast(layer.heights[lidx]);
            if (lh == 0xff) continue;

            const area = layer.areas[lidx];

            var col: u32 = undefined;
            if (area == recast.WALKABLE_AREA) {
                col = dd_mod.lerpCol(color, dd_mod.rgba(0, 192, 255, 64), 32);
            } else if (area == recast.NULL_AREA) {
                col = dd_mod.lerpCol(color, dd_mod.rgba(0, 0, 0, 64), 32);
            } else {
                col = dd_mod.lerpCol(color, dd.areaToCol(area), 32);
            }

            const fx = layer.bmin[0] + @as(f32, @floatFromInt(x)) * cs;
            const fy = layer.bmin[1] + @as(f32, @floatFromInt(lh + 1)) * ch;
            const fz = layer.bmin[2] + @as(f32, @floatFromInt(y)) * cs;

            dd.vertex(&.{ fx, fy, fz }, col);
            dd.vertex(&.{ fx, fy, fz + cs }, col);
            dd.vertex(&.{ fx + cs, fy, fz + cs }, col);
            dd.vertex(&.{ fx + cs, fy, fz }, col);
        }
    }

    dd.end();

    // Portals
    drawLayerPortals(dd, layer);
}

fn drawLayerPortals(dd: DebugDraw, layer: *const HeightfieldLayer) void {
    const cs = layer.cs;
    const ch = layer.ch;
    const w = layer.width;
    const h = layer.height;

    const pcol = WHITE;

    const segs = [16]i32{ 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0 };

    dd.begin(.lines, 2.0);

    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const idx = x + y * w;
            const lh: i32 = @intCast(layer.heights[idx]);
            if (lh == 255) continue;

            for (0..4) |dir| {
                if ((layer.cons[idx] & (@as(u8, 1) << @intCast(dir + 4))) != 0) {
                    const seg_base = dir * 4;
                    const ax = layer.bmin[0] + @as(f32, @floatFromInt(@as(i32, @intCast(x)) + segs[seg_base + 0])) * cs;
                    const ay = layer.bmin[1] + @as(f32, @floatFromInt(lh + 2)) * ch;
                    const az = layer.bmin[2] + @as(f32, @floatFromInt(@as(i32, @intCast(y)) + segs[seg_base + 1])) * cs;
                    const bx = layer.bmin[0] + @as(f32, @floatFromInt(@as(i32, @intCast(x)) + segs[seg_base + 2])) * cs;
                    const by = layer.bmin[1] + @as(f32, @floatFromInt(lh + 2)) * ch;
                    const bz = layer.bmin[2] + @as(f32, @floatFromInt(@as(i32, @intCast(y)) + segs[seg_base + 3])) * cs;
                    dd.vertex(&.{ ax, ay, az }, pcol);
                    dd.vertex(&.{ bx, by, bz }, pcol);
                }
            }
        }
    }

    dd.end();
}

/// Draw all heightfield layers
pub fn debugDrawHeightfieldLayers(dd: DebugDraw, lset: *const HeightfieldLayerSet) void {
    for (0..@intCast(lset.nlayers)) |i| {
        debugDrawHeightfieldLayer(dd, &lset.layers[i], @intCast(i));
    }
}

/// Draw heightfield layers regions (colored by region)
pub fn debugDrawHeightfieldLayersRegions(dd: DebugDraw, lset: *const HeightfieldLayerSet) void {
    for (0..@intCast(lset.nlayers)) |i| {
        const layer = &lset.layers[i];
        const cs = layer.cs;
        const ch = layer.ch;
        const w = layer.width;
        const h = layer.height;

        dd.begin(.quads, 1.0);

        var y: usize = 0;
        while (y < h) : (y += 1) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const lidx = x + y * w;
                const lh: i32 = @intCast(layer.heights[lidx]);
                if (lh == 0xff) continue;

                const reg = layer.regs[lidx];
                const col = if (reg > 0)
                    dd_mod.intToCol(@intCast(reg), 255)
                else
                    dd_mod.rgba(0, 0, 0, 255);

                const fx = layer.bmin[0] + @as(f32, @floatFromInt(x)) * cs;
                const fy = layer.bmin[1] + @as(f32, @floatFromInt(lh)) * ch;
                const fz = layer.bmin[2] + @as(f32, @floatFromInt(y)) * cs;

                dd.vertex(&.{ fx, fy, fz }, col);
                dd.vertex(&.{ fx, fy, fz + cs }, col);
                dd.vertex(&.{ fx + cs, fy, fz + cs }, col);
                dd.vertex(&.{ fx + cs, fy, fz }, col);
            }
        }

        dd.end();
    }
}

/// Helper: Draw box wireframe
fn debugDrawBoxWire(dd: DebugDraw, minx: f32, miny: f32, minz: f32, maxx: f32, maxy: f32, maxz: f32, col: u32, line_width: f32) void {
    dd.begin(.lines, line_width);

    // Bottom
    dd.vertex(&.{ minx, miny, minz }, col);
    dd.vertex(&.{ maxx, miny, minz }, col);
    dd.vertex(&.{ maxx, miny, minz }, col);
    dd.vertex(&.{ maxx, miny, maxz }, col);
    dd.vertex(&.{ maxx, miny, maxz }, col);
    dd.vertex(&.{ minx, miny, maxz }, col);
    dd.vertex(&.{ minx, miny, maxz }, col);
    dd.vertex(&.{ minx, miny, minz }, col);

    // Top
    dd.vertex(&.{ minx, maxy, minz }, col);
    dd.vertex(&.{ maxx, maxy, minz }, col);
    dd.vertex(&.{ maxx, maxy, minz }, col);
    dd.vertex(&.{ maxx, maxy, maxz }, col);
    dd.vertex(&.{ maxx, maxy, maxz }, col);
    dd.vertex(&.{ minx, maxy, maxz }, col);
    dd.vertex(&.{ minx, maxy, maxz }, col);
    dd.vertex(&.{ minx, maxy, minz }, col);

    // Sides
    dd.vertex(&.{ minx, miny, minz }, col);
    dd.vertex(&.{ minx, maxy, minz }, col);
    dd.vertex(&.{ maxx, miny, minz }, col);
    dd.vertex(&.{ maxx, maxy, minz }, col);
    dd.vertex(&.{ maxx, miny, maxz }, col);
    dd.vertex(&.{ maxx, maxy, maxz }, col);
    dd.vertex(&.{ minx, miny, maxz }, col);
    dd.vertex(&.{ minx, maxy, maxz }, col);

    dd.end();
}

/// Draw region connections between contours
pub fn debugDrawRegionConnections(dd: DebugDraw, cset: *const ContourSet, alpha: f32) void {
    const orig = &cset.bmin;
    const cs = cset.cs;
    const ch = cset.ch;

    var pos: [3]f32 = undefined;
    var pos2: [3]f32 = undefined;

    const color = dd_mod.rgba(0, 0, 0, 196);

    dd.begin(.lines, 2.0);

    for (0..@intCast(cset.nconts)) |i| {
        const cont = &cset.conts[i];
        getContourCenter(cont, orig, cs, ch, &pos);

        for (0..@intCast(cont.nverts)) |j| {
            const v = &cont.verts[j * 4];
            if (v[3] == 0 or @as(u16, @intCast(v[3])) < cont.reg) continue;

            if (findContourFromSet(cset, @intCast(v[3]))) |cont2| {
                getContourCenter(cont2, orig, cs, ch, &pos2);
                dd_mod.appendArc(dd, pos[0], pos[1], pos[2], pos2[0], pos2[1], pos2[2], 0.25, 0.6, 0.6, color);
            }
        }
    }

    dd.end();

    const a: u8 = @intFromFloat(alpha * 255.0);
    dd.begin(.points, 7.0);

    for (0..@intCast(cset.nconts)) |i| {
        const cont = &cset.conts[i];
        const col = dd_mod.darkenCol(dd_mod.intToCol(@intCast(cont.reg), @intCast(a)));
        getContourCenter(cont, orig, cs, ch, &pos);
        dd.vertex(&pos, col);
    }

    dd.end();
}

fn getContourCenter(cont: *const recast.Contour, orig: *const [3]f32, cs: f32, ch: f32, center: *[3]f32) void {
    center[0] = 0;
    center[1] = 0;
    center[2] = 0;
    if (cont.nverts == 0) return;

    for (0..@intCast(cont.nverts)) |i| {
        const v = &cont.verts[i * 4];
        center[0] += @floatFromInt(v[0]);
        center[1] += @floatFromInt(v[1]);
        center[2] += @floatFromInt(v[2]);
    }

    const s = 1.0 / @as(f32, @floatFromInt(cont.nverts));
    center[0] *= s * cs;
    center[1] *= s * ch;
    center[2] *= s * cs;
    center[0] += orig[0];
    center[1] += orig[1] + 4.0 * ch;
    center[2] += orig[2];
}

fn findContourFromSet(cset: *const ContourSet, reg: u16) ?*const recast.Contour {
    for (0..@intCast(cset.nconts)) |i| {
        if (cset.conts[i].reg == reg) {
            return &cset.conts[i];
        }
    }
    return null;
}

/// Draw raw contours (unsmoothed)
pub fn debugDrawRawContours(dd: DebugDraw, cset: *const ContourSet, alpha: f32) void {
    const orig = &cset.bmin;
    const cs = cset.cs;
    const ch = cset.ch;

    const a: u8 = @intFromFloat(alpha * 255.0);

    dd.begin(.lines, 2.0);

    for (0..@intCast(cset.nconts)) |i| {
        const c = &cset.conts[i];
        const color = dd_mod.intToCol(@intCast(c.reg), @intCast(a));

        for (0..@intCast(c.nrverts)) |j| {
            const v = &c.rverts[j * 4];
            const fx = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
            const fy = orig[1] + @as(f32, @floatFromInt(v[1] + 1 + @as(i32, @intCast(i & 1)))) * ch;
            const fz = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
            dd.vertexXYZ(fx, fy, fz, color);
            if (j > 0) {
                dd.vertexXYZ(fx, fy, fz, color);
            }
        }
        // Loop last segment
        const v = &c.rverts[0];
        const fx = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
        const fy = orig[1] + @as(f32, @floatFromInt(v[1] + 1 + @as(i32, @intCast(i & 1)))) * ch;
        const fz = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
        dd.vertexXYZ(fx, fy, fz, color);
    }

    dd.end();

    dd.begin(.points, 2.0);

    for (0..@intCast(cset.nconts)) |i| {
        const c = &cset.conts[i];
        const color = dd_mod.darkenCol(dd_mod.intToCol(@intCast(c.reg), @intCast(a)));

        for (0..@intCast(c.nrverts)) |j| {
            const v = &c.rverts[j * 4];
            var off: f32 = 0;
            var colv = color;
            if ((v[3] & recast.BORDER_VERTEX) != 0) {
                colv = dd_mod.rgba(255, 255, 255, a);
                off = ch * 2.0;
            }

            const fx = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
            const fy = orig[1] + @as(f32, @floatFromInt(v[1] + 1 + @as(i32, @intCast(i & 1)))) * ch + off;
            const fz = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
            dd.vertexXYZ(fx, fy, fz, colv);
        }
    }

    dd.end();
}

/// Draw simplified contours
pub fn debugDrawContours(dd: DebugDraw, cset: *const ContourSet, alpha: f32) void {
    const orig = &cset.bmin;
    const cs = cset.cs;
    const ch = cset.ch;

    const a: u8 = @intFromFloat(alpha * 255.0);

    dd.begin(.lines, 2.5);

    for (0..@intCast(cset.nconts)) |i| {
        const c = &cset.conts[i];
        if (c.nverts == 0) continue;

        const color = dd_mod.intToCol(@intCast(c.reg), @intCast(a));
        const bcolor = dd_mod.lerpCol(color, dd_mod.rgba(255, 255, 255, a), 128);

        var j: usize = 0;
        var k: usize = @intCast(c.nverts - 1);
        while (j < c.nverts) : ({
            k = j;
            j += 1;
        }) {
            const va = &c.verts[k * 4];
            const vb = &c.verts[j * 4];
            const col = if ((va[3] & recast.AREA_BORDER) != 0) bcolor else color;

            var fx = orig[0] + @as(f32, @floatFromInt(va[0])) * cs;
            var fy = orig[1] + @as(f32, @floatFromInt(va[1] + 1 + @as(i32, @intCast(i & 1)))) * ch;
            var fz = orig[2] + @as(f32, @floatFromInt(va[2])) * cs;
            dd.vertexXYZ(fx, fy, fz, col);

            fx = orig[0] + @as(f32, @floatFromInt(vb[0])) * cs;
            fy = orig[1] + @as(f32, @floatFromInt(vb[1] + 1 + @as(i32, @intCast(i & 1)))) * ch;
            fz = orig[2] + @as(f32, @floatFromInt(vb[2])) * cs;
            dd.vertexXYZ(fx, fy, fz, col);
        }
    }

    dd.end();

    dd.begin(.points, 3.0);

    for (0..@intCast(cset.nconts)) |i| {
        const c = &cset.conts[i];
        const color = dd_mod.darkenCol(dd_mod.intToCol(@intCast(c.reg), @intCast(a)));

        for (0..@intCast(c.nverts)) |j| {
            const v = &c.verts[j * 4];
            var off: f32 = 0;
            var colv = color;
            if ((v[3] & recast.BORDER_VERTEX) != 0) {
                colv = dd_mod.rgba(255, 255, 255, a);
                off = ch * 2.0;
            }

            const fx = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
            const fy = orig[1] + @as(f32, @floatFromInt(v[1] + 1 + @as(i32, @intCast(i & 1)))) * ch + off;
            const fz = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
            dd.vertexXYZ(fx, fy, fz, colv);
        }
    }

    dd.end();
}

/// Draw polygon mesh
pub fn debugDrawPolyMesh(dd: DebugDraw, mesh: *const PolyMesh) void {
    const nvp = mesh.nvp;
    const cs = mesh.cs;
    const ch = mesh.ch;
    const orig = &mesh.bmin;

    // Draw triangulated polygons
    dd.begin(.tris, 1.0);

    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. (i + 1) * nvp * 2];
        const area = mesh.areas[i];

        var color: u32 = undefined;
        if (area == recast.WALKABLE_AREA) {
            color = dd_mod.rgba(0, 192, 255, 64);
        } else if (area == recast.NULL_AREA) {
            color = dd_mod.rgba(0, 0, 0, 64);
        } else {
            color = dd.areaToCol(area);
        }

        var vi: [3]u16 = undefined;
        var j: usize = 2;
        while (j < nvp) : (j += 1) {
            if (p[j] == recast.MESH_NULL_IDX) break;
            vi[0] = p[0];
            vi[1] = p[j - 1];
            vi[2] = p[j];

            for (0..3) |k| {
                const v = &mesh.verts[vi[k] * 3];
                const x = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
                const y = orig[1] + @as(f32, @floatFromInt(v[1] + 1)) * ch;
                const z = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
                dd.vertexXYZ(x, y, z, color);
            }
        }
    }

    dd.end();

    // Draw neighbour edges
    const coln = dd_mod.rgba(0, 48, 64, 32);
    dd.begin(.lines, 1.5);

    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. (i + 1) * nvp * 2];

        for (0..nvp) |j| {
            if (p[j] == recast.MESH_NULL_IDX) break;
            if ((p[nvp + j] & 0x8000) != 0) continue;

            const nj = if (j + 1 >= nvp or p[j + 1] == recast.MESH_NULL_IDX) 0 else j + 1;
            const vi = [2]u16{ p[j], p[nj] };

            for (0..2) |k| {
                const v = &mesh.verts[vi[k] * 3];
                const x = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
                const y = orig[1] + @as(f32, @floatFromInt(v[1] + 1)) * ch + 0.1;
                const z = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
                dd.vertexXYZ(x, y, z, coln);
            }
        }
    }

    dd.end();

    // Draw boundary edges
    const colb = dd_mod.rgba(0, 48, 64, 220);
    dd.begin(.lines, 2.5);

    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 .. (i + 1) * nvp * 2];

        for (0..nvp) |j| {
            if (p[j] == recast.MESH_NULL_IDX) break;
            if ((p[nvp + j] & 0x8000) == 0) continue;

            const nj = if (j + 1 >= nvp or p[j + 1] == recast.MESH_NULL_IDX) 0 else j + 1;
            const vi = [2]u16{ p[j], p[nj] };

            var col = colb;
            if ((p[nvp + j] & 0xf) != 0xf) {
                col = dd_mod.rgba(255, 255, 255, 128);
            }

            for (0..2) |k| {
                const v = &mesh.verts[vi[k] * 3];
                const x = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
                const y = orig[1] + @as(f32, @floatFromInt(v[1] + 1)) * ch + 0.1;
                const z = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
                dd.vertexXYZ(x, y, z, col);
            }
        }
    }

    dd.end();

    // Draw vertices
    dd.begin(.points, 3.0);
    const colv = dd_mod.rgba(0, 0, 0, 220);

    for (0..@intCast(mesh.nverts)) |i| {
        const v = &mesh.verts[i * 3];
        const x = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
        const y = orig[1] + @as(f32, @floatFromInt(v[1] + 1)) * ch + 0.1;
        const z = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
        dd.vertexXYZ(x, y, z, colv);
    }

    dd.end();
}

/// Draw polygon mesh detail (high-resolution triangulation)
pub fn debugDrawPolyMeshDetail(dd: DebugDraw, dmesh: *const PolyMeshDetail) void {
    // Draw triangles
    dd.begin(.tris, 1.0);

    for (0..@intCast(dmesh.nmeshes)) |i| {
        const m = dmesh.meshes[i * 4 .. i * 4 + 4];
        const bverts = m[0];
        const btris = m[2];
        const ntris: usize = @intCast(m[3]);
        const verts = dmesh.verts[bverts * 3 ..];
        const tris_base = btris * 4;

        const color = dd_mod.intToCol(@intCast(i), 192);

        for (0..ntris) |j| {
            const t_idx = tris_base + j * 4;
            dd.vertex(@ptrCast(&verts[dmesh.tris[t_idx + 0] * 3]), color);
            dd.vertex(@ptrCast(&verts[dmesh.tris[t_idx + 1] * 3]), color);
            dd.vertex(@ptrCast(&verts[dmesh.tris[t_idx + 2] * 3]), color);
        }
    }

    dd.end();

    // Internal edges
    dd.begin(.lines, 1.0);
    const coli = dd_mod.rgba(0, 0, 0, 64);

    for (0..@intCast(dmesh.nmeshes)) |i| {
        const m = dmesh.meshes[i * 4 .. i * 4 + 4];
        const bverts = m[0];
        const btris = m[2];
        const ntris: usize = @intCast(m[3]);
        const verts = dmesh.verts[bverts * 3 ..];
        const tris_base = btris * 4;

        for (0..ntris) |j| {
            const t = dmesh.tris[tris_base + j * 4 .. tris_base + (j + 1) * 4];

            var k: usize = 0;
            var kp: usize = 2;
            while (k < 3) : ({
                kp = k;
                k += 1;
            }) {
                const ef = (t[3] >> @intCast(kp * 2)) & 0x3;
                if (ef == 0 and t[kp] < t[k]) {
                    dd.vertex(@ptrCast(&verts[t[kp] * 3]), coli);
                    dd.vertex(@ptrCast(&verts[t[k] * 3]), coli);
                }
            }
        }
    }

    dd.end();

    // External edges
    dd.begin(.lines, 2.0);
    const cole = dd_mod.rgba(0, 0, 0, 64);

    for (0..@intCast(dmesh.nmeshes)) |i| {
        const m = dmesh.meshes[i * 4 .. i * 4 + 4];
        const bverts = m[0];
        const btris = m[2];
        const ntris: usize = @intCast(m[3]);
        const verts = dmesh.verts[bverts * 3 ..];
        const tris_base = btris * 4;

        for (0..ntris) |j| {
            const t = dmesh.tris[tris_base + j * 4 .. tris_base + (j + 1) * 4];

            var k: usize = 0;
            var kp: usize = 2;
            while (k < 3) : ({
                kp = k;
                k += 1;
            }) {
                const ef = (t[3] >> @intCast(kp * 2)) & 0x3;
                if (ef != 0) {
                    dd.vertex(@ptrCast(&verts[t[kp] * 3]), cole);
                    dd.vertex(@ptrCast(&verts[t[k] * 3]), cole);
                }
            }
        }
    }

    dd.end();

    // Vertices
    dd.begin(.points, 3.0);
    const colv = dd_mod.rgba(0, 0, 0, 64);

    for (0..@intCast(dmesh.nmeshes)) |i| {
        const m = dmesh.meshes[i * 4 .. i * 4 + 4];
        const bverts = m[0];
        const nverts = m[1];
        const verts = dmesh.verts[bverts * 3 ..];

        for (0..nverts) |j| {
            dd.vertex(@ptrCast(&verts[j * 3]), colv);
        }
    }

    dd.end();
}
