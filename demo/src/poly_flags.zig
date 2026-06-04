//! Runtime registry of polygon flags for the demo.
//!
//! Detour poly flags are a `u16` bitmask, so there are at most 16 distinct flags.
//! Upstream RecastDemo hard-codes walk/swim/door/jump (+ an internal `disabled`
//! bit). This registry makes them a runtime list so a project can add its own
//! reachability flags (e.g. "ladder", "crouch") and have them appear everywhere
//! flags are used: the area-type editor and the NavMesh-tester include/exclude
//! filter.
//!
//! Flags are global config (shared across all area types and the query filters),
//! managed from the "Poly Flags" section of the Properties panel.

const std = @import("std");
const sample = @import("sample.zig");

pub const MAX_FLAGS: usize = 16; // u16 bitmask
const NAME_CAP: usize = 20;

/// Internal bit used by "toggle polygons" (RecastDemo's SAMPLE_POLYFLAGS_DISABLED).
/// Reserved — not offered as a user-editable flag.
const RESERVED_BIT: u16 = sample.SamplePolyFlags.disabled; // 0x10 (bit 4)

pub const Flag = struct {
    used: bool = false,
    builtin: bool = false, // walk/swim/door/jump — name not removable
    name_buf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    name_len: u8 = 0,

    pub fn name(self: *const Flag) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn setName(self: *Flag, s: []const u8) void {
        const n = @min(s.len, NAME_CAP);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
};

/// Indexed by bit position 0..15; the flag value is `1 << index`.
var flags: [MAX_FLAGS]Flag = undefined;
var initialized = false;

fn seed(bit_index: u5, nm: []const u8) void {
    var f = &flags[bit_index];
    f.* = .{ .used = true, .builtin = true };
    f.setName(nm);
}

pub fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    for (&flags) |*f| f.* = .{};
    seed(0, "walk"); // 0x01
    seed(1, "swim"); // 0x02
    seed(2, "door"); // 0x04
    seed(3, "jump"); // 0x08
    // bit 4 (0x10) is RESERVED for `disabled` — kept out of the user list.
}

/// The flag value (`1 << index`) for a registry slot, or null if unused/reserved.
pub fn bitOf(index: usize) ?u16 {
    ensureInit();
    if (index >= MAX_FLAGS or !flags[index].used) return null;
    const bit = @as(u16, 1) << @intCast(index);
    if (bit == RESERVED_BIT) return null;
    return bit;
}

pub fn get(index: usize) ?*Flag {
    ensureInit();
    if (index >= MAX_FLAGS or !flags[index].used) return null;
    if ((@as(u16, 1) << @intCast(index)) == RESERVED_BIT) return null;
    return &flags[index];
}

/// Bitmask of every registered (non-reserved) flag — the default "include all".
pub fn allMask() u16 {
    ensureInit();
    var m: u16 = 0;
    for (0..MAX_FLAGS) |i| {
        if (bitOf(i)) |bit| m |= bit;
    }
    return m;
}

/// Allocate the next free bit and register a new flag. Returns its value, or null
/// if all 16 bits are taken.
pub fn addFlag(nm: []const u8) ?u16 {
    ensureInit();
    for (0..MAX_FLAGS) |i| {
        const bit = @as(u16, 1) << @intCast(i);
        if (!flags[i].used and bit != RESERVED_BIT) {
            flags[i] = .{ .used = true, .builtin = false };
            const name_trimmed = std.mem.trim(u8, nm, " ");
            flags[i].setName(if (name_trimmed.len > 0) name_trimmed else "flag");
            return bit;
        }
    }
    return null;
}

/// Number of registered (non-reserved) flags.
pub fn count() usize {
    ensureInit();
    var n: usize = 0;
    for (0..MAX_FLAGS) |i| {
        if (bitOf(i) != null) n += 1;
    }
    return n;
}

pub fn removeFlag(index: usize) void {
    ensureInit();
    if (index < MAX_FLAGS and flags[index].used and !flags[index].builtin) {
        flags[index] = .{};
    }
}
