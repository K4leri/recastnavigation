const std = @import("std");

/// Simple OBJ mesh data
pub const ObjMesh = struct {
    vertices: []f32, // x,y,z coordinates (length = vertex_count * 3)
    indices: []i32, // triangle indices (length = tri_count * 3)
    vertex_count: usize,
    tri_count: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ObjMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
        self.* = undefined;
    }
};

/// Load OBJ file and return mesh data
/// Supports vertices (v) and faces (f) with triangulation of quads
pub fn loadObj(file_path: []const u8, allocator: std.mem.Allocator) !ObjMesh {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var vertices = std.array_list.Managed(f32).init(allocator);
    defer vertices.deinit();

    var indices = std.array_list.Managed(i32).init(allocator);
    defer indices.deinit();

    // New I/O API in Zig 0.15.1 - streaming mode with dynamic buffer
    // Buffer size can be adjusted based on expected line length
    var read_buffer: [8192]u8 = undefined; // 8KB buffer for longer lines
    var file_reader = file.readerStreaming(&read_buffer);
    const reader = &file_reader.interface;

    while (reader.takeDelimiterExclusive('\n')) |line| {
        var trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "v ")) {
            // Vertex: v x y z
            var iter = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
            var coords: [3]f32 = undefined;
            var i: usize = 0;
            while (iter.next()) |token| : (i += 1) {
                if (i >= 3) break;
                coords[i] = try std.fmt.parseFloat(f32, token);
            }
            try vertices.append(coords[0]);
            try vertices.append(coords[1]);
            try vertices.append(coords[2]);
        } else if (std.mem.startsWith(u8, trimmed, "f ")) {
            // Face: f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3 [v4/vt4/vn4]
            var iter = std.mem.tokenizeScalar(u8, trimmed[2..], ' ');
            var face_verts = std.array_list.Managed(i32).init(allocator);
            defer face_verts.deinit();

            while (iter.next()) |token| {
                // Parse v/vt/vn or v//vn or v/vt or v
                var slash_iter = std.mem.tokenizeScalar(u8, token, '/');
                if (slash_iter.next()) |v_str| {
                    const v_idx = try std.fmt.parseInt(i32, v_str, 10);
                    try face_verts.append(v_idx - 1); // OBJ indices start at 1
                }
            }

            // Triangulate: if quad (4 vertices), split into 2 triangles
            if (face_verts.items.len == 3) {
                // Triangle
                try indices.append(face_verts.items[0]);
                try indices.append(face_verts.items[1]);
                try indices.append(face_verts.items[2]);
            } else if (face_verts.items.len == 4) {
                // Quad -> two triangles: (0,1,2) and (0,2,3)
                try indices.append(face_verts.items[0]);
                try indices.append(face_verts.items[1]);
                try indices.append(face_verts.items[2]);

                try indices.append(face_verts.items[0]);
                try indices.append(face_verts.items[2]);
                try indices.append(face_verts.items[3]);
            }
            // Ignore faces with > 4 vertices for now
        }
    } else |err| switch (err) {
        error.EndOfStream => {}, // Normal end of file
        error.StreamTooLong => return error.LineTooLong, // Line exceeds buffer size
        error.ReadFailed => return error.ReadFailed,
    }

    const vertex_count = vertices.items.len / 3;
    const tri_count = indices.items.len / 3;

    return ObjMesh{
        .vertices = try vertices.toOwnedSlice(),
        .indices = try indices.toOwnedSlice(),
        .vertex_count = vertex_count,
        .tri_count = tri_count,
        .allocator = allocator,
    };
}

// Tests
test "loadObj - basic functionality" {
    const allocator = std.testing.allocator;

    // Create a simple test OBJ file
    const test_obj =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3
    ;

    // Write to temp file
    const tmp_path = "test_temp.obj";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(test_obj);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var mesh = try loadObj(tmp_path, allocator);
    defer mesh.deinit();

    try std.testing.expectEqual(@as(usize, 3), mesh.vertex_count);
    try std.testing.expectEqual(@as(usize, 1), mesh.tri_count);
    try std.testing.expectEqual(@as(f32, 0.0), mesh.vertices[0]);
    try std.testing.expectEqual(@as(i32, 0), mesh.indices[0]);
}

test "loadObj - quad triangulation" {
    const allocator = std.testing.allocator;

    const test_obj =
        \\v 0.0 0.0 0.0
        \\v 1.0 0.0 0.0
        \\v 1.0 1.0 0.0
        \\v 0.0 1.0 0.0
        \\f 1 2 3 4
    ;

    const tmp_path = "test_temp_quad.obj";
    {
        const file = try std.fs.cwd().createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(test_obj);
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var mesh = try loadObj(tmp_path, allocator);
    defer mesh.deinit();

    try std.testing.expectEqual(@as(usize, 4), mesh.vertex_count);
    try std.testing.expectEqual(@as(usize, 2), mesh.tri_count); // Quad -> 2 triangles
    try std.testing.expectEqual(@as(usize, 6), mesh.indices.len); // 2 * 3 indices
}
