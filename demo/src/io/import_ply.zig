/// import_ply.zig — PLY geometry importer (ASCII + binary_little_endian + binary_big_endian).
///
/// Public API:
///   pub const Mesh = struct { verts: []f32, tris: []i32, pub fn deinit(self, alloc) void }
///   pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Mesh
///
/// Only std is imported — file is self-contained and testable via `zig test`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Mesh = struct {
    verts: []f32, // owned; flat x,y,z triples
    tris: []i32, // owned; flat i0,i1,i2 triples (fan-triangulated)

    pub fn deinit(self: Mesh, alloc: std.mem.Allocator) void {
        alloc.free(self.verts);
        alloc.free(self.tris);
    }
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const PlyError = error{
    BadPlyHeader,
    UnsupportedPlyFormat,
    UnsupportedPlyProperty,
    TruncatedPly,
    InvalidPlyData,
};

// ---------------------------------------------------------------------------
// Internal helpers — PLY property scalar types
// ---------------------------------------------------------------------------

const ScalarKind = enum {
    int8,
    uint8,
    int16,
    uint16,
    int32,
    uint32,
    float32,
    float64,

    fn byteSize(self: ScalarKind) usize {
        return switch (self) {
            .int8, .uint8 => 1,
            .int16, .uint16 => 2,
            .int32, .uint32, .float32 => 4,
            .float64 => 8,
        };
    }
};

fn parseScalarKind(name: []const u8) !ScalarKind {
    if (std.mem.eql(u8, name, "char") or std.mem.eql(u8, name, "int8")) return .int8;
    if (std.mem.eql(u8, name, "uchar") or std.mem.eql(u8, name, "uint8")) return .uint8;
    if (std.mem.eql(u8, name, "short") or std.mem.eql(u8, name, "int16")) return .int16;
    if (std.mem.eql(u8, name, "ushort") or std.mem.eql(u8, name, "uint16")) return .uint16;
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "int32")) return .int32;
    if (std.mem.eql(u8, name, "uint") or std.mem.eql(u8, name, "uint32")) return .uint32;
    if (std.mem.eql(u8, name, "float") or std.mem.eql(u8, name, "float32")) return .float32;
    if (std.mem.eql(u8, name, "double") or std.mem.eql(u8, name, "float64")) return .float64;
    return PlyError.UnsupportedPlyProperty;
}

// ---------------------------------------------------------------------------
// Internal helpers — read scalar from binary buffer
// ---------------------------------------------------------------------------

fn readScalarLE(kind: ScalarKind, buf: []const u8, offset: usize) !f64 {
    const end = offset + kind.byteSize();
    if (end > buf.len) return PlyError.TruncatedPly;
    const b = buf[offset..end];
    return switch (kind) {
        .int8 => @as(f64, @floatFromInt(@as(i8, @bitCast(b[0])))),
        .uint8 => @as(f64, @floatFromInt(b[0])),
        .int16 => @as(f64, @floatFromInt(@as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .little))))),
        .uint16 => @as(f64, @floatFromInt(std.mem.readInt(u16, b[0..2], .little))),
        .int32 => @as(f64, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))),
        .uint32 => @as(f64, @floatFromInt(std.mem.readInt(u32, b[0..4], .little))),
        .float32 => @as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .little))))),
        .float64 => @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .little))),
    };
}

fn readScalarBE(kind: ScalarKind, buf: []const u8, offset: usize) !f64 {
    const end = offset + kind.byteSize();
    if (end > buf.len) return PlyError.TruncatedPly;
    const b = buf[offset..end];
    return switch (kind) {
        .int8 => @as(f64, @floatFromInt(@as(i8, @bitCast(b[0])))),
        .uint8 => @as(f64, @floatFromInt(b[0])),
        .int16 => @as(f64, @floatFromInt(@as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .big))))),
        .uint16 => @as(f64, @floatFromInt(std.mem.readInt(u16, b[0..2], .big))),
        .int32 => @as(f64, @floatFromInt(std.mem.readInt(i32, b[0..4], .big))),
        .uint32 => @as(f64, @floatFromInt(std.mem.readInt(u32, b[0..4], .big))),
        .float32 => @as(f64, @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, b[0..4], .big))))),
        .float64 => @as(f64, @bitCast(std.mem.readInt(u64, b[0..8], .big))),
    };
}

// Read a scalar as i64 (for index values in face lists).
fn readScalarIntLE(kind: ScalarKind, buf: []const u8, offset: usize) !i64 {
    const end = offset + kind.byteSize();
    if (end > buf.len) return PlyError.TruncatedPly;
    const b = buf[offset..end];
    return switch (kind) {
        .int8 => @as(i64, @as(i8, @bitCast(b[0]))),
        .uint8 => @as(i64, b[0]),
        .int16 => @as(i64, @as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .little)))),
        .uint16 => @as(i64, std.mem.readInt(u16, b[0..2], .little)),
        .int32 => @as(i64, std.mem.readInt(i32, b[0..4], .little)),
        .uint32 => @as(i64, std.mem.readInt(u32, b[0..4], .little)),
        .float32, .float64 => return PlyError.InvalidPlyData,
    };
}

fn readScalarIntBE(kind: ScalarKind, buf: []const u8, offset: usize) !i64 {
    const end = offset + kind.byteSize();
    if (end > buf.len) return PlyError.TruncatedPly;
    const b = buf[offset..end];
    return switch (kind) {
        .int8 => @as(i64, @as(i8, @bitCast(b[0]))),
        .uint8 => @as(i64, b[0]),
        .int16 => @as(i64, @as(i16, @bitCast(std.mem.readInt(u16, b[0..2], .big)))),
        .uint16 => @as(i64, std.mem.readInt(u16, b[0..2], .big)),
        .int32 => @as(i64, std.mem.readInt(i32, b[0..4], .big)),
        .uint32 => @as(i64, std.mem.readInt(u32, b[0..4], .big)),
        .float32, .float64 => return PlyError.InvalidPlyData,
    };
}

// ---------------------------------------------------------------------------
// Header structures
// ---------------------------------------------------------------------------

const Format = enum { ascii, binary_little_endian, binary_big_endian };

// Vertex property descriptor
const VertProp = struct {
    kind: ScalarKind,
    role: enum { x, y, z, skip },
};

// Face list property descriptor
const FaceProp = struct {
    count_kind: ScalarKind,
    index_kind: ScalarKind,
};

const Header = struct {
    format: Format,
    vertex_count: u32,
    face_count: u32,
    vertex_props: std.array_list.Managed(VertProp),
    face_prop: ?FaceProp,
    body_offset: usize, // byte offset of body in original bytes slice

    fn deinit(self: *Header) void {
        self.vertex_props.deinit();
    }
};

// ---------------------------------------------------------------------------
// Header parser
// ---------------------------------------------------------------------------

fn parseHeader(alloc: std.mem.Allocator, bytes: []const u8) !Header {
    // We need line-by-line over ASCII header. Find the `end_header` LINE (not just
    // any substring — `end_header` could legitimately appear inside a comment line).
    // Scan line by line tracking byte offsets so the binary body offset is exact.
    var end_pos: usize = 0; // offset of start of the end_header line
    var body_offset: usize = 0; // offset of first body byte (after the line's newline)
    {
        var found = false;
        var i: usize = 0;
        while (i < bytes.len) {
            // find end of current line (the '\n', or EOF)
            var j = i;
            while (j < bytes.len and bytes[j] != '\n') j += 1;
            // line content is bytes[i..j], trim trailing '\r' for comparison
            var line_end = j;
            if (line_end > i and bytes[line_end - 1] == '\r') line_end -= 1;
            const line = std.mem.trim(u8, bytes[i..line_end], " \t");
            if (std.mem.eql(u8, line, "end_header")) {
                end_pos = i;
                // body begins right after this line's terminating '\n' (if any)
                body_offset = if (j < bytes.len) j + 1 else j;
                found = true;
                break;
            }
            if (j >= bytes.len) break; // no newline, EOF reached without end_header
            i = j + 1;
        }
        if (!found) return PlyError.BadPlyHeader;
    }

    const header_text = bytes[0..end_pos];

    var lines = std.mem.splitScalar(u8, header_text, '\n');

    // First line must be "ply"
    const first = blk: {
        const l = lines.next() orelse return PlyError.BadPlyHeader;
        break :blk std.mem.trim(u8, l, " \t\r");
    };
    if (!std.mem.eql(u8, first, "ply")) return PlyError.BadPlyHeader;

    var format: ?Format = null;
    var vertex_count: u32 = 0;
    var face_count: u32 = 0;
    var vertex_props = std.array_list.Managed(VertProp).init(alloc);
    errdefer vertex_props.deinit();
    var face_prop: ?FaceProp = null;

    // Current element context: 0=none, 1=vertex, 2=face, 3=other
    var ctx: u8 = 0;
    var xyz_found = [3]bool{ false, false, false };

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "comment")) continue;
        if (std.mem.startsWith(u8, line, "obj_info")) continue;

        if (std.mem.startsWith(u8, line, "format ")) {
            const rest = std.mem.trim(u8, line[7..], " \t");
            if (std.mem.startsWith(u8, rest, "ascii")) {
                format = .ascii;
            } else if (std.mem.startsWith(u8, rest, "binary_little_endian")) {
                format = .binary_little_endian;
            } else if (std.mem.startsWith(u8, rest, "binary_big_endian")) {
                format = .binary_big_endian;
            } else {
                return PlyError.UnsupportedPlyFormat;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "element ")) {
            var toks = std.mem.tokenizeScalar(u8, line[8..], ' ');
            const elem_name = toks.next() orelse return PlyError.BadPlyHeader;
            const count_str = toks.next() orelse return PlyError.BadPlyHeader;
            const count = std.fmt.parseInt(u32, count_str, 10) catch return PlyError.BadPlyHeader;
            if (std.mem.eql(u8, elem_name, "vertex")) {
                ctx = 1;
                vertex_count = count;
            } else if (std.mem.eql(u8, elem_name, "face")) {
                ctx = 2;
                face_count = count;
            } else {
                ctx = 3;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "property ")) {
            const rest = line[9..];
            if (std.mem.startsWith(u8, rest, "list ")) {
                // list property
                if (ctx == 2) {
                    // face list
                    var toks = std.mem.tokenizeScalar(u8, rest[5..], ' ');
                    const cnt_type_str = toks.next() orelse return PlyError.BadPlyHeader;
                    const idx_type_str = toks.next() orelse return PlyError.BadPlyHeader;
                    // prop name (vertex_indices / vertex_index) — we don't validate name
                    const cnt_kind = parseScalarKind(cnt_type_str) catch return PlyError.BadPlyHeader;
                    const idx_kind = parseScalarKind(idx_type_str) catch return PlyError.BadPlyHeader;
                    face_prop = FaceProp{ .count_kind = cnt_kind, .index_kind = idx_kind };
                }
                // for other elements or extra list props: ignore
                continue;
            }
            // scalar property
            var toks = std.mem.tokenizeScalar(u8, rest, ' ');
            const type_str = toks.next() orelse return PlyError.BadPlyHeader;
            const prop_name = toks.next() orelse return PlyError.BadPlyHeader;
            if (ctx == 1) {
                const kind = parseScalarKind(type_str) catch return PlyError.BadPlyHeader;
                const role: @TypeOf(@as(VertProp, undefined).role) = r: {
                    if (std.mem.eql(u8, prop_name, "x")) {
                        xyz_found[0] = true;
                        break :r .x;
                    } else if (std.mem.eql(u8, prop_name, "y")) {
                        xyz_found[1] = true;
                        break :r .y;
                    } else if (std.mem.eql(u8, prop_name, "z")) {
                        xyz_found[2] = true;
                        break :r .z;
                    } else {
                        break :r .skip;
                    }
                };
                try vertex_props.append(VertProp{ .kind = kind, .role = role });
            }
            // ctx==2 scalar props on face: ignore (shouldn't appear in standard PLY)
            // ctx==3 other element: ignore
            continue;
        }
    }

    if (format == null) return PlyError.BadPlyHeader;
    if (!xyz_found[0] or !xyz_found[1] or !xyz_found[2]) return PlyError.BadPlyHeader;

    return Header{
        .format = format.?,
        .vertex_count = vertex_count,
        .face_count = face_count,
        .vertex_props = vertex_props,
        .face_prop = face_prop,
        .body_offset = body_offset,
    };
}

// ---------------------------------------------------------------------------
// ASCII body parser
// ---------------------------------------------------------------------------

fn parseBodyAscii(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    hdr: *const Header,
) !Mesh {
    var verts = std.array_list.Managed(f32).init(alloc);
    errdefer verts.deinit();
    var tris = std.array_list.Managed(i32).init(alloc);
    errdefer tris.deinit();

    try verts.ensureTotalCapacity(@as(usize, hdr.vertex_count) * 3);
    try tris.ensureTotalCapacity(@as(usize, hdr.face_count) * 3);

    const body = bytes[hdr.body_offset..];
    var lines = std.mem.splitScalar(u8, body, '\n');

    // --- vertices ---
    var vi: u32 = 0;
    while (vi < hdr.vertex_count) : (vi += 1) {
        const raw = lines.next() orelse return PlyError.TruncatedPly;
        const line = std.mem.trim(u8, raw, " \t\r");
        var toks = std.mem.tokenizeScalar(u8, line, ' ');

        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;

        for (hdr.vertex_props.items) |prop| {
            const tok = toks.next() orelse return PlyError.TruncatedPly;
            const val = std.fmt.parseFloat(f32, tok) catch return PlyError.InvalidPlyData;
            switch (prop.role) {
                .x => x = val,
                .y => y = val,
                .z => z = val,
                .skip => {},
            }
        }
        try verts.append(x);
        try verts.append(y);
        try verts.append(z);
    }

    // --- faces ---
    var fi: u32 = 0;
    while (fi < hdr.face_count) : (fi += 1) {
        const raw = lines.next() orelse return PlyError.TruncatedPly;
        const line = std.mem.trim(u8, raw, " \t\r");
        var toks = std.mem.tokenizeScalar(u8, line, ' ');

        const cnt_tok = toks.next() orelse return PlyError.TruncatedPly;
        const cnt = std.fmt.parseInt(u32, cnt_tok, 10) catch return PlyError.InvalidPlyData;
        if (cnt < 3) {
            // skip degenerate faces — consume tokens
            var i: u32 = 0;
            while (i < cnt) : (i += 1) {
                _ = toks.next();
            }
            continue;
        }

        var face_buf: [64]i32 = undefined;
        var nf: usize = 0;
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            const tok = toks.next() orelse return PlyError.TruncatedPly;
            const idx = std.fmt.parseInt(i32, tok, 10) catch return PlyError.InvalidPlyData;
            if (idx < 0 or @as(i64, idx) >= @as(i64, hdr.vertex_count)) return PlyError.InvalidPlyData;
            if (nf < face_buf.len) {
                face_buf[nf] = idx;
                nf += 1;
            }
        }

        // fan triangulation: (0,1,2),(0,2,3),...
        var k: usize = 2;
        while (k < nf) : (k += 1) {
            try tris.append(face_buf[0]);
            try tris.append(face_buf[k - 1]);
            try tris.append(face_buf[k]);
        }
    }

    return Mesh{
        .verts = try verts.toOwnedSlice(),
        .tris = try tris.toOwnedSlice(),
    };
}

// ---------------------------------------------------------------------------
// Binary body parser (shared logic, endianness via comptime)
// ---------------------------------------------------------------------------

fn parseBodyBinary(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    hdr: *const Header,
    comptime endian: std.builtin.Endian,
) !Mesh {
    var verts = std.array_list.Managed(f32).init(alloc);
    errdefer verts.deinit();
    var tris = std.array_list.Managed(i32).init(alloc);
    errdefer tris.deinit();

    try verts.ensureTotalCapacity(@as(usize, hdr.vertex_count) * 3);
    try tris.ensureTotalCapacity(@as(usize, hdr.face_count) * 3);

    var pos: usize = hdr.body_offset;

    // Helper lambdas (closures via inline fns)
    const readF = struct {
        fn call(kind: ScalarKind, buf: []const u8, off: usize) !f64 {
            if (endian == .little) return readScalarLE(kind, buf, off);
            return readScalarBE(kind, buf, off);
        }
    }.call;
    const readI = struct {
        fn call(kind: ScalarKind, buf: []const u8, off: usize) !i64 {
            if (endian == .little) return readScalarIntLE(kind, buf, off);
            return readScalarIntBE(kind, buf, off);
        }
    }.call;

    // --- vertices ---
    var vi: u32 = 0;
    while (vi < hdr.vertex_count) : (vi += 1) {
        var x: f32 = 0;
        var y: f32 = 0;
        var z: f32 = 0;
        for (hdr.vertex_props.items) |prop| {
            const val = try readF(prop.kind, bytes, pos);
            pos += prop.kind.byteSize();
            switch (prop.role) {
                .x => x = @floatCast(val),
                .y => y = @floatCast(val),
                .z => z = @floatCast(val),
                .skip => {},
            }
        }
        try verts.append(x);
        try verts.append(y);
        try verts.append(z);
    }

    // --- faces ---
    const fp = hdr.face_prop orelse return PlyError.BadPlyHeader;
    var fi: u32 = 0;
    while (fi < hdr.face_count) : (fi += 1) {
        if (pos + fp.count_kind.byteSize() > bytes.len) return PlyError.TruncatedPly;
        const cnt_raw = try readI(fp.count_kind, bytes, pos);
        pos += fp.count_kind.byteSize();
        const cnt: u32 = if (cnt_raw < 0) return PlyError.InvalidPlyData else @intCast(cnt_raw);

        if (cnt < 3) {
            pos += cnt * fp.index_kind.byteSize();
            continue;
        }

        var face_buf: [64]i32 = undefined;
        var nf: usize = 0;
        var i: u32 = 0;
        while (i < cnt) : (i += 1) {
            const idx_raw = try readI(fp.index_kind, bytes, pos);
            pos += fp.index_kind.byteSize();
            // Index must be in [0, vertex_count). uint32 may exceed i32 range,
            // so validate against i64 before narrowing (avoids @intCast panic).
            if (idx_raw < 0 or idx_raw >= @as(i64, hdr.vertex_count)) return PlyError.InvalidPlyData;
            if (nf < face_buf.len) {
                face_buf[nf] = @intCast(idx_raw);
                nf += 1;
            }
        }

        // fan triangulation
        var k: usize = 2;
        while (k < nf) : (k += 1) {
            try tris.append(face_buf[0]);
            try tris.append(face_buf[k - 1]);
            try tris.append(face_buf[k]);
        }
    }

    return Mesh{
        .verts = try verts.toOwnedSlice(),
        .tris = try tris.toOwnedSlice(),
    };
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

pub fn parse(alloc: std.mem.Allocator, bytes: []const u8) !Mesh {
    var hdr = try parseHeader(alloc, bytes);
    defer hdr.deinit();

    return switch (hdr.format) {
        .ascii => parseBodyAscii(alloc, bytes, &hdr),
        .binary_little_endian => parseBodyBinary(alloc, bytes, &hdr, .little),
        .binary_big_endian => parseBodyBinary(alloc, bytes, &hdr, .big),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ascii PLY: square as 2 triangles" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 4
        \\property float x
        \\property float y
        \\property float z
        \\element face 2
        \\property list uchar int vertex_indices
        \\end_header
        \\0.0 0.0 0.0
        \\1.0 0.0 0.0
        \\1.0 1.0 0.0
        \\0.0 1.0 0.0
        \\3 0 1 2
        \\3 0 2 3
        \\
    ;
    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, ply);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 12), mesh.verts.len); // 4 verts * 3
    try std.testing.expectEqual(@as(usize, 6), mesh.tris.len); // 2 tris * 3

    // Verify first vertex
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), mesh.verts[2], 1e-6);

    // Verify second vertex
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[3], 1e-6);

    // Verify tri indices
    try std.testing.expectEqual(@as(i32, 0), mesh.tris[0]);
    try std.testing.expectEqual(@as(i32, 1), mesh.tris[1]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[2]);
    try std.testing.expectEqual(@as(i32, 0), mesh.tris[3]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[4]);
    try std.testing.expectEqual(@as(i32, 3), mesh.tris[5]);
}

test "ascii PLY: skip extra properties (normals)" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 3
        \\property float x
        \\property float y
        \\property float z
        \\property float nx
        \\property float ny
        \\property float nz
        \\element face 1
        \\property list uchar int vertex_indices
        \\end_header
        \\1.0 2.0 3.0 0.0 1.0 0.0
        \\4.0 5.0 6.0 0.0 1.0 0.0
        \\7.0 8.0 9.0 0.0 1.0 0.0
        \\3 0 1 2
        \\
    ;
    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, ply);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);

    // x,y,z of first vertex — normals must be skipped
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mesh.verts[2], 1e-6);

    // second vertex
    try std.testing.expectApproxEqAbs(@as(f32, 4.0), mesh.verts[3], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), mesh.verts[4], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), mesh.verts[5], 1e-6);
}

test "ascii PLY: quad fan-triangulation -> 2 triangles" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 4
        \\property float x
        \\property float y
        \\property float z
        \\element face 1
        \\property list uchar int vertex_indices
        \\end_header
        \\0.0 0.0 0.0
        \\1.0 0.0 0.0
        \\1.0 0.0 1.0
        \\0.0 0.0 1.0
        \\4 0 1 2 3
        \\
    ;
    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, ply);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 6), mesh.tris.len); // 2 tris * 3

    // Fan: (0,1,2) and (0,2,3)
    try std.testing.expectEqual(@as(i32, 0), mesh.tris[0]);
    try std.testing.expectEqual(@as(i32, 1), mesh.tris[1]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[2]);
    try std.testing.expectEqual(@as(i32, 0), mesh.tris[3]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[4]);
    try std.testing.expectEqual(@as(i32, 3), mesh.tris[5]);
}

test "binary_little_endian PLY: 3 verts 1 triangle" {
    const alloc = std.testing.allocator;

    // Build header as ASCII string
    const header =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "element face 1\n" ++
        "property list uchar int vertex_indices\n" ++
        "end_header\n";

    // Build binary body: 3 vertices (3 * 3 * 4 = 36 bytes) + 1 face
    var body_buf: [36 + 1 + 12]u8 = undefined;
    var off: usize = 0;

    // vert 0: (1, 2, 3)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 1.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 2.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 3.0)), .little);
    off += 4;
    // vert 1: (4, 5, 6)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 4.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 5.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 6.0)), .little);
    off += 4;
    // vert 2: (7, 8, 9)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 7.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 8.0)), .little);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 9.0)), .little);
    off += 4;
    // face: count=3 (uchar), then indices 0,1,2 (int LE)
    body_buf[off] = 3;
    off += 1;
    std.mem.writeInt(i32, body_buf[off..][0..4], 0, .little);
    off += 4;
    std.mem.writeInt(i32, body_buf[off..][0..4], 1, .little);
    off += 4;
    std.mem.writeInt(i32, body_buf[off..][0..4], 2, .little);
    off += 4;

    // Concatenate header + body
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(header);
    try buf.appendSlice(body_buf[0..off]);

    const mesh = try parse(alloc, buf.items);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mesh.verts[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mesh.verts[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), mesh.verts[6], 1e-5);

    try std.testing.expectEqual(@as(i32, 0), mesh.tris[0]);
    try std.testing.expectEqual(@as(i32, 1), mesh.tris[1]);
    try std.testing.expectEqual(@as(i32, 2), mesh.tris[2]);
}

test "binary_big_endian PLY: 3 verts 1 triangle" {
    const alloc = std.testing.allocator;

    const header =
        "ply\n" ++
        "format binary_big_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property float x\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "element face 1\n" ++
        "property list uchar int vertex_indices\n" ++
        "end_header\n";

    var body_buf: [36 + 1 + 12]u8 = undefined;
    var off: usize = 0;

    // vert 0: (10, 20, 30)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 10.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 20.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 30.0)), .big);
    off += 4;
    // vert 1: (11, 21, 31)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 11.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 21.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 31.0)), .big);
    off += 4;
    // vert 2: (12, 22, 32)
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 12.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 22.0)), .big);
    off += 4;
    std.mem.writeInt(u32, body_buf[off..][0..4], @bitCast(@as(f32, 32.0)), .big);
    off += 4;
    // face: count=3 (uchar), indices 0,1,2 (int BE)
    body_buf[off] = 3;
    off += 1;
    std.mem.writeInt(i32, body_buf[off..][0..4], 0, .big);
    off += 4;
    std.mem.writeInt(i32, body_buf[off..][0..4], 1, .big);
    off += 4;
    std.mem.writeInt(i32, body_buf[off..][0..4], 2, .big);
    off += 4;

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(header);
    try buf.appendSlice(body_buf[0..off]);

    const mesh = try parse(alloc, buf.items);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);

    try std.testing.expectApproxEqAbs(@as(f32, 10.0), mesh.verts[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), mesh.verts[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), mesh.verts[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), mesh.verts[6], 1e-5);
}

test "ascii PLY: x/y/z not first, interleaved" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 3
        \\property float nx
        \\property float x
        \\property uchar red
        \\property float y
        \\property float z
        \\property float ny
        \\element face 1
        \\property list uchar int vertex_indices
        \\end_header
        \\9.0 1.0 255 2.0 3.0 8.0
        \\9.0 4.0 255 5.0 6.0 8.0
        \\9.0 7.0 255 8.0 9.0 8.0
        \\3 0 1 2
        \\
    ;
    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, ply);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    // first vertex x,y,z = 1,2,3 (NOT nx=9 / red=255)
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mesh.verts[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mesh.verts[2], 1e-6);
    // third vertex
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), mesh.verts[6], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0), mesh.verts[7], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), mesh.verts[8], 1e-6);
}

test "binary_little_endian PLY: x/y/z not first + double-skip property" {
    const alloc = std.testing.allocator;

    // Per-vertex layout (LE): nx float32(4), confidence double(8, skip), x f32, y f32, z f32
    // stride = 4 + 8 + 4 + 4 + 4 = 24 bytes
    const header =
        "ply\n" ++
        "format binary_little_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property float nx\n" ++
        "property double confidence\n" ++
        "property float x\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "element face 1\n" ++
        "property list uchar int vertex_indices\n" ++
        "end_header\n";

    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();

    const verts_xyz = [3][3]f32{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
        .{ 7.0, 8.0, 9.0 },
    };
    for (verts_xyz) |v| {
        // nx (garbage 99.0)
        var tmp4: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp4, @bitCast(@as(f32, 99.0)), .little);
        try body.appendSlice(&tmp4);
        // confidence (double garbage 0.5) — must be skipped over 8 bytes
        var tmp8: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp8, @bitCast(@as(f64, 0.5)), .little);
        try body.appendSlice(&tmp8);
        // x, y, z
        inline for (0..3) |k| {
            std.mem.writeInt(u32, &tmp4, @bitCast(v[k]), .little);
            try body.appendSlice(&tmp4);
        }
    }
    // face: cnt=3 uchar, indices 0,1,2 int LE
    try body.append(3);
    inline for ([_]i32{ 0, 1, 2 }) |ix| {
        var tmp4: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp4, ix, .little);
        try body.appendSlice(&tmp4);
    }

    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(header);
    try buf.appendSlice(body.items);

    const mesh = try parse(alloc, buf.items);
    defer mesh.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectEqual(@as(usize, 3), mesh.tris.len);
    // x/y/z must be the real values, not nx=99 nor the double
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mesh.verts[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), mesh.verts[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), mesh.verts[6], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), mesh.verts[8], 1e-5);
}

test "binary_big_endian PLY: x/y/z not first + double-skip property" {
    const alloc = std.testing.allocator;

    const header =
        "ply\n" ++
        "format binary_big_endian 1.0\n" ++
        "element vertex 3\n" ++
        "property double confidence\n" ++ // skip 8B leading
        "property float x\n" ++
        "property float y\n" ++
        "property float z\n" ++
        "property uchar flag\n" ++ // trailing skip 1B
        "element face 1\n" ++
        "property list uchar int vertex_indices\n" ++
        "end_header\n";

    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    const verts_xyz = [3][3]f32{
        .{ 10.0, 20.0, 30.0 },
        .{ 40.0, 50.0, 60.0 },
        .{ 70.0, 80.0, 90.0 },
    };
    for (verts_xyz) |v| {
        var t8: [8]u8 = undefined;
        std.mem.writeInt(u64, &t8, @bitCast(@as(f64, 0.25)), .big);
        try body.appendSlice(&t8);
        inline for (0..3) |k| {
            var t4: [4]u8 = undefined;
            std.mem.writeInt(u32, &t4, @bitCast(v[k]), .big);
            try body.appendSlice(&t4);
        }
        try body.append(7); // flag uchar
    }
    try body.append(3);
    inline for ([_]i32{ 0, 1, 2 }) |ix| {
        var t4: [4]u8 = undefined;
        std.mem.writeInt(i32, &t4, ix, .big);
        try body.appendSlice(&t4);
    }
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(header);
    try buf.appendSlice(body.items);

    const mesh = try parse(alloc, buf.items);
    defer mesh.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), mesh.verts[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), mesh.verts[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 30.0), mesh.verts[2], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), mesh.verts[8], 1e-5);
}

test "ascii PLY: out-of-range face index is rejected" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\element vertex 3
        \\property float x
        \\property float y
        \\property float z
        \\element face 1
        \\property list uchar int vertex_indices
        \\end_header
        \\0.0 0.0 0.0
        \\1.0 0.0 0.0
        \\0.0 1.0 0.0
        \\3 0 1 5
        \\
    ;
    const alloc = std.testing.allocator;
    try std.testing.expectError(PlyError.InvalidPlyData, parse(alloc, ply));
}

test "PLY header: 'end_header' substring inside comment is not mistaken for the marker" {
    const ply =
        \\ply
        \\format ascii 1.0
        \\comment this text mentions end_header in passing
        \\element vertex 3
        \\property float x
        \\property float y
        \\property float z
        \\element face 1
        \\property list uchar int vertex_indices
        \\end_header
        \\1.0 0.0 0.0
        \\0.0 1.0 0.0
        \\0.0 0.0 1.0
        \\3 0 1 2
        \\
    ;
    const alloc = std.testing.allocator;
    const mesh = try parse(alloc, ply);
    defer mesh.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-6);
}

test "binary PLY with CRLF header line endings" {
    const alloc = std.testing.allocator;
    const header =
        "ply\r\n" ++
        "format binary_little_endian 1.0\r\n" ++
        "element vertex 3\r\n" ++
        "property float x\r\n" ++
        "property float y\r\n" ++
        "property float z\r\n" ++
        "element face 1\r\n" ++
        "property list uchar int vertex_indices\r\n" ++
        "end_header\r\n";

    var body = std.array_list.Managed(u8).init(alloc);
    defer body.deinit();
    const vs = [9]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    for (vs) |val| {
        var t: [4]u8 = undefined;
        std.mem.writeInt(u32, &t, @bitCast(val), .little);
        try body.appendSlice(&t);
    }
    try body.append(3);
    inline for ([_]i32{ 0, 1, 2 }) |ix| {
        var t: [4]u8 = undefined;
        std.mem.writeInt(i32, &t, ix, .little);
        try body.appendSlice(&t);
    }
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    try buf.appendSlice(header);
    try buf.appendSlice(body.items);

    const mesh = try parse(alloc, buf.items);
    defer mesh.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), mesh.verts.len);
    // CRLF must not shift the binary body offset by an extra byte
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), mesh.verts[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9.0), mesh.verts[8], 1e-5);
}
