//! MEM BUDGET (C3) — memory cost of navmesh build structures.
//!
//! Pure byte-size helpers + formatBytes + the MemBudget report struct.
//! No recast/dvui imports — this module is unit-testable standalone.
//!
//! Element-size assumptions (document for clarity):
//!   PolyMesh:
//!     verts  : u16  (2 bytes) — vertCount * 3 components per vertex
//!     polys  : u16  (2 bytes) — polyCount * 2 * nvp (poly-verts + neighbour-indices)
//!     regs   : u16  (2 bytes) — polyCount * 1   (region ID per polygon)
//!     flags  : u16  (2 bytes) — polyCount * 1   (user flags per polygon)
//!     areas  : u8   (1 byte)  — polyCount * 1   (area ID per polygon)
//!   NOTE: The actual allocation uses maxpolys (>= polyCount), so the real
//!   footprint may be slightly larger. The pure helper is an APPROXIMATION
//!   (lower bound). For exact sizes on live structs, use the slice-length path
//!   in the panel code (polyMeshBytesExact).
//!
//!   PolyMeshDetail:
//!     meshes : u32  (4 bytes) — nmeshes * 4 u32s per sub-mesh entry
//!     verts  : f32  (4 bytes) — vertCount * 3 components per vertex
//!     tris   : u8   (1 byte)  — triCount * 4 (3 vertex-indices + 1 flag byte)

const std = @import("std");

/// Full memory budget snapshot produced after a navmesh build.
pub const MemBudget = struct {
    /// Navmesh tile blob(s) total bytes (the data handed to addTile).
    navmesh_bytes: usize,
    /// Approximate polymesh array bytes (see element-size assumptions above).
    polymesh_bytes: usize,
    /// Approximate detail-mesh array bytes (see element-size assumptions above).
    detail_bytes: usize,
    /// Number of live tiles in the navmesh (0 for Solo = 1 logical tile; for
    /// Tile mode = tiles actually built).
    tile_count: usize,
    /// TileCache raw layer bytes (0 when N/A; == tilecache_compressed while the
    /// compressor is a no-op).
    tilecache_raw: usize,
    /// TileCache compressed bytes (== tilecache_raw while the compressor is a no-op).
    tilecache_compressed: usize,
};

// ---------------------------------------------------------------------------
// Pure byte-size helpers
// ---------------------------------------------------------------------------

/// Approximate byte footprint of a PolyMesh given its active counts.
///
/// Element sizes (see module docstring for full rationale):
///   verts  = vertCount  * 3 * @sizeOf(u16)   = vertCount  * 6
///   polys  = polyCount  * 2 * nvp * @sizeOf(u16) = polyCount * 4 * nvp
///   regs   = polyCount  * 1 * @sizeOf(u16)   = polyCount  * 2
///   flags  = polyCount  * 1 * @sizeOf(u16)   = polyCount  * 2
///   areas  = polyCount  * 1 * @sizeOf(u8)    = polyCount  * 1
///
/// NOTE: uses active counts (not maxpolys), so this is a lower-bound approximation.
pub fn polyMeshBytes(vert_count: usize, poly_count: usize, nvp: usize) usize {
    const verts_sz = vert_count * 3 * @sizeOf(u16);
    const polys_sz = poly_count * 2 * nvp * @sizeOf(u16);
    const regs_sz = poly_count * @sizeOf(u16);
    const flags_sz = poly_count * @sizeOf(u16);
    const areas_sz = poly_count * @sizeOf(u8);
    return verts_sz + polys_sz + regs_sz + flags_sz + areas_sz;
}

/// Approximate byte footprint of a PolyMeshDetail given its active counts.
///
/// Element sizes (see module docstring for full rationale):
///   meshes = nmeshes  * 4 * @sizeOf(u32) = nmeshes  * 16
///   verts  = vertCount * 3 * @sizeOf(f32) = vertCount * 12
///   tris   = triCount  * 4 * @sizeOf(u8)  = triCount  * 4
pub fn detailMeshBytes(nmeshes: usize, vert_count: usize, tri_count: usize) usize {
    const meshes_sz = nmeshes * 4 * @sizeOf(u32);
    const verts_sz = vert_count * 3 * @sizeOf(f32);
    const tris_sz = tri_count * 4 * @sizeOf(u8);
    return meshes_sz + verts_sz + tris_sz;
}

/// Format a byte count into a human-readable string like "1.2 MB" / "345 KB" / "78 B".
/// Writes into `buf` (caller must provide at least 32 bytes) and returns a slice.
/// Thresholds: >= 1 MiB -> "X.X MB"; >= 1 KiB -> "X.X KB"; else "N B".
pub fn formatBytes(buf: []u8, n: usize) []const u8 {
    const mib: usize = 1024 * 1024;
    const kib: usize = 1024;
    if (n >= mib) {
        const mb_x10: usize = (n * 10 + mib / 2) / mib; // rounded tenth
        return std.fmt.bufPrint(buf, "{d}.{d} MB", .{ mb_x10 / 10, mb_x10 % 10 }) catch buf[0..0];
    } else if (n >= kib) {
        const kb_x10: usize = (n * 10 + kib / 2) / kib;
        return std.fmt.bufPrint(buf, "{d}.{d} KB", .{ kb_x10 / 10, kb_x10 % 10 }) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d} B", .{n}) catch buf[0..0];
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "polyMeshBytes known counts" {
    // vert_count=10, poly_count=5, nvp=6
    //   verts  = 10 * 3 * 2 = 60
    //   polys  =  5 * 2 * 6 * 2 = 120
    //   regs   =  5 * 2 = 10
    //   flags  =  5 * 2 = 10
    //   areas  =  5 * 1 = 5
    //   total  = 205
    try std.testing.expectEqual(@as(usize, 205), polyMeshBytes(10, 5, 6));
}

test "polyMeshBytes zero" {
    try std.testing.expectEqual(@as(usize, 0), polyMeshBytes(0, 0, 6));
}

test "detailMeshBytes known counts" {
    // nmeshes=3, vert_count=12, tri_count=8
    //   meshes = 3 * 4 * 4 = 48
    //   verts  = 12 * 3 * 4 = 144
    //   tris   = 8 * 4 * 1 = 32
    //   total  = 224
    try std.testing.expectEqual(@as(usize, 224), detailMeshBytes(3, 12, 8));
}

test "detailMeshBytes zero" {
    try std.testing.expectEqual(@as(usize, 0), detailMeshBytes(0, 0, 0));
}

test "formatBytes B threshold" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try std.testing.expectEqualStrings("78 B", formatBytes(&buf, 78));
    try std.testing.expectEqualStrings("1023 B", formatBytes(&buf, 1023));
}

test "formatBytes KB threshold" {
    var buf: [32]u8 = undefined;
    // 1024 -> 1.0 KB
    try std.testing.expectEqualStrings("1.0 KB", formatBytes(&buf, 1024));
    // 2048 -> 2.0 KB
    try std.testing.expectEqualStrings("2.0 KB", formatBytes(&buf, 2048));
    // 1536 (1.5 KiB) -> 1.5 KB
    try std.testing.expectEqualStrings("1.5 KB", formatBytes(&buf, 1536));
    // 345 * 1024 = 353280 -> ~345 KB
    try std.testing.expectEqualStrings("345.0 KB", formatBytes(&buf, 353280));
}

test "formatBytes MB threshold" {
    var buf: [32]u8 = undefined;
    // 1 MiB -> 1.0 MB
    try std.testing.expectEqualStrings("1.0 MB", formatBytes(&buf, 1024 * 1024));
    // 1.2 MiB = 1258291 bytes -> 1.2 MB
    try std.testing.expectEqualStrings("1.2 MB", formatBytes(&buf, 1258291));
}
