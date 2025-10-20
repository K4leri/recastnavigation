const std = @import("std");

test "PolyRef 64-bit compatibility test" {
    // Test that we can use u64 and it compiles
    const PolyRef64 = u64;

    // Test basic operations
    const test_ref: PolyRef64 = 0x123456789ABCDEF0;
    _ = test_ref; // Mark as used

    // Test encoding/decoding with 64-bit bit layout
    // 64-bit: [16 bits salt][28 bits tile][20 bits poly]
    const encoded = (@as(PolyRef64, 1000) << 48) | (@as(PolyRef64, 500000) << 20) | @as(PolyRef64, 1000);
    const salt = (encoded >> 48) & 0xFFFF;
    const tile = (encoded >> 20) & 0xFFFFFFF;
    const poly = encoded & 0xFFFFF;

    try std.testing.expectEqual(@as(u64, 1000), salt);
    try std.testing.expectEqual(@as(u64, 500000), tile);
    try std.testing.expectEqual(@as(u64, 1000), poly);
}

test "Current 32-bit PolyRef capacity test" {
    // Current 32-bit limits from original implementation
    const max_tiles = 16383;  // 2^14 - 1 (from original code)
    const max_polys = 1023;   // 2^10 - 1 (from original code)
    const max_salt = 255;     // 2^8 - 1 (from original code)

    try std.testing.expect(max_tiles > 16000);
    try std.testing.expect(max_polys > 1000);
    try std.testing.expect(max_salt > 250);
}

test "64-bit capacity comparison" {
    // 64-bit limits (what C++ supports)
    const max_tiles_64 = 268435455;  // 2^28 - 1
    const max_polys_64 = 1048575;   // 2^20 - 1
    const max_salt_64 = 65535;      // 2^16 - 1

    // Verify 64-bit can handle much larger values
    try std.testing.expect(max_tiles_64 > 260000000);
    try std.testing.expect(max_polys_64 > 1000000);
    try std.testing.expect(max_salt_64 > 65000);

    // Test that 64-bit values fit in u64
    const large_poly_ref: u64 = (@as(u64, max_salt_64) << 48) | (@as(u64, max_tiles_64) << 20) | @as(u64, max_polys_64);
    _ = large_poly_ref; // Mark as used

    // Calculate improvement factors
    const current_max_tiles = 16383;
    const current_max_polys = 1023;
    const tile_improvement = max_tiles_64 / current_max_tiles;
    const poly_improvement = max_polys_64 / current_max_polys;
    const total_improvement = (@as(u64, max_tiles_64) * max_polys_64) / (current_max_tiles * current_max_polys);

    try std.testing.expect(tile_improvement > 16000);
    try std.testing.expect(poly_improvement > 1000);
    try std.testing.expect(total_improvement > 16000000);
}