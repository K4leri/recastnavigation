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

// Simplified versions of binary dump/read functions
// These are placeholder implementations - full binary serialization
// would require more complex format handling

/// Dump ContourSet to binary (placeholder)
pub fn dumpContourSet(cset: *const recast.ContourSet, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;
    // TODO: Implement binary serialization
    _ = cset;
    return error.NotImplemented;
}

/// Read ContourSet from binary (placeholder)
pub fn readContourSet(cset: *recast.ContourSet, io: FileIO) !void {
    if (!io.isReading()) return error.NotReading;
    // TODO: Implement binary deserialization
    _ = cset;
    return error.NotImplemented;
}

/// Dump CompactHeightfield to binary (placeholder)
pub fn dumpCompactHeightfield(chf: *const recast.CompactHeightfield, io: FileIO) !void {
    if (!io.isWriting()) return error.NotWriting;
    // TODO: Implement binary serialization
    _ = chf;
    return error.NotImplemented;
}

/// Read CompactHeightfield from binary (placeholder)
pub fn readCompactHeightfield(chf: *recast.CompactHeightfield, io: FileIO) !void {
    if (!io.isReading()) return error.NotReading;
    // TODO: Implement binary deserialization
    _ = chf;
    return error.NotImplemented;
}
