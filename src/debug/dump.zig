const std = @import("std");
const recast = @import("../recast.zig");

const PolyMesh = recast.PolyMesh;
const PolyMeshDetail = recast.PolyMeshDetail;

/// File I/O interface for exporting/importing data
pub const FileIO = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isWriting: *const fn (ptr: *anyopaque) bool,
        isReading: *const fn (ptr: *anyopaque) bool,
        write: *const fn (ptr: *anyopaque, data: []const u8) bool,
        read: *const fn (ptr: *anyopaque, buffer: []u8) bool,
    };

    pub fn isWriting(self: FileIO) bool {
        return self.vtable.isWriting(self.ptr);
    }

    pub fn isReading(self: FileIO) bool {
        return self.vtable.isReading(self.ptr);
    }

    pub fn write(self: FileIO, data: []const u8) bool {
        return self.vtable.write(self.ptr, data);
    }

    pub fn read(self: FileIO, buffer: []u8) bool {
        return self.vtable.read(self.ptr, buffer);
    }
};

/// Simple FileIO implementation using std.fs.File
pub const StdFileIO = struct {
    file: std.fs.File,
    mode: Mode,

    pub const Mode = enum {
        read,
        write,
    };

    const vtable = FileIO.VTable{
        .isWriting = isWriting,
        .isReading = isReading,
        .write = write,
        .read = read,
    };

    pub fn init(file: std.fs.File, mode: Mode) StdFileIO {
        return .{ .file = file, .mode = mode };
    }

    pub fn fileIO(self: *StdFileIO) FileIO {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn isWriting(ptr: *anyopaque) bool {
        const self: *StdFileIO = @ptrCast(@alignCast(ptr));
        return self.mode == .write;
    }

    fn isReading(ptr: *anyopaque) bool {
        const self: *StdFileIO = @ptrCast(@alignCast(ptr));
        return self.mode == .read;
    }

    fn write(ptr: *anyopaque, data: []const u8) bool {
        const self: *StdFileIO = @ptrCast(@alignCast(ptr));
        self.file.writeAll(data) catch return false;
        return true;
    }

    fn read(ptr: *anyopaque, buffer: []u8) bool {
        const self: *StdFileIO = @ptrCast(@alignCast(ptr));
        const n = self.file.readAll(buffer) catch return false;
        return n == buffer.len;
    }
};

// Helper to write formatted text
fn ioprintf(io: FileIO, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = io.write(text);
}

/// Dump PolyMesh to Wavefront OBJ format
pub fn dumpPolyMeshToObj(pmesh: *const PolyMesh, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;

    const nvp = pmesh.nvp;
    const cs = pmesh.cs;
    const ch = pmesh.ch;
    const orig = &pmesh.bmin;

    ioprintf(io, "# Recast Navmesh\n", .{});
    ioprintf(io, "o NavMesh\n\n", .{});

    // Write vertices
    for (0..@intCast(pmesh.nverts)) |i| {
        const v = &pmesh.verts[i * 3];
        const x = orig[0] + @as(f32, @floatFromInt(v[0])) * cs;
        const y = orig[1] + @as(f32, @floatFromInt(v[1] + 1)) * ch + 0.1;
        const z = orig[2] + @as(f32, @floatFromInt(v[2])) * cs;
        ioprintf(io, "v {d:.6} {d:.6} {d:.6}\n", .{ x, y, z });
    }

    ioprintf(io, "\n", .{});

    // Write faces (triangulated polygons)
    for (0..@intCast(pmesh.npolys)) |i| {
        const p = pmesh.polys[i * nvp * 2 .. (i + 1) * nvp * 2];
        var j: usize = 2;
        while (j < nvp) : (j += 1) {
            if (p[j] == recast.MESH_NULL_IDX) break;
            // OBJ indices are 1-based
            ioprintf(io, "f {d} {d} {d}\n", .{ p[0] + 1, p[j - 1] + 1, p[j] + 1 });
        }
    }
}

/// Dump PolyMeshDetail to Wavefront OBJ format
pub fn dumpPolyMeshDetailToObj(dmesh: *const PolyMeshDetail, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;

    ioprintf(io, "# Recast Navmesh Detail\n", .{});
    ioprintf(io, "o NavMeshDetail\n\n", .{});

    // Write vertices
    for (0..@intCast(dmesh.nverts)) |i| {
        const v = &dmesh.verts[i * 3];
        ioprintf(io, "v {d:.6} {d:.6} {d:.6}\n", .{ v[0], v[1], v[2] });
    }

    ioprintf(io, "\n", .{});

    // Write triangles
    for (0..@intCast(dmesh.nmeshes)) |i| {
        const m = dmesh.meshes[i * 4 .. i * 4 + 4];
        const bverts = m[0];
        const btris = m[2];
        const ntris: usize = @intCast(m[3]);

        for (0..ntris) |j| {
            const t_idx = (btris + @as(u32, @intCast(j))) * 4;
            const t = dmesh.tris[t_idx .. t_idx + 4];

            // OBJ indices are 1-based
            const v0 = bverts + @as(u32, t[0]) + 1;
            const v1 = bverts + @as(u32, t[1]) + 1;
            const v2 = bverts + @as(u32, t[2]) + 1;

            ioprintf(io, "f {d} {d} {d}\n", .{ v0, v1, v2 });
        }
    }
}

/// Log build times from context
pub fn logBuildTimes(ctx: *recast.Context, total_tile_usec: i32) void {
    const total_ms: f32 = @as(f32, @floatFromInt(total_tile_usec)) / 1000.0;

    std.debug.print("\n", .{});
    std.debug.print("Build Times\n", .{});
    std.debug.print("-----------\n", .{});

    // Get timers from context
    const timers = [_]recast.TimerLabel{
        .rasterize_triangles,
        .build_compact_heightfield,
        .build_contours,
        .build_contours_trace,
        .build_contours_simplify,
        .filter_border,
        .filter_walkable,
        .median_area,
        .filter_low_obstacles,
        .build_polymesh,
        .merge_polymesh,
        .erode_area,
        .mark_box_area,
        .mark_cylinder_area,
        .mark_convex_area,
        .build_distancefield,
        .build_distancefield_dist,
        .build_regions,
        .build_regions_watershed,
        .build_regions_expand,
        .build_regions_flood,
        .build_regions_filter,
        .build_layers,
        .build_polymeshdetail,
        .merge_polymeshdetail,
    };

    for (timers) |label| {
        const usec = ctx.getAccumulatedTime(label);
        const ms: f32 = @as(f32, @floatFromInt(usec)) / 1000.0;
        const pct = if (total_ms > 0) (ms / total_ms) * 100.0 else 0.0;
        std.debug.print("{s}: {d:.2}ms ({d:.1}%)\n", .{ @tagName(label), ms, pct });
    }

    std.debug.print("-----------\n", .{});
    std.debug.print("Total: {d:.2}ms\n", .{total_ms});
    std.debug.print("\n", .{});
}

// Binary dump/read of intermediate Recast structures. 1:1 with upstream
// RecastDump.cpp (same magic/version tags and field order). The struct-array
// blobs (contours, compact cells/spans) round-trip within this port; exact
// byte-compatibility with the C++ reader depends on identical struct layout.

const CSET_MAGIC: i32 = ('c' << 24) | ('s' << 16) | ('e' << 8) | 't';
const CSET_VERSION: i32 = 2;
const CHF_MAGIC: i32 = ('r' << 24) | ('c' << 16) | ('h' << 8) | 'f';
const CHF_VERSION: i32 = 3;

fn wr(io: FileIO, comptime T: type, value: T) !void {
    var tmp = value;
    if (!io.write(std.mem.asBytes(&tmp))) return error.WriteFailed;
}
fn rd(io: FileIO, comptime T: type) !T {
    var v: T = undefined;
    if (!io.read(std.mem.asBytes(&v))) return error.ReadFailed;
    return v;
}
fn wrSlice(io: FileIO, comptime T: type, s: []const T) !void {
    if (s.len == 0) return;
    if (!io.write(std.mem.sliceAsBytes(s))) return error.WriteFailed;
}
fn rdSlice(io: FileIO, comptime T: type, s: []T) !void {
    if (s.len == 0) return;
    if (!io.read(std.mem.sliceAsBytes(s))) return error.ReadFailed;
}
fn wrVec(io: FileIO, v: anytype) !void {
    try wr(io, f32, v.x);
    try wr(io, f32, v.y);
    try wr(io, f32, v.z);
}
fn rdVec(io: FileIO, v: anytype) !void {
    v.x = try rd(io, f32);
    v.y = try rd(io, f32);
    v.z = try rd(io, f32);
}

/// Dump ContourSet to binary (rcContourSet format).
pub fn dumpContourSet(cset: *const recast.ContourSet, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;

    try wr(io, i32, CSET_MAGIC);
    try wr(io, i32, CSET_VERSION);
    try wr(io, i32, cset.nconts);
    try wrVec(io, cset.bmin);
    try wrVec(io, cset.bmax);
    try wr(io, f32, cset.cs);
    try wr(io, f32, cset.ch);
    try wr(io, i32, cset.width);
    try wr(io, i32, cset.height);
    try wr(io, i32, cset.border_size);

    for (cset.conts[0..@intCast(cset.nconts)]) |cont| {
        try wr(io, i32, cont.nverts);
        try wr(io, i32, cont.nrverts);
        try wr(io, u16, cont.reg);
        try wr(io, u8, cont.area);
        try wrSlice(io, i32, cont.verts[0 .. @as(usize, @intCast(cont.nverts)) * 4]);
        try wrSlice(io, i32, cont.rverts[0 .. @as(usize, @intCast(cont.nrverts)) * 4]);
    }
}

/// Read ContourSet from binary. Allocates contour storage via cset.allocator;
/// `cset` must be freshly initialised (empty).
pub fn readContourSet(cset: *recast.ContourSet, io: FileIO) !void {
    if (!io.isReading()) return error.NotReading;

    if (try rd(io, i32) != CSET_MAGIC) return error.BadMagic;
    if (try rd(io, i32) != CSET_VERSION) return error.BadVersion;

    cset.nconts = try rd(io, i32);
    cset.conts = try cset.allocator.alloc(recast.Contour, @intCast(cset.nconts));
    for (cset.conts) |*c| c.* = recast.Contour.init(cset.allocator);

    try rdVec(io, &cset.bmin);
    try rdVec(io, &cset.bmax);
    cset.cs = try rd(io, f32);
    cset.ch = try rd(io, f32);
    cset.width = try rd(io, i32);
    cset.height = try rd(io, i32);
    cset.border_size = try rd(io, i32);

    for (cset.conts) |*cont| {
        cont.nverts = try rd(io, i32);
        cont.nrverts = try rd(io, i32);
        cont.reg = try rd(io, u16);
        cont.area = try rd(io, u8);
        cont.verts = try cset.allocator.alloc(i32, @as(usize, @intCast(cont.nverts)) * 4);
        cont.rverts = try cset.allocator.alloc(i32, @as(usize, @intCast(cont.nrverts)) * 4);
        try rdSlice(io, i32, cont.verts);
        try rdSlice(io, i32, cont.rverts);
    }
}

/// Dump CompactHeightfield to binary (rcCompactHeightfield format).
pub fn dumpCompactHeightfield(chf: *const recast.CompactHeightfield, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;

    try wr(io, i32, CHF_MAGIC);
    try wr(io, i32, CHF_VERSION);
    try wr(io, i32, chf.width);
    try wr(io, i32, chf.height);
    try wr(io, i32, chf.span_count);
    try wr(io, i32, chf.walkable_height);
    try wr(io, i32, chf.walkable_climb);
    try wr(io, i32, chf.border_size);
    try wr(io, u16, chf.max_distance);
    try wr(io, u16, chf.max_regions);
    try wrVec(io, chf.bmin);
    try wrVec(io, chf.bmax);
    try wr(io, f32, chf.cs);
    try wr(io, f32, chf.ch);

    var tmp: i32 = 0;
    if (chf.cells.len > 0) tmp |= 1;
    if (chf.spans.len > 0) tmp |= 2;
    if (chf.dist.len > 0) tmp |= 4;
    if (chf.areas.len > 0) tmp |= 8;
    try wr(io, i32, tmp);

    try wrSlice(io, recast.CompactCell, chf.cells);
    try wrSlice(io, recast.CompactSpan, chf.spans);
    try wrSlice(io, u16, chf.dist);
    try wrSlice(io, u8, chf.areas);
}

/// Read CompactHeightfield from binary. Allocates via chf.allocator; `chf` must
/// be freshly initialised (empty).
pub fn readCompactHeightfield(chf: *recast.CompactHeightfield, io: FileIO) !void {
    if (!io.isReading()) return error.NotReading;

    if (try rd(io, i32) != CHF_MAGIC) return error.BadMagic;
    if (try rd(io, i32) != CHF_VERSION) return error.BadVersion;

    chf.width = try rd(io, i32);
    chf.height = try rd(io, i32);
    chf.span_count = try rd(io, i32);
    chf.walkable_height = try rd(io, i32);
    chf.walkable_climb = try rd(io, i32);
    chf.border_size = try rd(io, i32);
    chf.max_distance = try rd(io, u16);
    chf.max_regions = try rd(io, u16);
    try rdVec(io, &chf.bmin);
    try rdVec(io, &chf.bmax);
    chf.cs = try rd(io, f32);
    chf.ch = try rd(io, f32);

    const tmp = try rd(io, i32);
    const wh: usize = @intCast(chf.width * chf.height);
    const sc: usize = @intCast(chf.span_count);

    if ((tmp & 1) != 0) {
        chf.cells = try chf.allocator.alloc(recast.CompactCell, wh);
        try rdSlice(io, recast.CompactCell, chf.cells);
    }
    if ((tmp & 2) != 0) {
        chf.spans = try chf.allocator.alloc(recast.CompactSpan, sc);
        try rdSlice(io, recast.CompactSpan, chf.spans);
    }
    if ((tmp & 4) != 0) {
        chf.dist = try chf.allocator.alloc(u16, sc);
        try rdSlice(io, u16, chf.dist);
    }
    if ((tmp & 8) != 0) {
        chf.areas = try chf.allocator.alloc(u8, sc);
        try rdSlice(io, u8, chf.areas);
    }
}
