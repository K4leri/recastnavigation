//! Minimal Wavefront .obj reader for the Zig benchmark runner.
//!
//! Parses the exact format our exporter produces for the shared bench geometry
//! (`test_data/bench_geom/*.obj`): a leading `# bench_geom verts=.. tris=..`
//! comment, `v x y z` vertex lines, and `f a b c` 1-indexed triangle faces.
//! For robustness it also accepts the general OBJ face token forms `a/b/c`,
//! `a//c`, `a/b` (the vertex index is the part before the first `/`) and skips
//! any other line type (vt, vn, comments, blanks) gracefully.
//!
//! The whole file is read into memory (bench geometry tops out at a few MB) via
//! the repo-idiomatic Zig 0.16 read path: a self-contained `std.Io.Threaded`
//! backend driving `std.Io.Dir.cwd().readFileAlloc(...)` (mirrors
//! `demo/src/io_util.zig` and `test/obj_loader.zig`).

const std = @import("std");

/// Triangle soup loaded from an .obj file. Caller owns it; call `deinit`.
pub const Mesh = struct {
    /// Flat x,y,z vertex triplets. `len == vertCount() * 3`.
    verts: []f32,
    /// Flat triangle index triplets, 0-INDEXED. `len == triCount() * 3`.
    tris: []i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Mesh) void {
        self.allocator.free(self.verts);
        self.allocator.free(self.tris);
        self.* = undefined;
    }

    pub fn vertCount(self: Mesh) usize {
        return self.verts.len / 3;
    }

    pub fn triCount(self: Mesh) usize {
        return self.tris.len / 3;
    }
};

/// Reads an entire file into an owned buffer (Zig 0.16 `std.Io.Dir`).
/// Self-contained: spins up a Threaded Io backend for the blocking read,
/// matching `demo/src/io_util.zig` / `test/obj_loader.zig`.
fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

/// Vertex index of an OBJ face token, converted 1-indexed -> 0-indexed.
/// Accepts `a`, `a/b`, `a/b/c`, `a//c` — only the field before the first `/`
/// is the vertex index; the rest (texcoord/normal) is ignored.
fn parseFaceIndex(token: []const u8) !i32 {
    const slash = std.mem.indexOfScalar(u8, token, '/');
    const v_str = if (slash) |s| token[0..s] else token;
    const one_indexed = try std.fmt.parseInt(i32, v_str, 10);
    return one_indexed - 1;
}

/// Load + parse an .obj file into a triangle soup. Caller owns the returned
/// Mesh (call `deinit`). Triangles only (3 vertices per face); our exported
/// bench geometry is all triangles, so non-triangle faces are skipped.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Mesh {
    const content = try readWholeFile(allocator, path);
    defer allocator.free(content);

    var verts = std.array_list.Managed(f32).init(allocator);
    defer verts.deinit();
    var tris = std.array_list.Managed(i32).init(allocator);
    defer tris.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        // Tolerate CRLF (and stray surrounding whitespace).
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue; // comment

        if (std.mem.startsWith(u8, line, "v ")) {
            var it = std.mem.tokenizeScalar(u8, line[2..], ' ');
            var coords: [3]f32 = .{ 0, 0, 0 };
            var i: usize = 0;
            while (it.next()) |tok| : (i += 1) {
                if (i >= 3) break;
                coords[i] = try std.fmt.parseFloat(f32, tok);
            }
            try verts.append(coords[0]);
            try verts.append(coords[1]);
            try verts.append(coords[2]);
        } else if (std.mem.startsWith(u8, line, "f ")) {
            var it = std.mem.tokenizeScalar(u8, line[2..], ' ');
            var idx: [3]i32 = undefined;
            var i: usize = 0;
            while (it.next()) |tok| : (i += 1) {
                if (i >= 3) break; // triangles only
                idx[i] = try parseFaceIndex(tok);
            }
            // Only emit complete triangles (our bench data is all triangles).
            if (i >= 3) {
                try tris.append(idx[0]);
                try tris.append(idx[1]);
                try tris.append(idx[2]);
            }
        }
        // Any other line type (vt, vn, o, g, mtllib, ...) is ignored.
    }

    return Mesh{
        .verts = try verts.toOwnedSlice(),
        .tris = try tris.toOwnedSlice(),
        .allocator = allocator,
    };
}
