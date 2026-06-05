//! Inspector — pure staging<->object mapping for the Properties inspector
//! (cluster F, feature F5). NO UI here: this layer only holds the staging
//! buffers that mirror the SINGLE selected scene object and the pure functions
//! that (a) seed staging from a live object and (b) build the `after` value to
//! record as an `edit_volume` / `edit_offmesh` op. main.zig owns one instance,
//! renders dvui widgets bound to the staging fields, and on Apply calls
//! `buildAfterVolume` / `buildAfterOffmesh` to produce the committed value.
//!
//! Keeping the field-mapping + hmin<=hmax clamp here (instead of inline in the
//! UI loop) makes the load-bearing logic unit-testable without dvui.

const std = @import("std");
const ig = @import("../input_geom.zig");
const ConvexVolume = ig.ConvexVolume;
const VolumeMode = ig.VolumeMode;
const edit_op = @import("edit_op.zig");
const OffMeshData = edit_op.OffMeshData;

/// Editable scalars mirrored from the selected ConvexVolume. Vertices/id are NOT
/// staged here (they are preserved from the live object on Apply); only the
/// numerically-editable scalars the inspector exposes live in the buffer.
pub const VolumeStaging = struct {
    hmin: f32 = 0,
    hmax: f32 = 0,
    area: f32 = 0, // u8 held as f32 for the slider/dropdown proxy
    mode: VolumeMode = .surface,
    band_below: f32 = 1.0,
    band_above: f32 = 1.0,

    /// Seed the buffer from a live volume value.
    pub fn seed(vol: ConvexVolume) VolumeStaging {
        return .{
            .hmin = vol.hmin,
            .hmax = vol.hmax,
            .area = @floatFromInt(vol.area),
            .mode = vol.mode,
            .band_below = vol.band_below,
            .band_above = vol.band_above,
        };
    }
};

/// Editable fields mirrored from the selected off-mesh connection.
pub const OffMeshStaging = struct {
    start: [3]f32 = .{ 0, 0, 0 },
    end: [3]f32 = .{ 0, 0, 0 },
    rad: f32 = 0,
    dir: u8 = 0, // 0 = one-way, 1 = bidirectional
    area: f32 = 0, // u8 proxy
    flags: u16 = 0,

    /// Seed the buffer from a live off-mesh snapshot.
    pub fn seed(d: OffMeshData) OffMeshStaging {
        return .{
            .start = .{ d.verts[0], d.verts[1], d.verts[2] },
            .end = .{ d.verts[3], d.verts[4], d.verts[5] },
            .rad = d.rad,
            .dir = d.dir,
            .area = @floatFromInt(d.area),
            .flags = d.flags,
        };
    }
};

/// Build the `after` ConvexVolume by overlaying the staged scalars on top of a
/// COPY of the current live volume (so verts/id/etc. are preserved verbatim).
/// VALIDATION: if hmin > hmax the two are swapped so the band is never inverted.
pub fn buildAfterVolume(live: ConvexVolume, st: VolumeStaging) ConvexVolume {
    var out = live; // preserves verts, nverts, id
    var lo = st.hmin;
    var hi = st.hmax;
    if (lo > hi) {
        const t = lo;
        lo = hi;
        hi = t;
    }
    out.hmin = lo;
    out.hmax = hi;
    out.area = @intFromFloat(std.math.clamp(@round(st.area), 0, 63));
    out.mode = st.mode;
    out.band_below = st.band_below;
    out.band_above = st.band_above;
    return out;
}

/// Build the `after` OffMeshData by overlaying staged fields on a COPY of the
/// live snapshot (preserving the stable `.id`). `dir` is clamped to 0/1.
pub fn buildAfterOffmesh(live: OffMeshData, st: OffMeshStaging) OffMeshData {
    var out = live; // preserves id
    out.verts = .{ st.start[0], st.start[1], st.start[2], st.end[0], st.end[1], st.end[2] };
    out.rad = st.rad;
    out.dir = if (st.dir != 0) 1 else 0;
    out.area = @intFromFloat(std.math.clamp(@round(st.area), 0, 63));
    out.flags = st.flags;
    return out;
}

test "buildAfterVolume maps fields and clamps hmin<=hmax (swap on inversion)" {
    var live = ConvexVolume{ .nverts = 3, .id = 42, .hmin = 1, .hmax = 2, .area = 0, .mode = .prism };
    live.verts[0] = 9.0; // a vert that must survive untouched

    // Normal case: fields copied through, verts/id preserved.
    const st = VolumeStaging{ .hmin = 0.5, .hmax = 5.0, .area = 3, .mode = .surface, .band_below = 2.0, .band_above = 3.0 };
    const a = buildAfterVolume(live, st);
    try std.testing.expectEqual(@as(f32, 0.5), a.hmin);
    try std.testing.expectEqual(@as(f32, 5.0), a.hmax);
    try std.testing.expectEqual(@as(u8, 3), a.area);
    try std.testing.expectEqual(VolumeMode.surface, a.mode);
    try std.testing.expectEqual(@as(f32, 2.0), a.band_below);
    try std.testing.expectEqual(@as(f32, 3.0), a.band_above);
    try std.testing.expectEqual(@as(u32, 42), a.id); // id preserved
    try std.testing.expectEqual(@as(f32, 9.0), a.verts[0]); // verts preserved

    // Inverted band: hmin>hmax -> swapped.
    const inv = buildAfterVolume(live, .{ .hmin = 8.0, .hmax = 1.0 });
    try std.testing.expectEqual(@as(f32, 1.0), inv.hmin);
    try std.testing.expectEqual(@as(f32, 8.0), inv.hmax);

    // Area clamps into [0,63].
    const cl = buildAfterVolume(live, .{ .area = 200 });
    try std.testing.expectEqual(@as(u8, 63), cl.area);
}

test "buildAfterOffmesh maps endpoints/rad/area/flags, clamps dir, preserves id" {
    const live = OffMeshData{ .verts = .{ 0, 0, 0, 0, 0, 0 }, .rad = 1, .dir = 0, .area = 0, .flags = 0, .id = 1000 };
    const st = OffMeshStaging{
        .start = .{ 1, 2, 3 },
        .end = .{ 4, 5, 6 },
        .rad = 2.5,
        .dir = 7, // non-zero -> clamps to 1
        .area = 4,
        .flags = 0x0A,
    };
    const a = buildAfterOffmesh(live, st);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 1, 2, 3, 4, 5, 6 }, &a.verts);
    try std.testing.expectEqual(@as(f32, 2.5), a.rad);
    try std.testing.expectEqual(@as(u8, 1), a.dir); // clamped
    try std.testing.expectEqual(@as(u8, 4), a.area);
    try std.testing.expectEqual(@as(u16, 0x0A), a.flags);
    try std.testing.expectEqual(@as(u32, 1000), a.id); // id preserved

    // dir 0 stays 0.
    const z = buildAfterOffmesh(live, .{ .dir = 0 });
    try std.testing.expectEqual(@as(u8, 0), z.dir);
}
