//! Persist Module 4a — tile_store: per-tile files inside a `.recastscene/tiles/`
//! container. One file per key (tx,ty,layer): `tiles/<tx>_<ty>_<layer>.tile`.
//!
//! File body = canonical Module 1 chunk:
//!   [ChunkHeader(TILE_MAGIC, TILE_VERSION, type_flags=kind, payload=blob)] ++ blob
//! payload = the raw tile blob, which is either:
//!   - an MSET static-navmesh tile (starts with dt.MeshHeader; x/y/layer), or
//!   - a TileCache compressed layer (starts with TileCacheLayerHeader; tx/ty/tlayer).
//! The tile NATURE (TileKind) is encoded in the chunk-header type_flags (bit 0).
//! The file NAME is derived from the key, which is itself read FROM the blob header
//! (keyFromBlob) — never trusted from the on-disk filename.
//!
//! Durability / integrity:
//!   - writeTile uses write_atomic.writeAtomic (createFileAtomic -> fsync -> replace).
//!   - loadTile verifies via the canonical chunk checksum (checksum.parseChunk):
//!     a corrupt tile is REJECTED (Truncated / WrongMagic / WrongVersion /
//!     ChecksumMismatch) so the orchestrator can graceful-skip it.
//!
//! Builds on Persist Module 1 (checksum.zig + write_atomic.zig).

const std = @import("std");
const recast = @import("recast-nav");
const write_atomic = @import("write_atomic.zig");
const cs_mod = @import("checksum.zig");

const dt = recast.detour;
const tc = recast.detour_tilecache;

const Io = std.Io;
const Dir = std.Io.Dir;

const ChunkHeader = cs_mod.ChunkHeader;
const unpackHeader = cs_mod.unpackHeader;
const parseChunk = cs_mod.parseChunk;
const HEADER_LEN = cs_mod.HEADER_LEN;

/// Magic for our tile chunk wrapper (NOT the inner blob's 'DTLR'/'DNAV').
/// LE 'TILE'.
pub const TILE_MAGIC: u32 = 0x454C4954; // 'T','I','L','E'
pub const TILE_VERSION: u32 = 1;

/// Nature of the payload blob. Encoded in the chunk-header type_flags (bit 0).
pub const TileKind = enum(u1) {
    /// MSET static-navmesh tile: payload begins with dt.MeshHeader (x/y/layer).
    mset = 0,
    /// TileCache compressed layer: payload begins with TileCacheLayerHeader
    /// (magic 'DTLR', tx/ty/tlayer).
    tilecache = 1,
};

pub const TileKey = struct {
    tx: i32,
    ty: i32,
    layer: i32,
};

/// Errors surfaced by tile parsing / key extraction. The Module-1 ChunkError set
/// plus Truncated (already part of ChunkError) covers corruption; FileNotFound /
/// OutOfMemory come from the IO/alloc layers in loadTile.
pub const Error = cs_mod.ChunkError;

/// Extract (tx,ty,layer) from a tile blob, dispatching on its declared nature.
///
/// Both header layouts begin with five i32 fields — magic, version, then the three
/// coordinate fields — at byte offsets 0/4/8/12/16:
///   TileCacheLayerHeader: magic, version, tx, ty, tlayer
///   dt.MeshHeader:        magic, version, x,  y,  layer
/// so the coords live at offsets 8/12/16 for BOTH kinds. We read them via
/// std.mem.readInt (no struct pointer cast) because the chunk payload may be
/// UNALIGNED relative to the header struct (it starts at HEADER_LEN=26 in the file).
pub fn keyFromBlob(kind: TileKind, blob: []const u8) error{Truncated}!TileKey {
    // Minimum length: through the layer field (offset 16 + 4 = 20). Also guard the
    // full struct size so a same-named record can't be a partial header.
    const min_len: usize = switch (kind) {
        .tilecache => @sizeOf(tc.TileCacheLayerHeader),
        .mset => @sizeOf(dt.MeshHeader),
    };
    if (blob.len < min_len) return error.Truncated;
    // Coordinates at offsets 8/12/16, little-endian (matches in-memory i32 layout).
    const tx = std.mem.readInt(i32, blob[8..12], .little);
    const ty = std.mem.readInt(i32, blob[12..16], .little);
    const layer = std.mem.readInt(i32, blob[16..20], .little);
    return .{ .tx = tx, .ty = ty, .layer = layer };
}

/// Render the per-tile file name into `buf` (>= 48 bytes). Returns a slice into buf.
/// Form: "<tx>_<ty>_<layer>.tile" (used UNDER the tiles/ subdir).
pub fn tileFileName(buf: []u8, key: TileKey) []const u8 {
    return std.fmt.bufPrint(buf, "{d}_{d}_{d}.tile", .{ key.tx, key.ty, key.layer }) catch unreachable;
}

/// Result of reading a tile file: nature + key + an OWNED copy of the payload blob.
/// Caller frees `payload` via the same allocator passed to loadTile.
pub const LoadedTile = struct {
    kind: TileKind,
    key: TileKey,
    /// Owned blob (caller frees). Suitable to hand to mesh.addTile(free_data=true).
    payload: []u8,
};

/// Serialize one tile blob into the canonical chunk bytes (owned buffer).
/// Caller frees the returned slice.
pub fn packTile(alloc: std.mem.Allocator, kind: TileKind, blob: []const u8) ![]u8 {
    const type_flags: u16 = @intFromEnum(kind);
    return cs_mod.buildChunk(alloc, TILE_MAGIC, TILE_VERSION, type_flags, blob);
}

/// Durably write one tile into `tiles_dir`. The file name is derived from the
/// blob's own header (keyFromBlob), so a wrong name can never be persisted.
/// writeAtomic fsyncs the file; the caller fsyncs `tiles_dir` once after the batch.
pub fn writeTile(
    io: Io,
    alloc: std.mem.Allocator,
    tiles_dir: Dir,
    kind: TileKind,
    blob: []const u8,
) !void {
    const key = try keyFromBlob(kind, blob);
    var name_buf: [48]u8 = undefined;
    const name = tileFileName(&name_buf, key);

    const chunk = try packTile(alloc, kind, blob);
    defer alloc.free(chunk);

    try write_atomic.writeAtomic(io, tiles_dir, name, chunk);
}

/// Read + verify one tile file by key from `tiles_dir`. Returns the nature/key and
/// an OWNED copy of the payload blob (caller frees `payload`). A corrupt file is
/// rejected via the canonical chunk checksum (ChunkError); a missing file surfaces
/// FileNotFound from the read.
pub fn loadTile(
    io: Io,
    alloc: std.mem.Allocator,
    tiles_dir: Dir,
    key: TileKey,
) !LoadedTile {
    var name_buf: [48]u8 = undefined;
    const name = tileFileName(&name_buf, key);

    const data = try tiles_dir.readFileAlloc(io, name, alloc, .unlimited);
    defer alloc.free(data);

    // Verify magic/version/length/checksum; returns a no-copy slice into `data`.
    const payload_view = try parseChunk(data, TILE_MAGIC, TILE_VERSION);

    // Recover the kind from the header type_flags (bit 0).
    const hdr = try unpackHeader(data, TILE_MAGIC, TILE_VERSION);
    const kind: TileKind = @enumFromInt(@as(u1, @truncate(hdr.type_flags)));

    // Re-derive the key from the blob header (authoritative) — guards against a
    // renamed file. We still return the caller-requested key's coords from the blob.
    const blob_key = try keyFromBlob(kind, payload_view);

    const owned = try alloc.dupe(u8, payload_view);
    return .{ .kind = kind, .key = blob_key, .payload = owned };
}

/// Write ALL valid tiles of a static navmesh, one file per tile. Returns an OWNED
/// slice of TileKey (caller frees) for the manifest. writeTile fsyncs each file;
/// the caller fsyncs tiles_dir once afterwards (commit order).
pub fn saveAllTiles(
    io: Io,
    alloc: std.mem.Allocator,
    tiles_dir: Dir,
    mesh: *const dt.NavMesh,
) ![]TileKey {
    var keys = std.array_list.Managed(TileKey).init(alloc);
    errdefer keys.deinit();

    for (mesh.tiles) |*t| {
        if (t.header == null or t.data_size == 0) continue;
        const blob = t.data[0..t.data_size];
        try writeTile(io, alloc, tiles_dir, .mset, blob);
        try keys.append(try keyFromBlob(.mset, blob));
    }
    return keys.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests (aggregated via demo/src/tests.zig -> `zig build demo-test`).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Build a synthetic, zeroed TileCacheLayerHeader blob with given coords.
fn synthTileCacheBlob(buf: []u8, tx: i32, ty: i32, tlayer: i32) []u8 {
    const H = tc.TileCacheLayerHeader;
    std.debug.assert(buf.len >= @sizeOf(H));
    const h: *H = @ptrCast(@alignCast(buf.ptr));
    h.* = std.mem.zeroes(H);
    h.magic = tc.TILECACHE_MAGIC;
    h.version = tc.TILECACHE_VERSION;
    h.tx = tx;
    h.ty = ty;
    h.tlayer = tlayer;
    return buf[0..@sizeOf(H)];
}

/// Build a synthetic, zeroed dt.MeshHeader blob with given coords.
fn synthMsetBlob(buf: []u8, x: i32, y: i32, layer: i32) []u8 {
    const H = dt.MeshHeader;
    std.debug.assert(buf.len >= @sizeOf(H));
    const h: *H = @ptrCast(@alignCast(buf.ptr));
    h.* = dt.MeshHeader.init();
    h.x = x;
    h.y = y;
    h.layer = layer;
    return buf[0..@sizeOf(H)];
}

test "tileFileName format incl negatives" {
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("3_5_0.tile", tileFileName(&buf, .{ .tx = 3, .ty = 5, .layer = 0 }));
    try testing.expectEqualStrings("-1_0_2.tile", tileFileName(&buf, .{ .tx = -1, .ty = 0, .layer = 2 }));
}

test "keyFromBlob: tilecache header coords" {
    var raw: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    const blob = synthTileCacheBlob(&raw, 7, 8, 1);
    const key = try keyFromBlob(.tilecache, blob);
    try testing.expectEqual(@as(i32, 7), key.tx);
    try testing.expectEqual(@as(i32, 8), key.ty);
    try testing.expectEqual(@as(i32, 1), key.layer);
}

test "keyFromBlob: mset header coords" {
    var raw: [@sizeOf(dt.MeshHeader)]u8 align(@alignOf(dt.MeshHeader)) = undefined;
    const blob = synthMsetBlob(&raw, -2, 9, 3);
    const key = try keyFromBlob(.mset, blob);
    try testing.expectEqual(@as(i32, -2), key.tx);
    try testing.expectEqual(@as(i32, 9), key.ty);
    try testing.expectEqual(@as(i32, 3), key.layer);
}

test "keyFromBlob: truncated blob -> error" {
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.Truncated, keyFromBlob(.tilecache, &tiny));
    try testing.expectError(error.Truncated, keyFromBlob(.mset, &tiny));
}

test "packTile -> parse round-trip preserves kind+coords+bytes" {
    const alloc = testing.allocator;
    var raw: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    const blob = synthTileCacheBlob(&raw, 2, 3, 0);

    const chunk = try packTile(alloc, .tilecache, blob);
    defer alloc.free(chunk);

    const payload = try parseChunk(chunk, TILE_MAGIC, TILE_VERSION);
    const hdr = try unpackHeader(chunk, TILE_MAGIC, TILE_VERSION);
    const kind: TileKind = @enumFromInt(@as(u1, @truncate(hdr.type_flags)));
    try testing.expectEqual(TileKind.tilecache, kind);
    try testing.expectEqualSlices(u8, blob, payload);
    const key = try keyFromBlob(kind, payload);
    try testing.expectEqual(@as(i32, 2), key.tx);
}

test "writeTile -> loadTile disk round-trip (tilecache)" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var raw: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    const blob = synthTileCacheBlob(&raw, 4, 5, 1);

    try writeTile(io, alloc, tmp.dir, .tilecache, blob);

    const got = try loadTile(io, alloc, tmp.dir, .{ .tx = 4, .ty = 5, .layer = 1 });
    defer alloc.free(got.payload);
    try testing.expectEqual(TileKind.tilecache, got.kind);
    try testing.expectEqual(@as(i32, 4), got.key.tx);
    try testing.expectEqual(@as(i32, 5), got.key.ty);
    try testing.expectEqual(@as(i32, 1), got.key.layer);
    try testing.expectEqualSlices(u8, blob, got.payload);
}

test "writeTile -> loadTile disk round-trip (mset)" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var raw: [@sizeOf(dt.MeshHeader)]u8 align(@alignOf(dt.MeshHeader)) = undefined;
    const blob = synthMsetBlob(&raw, 1, 2, 0);

    try writeTile(io, alloc, tmp.dir, .mset, blob);

    const got = try loadTile(io, alloc, tmp.dir, .{ .tx = 1, .ty = 2, .layer = 0 });
    defer alloc.free(got.payload);
    try testing.expectEqual(TileKind.mset, got.kind);
    try testing.expectEqualSlices(u8, blob, got.payload);
}

test "loadTile rejects a corrupted tile file" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var raw: [@sizeOf(tc.TileCacheLayerHeader)]u8 align(@alignOf(tc.TileCacheLayerHeader)) = undefined;
    const blob = synthTileCacheBlob(&raw, 0, 0, 0);
    try writeTile(io, alloc, tmp.dir, .tilecache, blob);

    // Read raw, flip one payload byte, overwrite -> checksum mismatch on load.
    const data = try tmp.dir.readFileAlloc(io, "0_0_0.tile", alloc, .unlimited);
    defer alloc.free(data);
    data[data.len - 1] ^= 0xFF;
    try tmp.dir.writeFile(io, .{ .sub_path = "0_0_0.tile", .data = data });

    try testing.expectError(error.ChecksumMismatch, loadTile(io, alloc, tmp.dir, .{ .tx = 0, .ty = 0, .layer = 0 }));
}

test "loadTile rejects a too-short tile file (Truncated)" {
    const alloc = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "9_9_9.tile", .data = "garbage" });
    try testing.expectError(error.Truncated, loadTile(io, alloc, tmp.dir, .{ .tx = 9, .ty = 9, .layer = 9 }));
}
