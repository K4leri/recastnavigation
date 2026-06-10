//! Bench group: recast pipeline STAGES (isolation class B). A stage needs upstream
//! pipeline state, so each uses core.Bench.setup to build a small synthetic compact
//! heightfield ONCE (untimed) via the real pipeline, then times the target stage on
//! it. Stage ANALOGS (alternative algorithms, proven identical by hashing the stage's
//! output) will be added alongside each orig here. Aggregated by ../microbench.zig.
//!
//! Input is a small flat quad (not an 8M-cell map): the absolute times are tiny, but
//! they are apples-to-apples for ranking an orig vs an analog of the same stage.

const std = @import("std");
const core = @import("core.zig");
const nav = @import("zig-recast");
const dna = std.mem.doNotOptimizeAway;
const Vec3 = nav.math.Vec3;

const alloc = std.heap.page_allocator;

// Synthetic flat 10x10 world quad at y=0, two +Y-facing triangles (walkable).
const verts = [_]f32{ 0, 0, 0, 10, 0, 0, 10, 0, 10, 0, 0, 10 };
const tris = [_]i32{ 0, 2, 1, 0, 3, 2 };
const cs: f32 = 0.3;
const ch: f32 = 0.2;
const grid_w: i32 = 34;
const grid_h: i32 = 34;

var ctx: nav.Context = undefined;
var chf: nav.CompactHeightfield = undefined;
var chf_ready = false;

/// Build a small compact heightfield (rasterize -> compact -> erode) once. This is
/// the prerequisite for the region stages; kept untimed (core calls setup before measure).
fn buildPrereqChf() void {
    if (chf_ready) return;
    ctx = nav.Context.init(alloc);
    ctx.enableLog(false);
    ctx.enableTimer(false);
    const bmin = Vec3.init(0, -1, 0);
    const bmax = Vec3.init(10, 1, 10);

    var hf = nav.Heightfield.init(alloc, grid_w, grid_h, bmin, bmax, cs, ch) catch unreachable;
    defer hf.deinit();

    var areas = [_]u8{nav.recast.config.AreaId.NULL_AREA} ** 2;
    nav.recast.filter.markWalkableTriangles(&ctx, 45.0, &verts, &tris, &areas);
    nav.recast.rasterization.rasterizeTriangles(&ctx, &verts, &tris, &areas, &hf, 1) catch unreachable;

    const span_count = nav.recast.compact.getHeightFieldSpanCount(&ctx, &hf);
    chf = nav.CompactHeightfield.init(alloc, grid_w, grid_h, @intCast(span_count), 2, 1, bmin, bmax, cs, ch, 0) catch unreachable;
    nav.recast.compact.buildCompactHeightfield(&ctx, 2, 1, &hf, &chf) catch unreachable;
    nav.recast.area.erodeWalkableArea(&ctx, 1, &chf, alloc) catch unreachable;
    chf_ready = true;
}

fn runBuildDistanceField(i: usize) void {
    _ = i;
    nav.recast.region.buildDistanceField(&ctx, &chf, alloc) catch {};
    dna(chf.max_distance);
}
fn checkBuildDistanceField() bool {
    nav.recast.region.buildDistanceField(&ctx, &chf, alloc) catch return false;
    return chf.span_count > 0 and chf.max_distance > 0; // distance field actually computed
}

// ANALOG: the same stage with runtime `for (0..4)` in both direction sweeps
// instead of the library's `inline for`. Audits the comptime-direction effect on
// Zig 0.16 (see analog_distfield.zig + RESULTS.md addendum).
const analog_distfield = @import("analog_distfield.zig");

fn runBuildDistanceFieldOrig(i: usize) void {
    _ = i;
    analog_distfield.buildDistanceField_orig(&ctx, &chf, alloc) catch {};
    dna(chf.max_distance);
}
// EXACT gate: the orig-for variant must produce a bit-identical distance field
// (chf.dist array + max_distance) to the real library function.
fn checkBuildDistanceFieldOrig() bool {
    nav.recast.region.buildDistanceField(&ctx, &chf, alloc) catch return false;
    const ref_max = chf.max_distance;
    const ref = alloc.dupe(u16, chf.dist) catch return false;
    defer alloc.free(ref);

    analog_distfield.buildDistanceField_orig(&ctx, &chf, alloc) catch return false;
    if (chf.max_distance != ref_max) return false;
    if (chf.dist.len != ref.len) return false;
    for (chf.dist, ref) |a, b| {
        if (a != b) return false;
    }
    return true;
}

pub const benches = [_]core.Bench{
    .{ .name = "buildDistanceField", .module = "recast.region", .isolation = "B", .setup = buildPrereqChf, .run = runBuildDistanceField, .check = checkBuildDistanceField },
    .{ .name = "buildDistanceField", .module = "recast.region", .impl = "orig-for-runtime", .isolation = "B", .setup = buildPrereqChf, .run = runBuildDistanceFieldOrig, .check = checkBuildDistanceFieldOrig },
};
