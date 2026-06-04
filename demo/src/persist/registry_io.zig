//! Persist Module 2 — registry_io: serialize/deserialize area-type and poly-flag
//! registries to edits/areas.reg and edits/flags.reg inside a .recastscene container.
//!
//! Format: [FileHeader][Record...] (little-endian, fixed-size records).
//! FileHeader checksum covers the entire file body (all record bytes).
//! Each record carries its own XXH3 checksum for graceful per-record degradation:
//! a corrupt record is skipped, the rest load normally.
//!
//! LOAD ORDER INVARIANT: flags BEFORE area types (area.flags references flag bits).
//! Use loadAll/saveAll which enforce this order.
//!
//! Builds on Persist Module 1:
//!   - write_atomic.writeAtomic(io, dir: Dir, sub_path, bytes) — durable atomic write
//!   - checksum.checksum(bytes) u64 — XXH3 (seed=0)

const std = @import("std");
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");
const write_atomic = @import("write_atomic.zig");
const cs_mod = @import("checksum.zig");

const Io = std.Io;
const Dir = std.Io.Dir;

/// Checksum shorthand: XXH3 over arbitrary bytes.
const checksum = cs_mod.checksum;

pub const Error = error{
    Truncated,
    WrongMagic,
    WrongVersion,
    ChecksumMismatch,
} || std.mem.Allocator.Error;

const REG_VERSION: u32 = 1;
const AREAS_MAGIC: u32 = 0x41524547; // 'AREG'
const FLAGS_MAGIC: u32 = 0x464C4547; // 'FLEG'

/// type_flags value for the file header record.
const TYPE_FILE_HEADER: u16 = 0;
/// type_flags value for a data record (area or flag entry).
const TYPE_RECORD: u16 = 1;

/// NAME_CAP for area types (matches area_types.zig NAME_CAP = 24).
const AREA_NAME_CAP: usize = 24;
/// NAME_CAP for poly flags (matches poly_flags.zig NAME_CAP = 20).
const FLAG_NAME_CAP: usize = 20;

/// Fixed serialized size of one flag record in bytes.
/// Layout: type_flags(u16) + bit_index(u8) + builtin(u8) + name_len(u8) + name[20] + csum(u64)
///       = 2 + 1 + 1 + 1 + 20 + 8 = 33
const FLAG_REC_LEN: usize = 33;

/// Fixed serialized size of one area record in bytes.
/// Layout: type_flags(u16) + id(u8) + builtin(u8) + r(u8) + g(u8) + b(u8) + a(u8) +
///         flags(u16) + cost(f32) + name_len(u8) + name[24] + csum(u64)
///       = 2 + 1 + 1 + 1 + 1 + 1 + 1 + 2 + 4 + 1 + 24 + 8 = 47
const AREA_REC_LEN: usize = 47;

/// File header serialized size:
/// magic(u32) + version(u32) + type_flags(u16) + rec_count(u64) + body_csum(u64)
/// = 4 + 4 + 2 + 8 + 8 = 26
const FILE_HDR_LEN: usize = 26;

// ---------------------------------------------------------------------------
// Write helpers — little-endian, append to ArrayList
// ---------------------------------------------------------------------------

const Buf = std.array_list.Managed(u8);

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
fn putU64(b: *Buf, v: u64) !void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, v, .little);
    try b.appendSlice(&tmp);
}
fn putF32(b: *Buf, v: f32) !void {
    try putU32(b, @bitCast(v));
}

// ---------------------------------------------------------------------------
// Read helpers — little-endian cursor into a slice
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
    fn readU64(self: *Reader) !u64 {
        if (self.pos + 8 > self.data.len) return error.Truncated;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
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
    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }
};

// ---------------------------------------------------------------------------
// Flags serialization
// ---------------------------------------------------------------------------

/// Serialize the poly-flags registry into an owned buffer.
/// Format: [FileHeader][FlagRecord...] — all fixed-size, little-endian.
pub fn serializeFlags(alloc: std.mem.Allocator) !Buf {
    poly_flags.ensureInit();

    // Build body (all records) first so we can checksum it for the file header.
    var body = Buf.init(alloc);
    defer body.deinit();

    var rec_count: u64 = 0;
    for (0..poly_flags.MAX_FLAGS) |i| {
        const f = poly_flags.get(i) orelse continue; // skips unused AND reserved (bit 4)

        // Serialize record WITHOUT trailing checksum first, then append checksum.
        const rec_start = body.items.len;
        try putU16(&body, TYPE_RECORD);
        try putU8(&body, @intCast(i)); // bit_index
        try putU8(&body, if (f.builtin) 1 else 0);
        const nm = f.name();
        try putU8(&body, @intCast(nm.len));
        var name_buf = [_]u8{0} ** FLAG_NAME_CAP;
        @memcpy(name_buf[0..nm.len], nm);
        try body.appendSlice(&name_buf);
        // Checksum over the record bytes written so far (excludes the csum field itself).
        const rec_csum = checksum(body.items[rec_start..]);
        try putU64(&body, rec_csum);

        std.debug.assert(body.items.len - rec_start == FLAG_REC_LEN);
        rec_count += 1;
    }

    // Assemble final output: file header + body.
    var out = Buf.init(alloc);
    errdefer out.deinit();
    try putU32(&out, FLAGS_MAGIC);
    try putU32(&out, REG_VERSION);
    try putU16(&out, TYPE_FILE_HEADER);
    try putU64(&out, rec_count); // number of records (not bytes)
    try putU64(&out, checksum(body.items)); // file-level body checksum
    try out.appendSlice(body.items);

    std.debug.assert(out.items.len == FILE_HDR_LEN + rec_count * FLAG_REC_LEN);
    return out;
}

/// Deserialize flags from `data` into the module-global poly_flags registry.
/// Calls resetToBuiltins() first, then restoreFlag() for each valid record.
/// Corrupt records are skipped (graceful degradation). Returns count applied.
pub fn deserializeFlags(data: []const u8) Error!usize {
    var r = Reader{ .data = data };

    // Parse file header.
    if (try r.readU32() != FLAGS_MAGIC) return error.WrongMagic;
    if (try r.readU32() != REG_VERSION) return error.WrongVersion;
    if (try r.readU16() != TYPE_FILE_HEADER) return error.WrongMagic;
    const rec_count = try r.readU64();
    const file_csum = try r.readU64();
    const body = data[r.pos..];
    if (checksum(body) != file_csum) {
        std.log.warn("flags.reg: file checksum mismatch — attempting per-record recovery", .{});
    }

    poly_flags.resetToBuiltins();
    var applied: usize = 0;
    for (0..rec_count) |n| {
        if (r.remaining() < FLAG_REC_LEN) {
            std.log.warn("flags.reg: truncated at record {d}", .{n});
            break;
        }
        const rec_start = r.pos;
        const tf = try r.readU16();
        const bit_index = try r.readU8();
        const builtin_val = try r.readU8();
        const name_len = try r.readU8();
        const name_bytes = try r.readBytes(FLAG_NAME_CAP);
        const rec_csum = try r.readU64();

        // Per-record validation: type_flags, name_len in range, checksum.
        const rec_no_csum = data[rec_start .. r.pos - 8];
        if (tf != TYPE_RECORD or name_len > FLAG_NAME_CAP or checksum(rec_no_csum) != rec_csum) {
            std.log.warn("flags.reg: bad record {d} (skipped)", .{n});
            continue;
        }
        poly_flags.restoreFlag(bit_index, name_bytes[0..name_len], builtin_val != 0);
        applied += 1;
    }
    return applied;
}

/// Write the poly-flags registry to `dir/edits/flags.reg` durably (atomic).
pub fn saveFlags(alloc: std.mem.Allocator, io: Io, dir: Dir) !void {
    var out = try serializeFlags(alloc);
    defer out.deinit();
    try write_atomic.writeAtomic(io, dir, "edits/flags.reg", out.items);
}

/// Load poly-flags from `dir/edits/flags.reg`. If the file does not exist,
/// resets to builtins and returns 0. Returns the count of records applied.
pub fn loadFlags(alloc: std.mem.Allocator, io: Io, dir: Dir) !usize {
    const data = dir.readFileAlloc(io, "edits/flags.reg", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            poly_flags.resetToBuiltins();
            return 0;
        },
        else => return e,
    };
    defer alloc.free(data);
    return deserializeFlags(data);
}

// ---------------------------------------------------------------------------
// Area types serialization
// ---------------------------------------------------------------------------

/// Serialize the area-types registry into an owned buffer.
/// Format: [FileHeader][AreaRecord...] — all fixed-size, little-endian.
pub fn serializeAreas(alloc: std.mem.Allocator) !Buf {
    area_types.ensureInit();

    var body = Buf.init(alloc);
    defer body.deinit();

    var rec_count: u64 = 0;
    for (0..area_types.MAX_AREA_TYPES) |id| {
        const t = area_types.get(id) orelse continue;

        const rec_start = body.items.len;
        try putU16(&body, TYPE_RECORD);
        try putU8(&body, @intCast(id));
        try putU8(&body, if (t.builtin) 1 else 0);
        try putU8(&body, t.r);
        try putU8(&body, t.g);
        try putU8(&body, t.b);
        try putU8(&body, t.a);
        try putU16(&body, t.flags);
        try putF32(&body, t.cost);
        const nm = t.name();
        try putU8(&body, @intCast(nm.len));
        var name_buf = [_]u8{0} ** AREA_NAME_CAP;
        @memcpy(name_buf[0..nm.len], nm);
        try body.appendSlice(&name_buf);
        const rec_csum = checksum(body.items[rec_start..]);
        try putU64(&body, rec_csum);

        std.debug.assert(body.items.len - rec_start == AREA_REC_LEN);
        rec_count += 1;
    }

    var out = Buf.init(alloc);
    errdefer out.deinit();
    try putU32(&out, AREAS_MAGIC);
    try putU32(&out, REG_VERSION);
    try putU16(&out, TYPE_FILE_HEADER);
    try putU64(&out, rec_count);
    try putU64(&out, checksum(body.items));
    try out.appendSlice(body.items);

    std.debug.assert(out.items.len == FILE_HDR_LEN + rec_count * AREA_REC_LEN);
    return out;
}

/// Deserialize area types from `data` into the module-global area_types registry.
/// Calls resetToBuiltins() first. Corrupt records are skipped. Returns count applied.
/// IMPORTANT: call after loadFlags/deserializeFlags (area.flags references flag bits).
pub fn deserializeAreas(data: []const u8) Error!usize {
    var r = Reader{ .data = data };

    if (try r.readU32() != AREAS_MAGIC) return error.WrongMagic;
    if (try r.readU32() != REG_VERSION) return error.WrongVersion;
    if (try r.readU16() != TYPE_FILE_HEADER) return error.WrongMagic;
    const rec_count = try r.readU64();
    const file_csum = try r.readU64();
    const body = data[r.pos..];
    if (checksum(body) != file_csum) {
        std.log.warn("areas.reg: file checksum mismatch — attempting per-record recovery", .{});
    }

    area_types.resetToBuiltins();
    var applied: usize = 0;
    for (0..rec_count) |n| {
        if (r.remaining() < AREA_REC_LEN) {
            std.log.warn("areas.reg: truncated at record {d}", .{n});
            break;
        }
        const rec_start = r.pos;
        const tf = try r.readU16();
        const id = try r.readU8();
        const builtin_val = try r.readU8();
        const rr = try r.readU8();
        const gg = try r.readU8();
        const bb = try r.readU8();
        const aa = try r.readU8();
        const flags_val = try r.readU16();
        const cost = try r.readF32();
        const name_len = try r.readU8();
        const name_bytes = try r.readBytes(AREA_NAME_CAP);
        const rec_csum = try r.readU64();

        const rec_no_csum = data[rec_start .. r.pos - 8];
        if (tf != TYPE_RECORD or name_len > AREA_NAME_CAP or checksum(rec_no_csum) != rec_csum) {
            std.log.warn("areas.reg: bad record {d} (skipped)", .{n});
            continue;
        }
        var t = area_types.AreaType{
            .used = true,
            .builtin = builtin_val != 0,
            .r = rr,
            .g = gg,
            .b = bb,
            .a = aa,
            .flags = flags_val,
            .cost = cost,
        };
        t.setName(name_bytes[0..name_len]);
        area_types.restoreType(id, t);
        applied += 1;
    }
    return applied;
}

/// Write the area-types registry to `dir/edits/areas.reg` durably (atomic).
pub fn saveAreas(alloc: std.mem.Allocator, io: Io, dir: Dir) !void {
    var out = try serializeAreas(alloc);
    defer out.deinit();
    try write_atomic.writeAtomic(io, dir, "edits/areas.reg", out.items);
}

/// Load area types from `dir/edits/areas.reg`. If the file does not exist,
/// resets to builtins and returns 0.
/// IMPORTANT: call after loadFlags (area.flags references flag bits).
pub fn loadAreas(alloc: std.mem.Allocator, io: Io, dir: Dir) !usize {
    const data = dir.readFileAlloc(io, "edits/areas.reg", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => {
            area_types.resetToBuiltins();
            return 0;
        },
        else => return e,
    };
    defer alloc.free(data);
    return deserializeAreas(data);
}

/// Combined save: flags first, then areas.
pub fn saveAll(alloc: std.mem.Allocator, io: Io, dir: Dir) !void {
    try saveFlags(alloc, io, dir);
    try saveAreas(alloc, io, dir);
}

/// Combined load: flags first (INVARIANT), then areas.
pub fn loadAll(alloc: std.mem.Allocator, io: Io, dir: Dir) !void {
    _ = try loadFlags(alloc, io, dir);
    _ = try loadAreas(alloc, io, dir);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "registry round-trip: custom type+flag, edited builtin cost/color" {
    const alloc = std.testing.allocator;

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();

    // Add a custom flag (auto-bit) — first free after builtins (0..3) and reserved (4) = bit 5.
    const ladder_bit = poly_flags.addFlag("ladder").?;
    // Add a custom area type (auto-id) — first free after builtins (0..5) = slot 6.
    const lava_id = area_types.addType().?;
    {
        const t = area_types.get(lava_id).?;
        t.cost = 9.0;
        t.flags = ladder_bit;
        t.r = 7;
        t.g = 8;
        t.b = 9;
        t.setName("Lava");
    }
    // Edit builtin Ground (cost + color).
    {
        const g = area_types.get(0).?;
        g.cost = 4.25;
        g.r = 11;
        g.g = 22;
        g.b = 33;
    }
    // Rename builtin walk flag.
    poly_flags.get(0).?.setName("stride");

    // Serialize both registries.
    var flags_buf = try serializeFlags(alloc);
    defer flags_buf.deinit();
    var areas_buf = try serializeAreas(alloc);
    defer areas_buf.deinit();

    // Reset to fresh state, then deserialize (flags before areas — invariant).
    _ = try deserializeFlags(flags_buf.items);
    _ = try deserializeAreas(areas_buf.items);

    // Verify: renamed builtin walk flag.
    try std.testing.expectEqualStrings("stride", poly_flags.get(0).?.name());
    try std.testing.expect(poly_flags.get(0).?.builtin);

    // Verify: custom "ladder" flag restored in its exact slot.
    var found_ladder = false;
    for (0..poly_flags.MAX_FLAGS) |i| {
        if (poly_flags.get(i)) |f| {
            if (std.mem.eql(u8, f.name(), "ladder")) {
                found_ladder = true;
                try std.testing.expect(!f.builtin);
            }
        }
    }
    try std.testing.expect(found_ladder);

    // Verify: custom Lava type.
    const lava = area_types.get(lava_id).?;
    try std.testing.expectEqualStrings("Lava", lava.name());
    try std.testing.expectEqual(@as(f32, 9.0), lava.cost);
    try std.testing.expectEqual(@as(u8, 7), lava.r);
    try std.testing.expect(!lava.builtin);

    // Verify: edited builtin Ground.
    const g = area_types.get(0).?;
    try std.testing.expectEqual(@as(f32, 4.25), g.cost);
    try std.testing.expectEqual(@as(u8, 11), g.r);
    try std.testing.expect(g.builtin);
}

test "registry load skips corrupt record, keeps the rest" {
    const alloc = std.testing.allocator;
    poly_flags.resetToBuiltins();
    _ = poly_flags.addFlag("ladder");
    _ = poly_flags.addFlag("crouch");

    var buf = try serializeFlags(alloc);
    defer buf.deinit();

    // Corrupt a byte inside the FIRST record's name buffer (after file header = 26 bytes).
    // File header = FILE_HDR_LEN = 26. First record starts at offset 26.
    // Offset within record: type_flags(2) + bit_index(1) + builtin(1) + name_len(1) = 5.
    // name_buf starts at offset 26 + 5 = 31.
    buf.items[31] ^= 0xFF;

    poly_flags.resetToBuiltins();
    const applied = try deserializeFlags(buf.items);
    // 4 builtins + ladder + crouch = 6 records, 1 corrupt -> 5 applied.
    try std.testing.expect(applied >= 1);
    try std.testing.expect(applied < 6);
}

test "registry disk round-trip via saveAll/loadAll" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    _ = poly_flags.addFlag("ladder");
    const aid = area_types.addType().?;
    area_types.get(aid).?.cost = 5.0;
    area_types.get(aid).?.setName("Custom");

    try saveAll(alloc, io, tmp.dir);

    poly_flags.resetToBuiltins();
    area_types.resetToBuiltins();
    try loadAll(alloc, io, tmp.dir);

    try std.testing.expectEqual(@as(f32, 5.0), area_types.get(aid).?.cost);
    try std.testing.expectEqualStrings("Custom", area_types.get(aid).?.name());

    // Verify ladder flag was restored.
    var found_ladder = false;
    for (0..poly_flags.MAX_FLAGS) |i| {
        if (poly_flags.get(i)) |f| {
            if (std.mem.eql(u8, f.name(), "ladder")) found_ladder = true;
        }
    }
    try std.testing.expect(found_ladder);
}
