//! Persist Module 3 — scene_io: serialize the editable scene state (convex
//! volumes / off-mesh connections / .gset) plus an archive container.
//!
//! Binary files (volumes.bin / offmesh.bin / archive) reuse the canonical
//! Module 1 chunk header (file-header + per-record header with XXH3). Layout
//! mirrors registry_io.zig exactly:
//!   File = [ChunkHeader(TYPE_FILE_HEADER)] ++ body
//!   payload_len = BYTE length of body; file checksum over the locked domain.
//!   Each record = fixed/variable fields ++ appended u64 checksum(record_before_csum);
//!   a corrupt record is skipped (graceful per-record degradation).
//!
//! scene.gset is VERBATIM RecastDemo text (f/s/c/v prefixes), NO chunk header,
//! so it loads in the original RecastDemo. Unknown prefixes are ignored; a
//! malformed known row is skipped+logged (RecastDemo tolerates loose input).
//!
//! LOCKED DECISIONS:
//!   - volumes.bin stores the stable ConvexVolume.id; load writes directly into
//!     geom.volumes (NOT addConvexVolume, which would re-stamp id) and bumps
//!     next_volume_id to max(id)+1 (>= 1).
//!   - offmesh.bin stores the 6 parallel arrays incl. off_id; load writes
//!     directly into the parallel arrays (NOT addOffMeshConnection, which would
//!     overwrite off_id with 1000+i).
//!
//! Builds on Persist Module 1:
//!   - write_atomic.writeAtomic(io, dir, sub_path, bytes) — durable atomic write
//!     (sub_path may be nested, e.g. "edits/volumes.bin").
//!   - checksum.checksum(bytes) u64 — XXH3 (seed 0).
//!   - checksum.ChunkHeader / unpackHeader / readRecord / HEADER_LEN.

const std = @import("std");
const input_geom = @import("../input_geom.zig");
const write_atomic = @import("write_atomic.zig");
const cs_mod = @import("checksum.zig");

const InputGeom = input_geom.InputGeom;
const ConvexVolume = input_geom.ConvexVolume;
const MAX_CONVEXVOL_PTS = input_geom.MAX_CONVEXVOL_PTS;

const Io = std.Io;
const Dir = std.Io.Dir;
const Buf = std.array_list.Managed(u8);

const checksum = cs_mod.checksum;
const ChunkHeader = cs_mod.ChunkHeader;
const unpackHeader = cs_mod.unpackHeader;
const readRecord = cs_mod.readRecord;
const HEADER_LEN = cs_mod.HEADER_LEN;

// --- domain magics (LE u32, distinct from 'MSET'=0x4D534554 and each other) ---
const VOL_FILE_MAGIC: u32 = 0x52564F4C; // file-header volumes.bin
const VOL_REC_MAGIC: u32 = 0x31564F56; // per-volume record
const OFF_FILE_MAGIC: u32 = 0x52464D4F; // file-header offmesh.bin
const OFF_REC_MAGIC: u32 = 0x314D464F; // per-offmesh record
const ARC_FILE_MAGIC: u32 = 0x52415243; // archive file-header
const ARC_REC_MAGIC: u32 = 0x52464C46; // archive per-file record
const FORMAT_VERSION: u32 = 1;
/// volumes.bin format version (bumped from 1 -> 2 to add mode/band_below/band_above).
/// Off-mesh, archive, and gset remain at FORMAT_VERSION = 1 (unchanged).
const VOL_FORMAT_VERSION: u32 = 2;
const VOL_FORMAT_VERSION_LEGACY: u32 = 1;

const TYPE_FILE_HEADER: u16 = 0;
const TYPE_RECORD: u16 = 1;

pub const Error = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
    BadGsetRow,
    TooManyVerts,
    ArchivePathEscape,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Write helpers — little-endian, append to ArrayList (registry_io pattern)
// ---------------------------------------------------------------------------

fn putU8(b: *Buf, v: u8) !void {
    try b.append(v);
}
fn putU16(b: *Buf, v: u16) !void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, v, .little);
    try b.appendSlice(&tmp);
}
fn putU32(b: *Buf, v: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try b.appendSlice(&tmp);
}
fn putI32(b: *Buf, v: i32) !void {
    try putU32(b, @bitCast(v));
}
fn putU64(b: *Buf, v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try b.appendSlice(&tmp);
}
fn putF32(b: *Buf, v: f32) !void {
    try putU32(b, @bitCast(v));
}

/// Append a length-framed record: [ChunkHeader(magic, TYPE_RECORD, payload)] ++ payload.
/// The ChunkHeader gives a self-describing boundary (payload_len) so readRecord can
/// skip a corrupt record independently (graceful per-record degradation).
fn appendRecord(b: *Buf, magic: u32, payload: []const u8) !void {
    const hdr = ChunkHeader.init(magic, FORMAT_VERSION, TYPE_RECORD, payload).pack();
    try b.appendSlice(&hdr);
    try b.appendSlice(payload);
}

/// Like appendRecord but uses the volumes-specific format version.
fn appendVolumeRecord(b: *Buf, magic: u32, payload: []const u8) !void {
    const hdr = ChunkHeader.init(magic, VOL_FORMAT_VERSION, TYPE_RECORD, payload).pack();
    try b.appendSlice(&hdr);
    try b.appendSlice(payload);
}

/// Like assembleFile but uses VOL_FORMAT_VERSION for the file header.
fn assembleVolumeFile(alloc: std.mem.Allocator, magic: u32, body: []const u8) !Buf {
    var out = Buf.init(alloc);
    errdefer out.deinit();
    const hdr_bytes = ChunkHeader.init(magic, VOL_FORMAT_VERSION, TYPE_FILE_HEADER, body).pack();
    try out.appendSlice(&hdr_bytes);
    try out.appendSlice(body);
    return out;
}

/// Parse a volumes.bin file header. Tries VOL_FORMAT_VERSION (2) first; if the
/// file was written with the legacy version (1), falls back and returns version=1.
/// Returns the body slice and the detected file version.
fn volumeFileBody(data: []const u8) Error!struct { body: []const u8, version: u32 } {
    // Try new version first.
    if (unpackHeader(data, VOL_FILE_MAGIC, VOL_FORMAT_VERSION)) |hdr| {
        const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
        const body_end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
        if (body_end > data.len) return error.Truncated;
        const body = data[HEADER_LEN..body_end];
        const want = ChunkHeader.computeChecksum(VOL_FILE_MAGIC, VOL_FORMAT_VERSION, hdr.type_flags, body);
        if (want != hdr.checksum) {
            std.log.warn("scene_io: volumes.bin file checksum mismatch — attempting per-record recovery", .{});
        }
        return .{ .body = body, .version = VOL_FORMAT_VERSION };
    } else |e1| {
        if (e1 != error.WrongVersion) return e1;
        // Legacy: try version 1.
        const hdr = try unpackHeader(data, VOL_FILE_MAGIC, VOL_FORMAT_VERSION_LEGACY);
        const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
        const body_end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
        if (body_end > data.len) return error.Truncated;
        const body = data[HEADER_LEN..body_end];
        const want = ChunkHeader.computeChecksum(VOL_FILE_MAGIC, VOL_FORMAT_VERSION_LEGACY, hdr.type_flags, body);
        if (want != hdr.checksum) {
            std.log.warn("scene_io: volumes.bin (legacy v1) file checksum mismatch — attempting per-record recovery", .{});
        }
        std.log.info("scene_io: volumes.bin detected legacy format v1 — loading as prism with default bands", .{});
        return .{ .body = body, .version = VOL_FORMAT_VERSION_LEGACY };
    }
}

// ---------------------------------------------------------------------------
// Read helpers — little-endian cursor into a slice (registry_io pattern)
// ---------------------------------------------------------------------------

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readU8(self: *Reader) !u8 {
        if (self.pos + 1 > self.data.len) return error.Truncated;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
    fn readU16(self: *Reader) !u16 {
        if (self.pos + 2 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }
    fn readU32(self: *Reader) !u32 {
        if (self.pos + 4 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }
    fn readI32(self: *Reader) !i32 {
        return @bitCast(try self.readU32());
    }
    fn readF32(self: *Reader) !f32 {
        return @bitCast(try self.readU32());
    }
    fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn skip(self: *Reader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.Truncated;
        self.pos += n;
    }
};

/// Pack [ChunkHeader(TYPE_FILE_HEADER)] ++ body into an owned buffer.
fn assembleFile(alloc: std.mem.Allocator, magic: u32, body: []const u8) !Buf {
    var out = Buf.init(alloc);
    errdefer out.deinit();
    const hdr_bytes = ChunkHeader.init(magic, FORMAT_VERSION, TYPE_FILE_HEADER, body).pack();
    try out.appendSlice(&hdr_bytes);
    try out.appendSlice(body);
    return out;
}

/// Parse the file header, verify length + checksum (warn-and-continue on
/// mismatch, mirroring registry_io graceful degradation), return the body slice.
fn fileBody(data: []const u8, magic: u32, name: []const u8) Error![]const u8 {
    const hdr = try unpackHeader(data, magic, FORMAT_VERSION);
    const plen = std.math.cast(usize, hdr.payload_len) orelse return error.Truncated;
    const body_end = std.math.add(usize, HEADER_LEN, plen) catch return error.Truncated;
    if (body_end > data.len) return error.Truncated;
    const body = data[HEADER_LEN..body_end];
    const want = ChunkHeader.computeChecksum(magic, FORMAT_VERSION, hdr.type_flags, body);
    if (want != hdr.checksum) {
        std.log.warn("scene_io: {s} file checksum mismatch — attempting per-record recovery", .{name});
    }
    return body;
}

// ===========================================================================
// volumes.bin
// ===========================================================================

/// Serialize one convex volume record payload (framed by appendVolumeRecord's ChunkHeader).
/// Layout v2: id(u32) area(u8) _pad(u8x3) nverts(i32) hmin(f32) hmax(f32)
///            verts(f32 × nverts*3) mode(u8) band_below(f32) band_above(f32)
/// Layout v1 (legacy, read-only): same but WITHOUT the trailing mode/band_below/band_above.
fn encodeVolumePayload(pl: *Buf, vol: *const ConvexVolume) !void {
    if (vol.nverts < 1 or vol.nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
    try putU32(pl, vol.id);
    try putU8(pl, vol.area);
    try pl.appendSlice(&[_]u8{ 0, 0, 0 }); // _pad
    try putI32(pl, vol.nverts);
    try putF32(pl, vol.hmin);
    try putF32(pl, vol.hmax);
    const n: usize = @intCast(vol.nverts);
    for (vol.verts[0 .. n * 3]) |c| try putF32(pl, c);
    // v2 extension: mode + bands
    try putU8(pl, @intFromEnum(vol.mode));
    try putF32(pl, vol.band_below);
    try putF32(pl, vol.band_above);
}

/// Serialize ALL volumes into an owned buffer:
/// [ChunkHeader(VOL_FORMAT_VERSION=2)] ++ [count:u32] ++ [volume-record × count].
pub fn encodeVolumes(alloc: std.mem.Allocator, geom: *const InputGeom) !Buf {
    var body = Buf.init(alloc);
    defer body.deinit();
    try putU32(&body, @intCast(geom.volumes.items.len));
    var pl = Buf.init(alloc);
    defer pl.deinit();
    for (geom.volumes.items) |*vol| {
        pl.clearRetainingCapacity();
        try encodeVolumePayload(&pl, vol);
        try appendVolumeRecord(&body, VOL_REC_MAGIC, pl.items);
    }
    return assembleVolumeFile(alloc, VOL_FILE_MAGIC, body.items);
}

/// Load volumes from a binary blob into geom (clears existing volumes).
/// Handles both v2 (current) and v1 (legacy) files:
///   - v2: file header version=2, per-record version=2; records include mode/band.
///   - v1: file header version=1, per-record version=1; no mode/band -> defaults
///         vol.mode=.prism, band_below=1.0, band_above=1.0 (old prisms load as prisms).
/// The version is detected from the file-header (unpackHeader); the per-record
/// readRecord is called with the same detected version so both levels are consistent.
/// Corrupt per-volume records are skipped (graceful). next_volume_id is bumped
/// to max(loaded id)+1 (>= 1) so subsequent adds never reuse a stable id.
pub fn decodeVolumes(geom: *InputGeom, data: []const u8) Error!void {
    const fb = try volumeFileBody(data);
    const body = fb.body;
    const file_version = fb.version;

    geom.volumes.clearRetainingCapacity();
    var max_id: u32 = 0;

    var r = Reader{ .data = body };
    const count = try r.readU32();
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        var skip: usize = 0;
        const rec = readRecord(body[r.pos..], VOL_REC_MAGIC, file_version, &skip) catch |e| {
            std.log.warn("scene_io: skipping bad volume #{d}: {s}", .{ k, @errorName(e) });
            if (skip == 0) break; // boundary unknown — cannot resync
            r.pos += skip;
            continue;
        };
        r.pos += rec.next;
        decodeOneVolume(geom, rec.payload, file_version, &max_id) catch |e| {
            std.log.warn("scene_io: volume #{d} dropped: {s}", .{ k, @errorName(e) });
            continue;
        };
    }
    geom.next_volume_id = if (max_id == std.math.maxInt(u32)) max_id else max_id + 1;
    if (geom.next_volume_id < 1) geom.next_volume_id = 1;
}

fn decodeOneVolume(geom: *InputGeom, payload: []const u8, file_version: u32, max_id: *u32) !void {
    var r = Reader{ .data = payload };
    var vol = ConvexVolume{};
    vol.id = try r.readU32();
    vol.area = try r.readU8();
    try r.skip(3); // _pad
    vol.nverts = try r.readI32();
    if (vol.nverts < 1 or vol.nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
    vol.hmin = try r.readF32();
    vol.hmax = try r.readF32();
    const n: usize = @intCast(vol.nverts);
    for (0..n * 3) |i| vol.verts[i] = try r.readF32();
    if (file_version >= VOL_FORMAT_VERSION) {
        // v2+: read mode and band fields.
        const mode_raw = try r.readU8();
        // Clamp/validate: only 0 (prism) or 1 (surface) are valid.
        vol.mode = if (mode_raw <= 1) @enumFromInt(mode_raw) else .prism;
        vol.band_below = try r.readF32();
        vol.band_above = try r.readF32();
    } else {
        // v1 legacy: no mode/band stored — default to prism with stock bands.
        vol.mode = .prism;
        vol.band_below = 1.0;
        vol.band_above = 1.0;
    }
    if (vol.id > max_id.*) max_id.* = vol.id;
    try geom.volumes.append(vol);
}

// ===========================================================================
// offmesh.bin
// ===========================================================================

/// Serialize one off-mesh record payload (framed by appendRecord's ChunkHeader):
/// id(u32) flags(u16) area(u8) dir(u8) rad(f32) verts(f32 × 6)
fn encodeOffMeshPayload(pl: *Buf, geom: *const InputGeom, i: usize) !void {
    try putU32(pl, geom.off_id.items[i]);
    try putU16(pl, geom.off_flags.items[i]);
    try putU8(pl, geom.off_area.items[i]);
    try putU8(pl, geom.off_dir.items[i]);
    try putF32(pl, geom.off_rad.items[i]);
    const v = geom.off_verts.items[i * 6 ..][0..6];
    for (v) |c| try putF32(pl, c);
}

pub fn encodeOffMesh(alloc: std.mem.Allocator, geom: *const InputGeom) !Buf {
    var body = Buf.init(alloc);
    defer body.deinit();
    const count = geom.offMeshCount();
    try putU32(&body, @intCast(count));
    var pl = Buf.init(alloc);
    defer pl.deinit();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        pl.clearRetainingCapacity();
        try encodeOffMeshPayload(&pl, geom, i);
        try appendRecord(&body, OFF_REC_MAGIC, pl.items);
    }
    return assembleFile(alloc, OFF_FILE_MAGIC, body.items);
}

/// Load off-mesh connections directly into the parallel arrays (NOT via
/// addOffMeshConnection, which would overwrite off_id). Clears existing.
pub fn decodeOffMesh(geom: *InputGeom, data: []const u8) Error!void {
    const body = try fileBody(data, OFF_FILE_MAGIC, "offmesh.bin");

    geom.off_verts.clearRetainingCapacity();
    geom.off_rad.clearRetainingCapacity();
    geom.off_dir.clearRetainingCapacity();
    geom.off_area.clearRetainingCapacity();
    geom.off_flags.clearRetainingCapacity();
    geom.off_id.clearRetainingCapacity();

    var r = Reader{ .data = body };
    const count = try r.readU32();
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        var skip: usize = 0;
        const rec = readRecord(body[r.pos..], OFF_REC_MAGIC, FORMAT_VERSION, &skip) catch |e| {
            std.log.warn("scene_io: skipping bad off-mesh #{d}: {s}", .{ k, @errorName(e) });
            if (skip == 0) break;
            r.pos += skip;
            continue;
        };
        r.pos += rec.next;
        decodeOneOffMesh(geom, rec.payload) catch |e| {
            std.log.warn("scene_io: off-mesh #{d} dropped: {s}", .{ k, @errorName(e) });
            continue;
        };
    }
}

fn decodeOneOffMesh(geom: *InputGeom, payload: []const u8) !void {
    var r = Reader{ .data = payload };
    const id = try r.readU32();
    const flags = try r.readU16();
    const area = try r.readU8();
    const dir = try r.readU8();
    const rad = try r.readF32();
    var v: [6]f32 = undefined;
    for (&v) |*c| c.* = try r.readF32();
    try geom.off_verts.appendSlice(&v);
    try geom.off_rad.append(rad);
    try geom.off_dir.append(dir);
    try geom.off_area.append(area);
    try geom.off_flags.append(flags);
    try geom.off_id.append(id);
    // Keep the monotonic counter ahead of every restored id so a fresh add after
    // load can't collide with a loaded off_id.
    if (id >= geom.next_off_id) geom.next_off_id = id + 1;
}

// ===========================================================================
// scene.gset — verbatim RecastDemo text (f/s/c/v), NO chunk header
// ===========================================================================

/// Build settings for the `s` row (21 fields). Optional: if null, `s` is omitted.
///
/// CommonSettings mapping (RecastDemo Sample.h CommonSettings -> .gset `s`):
///   cell_size=m_cellSize, cell_height=m_cellHeight, agent_height=m_agentHeight,
///   agent_radius=m_agentRadius, agent_max_climb=m_agentMaxClimb,
///   agent_max_slope=m_agentMaxSlope, region_min_size=m_regionMinSize,
///   region_merge_size=m_regionMergeSize, edge_max_len=m_edgeMaxLen,
///   edge_max_error=m_edgeMaxError, verts_per_poly=(int)m_vertsPerPoly,
///   detail_sample_dist=m_detailSampleDist,
///   detail_sample_max_error=m_detailSampleMaxError,
///   partition_type=(int)m_partitionType, bmin[0..2], bmax[0..2],
///   tile_size=m_tileSize.
pub const GsetSettings = struct {
    cell_size: f32,
    cell_height: f32,
    agent_height: f32,
    agent_radius: f32,
    agent_max_climb: f32,
    agent_max_slope: f32,
    region_min_size: f32,
    region_merge_size: f32,
    edge_max_len: f32,
    edge_max_error: f32,
    verts_per_poly: i32,
    detail_sample_dist: f32,
    detail_sample_max_error: f32,
    partition_type: i32,
    bmin: [3]f32,
    bmax: [3]f32,
    tile_size: f32,
};

pub const GsetParsed = struct {
    /// owned — caller frees.
    mesh_name: []u8,
    has_settings: bool,
    settings: GsetSettings,
};

/// Append "<v> " or "<v>\n" for an f32 using shortest round-trip representation.
/// {d} on an f32 prints a valid float literal that RecastDemo's sscanf("%f") reads.
fn appendF32(out: *Buf, alloc: std.mem.Allocator, v: f32, sep: u8) !void {
    const s = try std.fmt.allocPrint(alloc, "{d}", .{v});
    defer alloc.free(s);
    try out.appendSlice(s);
    try out.append(sep);
}
fn appendI32(out: *Buf, alloc: std.mem.Allocator, v: i32, sep: u8) !void {
    const s = try std.fmt.allocPrint(alloc, "{d}", .{v});
    defer alloc.free(s);
    try out.appendSlice(s);
    try out.append(sep);
}

/// Serialize a .gset into a text buffer (verbatim RecastDemo format).
pub fn writeGsetText(
    alloc: std.mem.Allocator,
    geom: *const InputGeom,
    mesh_name: []const u8,
    settings: ?GsetSettings,
) !Buf {
    var out = Buf.init(alloc);
    errdefer out.deinit();

    // f %s
    try out.appendSlice("f ");
    try out.appendSlice(mesh_name);
    try out.append('\n');

    // s (21 fields, optional)
    if (settings) |s| {
        try out.appendSlice("s ");
        try appendF32(&out, alloc, s.cell_size, ' ');
        try appendF32(&out, alloc, s.cell_height, ' ');
        try appendF32(&out, alloc, s.agent_height, ' ');
        try appendF32(&out, alloc, s.agent_radius, ' ');
        try appendF32(&out, alloc, s.agent_max_climb, ' ');
        try appendF32(&out, alloc, s.agent_max_slope, ' ');
        try appendF32(&out, alloc, s.region_min_size, ' ');
        try appendF32(&out, alloc, s.region_merge_size, ' ');
        try appendF32(&out, alloc, s.edge_max_len, ' ');
        try appendF32(&out, alloc, s.edge_max_error, ' ');
        try appendI32(&out, alloc, s.verts_per_poly, ' ');
        try appendF32(&out, alloc, s.detail_sample_dist, ' ');
        try appendF32(&out, alloc, s.detail_sample_max_error, ' ');
        try appendI32(&out, alloc, s.partition_type, ' ');
        try appendF32(&out, alloc, s.bmin[0], ' ');
        try appendF32(&out, alloc, s.bmin[1], ' ');
        try appendF32(&out, alloc, s.bmin[2], ' ');
        try appendF32(&out, alloc, s.bmax[0], ' ');
        try appendF32(&out, alloc, s.bmax[1], ' ');
        try appendF32(&out, alloc, s.bmax[2], ' ');
        try appendF32(&out, alloc, s.tile_size, '\n');
    }

    // c (off-mesh): startXYZ endXYZ rad bidir area flags
    var i: usize = 0;
    while (i < geom.offMeshCount()) : (i += 1) {
        const v = geom.off_verts.items[i * 6 ..][0..6];
        try out.appendSlice("c ");
        try appendF32(&out, alloc, v[0], ' ');
        try appendF32(&out, alloc, v[1], ' ');
        try appendF32(&out, alloc, v[2], ' ');
        try appendF32(&out, alloc, v[3], ' ');
        try appendF32(&out, alloc, v[4], ' ');
        try appendF32(&out, alloc, v[5], ' ');
        try appendF32(&out, alloc, geom.off_rad.items[i], ' ');
        try appendI32(&out, alloc, @as(i32, geom.off_dir.items[i]), ' ');
        try appendI32(&out, alloc, @as(i32, geom.off_area.items[i]), ' ');
        try appendI32(&out, alloc, @as(i32, geom.off_flags.items[i]), '\n');
    }

    // v (convex volume): nverts area hmin hmax, then nverts lines "x y z"
    for (geom.volumes.items) |*vol| {
        try out.appendSlice("v ");
        try appendI32(&out, alloc, vol.nverts, ' ');
        try appendI32(&out, alloc, @as(i32, vol.area), ' ');
        try appendF32(&out, alloc, vol.hmin, ' ');
        try appendF32(&out, alloc, vol.hmax, '\n');
        const n: usize = @intCast(vol.nverts);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const p = vol.verts[k * 3 ..][0..3];
            try appendF32(&out, alloc, p[0], ' ');
            try appendF32(&out, alloc, p[1], ' ');
            try appendF32(&out, alloc, p[2], '\n');
        }
    }

    return out;
}

const TokIter = std.mem.TokenIterator(u8, .scalar);

fn nextF32(it: *TokIter) !f32 {
    return std.fmt.parseFloat(f32, it.next() orelse return error.BadGsetRow);
}
fn nextI32(it: *TokIter) !i32 {
    return std.fmt.parseInt(i32, it.next() orelse return error.BadGsetRow, 10);
}

fn parseSettings(it: *TokIter) !GsetSettings {
    return .{
        .cell_size = try nextF32(it),
        .cell_height = try nextF32(it),
        .agent_height = try nextF32(it),
        .agent_radius = try nextF32(it),
        .agent_max_climb = try nextF32(it),
        .agent_max_slope = try nextF32(it),
        .region_min_size = try nextF32(it),
        .region_merge_size = try nextF32(it),
        .edge_max_len = try nextF32(it),
        .edge_max_error = try nextF32(it),
        .verts_per_poly = try nextI32(it),
        .detail_sample_dist = try nextF32(it),
        .detail_sample_max_error = try nextF32(it),
        .partition_type = try nextI32(it),
        .bmin = .{ try nextF32(it), try nextF32(it), try nextF32(it) },
        .bmax = .{ try nextF32(it), try nextF32(it), try nextF32(it) },
        .tile_size = try nextF32(it),
    };
}

/// Read a .gset: fill geom (off-mesh + volumes), return mesh_name (owned) and
/// settings. Unknown prefixes are ignored; a malformed known row is skipped+logged.
pub fn readGsetText(alloc: std.mem.Allocator, geom: *InputGeom, text: []const u8) !GsetParsed {
    var mesh_name: []u8 = try alloc.dupe(u8, "");
    errdefer alloc.free(mesh_name);
    var has_settings = false;
    var settings: GsetSettings = undefined;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 1) continue;
        switch (line[0]) {
            'f' => {
                const rest = std.mem.trim(u8, line[1..], " \t");
                const dup = try alloc.dupe(u8, rest);
                alloc.free(mesh_name);
                mesh_name = dup;
            },
            's' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                settings = parseSettings(&it) catch |e| {
                    std.log.warn("scene_io: skipping bad .gset 's' row: {s}", .{@errorName(e)});
                    continue;
                };
                has_settings = true;
            },
            'c' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                const parsed = parseOffMeshRow(&it) catch |e| {
                    std.log.warn("scene_io: skipping bad .gset 'c' row: {s}", .{@errorName(e)});
                    continue;
                };
                try geom.addOffMeshConnection(
                    parsed.start,
                    parsed.end,
                    parsed.rad,
                    parsed.bidir,
                    parsed.area,
                    parsed.flags,
                );
            },
            'v' => {
                var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
                parseVolumeRows(alloc, geom, &it, &lines) catch |e| {
                    std.log.warn("scene_io: skipping bad .gset 'v' row: {s}", .{@errorName(e)});
                    continue;
                };
            },
            else => {}, // unknown prefix — ignore (as RecastDemo)
        }
    }

    return .{ .mesh_name = mesh_name, .has_settings = has_settings, .settings = settings };
}

const OffMeshRow = struct {
    start: [3]f32,
    end: [3]f32,
    rad: f32,
    bidir: u8,
    area: u8,
    flags: u16,
};

fn parseOffMeshRow(it: *TokIter) !OffMeshRow {
    const sx = try nextF32(it);
    const sy = try nextF32(it);
    const sz = try nextF32(it);
    const ex = try nextF32(it);
    const ey = try nextF32(it);
    const ez = try nextF32(it);
    const rad = try nextF32(it);
    const bidir = try nextI32(it);
    const area = try nextI32(it);
    const flags = try nextI32(it);
    return .{
        .start = .{ sx, sy, sz },
        .end = .{ ex, ey, ez },
        .rad = rad,
        .bidir = @intCast(@as(u32, @bitCast(bidir)) & 0xFF),
        .area = @intCast(@as(u32, @bitCast(area)) & 0xFF),
        .flags = @intCast(@as(u32, @bitCast(flags)) & 0xFFFF),
    };
}

fn parseVolumeRows(
    alloc: std.mem.Allocator,
    geom: *InputGeom,
    it: *TokIter,
    lines: *std.mem.SplitIterator(u8, .scalar),
) !void {
    _ = alloc;
    const nverts = try nextI32(it);
    const area = try nextI32(it);
    const hmin = try nextF32(it);
    const hmax = try nextF32(it);
    if (nverts < 1 or nverts > MAX_CONVEXVOL_PTS) return error.TooManyVerts;
    const n: usize = @intCast(nverts);
    var verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const vraw = lines.next() orelse return error.BadGsetRow;
        const vline = std.mem.trim(u8, vraw, " \t\r");
        var vit = std.mem.tokenizeScalar(u8, vline, ' ');
        verts[k * 3 + 0] = try nextF32(&vit);
        verts[k * 3 + 1] = try nextF32(&vit);
        verts[k * 3 + 2] = try nextF32(&vit);
    }
    try geom.addConvexVolume(verts[0 .. n * 3], nverts, hmin, hmax, @intCast(@as(u32, @bitCast(area)) & 0xFF));
}

// ===========================================================================
// Disk wrappers
// ===========================================================================

/// Write volumes.bin into dir (atomic). `dir` is the .recastscene container ROOT.
pub fn saveVolumes(alloc: std.mem.Allocator, io: Io, dir: Dir, geom: *const InputGeom) !void {
    var blob = try encodeVolumes(alloc, geom);
    defer blob.deinit();
    try write_atomic.writeAtomic(io, dir, "edits/volumes.bin", blob.items);
}

pub fn loadVolumes(alloc: std.mem.Allocator, io: Io, dir: Dir, geom: *InputGeom) !void {
    const bytes = dir.readFileAlloc(io, "edits/volumes.bin", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer alloc.free(bytes);
    try decodeVolumes(geom, bytes);
}

pub fn saveOffMesh(alloc: std.mem.Allocator, io: Io, dir: Dir, geom: *const InputGeom) !void {
    var blob = try encodeOffMesh(alloc, geom);
    defer blob.deinit();
    try write_atomic.writeAtomic(io, dir, "edits/offmesh.bin", blob.items);
}

pub fn loadOffMesh(alloc: std.mem.Allocator, io: Io, dir: Dir, geom: *InputGeom) !void {
    const bytes = dir.readFileAlloc(io, "edits/offmesh.bin", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer alloc.free(bytes);
    try decodeOffMesh(geom, bytes);
}

/// Write scene.gset (atomic, NO chunk header — RecastDemo format as-is).
pub fn writeGset(
    alloc: std.mem.Allocator,
    io: Io,
    dir: Dir,
    geom: *const InputGeom,
    mesh_name: []const u8,
    settings: ?GsetSettings,
) !void {
    var txt = try writeGsetText(alloc, geom, mesh_name, settings);
    defer txt.deinit();
    try write_atomic.writeAtomic(io, dir, "scene.gset", txt.items);
}

pub fn readGset(alloc: std.mem.Allocator, io: Io, dir: Dir, geom: *InputGeom) !GsetParsed {
    const text = try dir.readFileAlloc(io, "scene.gset", alloc, .unlimited);
    defer alloc.free(text);
    return readGsetText(alloc, geom, text);
}

// ===========================================================================
// Archive: directory <-> single file
// ===========================================================================

/// Reject absolute paths and `..` traversal segments.
fn isSafeRelPath(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (rel[0] == '/' or rel[0] == '\\') return false;
    if (rel.len >= 2 and rel[1] == ':') return false; // C:\ style
    var it = std.mem.splitAny(u8, rel, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Collect a sorted list of all relative POSIX file paths under `dir` (recursive).
/// Returns owned slice of owned strings (caller frees each + the slice).
fn collectFiles(io: Io, alloc: std.mem.Allocator, dir: Dir) ![][]u8 {
    var list = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (list.items) |s| alloc.free(s);
        list.deinit();
    }
    try walkInto(io, alloc, dir, "", &list);
    std.mem.sort([]u8, list.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return list.toOwnedSlice();
}

fn walkInto(io: Io, alloc: std.mem.Allocator, root: Dir, prefix: []const u8, list: *std.array_list.Managed([]u8)) !void {
    var d = try root.openDir(io, if (prefix.len == 0) "." else prefix, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        const rel = if (prefix.len == 0)
            try alloc.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, e.name });
        switch (e.kind) {
            .file => try list.append(rel),
            .directory => {
                defer alloc.free(rel);
                try walkInto(io, alloc, root, rel, list);
            },
            else => alloc.free(rel),
        }
    }
}

/// Pack all files under src_dir into a single owned blob:
/// [ChunkHeader] ++ [file_count:u32] ++ ([path_len:u32][path][record] × count),
/// paths sorted for determinism. Each per-file record = ChunkHeader+content.
pub fn packArchiveToBytes(io: Io, alloc: std.mem.Allocator, src_dir: Dir) !Buf {
    const files = try collectFiles(io, alloc, src_dir);
    defer {
        for (files) |s| alloc.free(s);
        alloc.free(files);
    }

    var body = Buf.init(alloc);
    defer body.deinit();
    try putU32(&body, @intCast(files.len));
    for (files) |rel| {
        try putU32(&body, @intCast(rel.len));
        try body.appendSlice(rel);
        const content = try src_dir.readFileAlloc(io, rel, alloc, .unlimited);
        defer alloc.free(content);
        const rec = ChunkHeader.init(ARC_REC_MAGIC, FORMAT_VERSION, TYPE_RECORD, content).pack();
        try body.appendSlice(&rec);
        try body.appendSlice(content);
    }
    return assembleFile(alloc, ARC_FILE_MAGIC, body.items);
}

/// Pack src_dir into a single file out_name in out_dir (atomic).
pub fn packArchive(io: Io, alloc: std.mem.Allocator, src_dir: Dir, out_dir: Dir, out_name: []const u8) !void {
    var blob = try packArchiveToBytes(io, alloc, src_dir);
    defer blob.deinit();
    try write_atomic.writeAtomic(io, out_dir, out_name, blob.items);
}

/// Unpack an archive blob into dst_dir (creates subdirs). Rejects path traversal.
pub fn unpackArchiveFromBytes(io: Io, blob: []const u8, dst_dir: Dir) !void {
    const body = try fileBody(blob, ARC_FILE_MAGIC, "archive");

    var r = Reader{ .data = body };
    const count = try r.readU32();
    var k: u32 = 0;
    while (k < count) : (k += 1) {
        const plen = try r.readU32();
        const rel = try r.readBytes(plen);
        if (!isSafeRelPath(rel)) return error.ArchivePathEscape;

        var skip: usize = 0;
        const rec = readRecord(body[r.pos..], ARC_REC_MAGIC, FORMAT_VERSION, &skip) catch |e| {
            std.log.warn("scene_io: skipping bad archived file '{s}': {s}", .{ rel, @errorName(e) });
            if (skip == 0) break;
            r.pos += skip;
            continue;
        };
        r.pos += rec.next;
        // writeAtomic creates intermediate parent dirs for a nested sub_path.
        try write_atomic.writeAtomic(io, dst_dir, rel, rec.payload);
    }
}

pub fn unpackArchive(io: Io, alloc: std.mem.Allocator, in_dir: Dir, in_name: []const u8, dst_dir: Dir) !void {
    const blob = try in_dir.readFileAlloc(io, in_name, alloc, .unlimited);
    defer alloc.free(blob);
    try unpackArchiveFromBytes(io, blob, dst_dir);
}

// ===========================================================================
// Tests
// ===========================================================================

test "volumes.bin round-trip preserves stable id and geometry" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0.5, 2.0, 7); // id=1
    try g.addConvexVolume(&tri, 3, -1.0, 1.0, 3); // id=2
    g.deleteConvexVolume(0); // leaves id=2
    try g.addConvexVolume(&tri, 3, 0.0, 5.0, 1); // id=3

    // Set custom mode/band on the first remaining volume (id=2) to verify v2 round-trip.
    g.volumes.items[0].mode = .surface;
    g.volumes.items[0].band_below = 2.5;
    g.volumes.items[0].band_above = 3.5;

    var blob = try encodeVolumes(alloc, &g);
    defer blob.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try decodeVolumes(&g2, blob.items);

    try std.testing.expectEqual(g.volumes.items.len, g2.volumes.items.len);
    for (g.volumes.items, g2.volumes.items) |a, b| {
        try std.testing.expectEqual(a.id, b.id);
        try std.testing.expectEqual(a.area, b.area);
        try std.testing.expectEqual(a.nverts, b.nverts);
        try std.testing.expectEqual(a.hmin, b.hmin);
        try std.testing.expectEqual(a.hmax, b.hmax);
        const n: usize = @intCast(a.nverts);
        try std.testing.expectEqualSlices(f32, a.verts[0 .. n * 3], b.verts[0 .. n * 3]);
        // v2: mode and band fields must survive the round-trip.
        try std.testing.expectEqual(a.mode, b.mode);
        try std.testing.expectEqual(a.band_below, b.band_below);
        try std.testing.expectEqual(a.band_above, b.band_above);
    }
    // Assert the surface/band values on the specific volume (id=2, index=0).
    try std.testing.expectEqual(@import("../input_geom.zig").VolumeMode.surface, g2.volumes.items[0].mode);
    try std.testing.expectApproxEqAbs(@as(f32, 2.5), g2.volumes.items[0].band_below, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), g2.volumes.items[0].band_above, 1e-6);
    // next_volume_id bumped past max loaded id (3) so a new add won't reuse it.
    try std.testing.expectEqual(@as(u32, 4), g2.next_volume_id);
}

test "volumes.bin legacy v1 decodes as prism with default bands" {
    // Construct a hand-crafted v1 volumes.bin with one record that has NO mode/band
    // fields (the old format). Verify that decodeVolumes assigns .prism + defaults.
    const alloc = std.testing.allocator;
    const VolumeMode = @import("../input_geom.zig").VolumeMode;

    // Build the v1 payload for one volume: id=42 area=5 pad nverts=3 hmin hmax verts
    var pl = Buf.init(alloc);
    defer pl.deinit();
    try putU32(&pl, 42); // id
    try putU8(&pl, 5); // area
    try pl.appendSlice(&[_]u8{ 0, 0, 0 }); // _pad
    try putI32(&pl, 3); // nverts
    try putF32(&pl, 0.5); // hmin
    try putF32(&pl, 2.0); // hmax
    // 3 verts
    const vcoords = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    for (vcoords) |c| try putF32(&pl, c);
    // NO mode/band_below/band_above — this is v1 legacy

    // Wrap in a v1 per-record chunk header (VOL_FORMAT_VERSION_LEGACY = 1)
    var body = Buf.init(alloc);
    defer body.deinit();
    try putU32(&body, 1); // count = 1
    const rec_hdr = ChunkHeader.init(VOL_REC_MAGIC, VOL_FORMAT_VERSION_LEGACY, TYPE_RECORD, pl.items).pack();
    try body.appendSlice(&rec_hdr);
    try body.appendSlice(pl.items);

    // Wrap in a v1 file header
    var blob = Buf.init(alloc);
    defer blob.deinit();
    const file_hdr = ChunkHeader.init(VOL_FILE_MAGIC, VOL_FORMAT_VERSION_LEGACY, TYPE_FILE_HEADER, body.items).pack();
    try blob.appendSlice(&file_hdr);
    try blob.appendSlice(body.items);

    var g = InputGeom.init(alloc);
    defer g.deinit();
    try decodeVolumes(&g, blob.items);

    try std.testing.expectEqual(@as(usize, 1), g.volumes.items.len);
    const vol = g.volumes.items[0];
    try std.testing.expectEqual(@as(u32, 42), vol.id);
    try std.testing.expectEqual(@as(u8, 5), vol.area);
    // Legacy decode must yield .prism with default bands.
    try std.testing.expectEqual(VolumeMode.prism, vol.mode);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vol.band_below, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vol.band_above, 1e-6);
}

test "volumes load skips a corrupt record, keeps the rest" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0, 1, 4);
    try g.addConvexVolume(&tri, 3, 0, 1, 5);
    try g.addConvexVolume(&tri, 3, 0, 1, 6);

    var blob = try encodeVolumes(alloc, &g);
    defer blob.deinit();

    // Corrupt a byte inside the FIRST record's payload. The file body starts at
    // HEADER_LEN; then [count:u32]; then the first record = [ChunkHeader][payload].
    // Payload of record 0 begins at HEADER_LEN + 4 + HEADER_LEN.
    const rec0_payload = HEADER_LEN + 4 + HEADER_LEN;
    blob.items[rec0_payload + 10] ^= 0xFF; // flips a vert byte -> ChecksumMismatch

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try decodeVolumes(&g2, blob.items);
    // 3 records, 1 corrupt -> 2 loaded.
    try std.testing.expectEqual(@as(usize, 2), g2.volumes.items.len);
}

test "offmesh.bin round-trip preserves all parallel arrays incl off_id" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.5, 1, 9, 0xABCD);
    try g.addOffMeshConnection(.{ -1, 0, 1 }, .{ 2, 2, 2 }, 1.25, 0, 2, 0x0001);

    var blob = try encodeOffMesh(alloc, &g);
    defer blob.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try decodeOffMesh(&g2, blob.items);

    try std.testing.expectEqual(g.offMeshCount(), g2.offMeshCount());
    try std.testing.expectEqualSlices(f32, g.off_verts.items, g2.off_verts.items);
    try std.testing.expectEqualSlices(f32, g.off_rad.items, g2.off_rad.items);
    try std.testing.expectEqualSlices(u8, g.off_dir.items, g2.off_dir.items);
    try std.testing.expectEqualSlices(u8, g.off_area.items, g2.off_area.items);
    try std.testing.expectEqualSlices(u16, g.off_flags.items, g2.off_flags.items);
    try std.testing.expectEqualSlices(u32, g.off_id.items, g2.off_id.items);
}

test "gset writer emits exact RecastDemo row format" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 0, 0, 0 }, .{ 1, 1, 1 }, 0.5, 1, 2, 3);
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0, 4, 5);

    var txt = try writeGsetText(alloc, &g, "mesh.obj", null);
    defer txt.deinit();

    const expected =
        "f mesh.obj\n" ++
        "c 0 0 0 1 1 1 0.5 1 2 3\n" ++
        "v 3 5 0 4\n" ++
        "0 0 0\n" ++
        "1 0 0\n" ++
        "0 0 1\n";
    try std.testing.expectEqualStrings(expected, txt.items);
}

test "gset round-trip (write -> read) preserves off-mesh and volumes" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.75, 0, 1, 7);
    const tri = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    try g.addConvexVolume(&tri, 3, -1, 3, 9);

    var txt = try writeGsetText(alloc, &g, "x.obj", null);
    defer txt.deinit();

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    const parsed = try readGsetText(alloc, &g2, txt.items);
    defer alloc.free(parsed.mesh_name);

    try std.testing.expectEqualStrings("x.obj", parsed.mesh_name);
    try std.testing.expectEqual(@as(usize, 1), g2.offMeshCount());
    try std.testing.expectEqual(@as(usize, 1), g2.volumes.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), g2.off_rad.items[0], 1e-6);
    try std.testing.expectEqual(@as(i32, 3), g2.volumes.items[0].nverts);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), g2.volumes.items[0].hmax, 1e-6);
    // verts preserved
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), g2.volumes.items[0].verts[3], 1e-6);
}

test "gset reader ignores unknown prefixes and tolerates settings line" {
    const alloc = std.testing.allocator;
    var g = InputGeom.init(alloc);
    defer g.deinit();
    const txt =
        "# a comment line\n" ++
        "f map.obj\n" ++
        "s 0.3 0.2 2 0.6 0.9 45 8 20 12 1.3 6 6 1 0 -1 -2 -3 4 5 6 48\n" ++
        "x ignore me\n" ++
        "c 1 2 3 4 5 6 0.5 1 0 1\n";
    const parsed = try readGsetText(alloc, &g, txt);
    defer alloc.free(parsed.mesh_name);
    try std.testing.expectEqualStrings("map.obj", parsed.mesh_name);
    try std.testing.expect(parsed.has_settings);
    try std.testing.expectEqual(@as(i32, 6), parsed.settings.verts_per_poly);
    try std.testing.expectApproxEqAbs(@as(f32, 48.0), parsed.settings.tile_size, 1e-6);
    try std.testing.expectEqual(@as(usize, 1), g.offMeshCount());
}

test "isSafeRelPath rejects traversal and absolute paths" {
    try std.testing.expect(isSafeRelPath("edits/volumes.bin"));
    try std.testing.expect(isSafeRelPath("scene.gset"));
    try std.testing.expect(!isSafeRelPath("../x"));
    try std.testing.expect(!isSafeRelPath("a/../../x"));
    try std.testing.expect(!isSafeRelPath("/abs/path"));
    try std.testing.expect(!isSafeRelPath("\\abs\\path"));
    try std.testing.expect(!isSafeRelPath("C:\\win"));
    try std.testing.expect(!isSafeRelPath(""));
}

test "saveVolumes -> loadVolumes through disk round-trips" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var g = InputGeom.init(alloc);
    defer g.deinit();
    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try g.addConvexVolume(&tri, 3, 0, 1, 4);
    try g.addConvexVolume(&tri, 3, 0, 2, 5);

    try saveVolumes(alloc, io, tmp.dir, &g);

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    try loadVolumes(alloc, io, tmp.dir, &g2);
    try std.testing.expectEqual(g.volumes.items.len, g2.volumes.items.len);
    try std.testing.expectEqual(g.volumes.items[0].id, g2.volumes.items[0].id);
    try std.testing.expectEqual(g.volumes.items[1].id, g2.volumes.items[1].id);
}

test "writeGset -> readGset through disk round-trips" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var g = InputGeom.init(alloc);
    defer g.deinit();
    try g.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.75, 0, 1, 7);

    try writeGset(alloc, io, tmp.dir, &g, "level.obj", null);

    var g2 = InputGeom.init(alloc);
    defer g2.deinit();
    const parsed = try readGset(alloc, io, tmp.dir, &g2);
    defer alloc.free(parsed.mesh_name);
    try std.testing.expectEqualStrings("level.obj", parsed.mesh_name);
    try std.testing.expectEqual(@as(usize, 1), g2.offMeshCount());
}

test "packArchive -> unpackArchive is idempotent (byte-identical files)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var srctmp = std.testing.tmpDir(.{});
    defer srctmp.cleanup();
    var dsttmp = std.testing.tmpDir(.{});
    defer dsttmp.cleanup();

    // Build a src dir with two files, one nested.
    try srctmp.dir.writeFile(io, .{ .sub_path = "scene.gset", .data = "f mesh.obj\n" });
    try srctmp.dir.createDirPath(io, "edits");
    try srctmp.dir.writeFile(io, .{ .sub_path = "edits/volumes.bin", .data = "\x01\x02\x03\x04" });

    // Re-open src as iterable.
    var src = try srctmp.dir.openDir(io, ".", .{ .iterate = true });
    defer src.close(io);

    var blob = try packArchiveToBytes(io, alloc, src);
    defer blob.deinit();

    try unpackArchiveFromBytes(io, blob.items, dsttmp.dir);

    const a = try dsttmp.dir.readFileAlloc(io, "scene.gset", alloc, .unlimited);
    defer alloc.free(a);
    const b = try dsttmp.dir.readFileAlloc(io, "edits/volumes.bin", alloc, .unlimited);
    defer alloc.free(b);
    try std.testing.expectEqualStrings("f mesh.obj\n", a);
    try std.testing.expectEqualSlices(u8, "\x01\x02\x03\x04", b);
}

test "unpackArchive rejects a path-traversal entry" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var dsttmp = std.testing.tmpDir(.{});
    defer dsttmp.cleanup();

    // Hand-craft an archive blob with one entry whose path is "../evil".
    const evil = "../evil";
    const content = "x";
    var body = Buf.init(alloc);
    defer body.deinit();
    try putU32(&body, 1);
    try putU32(&body, @intCast(evil.len));
    try body.appendSlice(evil);
    const rec = ChunkHeader.init(ARC_REC_MAGIC, FORMAT_VERSION, TYPE_RECORD, content).pack();
    try body.appendSlice(&rec);
    try body.appendSlice(content);
    var blob = try assembleFile(alloc, ARC_FILE_MAGIC, body.items);
    defer blob.deinit();

    try std.testing.expectError(error.ArchivePathEscape, unpackArchiveFromBytes(io, blob.items, dsttmp.dir));
}
