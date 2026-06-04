//! Persist Module 4b — manifest: the self-describing index of a `.recastscene/`
//! container, written `manifest` at the container ROOT.
//!
//! The manifest is a SINGLE canonical Module 1 chunk:
//!   [ChunkHeader(MANIFEST_MAGIC, MANIFEST_VERSION, 0, payload)] ++ payload
//! payload (little-endian, field-by-field):
//!   FormatVersions : 6 × u32  (scene, areas, flags, volumes, offmesh, tile)
//!   gset_name      : u32 len ++ bytes
//!   tiles          : u32 count ++ count × (i32 tx, i32 ty, i32 layer)
//! The chunk's XXH3 checksum protects the WHOLE manifest.
//!
//! COMMIT ROLE: the manifest is written LAST, via writeAtomic (atomic rename) — it
//! is the version-switch point of the world. Until it is replaced, the previous
//! manifest + previous tiles remain the valid world (all-or-nothing switch).
//!
//! FAILURE POLICY (asymmetric, deliberate):
//!   - A corrupt MANIFEST is FATAL: without it the world's version/tile-set is
//!     unknown, so loadScene cannot proceed (readManifest returns the ChunkError).
//!   - A corrupt individual TILE is graceful-skip (see tile_store/scene_container).
//!
//! Builds on Persist Module 1 (checksum.zig + write_atomic.zig) and tile_store
//! (TileKey, TILE_VERSION).

const std = @import("std");
const write_atomic = @import("write_atomic.zig");
const cs_mod = @import("checksum.zig");
const tile_store = @import("tile_store.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Buf = std.array_list.Managed(u8);

const ChunkHeader = cs_mod.ChunkHeader;
const unpackHeader = cs_mod.unpackHeader;
const parseChunk = cs_mod.parseChunk;
const HEADER_LEN = cs_mod.HEADER_LEN;

pub const MANIFEST_MAGIC: u32 = 0x4E414D52; // LE 'R','M','A','N'
pub const MANIFEST_VERSION: u32 = 1;
pub const MANIFEST_NAME = "manifest";

pub const Error = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
} || std.mem.Allocator.Error;

/// Per-subformat versions, so loadScene can reason about/refuse a specific
/// sub-file independently of the others.
pub const FormatVersions = struct {
    scene: u32 = 1,
    areas: u32 = 1,
    flags: u32 = 1,
    volumes: u32 = 1,
    offmesh: u32 = 1,
    tile: u32 = tile_store.TILE_VERSION,
};

pub const Manifest = struct {
    versions: FormatVersions = .{},
    /// Relative path to the geometry description inside the container.
    gset_name: []const u8 = "scene.gset",
    /// Tiles present under tiles/. Order is not significant.
    tiles: []const tile_store.TileKey = &.{},

    /// Serialize the payload (WITHOUT the chunk header — writeManifest adds it).
    pub fn serializePayload(self: Manifest, buf: *Buf) !void {
        try putU32(buf, self.versions.scene);
        try putU32(buf, self.versions.areas);
        try putU32(buf, self.versions.flags);
        try putU32(buf, self.versions.volumes);
        try putU32(buf, self.versions.offmesh);
        try putU32(buf, self.versions.tile);
        try putU32(buf, @intCast(self.gset_name.len));
        try buf.appendSlice(self.gset_name);
        try putU32(buf, @intCast(self.tiles.len));
        for (self.tiles) |k| {
            try putI32(buf, k.tx);
            try putI32(buf, k.ty);
            try putI32(buf, k.layer);
        }
    }
};

fn putU32(b: *Buf, v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try b.appendSlice(&tmp);
}
fn putI32(b: *Buf, v: i32) !void {
    try putU32(b, @bitCast(v));
}

/// Little-endian read cursor over the payload bytes.
const PReader = struct {
    data: []const u8,
    pos: usize = 0,
    fn readU32(self: *PReader) error{Truncated}!u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readI32(self: *PReader) error{Truncated}!i32 {
        return @bitCast(try self.readU32());
    }
    fn readBytes(self: *PReader, n: usize) error{Truncated}![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

/// Parse a manifest payload. `gset_name` and `tiles` are OWNED (free via free()).
pub fn parsePayload(alloc: std.mem.Allocator, payload: []const u8) Error!Manifest {
    var r = PReader{ .data = payload };
    var m = Manifest{};
    m.versions = .{
        .scene = try r.readU32(),
        .areas = try r.readU32(),
        .flags = try r.readU32(),
        .volumes = try r.readU32(),
        .offmesh = try r.readU32(),
        .tile = try r.readU32(),
    };
    const gname_len = try r.readU32();
    const gname = try r.readBytes(gname_len);
    const gname_owned = try alloc.dupe(u8, gname);
    errdefer alloc.free(gname_owned);
    m.gset_name = gname_owned;

    const count = try r.readU32();
    const tiles = try alloc.alloc(tile_store.TileKey, count);
    errdefer alloc.free(tiles);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        tiles[i] = .{ .tx = try r.readI32(), .ty = try r.readI32(), .layer = try r.readI32() };
    }
    m.tiles = tiles;
    return m;
}

/// Free an owned manifest returned by parsePayload / readManifest.
pub fn free(alloc: std.mem.Allocator, m: Manifest) void {
    alloc.free(m.gset_name);
    alloc.free(m.tiles);
}

/// Serialize a whole manifest (chunk + payload) into an owned buffer. Caller frees.
pub fn serialize(alloc: std.mem.Allocator, m: Manifest) ![]u8 {
    var payload = Buf.init(alloc);
    defer payload.deinit();
    try m.serializePayload(&payload);
    return cs_mod.buildChunk(alloc, MANIFEST_MAGIC, MANIFEST_VERSION, 0, payload.items);
}

/// Write the manifest durably (atomic rename) into the container ROOT `dir`.
/// THE LAST STEP of a save — call from commitWorld. writeAtomic fsyncs the file;
/// the directory barrier (fsync of `dir`) is done by commitWorld.
pub fn writeManifest(io: Io, alloc: std.mem.Allocator, dir: Dir, m: Manifest) !void {
    const bytes = try serialize(alloc, m);
    defer alloc.free(bytes);
    try write_atomic.writeAtomic(io, dir, MANIFEST_NAME, bytes);
}

/// Read + verify the manifest from the container ROOT `dir`. A corrupt manifest is
/// FATAL — the ChunkError (Truncated/WrongMagic/WrongVersion/ChecksumMismatch) or a
/// read error propagates. Returned manifest is OWNED (free via free()).
pub fn readManifest(io: Io, alloc: std.mem.Allocator, dir: Dir) !Manifest {
    const data = try dir.readFileAlloc(io, MANIFEST_NAME, alloc, .unlimited);
    defer alloc.free(data);
    const payload = try parseChunk(data, MANIFEST_MAGIC, MANIFEST_VERSION);
    return parsePayload(alloc, payload);
}

/// Finish a world commit AFTER all tiles + edits are written:
///   fsync(tiles_dir) -> atomic-write(manifest) -> fsync(root_dir).
/// This is the atomic version-switch point. MUST be called only once every tile
/// and edit file has been durably written; if any earlier step failed, do NOT call
/// this — the previous manifest keeps the old world valid.
pub fn commitWorld(io: Io, alloc: std.mem.Allocator, root_dir: Dir, tiles_dir: Dir, m: Manifest) !void {
    // 1) Directory barrier: the new tile dir-entries reach stable storage (POSIX;
    //    no-op on Windows where the rename is journaled).
    try write_atomic.dirFsync(tiles_dir);
    // 2) Manifest atomic rename (writeAtomic = createFileAtomic -> fsync -> replace).
    try writeManifest(io, alloc, root_dir, m);
    // 3) Root barrier: the new manifest dir-entry reaches stable storage.
    try write_atomic.dirFsync(root_dir);
}

// ---------------------------------------------------------------------------
// Tests (aggregated via demo/src/tests.zig -> `zig build demo-test`).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "manifest payload serialize -> parse round-trip" {
    const alloc = testing.allocator;
    const keys = [_]tile_store.TileKey{
        .{ .tx = 0, .ty = 0, .layer = 0 },
        .{ .tx = -2, .ty = 5, .layer = 1 },
    };
    const m = Manifest{ .gset_name = "scene.gset", .tiles = &keys };

    var buf = Buf.init(alloc);
    defer buf.deinit();
    try m.serializePayload(&buf);

    const got = try parsePayload(alloc, buf.items);
    defer free(alloc, got);

    try testing.expectEqualStrings("scene.gset", got.gset_name);
    try testing.expectEqual(@as(usize, 2), got.tiles.len);
    try testing.expectEqual(@as(i32, -2), got.tiles[1].tx);
    try testing.expectEqual(@as(i32, 5), got.tiles[1].ty);
    try testing.expectEqual(@as(i32, 1), got.tiles[1].layer);
    try testing.expectEqual(tile_store.TILE_VERSION, got.versions.tile);
}

test "manifest full chunk serialize -> readback (in-memory)" {
    const alloc = testing.allocator;
    const keys = [_]tile_store.TileKey{.{ .tx = 3, .ty = 4, .layer = 2 }};
    const m = Manifest{ .gset_name = "world.gset", .tiles = &keys };

    const bytes = try serialize(alloc, m);
    defer alloc.free(bytes);

    const payload = try parseChunk(bytes, MANIFEST_MAGIC, MANIFEST_VERSION);
    const got = try parsePayload(alloc, payload);
    defer free(alloc, got);
    try testing.expectEqualStrings("world.gset", got.gset_name);
    try testing.expectEqual(@as(i32, 3), got.tiles[0].tx);
}

test "manifest truncated payload -> Truncated" {
    const alloc = testing.allocator;
    var tiny = [_]u8{0} ** 8; // not even the 6 version u32s
    try testing.expectError(error.Truncated, parsePayload(alloc, &tiny));
}

test "corrupt manifest chunk is fatal (ChecksumMismatch)" {
    const alloc = testing.allocator;
    const m = Manifest{ .gset_name = "scene.gset", .tiles = &.{} };
    const bytes = try serialize(alloc, m);
    defer alloc.free(bytes);
    // Flip a payload byte -> file-level checksum mismatch.
    bytes[bytes.len - 1] ^= 0xFF;
    try testing.expectError(error.ChecksumMismatch, parseChunk(bytes, MANIFEST_MAGIC, MANIFEST_VERSION));
}

test "writeManifest -> readManifest disk round-trip" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const keys = [_]tile_store.TileKey{
        .{ .tx = 1, .ty = 1, .layer = 0 },
        .{ .tx = 2, .ty = 3, .layer = 1 },
    };
    const m = Manifest{ .gset_name = "scene.gset", .tiles = &keys };
    try writeManifest(io, alloc, tmp.dir, m);

    const got = try readManifest(io, alloc, tmp.dir);
    defer free(alloc, got);
    try testing.expectEqual(@as(usize, 2), got.tiles.len);
    try testing.expectEqual(@as(i32, 2), got.tiles[1].tx);
    try testing.expectEqualStrings("scene.gset", got.gset_name);
}

test "readManifest on corrupt file is fatal" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifest(io, alloc, tmp.dir, .{ .tiles = &.{} });
    const data = try tmp.dir.readFileAlloc(io, MANIFEST_NAME, alloc, .unlimited);
    defer alloc.free(data);
    data[data.len - 1] ^= 0xFF;
    try tmp.dir.writeFile(io, .{ .sub_path = MANIFEST_NAME, .data = data });

    try testing.expectError(error.ChecksumMismatch, readManifest(io, alloc, tmp.dir));
}
