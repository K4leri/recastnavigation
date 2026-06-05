/// STL geometry importer — binary and ASCII formats.
/// Detects format automatically, see detectFormat() for heuristic details.
/// Normals from the file are ignored (re-computed by recast pipeline).
/// Vertices are emitted as-is (no deduplication — YAGNI).
const std = @import("std");

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const Mesh = struct {
    /// Owned flat array: x0,y0,z0, x1,y1,z1, ...
    verts: []f32,
    /// Owned flat array: i0,i1,i2, i3,i4,i5, ... (3 indices per triangle)
    tris: []i32,

    pub fn deinit(self: Mesh, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.tris);
    }
};

/// Parse STL (binary OR ASCII — auto-detected) from raw bytes into Mesh.
/// Returns error.TruncatedStl / error.BadStl on malformed input.
pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Mesh {
    const fmt = detectFormat(bytes);
    return switch (fmt) {
        .binary => parseBinary(alloc, bytes),
        .ascii => parseAscii(alloc, bytes),
    };
}

// ---------------------------------------------------------------------------
// Format detection
// ---------------------------------------------------------------------------

const Format = enum { binary, ascii };

/// Heuristic (documented):
///
/// 1. If len < 84  → too short for binary header → try ASCII.
/// 2. Read triCount from bytes[80..84] (LE u32).
///    If len == 84 + 50 * triCount  → binary (exact size match).
/// 3. If bytes start with "solid" AND contain "facet" → ASCII.
/// 4. Otherwise fall back to binary (handles malformed ASCII headers
///    in real-world files produced by CAD tools).
fn detectFormat(bytes: []const u8) Format {
    // Step 1: too short for binary
    if (bytes.len < 84) {
        return .ascii;
    }

    // Step 2: exact binary size match.
    // Compare via subtraction/division to avoid any 84 + 50*triCount overflow
    // on narrow-usize targets (triCount is attacker-controlled).
    const tri_count = std.mem.readInt(u32, bytes[80..84], .little);
    if (bytes.len >= 84 and (bytes.len - 84) % 50 == 0 and
        (bytes.len - 84) / 50 == @as(usize, tri_count))
    {
        return .binary;
    }

    // Step 3: ASCII signature
    const prefix = bytes[0..@min(bytes.len, 256)];
    const has_solid = std.mem.startsWith(u8, prefix, "solid");
    const has_facet = std.mem.indexOf(u8, bytes, "facet") != null;
    if (has_solid and has_facet) {
        return .ascii;
    }

    // Step 4: default fallback
    return .binary;
}

// ---------------------------------------------------------------------------
// Binary parser
// ---------------------------------------------------------------------------

fn parseBinary(alloc: std.mem.Allocator, bytes: []const u8) !Mesh {
    // Minimum: 80-byte header + 4-byte count
    if (bytes.len < 84) return error.TruncatedStl;

    const tri_count = std.mem.readInt(u32, bytes[80..84], .little);
    // Validate body size via subtraction/division (no 84 + 50*triCount multiply
    // that could overflow usize on narrow targets when triCount is garbage).
    const body_len = bytes.len - 84;
    if (body_len / 50 < @as(usize, tri_count)) return error.TruncatedStl;

    // Each triangle emits 3 vertices; indices are consecutive 0-based.
    const vert_count: usize = @as(usize, tri_count) * 3;

    var verts = try alloc.alloc(f32, vert_count * 3);
    errdefer alloc.free(verts);
    var tris = try alloc.alloc(i32, @as(usize, tri_count) * 3);
    errdefer alloc.free(tris);

    var offset: usize = 84;
    var vi: usize = 0; // vertex float index
    var ti: usize = 0; // triangle index index

    for (0..tri_count) |t| {
        // Skip normal (3 × f32 = 12 bytes)
        offset += 12;

        // Read 3 vertices × 3 floats (bit-cast u32 LE → f32)
        for (0..3) |_| {
            verts[vi + 0] = @bitCast(std.mem.readInt(u32, bytes[offset .. offset + 4][0..4], .little));
            verts[vi + 1] = @bitCast(std.mem.readInt(u32, bytes[offset + 4 .. offset + 8][0..4], .little));
            verts[vi + 2] = @bitCast(std.mem.readInt(u32, bytes[offset + 8 .. offset + 12][0..4], .little));
            offset += 12;
            vi += 3;
        }

        // Skip attribute byte count (2 bytes)
        offset += 2;

        // Triangle indices: 3 consecutive vertices for triangle t
        const base = @as(i32, @intCast(t * 3));
        tris[ti + 0] = base;
        tris[ti + 1] = base + 1;
        tris[ti + 2] = base + 2;
        ti += 3;
    }

    return Mesh{ .verts = verts, .tris = tris };
}

// ---------------------------------------------------------------------------
// ASCII parser
// ---------------------------------------------------------------------------

fn parseAscii(alloc: std.mem.Allocator, bytes: []const u8) !Mesh {
    var verts_list = std.array_list.Managed(f32).init(alloc);
    errdefer verts_list.deinit();
    var tris_list = std.array_list.Managed(i32).init(alloc);
    errdefer tris_list.deinit();

    var lines = std.mem.splitScalar(u8, bytes, '\n');

    // Current facet vertex collection
    var facet_verts: [3][3]f32 = undefined;
    var fv_count: usize = 0;
    var in_loop = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "outer loop")) {
            in_loop = true;
            fv_count = 0;
        } else if (std.mem.startsWith(u8, line, "endloop")) {
            in_loop = false;
        } else if (std.mem.startsWith(u8, line, "endfacet")) {
            if (fv_count != 3) return error.BadStl;
            // Emit triangle
            const base = @as(i32, @intCast(verts_list.items.len / 3));
            for (0..3) |i| {
                try verts_list.append(facet_verts[i][0]);
                try verts_list.append(facet_verts[i][1]);
                try verts_list.append(facet_verts[i][2]);
            }
            try tris_list.append(base);
            try tris_list.append(base + 1);
            try tris_list.append(base + 2);
        } else if (in_loop and std.mem.startsWith(u8, line, "vertex")) {
            if (fv_count >= 3) return error.BadStl;
            // Split coordinates on any run of spaces/tabs (CAD tools mix them).
            var tok = std.mem.tokenizeAny(u8, line[6..], " \t");
            for (0..3) |i| {
                const s = tok.next() orelse return error.BadStl;
                facet_verts[fv_count][i] = std.fmt.parseFloat(f32, s) catch return error.BadStl;
            }
            fv_count += 1;
        }
        // Lines: "solid", "facet normal ...", "endsolid" — ignored
    }

    // An empty parse result means the input had no recognisable geometry.
    if (tris_list.items.len == 0) return error.BadStl;

    return Mesh{
        .verts = try verts_list.toOwnedSlice(),
        .tris = try tris_list.toOwnedSlice(),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "binary STL — two triangles" {
    const alloc = std.testing.allocator;

    // Build a minimal binary STL with 2 triangles in memory.
    // Layout: [80 header][u32 count=2][tri0][tri1]
    // Each tri: [normal 3×f32][v0 3×f32][v1 3×f32][v2 3×f32][attr u16]
    //           = 12 + 36 + 2 = 50 bytes
    var buf: [84 + 50 * 2]u8 = std.mem.zeroes([84 + 50 * 2]u8);

    // Triangle count = 2
    std.mem.writeInt(u32, buf[80..84], 2, .little);

    // Helper: write f32 LE at position
    const writeF32 = struct {
        fn f(b: []u8, pos: usize, val: f32) void {
            std.mem.writeInt(u32, b[pos..][0..4], @bitCast(val), .little);
        }
    }.f;

    // Triangle 0 — normal ignored, vertices: (1,0,0),(0,1,0),(0,0,1)
    var off: usize = 84;
    // normal
    writeF32(&buf, off, 0.577); writeF32(&buf, off + 4, 0.577); writeF32(&buf, off + 8, 0.577);
    off += 12;
    // v0
    writeF32(&buf, off, 1.0); writeF32(&buf, off + 4, 0.0); writeF32(&buf, off + 8, 0.0);
    off += 12;
    // v1
    writeF32(&buf, off, 0.0); writeF32(&buf, off + 4, 1.0); writeF32(&buf, off + 8, 0.0);
    off += 12;
    // v2
    writeF32(&buf, off, 0.0); writeF32(&buf, off + 4, 0.0); writeF32(&buf, off + 8, 1.0);
    off += 12;
    off += 2; // attr

    // Triangle 1 — normal ignored, vertices: (2,0,0),(0,2,0),(0,0,2)
    writeF32(&buf, off, 0.0); writeF32(&buf, off + 4, 0.0); writeF32(&buf, off + 8, 1.0);
    off += 12;
    writeF32(&buf, off, 2.0); writeF32(&buf, off + 4, 0.0); writeF32(&buf, off + 8, 0.0);
    off += 12;
    writeF32(&buf, off, 0.0); writeF32(&buf, off + 4, 2.0); writeF32(&buf, off + 8, 0.0);
    off += 12;
    writeF32(&buf, off, 0.0); writeF32(&buf, off + 4, 0.0); writeF32(&buf, off + 8, 2.0);
    off += 12;
    // attr already zero

    const mesh = try parse(alloc, &buf);
    defer mesh.deinit(alloc);

    // 2 triangles → 6 vertices → 18 floats
    try std.testing.expectEqual(@as(usize, 18), mesh.verts.len);
    // 2 triangles → 6 indices
    try std.testing.expectEqual(@as(usize, 6), mesh.tris.len);

    // Triangle 0 vertex 0 = (1,0,0)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[2], 1e-6);

    // Indices: 0,1,2 for first tri
    try std.testing.expectEqual(@as(i32, 0), mesh.tris[0]);
    try std.testing.expectEqual(@as(i32, 1), mesh.tris[1]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[2]);

    // Indices: 3,4,5 for second tri
    try std.testing.expectEqual(@as(i32, 3), mesh.tris[3]);
    try std.testing.expectEqual(@as(i32, 4), mesh.tris[4]);
    try std.testing.expectEqual(@as(i32, 5), mesh.tris[5]);
}

test "binary STL — normals are ignored (vert count == 3 * triCount)" {
    const alloc = std.testing.allocator;

    var buf: [84 + 50 * 1]u8 = std.mem.zeroes([84 + 50 * 1]u8);
    std.mem.writeInt(u32, buf[80..84], 1, .little);

    // Set a non-zero normal — must not appear in verts
    const writeF32 = struct {
        fn f(b: []u8, pos: usize, val: f32) void {
            std.mem.writeInt(u32, b[pos..][0..4], @bitCast(val), .little);
        }
    }.f;
    var off: usize = 84;
    writeF32(&buf, off, 99.0); writeF32(&buf, off + 4, 99.0); writeF32(&buf, off + 8, 99.0); // normal
    off += 12;
    writeF32(&buf, off, 1.0); writeF32(&buf, off + 4, 2.0); writeF32(&buf, off + 8, 3.0); off += 12;
    writeF32(&buf, off, 4.0); writeF32(&buf, off + 4, 5.0); writeF32(&buf, off + 8, 6.0); off += 12;
    writeF32(&buf, off, 7.0); writeF32(&buf, off + 4, 8.0); writeF32(&buf, off + 8, 9.0); off += 12;

    const mesh = try parse(alloc, &buf);
    defer mesh.deinit(alloc);

    // 1 triangle → 3 vertices → 9 floats (no 99.0)
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    for (mesh.verts) |v| {
        try std.testing.expect(v != 99.0);
    }
}

test "ASCII STL — single triangle" {
    const src =
        \\solid test
        \\  facet normal 0 0 1
        \\    outer loop
        \\      vertex 1.0 0.0 0.0
        \\      vertex 0.0 1.0 0.0
        \\      vertex 0.0 0.0 1.0
        \\    endloop
        \\  endfacet
        \\endsolid test
    ;

    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, src);
    defer mesh.deinit(alloc);

    // 1 triangle → 3 vertices → 9 floats, 3 indices
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[2], 1e-6);

    try std.testing.expectEqual(@as(i32, 0), mesh.tris[0]);
    try std.testing.expectEqual(@as(i32, 1), mesh.tris[1]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[2]);
}

test "ASCII STL — two triangles (normals ignored)" {
    const src =
        \\solid cube_face
        \\  facet normal 0 1 0
        \\    outer loop
        \\      vertex 0.0 0.0 0.0
        \\      vertex 1.0 0.0 0.0
        \\      vertex 1.0 0.0 1.0
        \\    endloop
        \\  endfacet
        \\  facet normal 0 1 0
        \\    outer loop
        \\      vertex 0.0 0.0 0.0
        \\      vertex 1.0 0.0 1.0
        \\      vertex 0.0 0.0 1.0
        \\    endloop
        \\  endfacet
        \\endsolid cube_face
    ;

    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, src);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 18), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 6), mesh.tris.len);
    // Normals (0,1,0) must NOT appear as vertex data
    // Second tri starts at index 3
    try std.testing.expectEqual(@as(i32, 3), mesh.tris[3]);
}

test "empty input → error" {
    const alloc = std.testing.allocator;
    const result = parse(alloc, "");
    try std.testing.expectError(error.BadStl, result);
}

test "truncated binary STL → error.TruncatedStl" {
    const alloc = std.testing.allocator;
    // Valid header says 5 triangles but we only provide the header
    var buf: [84]u8 = std.mem.zeroes([84]u8);
    std.mem.writeInt(u32, buf[80..84], 5, .little);
    const result = parse(alloc, &buf);
    try std.testing.expectError(error.TruncatedStl, result);
}

test "binary STL — garbage triCount (overflow-safe) → error.TruncatedStl" {
    const alloc = std.testing.allocator;
    // 84-byte buffer but header claims 0xFFFFFFFF triangles.
    // The size check must not overflow (84 + 50*0xFFFFFFFF) and must reject.
    var buf: [200]u8 = std.mem.zeroes([200]u8);
    std.mem.writeInt(u32, buf[80..84], 0xFFFF_FFFF, .little);
    const result = parse(alloc, &buf);
    try std.testing.expectError(error.TruncatedStl, result);
}

test "binary STL — header begins with \"solid\" is still binary" {
    const alloc = std.testing.allocator;
    // Real-world hazard: a binary STL whose 80-byte header text starts with
    // "solid ...". Exact-size match must classify it as binary, not ASCII.
    var buf: [84 + 50 * 1]u8 = std.mem.zeroes([84 + 50 * 1]u8);
    const hdr = "solid created by some CAD tool";
    @memcpy(buf[0..hdr.len], hdr);
    std.mem.writeInt(u32, buf[80..84], 1, .little);

    const writeF32 = struct {
        fn f(b: []u8, pos: usize, val: f32) void {
            std.mem.writeInt(u32, b[pos..][0..4], @bitCast(val), .little);
        }
    }.f;
    const off: usize = 84 + 12; // skip normal
    writeF32(&buf, off, 1.0);
    writeF32(&buf, off + 4, 2.0);
    writeF32(&buf, off + 8, 3.0);

    const mesh = try parse(alloc, &buf);
    defer mesh.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
}

test "ASCII STL — CRLF line endings, tab separators, exponent floats" {
    // CRLF endings, tabs between coords, scientific notation, leading spaces.
    const src =
        "solid x\r\n" ++
        "\tfacet normal 0 0 1\r\n" ++
        "\t\touter loop\r\n" ++
        "\t\t\tvertex\t1.5e-3\t-2.0E0\t3.0\r\n" ++
        "\t\t\tvertex 0.0  1.0   0.0\r\n" ++ // multiple spaces
        "\t\t\tvertex 0.0 0.0 1.0\r\n" ++
        "\t\tendloop\r\n" ++
        "\tendfacet\r\n" ++
        "endsolid x\r\n";

    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, src);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5e-3), mesh.verts[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mesh.verts[2], 1e-6);
}

test "ASCII STL — facet with wrong vertex count → error.BadStl" {
    const src =
        \\solid bad
        \\  facet normal 0 0 1
        \\    outer loop
        \\      vertex 1.0 0.0 0.0
        \\      vertex 0.0 1.0 0.0
        \\    endloop
        \\  endfacet
        \\endsolid bad
    ;
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.BadStl, parse(alloc, src));
}
