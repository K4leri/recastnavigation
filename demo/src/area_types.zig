//! Runtime registry of navmesh area types for the demo.
//!
//! Upstream RecastDemo hard-codes six `SamplePolyAreas` (ground/water/road/door/
//! grass/jump) and bakes their flags + cost in code. This registry makes them
//! editable and extensible at run time: each type carries a colour, the poly
//! *flags* it maps to (reachability, baked into the navmesh) and an *area cost*
//! (the movement coefficient the QueryFilter weights paths by — runtime).
//!
//! - cost  -> QueryFilter.area_cost (applyCosts) — takes effect on the next query.
//! - flags -> baked into tile data at build time — editing requires a rebuild.
//! - color -> debug-draw only — immediate.

const std = @import("std");
const recast = @import("recast-nav");
const sample = @import("sample.zig");

/// Detour areas are a u8 in [0, 63] (DT_MAX_AREAS = 64).
pub const MAX_AREA_TYPES: usize = 64;
const NAME_CAP: usize = 24;

/// Poly flag bits (1:1 with sample.SamplePolyFlags).
pub const Flags = sample.SamplePolyFlags;

pub const AreaType = struct {
    used: bool = false,
    builtin: bool = false, // seeded default (ground..jump) — name not removable
    name_buf: [NAME_CAP]u8 = [_]u8{0} ** NAME_CAP,
    name_len: u8 = 0,
    r: u8 = 255,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
    flags: u16 = Flags.walk,
    cost: f32 = 1.0,

    pub fn name(self: *const AreaType) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn setName(self: *AreaType, s: []const u8) void {
        const n = @min(s.len, NAME_CAP);
        @memcpy(self.name_buf[0..n], s[0..n]);
        self.name_len = @intCast(n);
    }
    /// Packed RGBA for debug draw (recast.debug.rgba).
    pub fn color(self: *const AreaType) u32 {
        return recast.debug.rgba(self.r, self.g, self.b, self.a);
    }
};

var types: [MAX_AREA_TYPES]AreaType = undefined;
var initialized = false;

/// When a *flags* edit (or any change that affects baked tile data) happens, the
/// navmesh must be rebuilt for it to take effect. The rebuild mini-tool reads
/// these.
pub var rebuild_needed: bool = false;
/// If true, the rebuild mini-tool rebuilds automatically whenever `rebuild_needed`
/// is raised; otherwise it only notifies and waits for a manual Rebuild.
pub var auto_rebuild: bool = false;
/// Raised when an area *cost* is edited; the main loop re-applies costs to the
/// live tester/crowd filters (cheap) and clears it.
pub var costs_dirty: bool = false;

/// Auto-colour palette for newly added types (distinct, readable on the mesh).
const palette = [_][3]u8{
    .{ 255, 128, 0 }, .{ 200, 0, 200 }, .{ 0, 200, 200 }, .{ 160, 160, 0 },
    .{ 128, 0, 255 }, .{ 0, 160, 80 }, .{ 255, 0, 128 }, .{ 120, 200, 255 },
};

fn seed(id: usize, nm: []const u8, r: u8, g: u8, b: u8, flags: u16, cost: f32) void {
    var t = &types[id];
    t.* = .{ .used = true, .builtin = true, .r = r, .g = g, .b = b, .a = 255, .flags = flags, .cost = cost };
    t.setName(nm);
}

pub fn ensureInit() void {
    if (initialized) return;
    initialized = true;
    for (&types) |*t| t.* = .{};
    // Six built-ins. Costs mirror upstream RecastDemo's NavMeshTesterTool filter:
    // water is expensive to discourage swimming, grass mildly so, jump slightly.
    seed(0, "Ground", 0, 192, 255, Flags.walk, 1.0);
    seed(1, "Water", 0, 0, 255, Flags.swim, 10.0);
    seed(2, "Road", 50, 20, 12, Flags.walk, 1.0);
    seed(3, "Door", 0, 255, 255, Flags.walk | Flags.door, 1.0);
    seed(4, "Grass", 0, 255, 0, Flags.walk, 2.0);
    seed(5, "Jump", 255, 255, 0, Flags.walk | Flags.jump, 1.5);
}

/// Mutable access to a type by area id, or null if the id is unused/out of range.
pub fn get(id: usize) ?*AreaType {
    ensureInit();
    if (id >= MAX_AREA_TYPES or !types[id].used) return null;
    return &types[id];
}

pub fn count() usize {
    ensureInit();
    var n: usize = 0;
    for (&types) |*t| {
        if (t.used) n += 1;
    }
    return n;
}

/// Poly flags an area maps to (baked into tile data). Falls back to `walk`.
pub fn flagsFor(area: u32) u16 {
    if (get(area)) |t| return t.flags;
    return Flags.walk;
}

/// Debug-draw colour for an area. Unknown -> red (matches upstream areaToCol).
pub fn colorFor(area: u32) u32 {
    if (get(area)) |t| return t.color();
    return recast.debug.rgba(255, 0, 0, 255);
}

pub fn costFor(area: usize) f32 {
    if (get(area)) |t| return t.cost;
    return 1.0;
}

/// Push every type's cost into a QueryFilter. Call after the filter is created
/// and whenever a cost is edited (for the NavMesh-tester and crowd filters).
pub fn applyCosts(filter: *recast.detour.QueryFilter) void {
    ensureInit();
    for (&types, 0..) |*t, id| {
        if (t.used) filter.setAreaCost(id, t.cost);
    }
}

/// Allocate the next free area id and seed a new type (auto-coloured). Returns the
/// new id, or null if all 64 slots are taken.
pub fn addType() ?u8 {
    ensureInit();
    var id: usize = 0;
    while (id < MAX_AREA_TYPES) : (id += 1) {
        if (!types[id].used) {
            const c = palette[id % palette.len];
            types[id] = .{ .used = true, .builtin = false, .r = c[0], .g = c[1], .b = c[2], .a = 255, .flags = Flags.walk, .cost = 1.0 };
            var buf: [NAME_CAP]u8 = undefined;
            const nm = std.fmt.bufPrint(&buf, "Area {d}", .{id}) catch "Area";
            types[id].setName(nm);
            return @intCast(id);
        }
    }
    return null;
}

pub fn removeType(id: usize) void {
    ensureInit();
    if (id < MAX_AREA_TYPES and types[id].used and !types[id].builtin) {
        types[id] = .{};
    }
}

/// Reset the registry to seed state (Ground..Jump). Used by registry_io BEFORE
/// restoring saved types so edited builtins revert to defaults first, then the
/// saved state overwrites them exactly.
pub fn resetToBuiltins() void {
    initialized = false;
    ensureInit();
}

/// Restore a type into EXACT slot `id` (bypasses auto-id-allocation addType).
/// Copies all fields from `t` (used/builtin/name/rgba/flags/cost) verbatim.
/// No-op if id >= MAX_AREA_TYPES.
pub fn restoreType(id: usize, t: AreaType) void {
    ensureInit();
    if (id >= MAX_AREA_TYPES) return;
    types[id] = t;
}

test "restoreType overwrites exact slot, resetToBuiltins reseeds" {
    resetToBuiltins();
    try std.testing.expectEqualStrings("Ground", get(0).?.name());
    try std.testing.expectEqual(@as(f32, 1.0), get(0).?.cost);
    // edit builtin Ground (cost + color)
    var edited = get(0).?.*;
    edited.cost = 3.5;
    edited.r = 10;
    edited.g = 20;
    edited.b = 30;
    restoreType(0, edited);
    try std.testing.expectEqual(@as(f32, 3.5), get(0).?.cost);
    try std.testing.expectEqual(@as(u8, 10), get(0).?.r);
    try std.testing.expect(get(0).?.builtin); // builtin flag preserved
    // custom type in slot 40
    var custom = AreaType{ .used = true, .builtin = false, .r = 1, .g = 2, .b = 3, .a = 4, .flags = 0x09, .cost = 7.0 };
    custom.setName("Lava");
    restoreType(40, custom);
    try std.testing.expectEqualStrings("Lava", get(40).?.name());
    try std.testing.expectEqual(@as(u16, 0x09), get(40).?.flags);
    // reset clears custom and restores Ground.cost=1.0
    resetToBuiltins();
    try std.testing.expectEqual(@as(?*AreaType, null), get(40));
    try std.testing.expectEqual(@as(f32, 1.0), get(0).?.cost);
}
