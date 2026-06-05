//! POLYGON TABLE INSPECTOR — structured extractor + formatters for the polygon
//! under the cursor (Disabled-tool inspection click, cluster B feature B-4).
//!
//! Два слоя:
//!   1. PolyInfo + inspect() — извлекает данные из NavMesh (чистое чтение, нет
//!      мутаций, bounds-safe, bad ref -> null).
//!   2. Форматтеры (formatRefText / formatAreaText / formatFlagsText) — чистые
//!      функции без зависимостей на UI; покрыты юнит-тестами.
//!
//! Two layers:
//!   1. PolyInfo + inspect() — reads from NavMesh (no mutations, bounds-safe,
//!      bad ref -> null).
//!   2. Pure formatters (formatRefText / formatAreaText / formatFlagsText) —
//!      no UI deps; covered by unit tests.

const std = @import("std");
const recast = @import("recast-nav");
const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");

const NavMesh = recast.detour.NavMesh;
const common = recast.detour.common;

/// Cap on neighbour refs we store (link list can be longer; extras are counted
/// but not stored — link_count still reflects the true total).
pub const MAX_NEIGHBOURS: usize = 16;

/// Extracted polygon information. All fields are filled by inspect(); safe to
/// copy/store per frame (plain value type, no allocations).
///
/// Извлечённые данные полигона. Заполняются inspect(); чистый value-тип,
/// никаких аллокаций.
pub const PolyInfo = struct {
    /// Raw poly-ref (same value passed to inspect).
    ref: u32,
    /// Area id (low 6 bits of area_and_type).
    area: u8,
    /// User-defined flags (u16 bitmask).
    flags: u16,
    /// Number of vertices in this polygon (1..VERTS_PER_POLYGON).
    vert_count: u32,
    /// Centroid in world space (average of vertex positions).
    centroid: [3]f32,
    /// Minimum and maximum Y among this polygon's vertices.
    y_min: f32,
    y_max: f32,
    /// Total number of links walked (all, including boundary markers).
    link_count: u32,
    /// Neighbour poly-refs where link.ref != 0, up to MAX_NEIGHBOURS.
    neighbours: [MAX_NEIGHBOURS]u32,
    /// Number of valid entries in `neighbours` (capped at MAX_NEIGHBOURS).
    neighbour_count: u32,
};

/// Extract PolyInfo for `ref` from `nav`. Returns null for any bad/stale ref or
/// out-of-bounds access (never panics on corrupt data).
///
/// Извлекает PolyInfo для `ref` из `nav`. Возвращает null при плохом/устаревшем
/// ref или выходе индексов за границы (никогда не паникует на кривых данных).
pub fn inspect(nav: *const NavMesh, ref: u32) ?PolyInfo {
    if (ref == 0) return null;

    // getTileAndPolyByRef validates salt + bounds; returns error on bad ref.
    const tp = nav.getTileAndPolyByRef(ref) catch return null;
    const tile = tp.tile;
    const poly = tp.poly;

    const vc: u32 = poly.vert_count;
    if (vc == 0) return null; // degenerate / uninitialized

    // --- Vertex positions: centroid + Y range ---
    // tile.verts is a flat f32 slice: [x0,y0,z0, x1,y1,z1, ...]
    // poly.verts[k] is the vertex index into tile.verts (multiply by 3).
    var cx: f32 = 0;
    var cy: f32 = 0;
    var cz: f32 = 0;
    var y_min: f32 = std.math.floatMax(f32);
    var y_max: f32 = -std.math.floatMax(f32);

    var k: u32 = 0;
    while (k < vc) : (k += 1) {
        const vi: usize = @as(usize, poly.verts[k]) * 3;
        // Bounds check: tile.verts must have at least vi+2 elements.
        if (vi + 2 >= tile.verts.len) break; // corrupted tile data — stop early
        const vx = tile.verts[vi + 0];
        const vy = tile.verts[vi + 1];
        const vz = tile.verts[vi + 2];
        cx += vx;
        cy += vy;
        cz += vz;
        if (vy < y_min) y_min = vy;
        if (vy > y_max) y_max = vy;
    }
    const fvc: f32 = @floatFromInt(vc);
    cx /= fvc;
    cy /= fvc;
    cz /= fvc;

    // --- Walk links: count total + collect up to MAX_NEIGHBOURS non-zero refs ---
    var link_count: u32 = 0;
    var neighbours: [MAX_NEIGHBOURS]u32 = [_]u32{0} ** MAX_NEIGHBOURS;
    var neighbour_count: u32 = 0;

    var li: u32 = poly.first_link;
    while (li != common.NULL_LINK) {
        // Bounds check: tile.links must have index li.
        if (li >= tile.links.len) break; // corrupted tile data
        const link = &tile.links[li];
        link_count += 1;
        if (link.ref != 0 and neighbour_count < MAX_NEIGHBOURS) {
            neighbours[neighbour_count] = @intCast(link.ref);
            neighbour_count += 1;
        }
        li = link.next;
    }

    return PolyInfo{
        .ref = ref,
        .area = poly.getArea(),
        .flags = poly.flags,
        .vert_count = vc,
        .centroid = .{ cx, cy, cz },
        .y_min = y_min,
        .y_max = y_max,
        .link_count = link_count,
        .neighbours = neighbours,
        .neighbour_count = neighbour_count,
    };
}

// ============================================================================
// PURE FORMATTERS — no UI or NavMesh dependencies; unit-testable.
// Чистые форматтеры — нет зависимостей на UI или NavMesh; покрыты тестами.
// ============================================================================

/// Formats the poly-ref as a hex string: "0x0000ABCD".
/// Returns a slice into `buf`. buf must be >= 12 bytes.
///
/// Форматирует ref как hex: "0x0000ABCD". Возвращает срез из buf (>= 12 байт).
pub fn formatRefText(buf: []u8, ref: u32) []const u8 {
    return std.fmt.bufPrint(buf, "0x{X:0>8}", .{ref}) catch buf[0..0];
}

/// Formats area as "<id> <name>" if the registry has the area, else just "<id>".
/// buf must be >= 32 bytes.
///
/// Форматирует area как "<id> <name>" если реестр знает area, иначе "<id>".
pub fn formatAreaText(buf: []u8, area_id: u8, area_name: ?[]const u8) []const u8 {
    if (area_name) |nm| {
        return std.fmt.bufPrint(buf, "{d} ({s})", .{ area_id, nm }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d}", .{area_id}) catch buf[0..0];
}

/// Formats flags as a pipe-separated list of set-bit names + hex value.
/// Example: "walk|door (0x05)".  Unknown bits are shown as "bit<N>".
/// buf must be >= 128 bytes.
///
/// Форматирует flags как pipe-список имён выставленных битов + hex.
/// Пример: "walk|door (0x05)". Неизвестные биты: "bit<N>".
pub fn formatFlagsText(buf: []u8, flags: u16) []const u8 {
    if (flags == 0) {
        return std.fmt.bufPrint(buf, "none (0x0000)", .{}) catch buf[0..0];
    }

    // Build the names portion into a local scratch buffer.
    var scratch: [100]u8 = undefined;
    var pos: usize = 0;
    var first = true;

    var bit_i: usize = 0;
    while (bit_i < poly_flags.MAX_FLAGS) : (bit_i += 1) {
        const bit = @as(u16, 1) << @intCast(bit_i);
        if ((flags & bit) == 0) continue;

        if (!first) {
            if (pos + 1 < scratch.len) {
                scratch[pos] = '|';
                pos += 1;
            }
        }
        first = false;

        if (poly_flags.get(bit_i)) |fl| {
            const nm = fl.name();
            const copy = @min(nm.len, scratch.len - pos);
            @memcpy(scratch[pos .. pos + copy], nm[0..copy]);
            pos += copy;
        } else {
            // Unknown/reserved bit — show "bit<N>".
            const s = std.fmt.bufPrint(scratch[pos..], "bit{d}", .{bit_i}) catch scratch[pos..pos];
            pos += s.len;
        }
    }

    const names = scratch[0..pos];
    return std.fmt.bufPrint(buf, "{s} (0x{X:0>4})", .{ names, flags }) catch buf[0..0];
}

// ============================================================================
// UNIT TESTS — formatters only (pure; no NavMesh needed).
// Юнит-тесты только форматтеров (чистые; NavMesh не нужен).
// ============================================================================
const testing = std.testing;

test "formatRefText: zero ref" {
    var buf: [16]u8 = undefined;
    const s = formatRefText(&buf, 0);
    try testing.expectEqualStrings("0x00000000", s);
}

test "formatRefText: typical ref" {
    var buf: [16]u8 = undefined;
    const s = formatRefText(&buf, 0xABCD1234);
    try testing.expectEqualStrings("0xABCD1234", s);
}

test "formatAreaText: with known name" {
    var buf: [64]u8 = undefined;
    const s = formatAreaText(&buf, 0, "Ground");
    try testing.expectEqualStrings("0 (Ground)", s);
}

test "formatAreaText: unknown area (no name)" {
    var buf: [64]u8 = undefined;
    const s = formatAreaText(&buf, 42, null);
    try testing.expectEqualStrings("42", s);
}

test "formatFlagsText: zero flags" {
    poly_flags.resetToBuiltins();
    var buf: [128]u8 = undefined;
    const s = formatFlagsText(&buf, 0);
    try testing.expectEqualStrings("none (0x0000)", s);
}

test "formatFlagsText: walk only (bit 0 = 0x01)" {
    poly_flags.resetToBuiltins();
    var buf: [128]u8 = undefined;
    const s = formatFlagsText(&buf, 0x0001);
    try testing.expectEqualStrings("walk (0x0001)", s);
}

test "formatFlagsText: walk|door (bits 0+2 = 0x05)" {
    poly_flags.resetToBuiltins();
    var buf: [128]u8 = undefined;
    const s = formatFlagsText(&buf, 0x0005);
    try testing.expectEqualStrings("walk|door (0x0005)", s);
}

test "formatFlagsText: all four builtins walk|swim|door|jump = 0x0F" {
    poly_flags.resetToBuiltins();
    var buf: [128]u8 = undefined;
    const s = formatFlagsText(&buf, 0x000F);
    // builtins are walk(0),swim(1),door(2),jump(3) = bits 0..3
    try testing.expect(std.mem.indexOf(u8, s, "walk") != null);
    try testing.expect(std.mem.indexOf(u8, s, "swim") != null);
    try testing.expect(std.mem.indexOf(u8, s, "door") != null);
    try testing.expect(std.mem.indexOf(u8, s, "jump") != null);
    try testing.expect(std.mem.indexOf(u8, s, "0x000F") != null);
}

test "formatFlagsText: reserved bit 4 (0x10) shows as bit4 (not in registry)" {
    poly_flags.resetToBuiltins();
    var buf: [128]u8 = undefined;
    // bit 4 = RESERVED (disabled), not in registry -> shown as bit4
    const s = formatFlagsText(&buf, 0x0010);
    try testing.expect(std.mem.indexOf(u8, s, "bit4") != null);
    try testing.expect(std.mem.indexOf(u8, s, "0x0010") != null);
}

test "formatAreaText: area 3 with registry name Door" {
    area_types.resetToBuiltins();
    var buf: [64]u8 = undefined;
    const nm = if (area_types.get(3)) |t| t.name() else null;
    const s = formatAreaText(&buf, 3, nm);
    try testing.expectEqualStrings("3 (Door)", s);
}
