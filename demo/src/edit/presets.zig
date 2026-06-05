//! presets — named area-type / poly-flag PRESETS (cluster F, feature F4).
//!
//! A preset is the SAME binary format as edits/areas.reg + edits/flags.reg
//! (registry_io chunks), concatenated into one self-describing blob and stored
//! under `presets/<name>.reg`. No new format is introduced — the areas chunk and
//! the flags chunk each carry their own ChunkHeader{magic,version,payload_len,
//! checksum}, so the combined blob can be split on load by reading the FIRST
//! (areas) header's total length (HEADER_LEN + payload_len).
//!
//! Applying a preset is ONE undo-able edit: `applyBlob` mutates the module-global
//! registries and returns a `registry_snapshot` EditOp the caller records on the
//! UndoStack (before = current serialized, after = post-apply serialized).
//!
//! Two strategies:
//!   - REPLACE: deserialize the preset over the globals (registry == preset).
//!   - MERGE  : keep the current registry, add only preset entries whose NAME is
//!              absent from the current registry (default).

const std = @import("std");
const registry_io = @import("../persist/registry_io.zig");
const write_atomic = @import("../persist/write_atomic.zig");
const cs_mod = @import("../persist/checksum.zig");
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");
const edit_op = @import("edit_op.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const EditOp = edit_op.EditOp;
const HEADER_LEN = cs_mod.HEADER_LEN;

/// Strategy for applying a preset to the current registry.
pub const ApplyMode = enum { replace, merge };

pub const Error = error{
    Truncated,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Serialize / split
// ---------------------------------------------------------------------------

/// Serialize the CURRENT global registry into one combined preset blob:
///   areas_chunk ‖ flags_chunk  (each self-describing). Caller frees the result.
pub fn serializeCurrent(alloc: std.mem.Allocator) ![]u8 {
    var areas = try registry_io.serializeAreas(alloc);
    defer areas.deinit();
    var flags = try registry_io.serializeFlags(alloc);
    defer flags.deinit();

    const out = try alloc.alloc(u8, areas.items.len + flags.items.len);
    @memcpy(out[0..areas.items.len], areas.items);
    @memcpy(out[areas.items.len..], flags.items);
    return out;
}

/// Split a combined preset blob into its areas and flags halves by reading the
/// areas chunk's header (HEADER_LEN + payload_len). Slices point INTO `blob`.
pub fn splitBlob(blob: []const u8) Error!struct { areas: []const u8, flags: []const u8 } {
    if (blob.len < HEADER_LEN) return error.Truncated;
    // payload_len of the FIRST (areas) chunk lives at bytes [10..18] (LE u64).
    const plen = std.mem.readInt(u64, blob[10..18], .little);
    const plen_usize = std.math.cast(usize, plen) orelse return error.Truncated;
    const areas_end = std.math.add(usize, HEADER_LEN, plen_usize) catch return error.Truncated;
    if (areas_end > blob.len) return error.Truncated;
    return .{ .areas = blob[0..areas_end], .flags = blob[areas_end..] };
}

// ---------------------------------------------------------------------------
// Disk: save / list
// ---------------------------------------------------------------------------

/// Cap on a sanitized preset file stem (before ".reg").
const NAME_STEM_CAP: usize = 48;

/// Sanitize a user-supplied preset name into a safe file STEM (no extension):
/// trim whitespace, strip path separators ('/' '\\' ':' and control chars),
/// cap length. Empty -> "preset". Writes into `buf`, returns the used slice.
pub fn sanitizeName(buf: []u8, name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    var n: usize = 0;
    for (trimmed) |c| {
        if (n >= NAME_STEM_CAP or n >= buf.len) break;
        if (c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or
            c == '"' or c == '<' or c == '>' or c == '|' or c < 0x20) continue;
        buf[n] = c;
        n += 1;
    }
    if (n == 0) {
        const def = "preset";
        @memcpy(buf[0..def.len], def);
        return buf[0..def.len];
    }
    return buf[0..n];
}

/// Save the CURRENT registry to `dir/presets/<name>.reg` atomically.
/// `name` is sanitized; ".reg" is appended here (caller passes a bare stem).
pub fn savePreset(alloc: std.mem.Allocator, io: Io, dir: Dir, name: []const u8) !void {
    var stem_buf: [NAME_STEM_CAP]u8 = undefined;
    const stem = sanitizeName(&stem_buf, name);

    var path_buf: [NAME_STEM_CAP + 16]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&path_buf, "presets/{s}.reg", .{stem});

    const blob = try serializeCurrent(alloc);
    defer alloc.free(blob);
    try write_atomic.writeAtomic(io, dir, sub_path, blob);
}

/// List preset names (file stems, ".reg" stripped) in `dir/presets/`.
/// Returns an owned slice of owned name strings; caller frees each + the slice.
/// A missing presets/ directory yields an empty list (not an error).
pub fn listPresets(alloc: std.mem.Allocator, io: Io, dir: Dir) ![][]u8 {
    var names = std.array_list.Managed([]u8).init(alloc);
    errdefer {
        for (names.items) |nm| alloc.free(nm);
        names.deinit();
    }

    var pdir = dir.openDir(io, "presets", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return names.toOwnedSlice(),
        else => return e,
    };
    defer pdir.close(io);

    var it = pdir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".reg")) continue;
        const stem = entry.name[0 .. entry.name.len - ".reg".len];
        if (stem.len == 0) continue;
        try names.append(try alloc.dupe(u8, stem));
    }
    return names.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Apply (replace | merge)
// ---------------------------------------------------------------------------

/// Build the registry_snapshot EditOp from two combined blobs (before/after),
/// splitting each into its areas/flags halves and DUPING the halves so the op
/// owns clean independent slices. Frees `before` and `after` (combined buffers).
fn snapshotFromCombined(alloc: std.mem.Allocator, before: []u8, after: []u8) !EditOp {
    defer alloc.free(before);
    defer alloc.free(after);

    const bs = try splitBlob(before);
    const as = try splitBlob(after);

    const ba = try alloc.dupe(u8, bs.areas);
    errdefer alloc.free(ba);
    const bf = try alloc.dupe(u8, bs.flags);
    errdefer alloc.free(bf);
    const aa = try alloc.dupe(u8, as.areas);
    errdefer alloc.free(aa);
    const af = try alloc.dupe(u8, as.flags);
    errdefer alloc.free(af);

    return edit_op.makeRegistrySnapshot(alloc, ba, aa, bf, af);
}

/// Apply a preset `blob` to the global registry, returning the registry_snapshot
/// EditOp the caller records on the UndoStack. The globals are left in the merged/
/// replaced state. `blob` itself is NOT freed (caller owns it).
pub fn applyBlob(alloc: std.mem.Allocator, blob: []const u8, mode: ApplyMode) !EditOp {
    const halves = try splitBlob(blob);

    // before = current serialized (combined). Owns its buffer (freed in snapshotFromCombined).
    const before = try serializeCurrent(alloc);
    errdefer alloc.free(before);

    switch (mode) {
        .replace => {
            // Deserialize the preset over the globals (flags BEFORE areas — invariant).
            _ = try registry_io.deserializeFlags(halves.flags);
            _ = try registry_io.deserializeAreas(halves.areas);
        },
        .merge => {
            // 1) Snapshot current NAME sets (areas + flags) from the globals.
            var cur_area_names = std.array_list.Managed([]u8).init(alloc);
            defer {
                for (cur_area_names.items) |nm| alloc.free(nm);
                cur_area_names.deinit();
            }
            var cur_flag_names = std.array_list.Managed([]u8).init(alloc);
            defer {
                for (cur_flag_names.items) |nm| alloc.free(nm);
                cur_flag_names.deinit();
            }
            for (0..area_types.MAX_AREA_TYPES) |i| {
                if (area_types.get(i)) |t| try cur_area_names.append(try alloc.dupe(u8, t.name()));
            }
            for (0..poly_flags.MAX_FLAGS) |i| {
                if (poly_flags.get(i)) |f| try cur_flag_names.append(try alloc.dupe(u8, f.name()));
            }

            // 2) Round-trip into the PRESET so we can read its used entries from the
            //    same global API. Copy out the preset's AreaType VALUES and flag NAMES.
            _ = try registry_io.deserializeFlags(halves.flags);
            _ = try registry_io.deserializeAreas(halves.areas);

            var preset_areas = std.array_list.Managed(area_types.AreaType).init(alloc);
            defer preset_areas.deinit();
            for (0..area_types.MAX_AREA_TYPES) |i| {
                if (area_types.get(i)) |t| try preset_areas.append(t.*);
            }
            var preset_flag_names = std.array_list.Managed([]u8).init(alloc);
            defer {
                for (preset_flag_names.items) |nm| alloc.free(nm);
                preset_flag_names.deinit();
            }
            for (0..poly_flags.MAX_FLAGS) |i| {
                if (poly_flags.get(i)) |f| try preset_flag_names.append(try alloc.dupe(u8, f.name()));
            }

            // 3) Restore the globals back to the ORIGINAL current registry.
            const bh = try splitBlob(before);
            _ = try registry_io.deserializeFlags(bh.flags);
            _ = try registry_io.deserializeAreas(bh.areas);

            // 4) Add only preset entries whose NAME is absent from the current set.
            //    Flags first (area.flags may reference flag bits — though we keep the
            //    preset area's flags bitmask verbatim, ordering matches load invariant).
            for (preset_flag_names.items) |pname| {
                if (nameInList(cur_flag_names.items, pname)) continue;
                _ = poly_flags.addFlag(pname); // null if all 16 bits taken — best-effort
            }
            for (preset_areas.items) |pt| {
                if (nameInList(cur_area_names.items, pt.name())) continue;
                const new_id = area_types.addType() orelse continue; // full -> skip
                // Restore the preset's VALUES into the freshly-allocated slot id.
                area_types.restoreType(new_id, pt);
            }
        },
    }

    // after = post-apply serialized (combined).
    const after = try serializeCurrent(alloc);
    // snapshotFromCombined frees both `before` and `after`.
    return snapshotFromCombined(alloc, before, after);
}

fn nameInList(list: []const []u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const InputGeom = @import("../input_geom.zig").InputGeom;
const UndoStack = @import("undo_stack.zig").UndoStack;

test "serializeCurrent + splitBlob round-trip (areas/flags halves deserialize)" {
    const alloc = std.testing.allocator;
    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();

    const blob = try serializeCurrent(alloc);
    defer alloc.free(blob);

    const halves = try splitBlob(blob);
    // Each half is a self-describing chunk that deserializes cleanly.
    _ = try registry_io.deserializeFlags(halves.flags);
    _ = try registry_io.deserializeAreas(halves.areas);
    try std.testing.expectEqualStrings("Ground", area_types.get(0).?.name());
    try std.testing.expectEqualStrings("walk", poly_flags.get(0).?.name());

    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
}

test "applyBlob REPLACE: preset with extra Lava replaces globals; undo restores builtins" {
    const alloc = std.testing.allocator;
    var geom = InputGeom.init(alloc);
    defer geom.deinit();
    var st = UndoStack.init(alloc);
    defer st.deinit();

    // Build a preset blob = a registry with an extra "Lava" type.
    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
    const lava_id = area_types.addType().?;
    area_types.get(lava_id).?.setName("Lava");
    const preset = try serializeCurrent(alloc);
    defer alloc.free(preset);

    // Reset globals to builtins, then REPLACE-apply the preset.
    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
    try std.testing.expectEqual(@as(?*area_types.AreaType, null), area_types.get(lava_id));

    const op = try applyBlob(alloc, preset, .replace);
    st.record(op);
    try std.testing.expectEqualStrings("Lava", area_types.get(lava_id).?.name());

    // Undo -> globals restored to builtins (Lava gone).
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(?*area_types.AreaType, null), area_types.get(lava_id));

    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
}

test "applyBlob MERGE: keeps current Mud, adds Lava, no builtin dupes; undo restores pre-merge" {
    const alloc = std.testing.allocator;
    var geom = InputGeom.init(alloc);
    defer geom.deinit();
    var st = UndoStack.init(alloc);
    defer st.deinit();

    // PRESET: builtins + "Lava" + a custom flag "ladder".
    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
    const p_lava = area_types.addType().?;
    area_types.get(p_lava).?.setName("Lava");
    _ = poly_flags.addFlag("ladder");
    const preset = try serializeCurrent(alloc);
    defer alloc.free(preset);

    // CURRENT: builtins + "Mud" (distinct from preset's extras).
    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
    const mud_id = area_types.addType().?;
    area_types.get(mud_id).?.setName("Mud");
    const builtin_area_count = area_types.count(); // 6 builtins + Mud = 7

    const op = try applyBlob(alloc, preset, .merge);
    st.record(op);

    // Both Mud (current) and Lava (preset) present; builtins not duplicated.
    try std.testing.expect(hasAreaNamed("Mud"));
    try std.testing.expect(hasAreaNamed("Lava"));
    try std.testing.expect(hasFlagNamed("ladder"));
    // Exactly one extra area was added (Lava); Ground/Water/... not duplicated.
    try std.testing.expectEqual(builtin_area_count + 1, area_types.count());

    // Undo -> pre-merge state: Mud kept, Lava + ladder gone.
    try std.testing.expect(st.undo(&geom));
    try std.testing.expect(hasAreaNamed("Mud"));
    try std.testing.expect(!hasAreaNamed("Lava"));
    try std.testing.expect(!hasFlagNamed("ladder"));

    // Redo round-trips with no leak.
    try std.testing.expect(st.redo(&geom));
    try std.testing.expect(hasAreaNamed("Lava"));

    area_types.resetToBuiltins();
    poly_flags.resetToBuiltins();
}

fn hasAreaNamed(name: []const u8) bool {
    for (0..area_types.MAX_AREA_TYPES) |i| {
        if (area_types.get(i)) |t| {
            if (std.mem.eql(u8, t.name(), name)) return true;
        }
    }
    return false;
}

fn hasFlagNamed(name: []const u8) bool {
    for (0..poly_flags.MAX_FLAGS) |i| {
        if (poly_flags.get(i)) |f| {
            if (std.mem.eql(u8, f.name(), name)) return true;
        }
    }
    return false;
}

test "sanitizeName strips separators and defaults empty to 'preset'" {
    var buf: [NAME_STEM_CAP]u8 = undefined;
    try std.testing.expectEqualStrings("abc", sanitizeName(&buf, "  a/b\\c  "));
    try std.testing.expectEqualStrings("preset", sanitizeName(&buf, "   "));
    try std.testing.expectEqualStrings("myPreset", sanitizeName(&buf, "my:Pre?set"));
}
