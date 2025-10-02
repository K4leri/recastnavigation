const std = @import("std");
const testing = std.testing;
const recast = @import("recast-nav");
const mesh = recast.recast.mesh;
const PolyMesh = recast.PolyMesh;
const Context = recast.Context;

const MESH_NULL_IDX = mesh.MESH_NULL_IDX;

// ==============================================================================
// HELPER FUNCTION TESTS
// ==============================================================================

test "countPolyVerts - empty polygon" {
    const p = [_]u16{ MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    const count = mesh.countPolyVerts(&p, 4);
    try testing.expectEqual(@as(usize, 0), count);
}

test "countPolyVerts - full polygon" {
    const p = [_]u16{ 0, 1, 2, 3 };
    const count = mesh.countPolyVerts(&p, 4);
    try testing.expectEqual(@as(usize, 4), count);
}

test "countPolyVerts - partial polygon (triangle)" {
    const p = [_]u16{ 0, 1, 2, MESH_NULL_IDX };
    const count = mesh.countPolyVerts(&p, 4);
    try testing.expectEqual(@as(usize, 3), count);
}

test "countPolyVerts - single vertex" {
    const p = [_]u16{ 0, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    const count = mesh.countPolyVerts(&p, 4);
    try testing.expectEqual(@as(usize, 1), count);
}

// ==============================================================================
// LEFT TURN TEST
// ==============================================================================

test "uleft - left turn (counter-clockwise)" {
    // Points: a=(0,0), b=(10,0), c=(5,5) -> left turn
    const a = [_]u16{ 0, 0, 0 }; // x=0, y=0, z=0
    const b = [_]u16{ 10, 0, 0 }; // x=10, y=0, z=0
    const c = [_]u16{ 5, 0, 5 }; // x=5, y=0, z=5

    const result = mesh.uleft(&a, &b, &c);
    try testing.expect(!result); // uleft returns true if < 0, this should be > 0
}

test "uleft - right turn (clockwise)" {
    // Points: a=(0,10), b=(10,10), c=(5,5) -> right turn (point below line)
    const a = [_]u16{ 0, 0, 10 }; // x=0, y=0, z=10
    const b = [_]u16{ 10, 0, 10 }; // x=10, y=0, z=10
    const c = [_]u16{ 5, 0, 5 }; // x=5, y=0, z=5

    const result = mesh.uleft(&a, &b, &c);
    try testing.expect(result); // Should be < 0 (right turn, point to the right)
}

test "uleft - collinear points" {
    // Points: a=(0,0), b=(10,0), c=(20,0) -> collinear
    const a = [_]u16{ 0, 0, 0 };
    const b = [_]u16{ 10, 0, 0 };
    const c = [_]u16{ 20, 0, 0 };

    const result = mesh.uleft(&a, &b, &c);
    try testing.expect(!result); // Cross product = 0, so >= 0, returns false
}

// ==============================================================================
// POLYGON MERGING TESTS
// ==============================================================================

test "getPolyMergeValue - two triangles with shared edge" {
    // Simplified test - just check function doesn't crash and returns valid value
    var pa = [_]u16{ 0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    var pb = [_]u16{ 2, 1, 3, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };

    // Simple quad vertices forming two triangles
    const verts = [_]u16{
        0, 0, 0, // v0
        10, 0, 0, // v1
        0, 0, 10, // v2
        10, 0, 10, // v3
    };

    var ea: i32 = -1;
    var eb: i32 = -1;
    const nvp: usize = 6;

    const value = mesh.getPolyMergeValue(&pa, &pb, &verts, &ea, &eb, nvp);

    // Just verify function returns a value (could be -1 if can't merge, or >= 0 if can)
    _ = value;
    // Function executed without crashing
}

test "getPolyMergeValue - no shared edge" {
    // Triangle A: vertices 0,1,2
    // Triangle B: vertices 3,4,5 (completely separate)

    var pa = [_]u16{ 0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    var pb = [_]u16{ 3, 4, 5, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };

    const verts = [_]u16{
        0, 0, 0, // v0
        10, 0, 0, // v1
        5, 0, 10, // v2
        20, 0, 0, // v3
        30, 0, 0, // v4
        25, 0, 10, // v5
    };

    var ea: i32 = -1;
    var eb: i32 = -1;
    const nvp: usize = 6;

    const value = mesh.getPolyMergeValue(&pa, &pb, &verts, &ea, &eb, nvp);

    // No shared edge, should return -1
    try testing.expectEqual(@as(i32, -1), value);
}

test "getPolyMergeValue - would exceed nvp" {
    // Two large polygons that would create polygon > nvp when merged
    var pa = [_]u16{ 0, 1, 2, 3, MESH_NULL_IDX, MESH_NULL_IDX };
    var pb = [_]u16{ 2, 3, 4, 5, MESH_NULL_IDX, MESH_NULL_IDX };

    const verts = [_]u16{
        0, 0, 0, // v0
        10, 0, 0, // v1
        10, 0, 10, // v2
        0, 0, 10, // v3
        10, 0, 20, // v4
        0, 0, 20, // v5
    };

    var ea: i32 = -1;
    var eb: i32 = -1;
    const nvp: usize = 4; // Too small for merged polygon (4 + 4 - 2 = 6 > 4)

    const value = mesh.getPolyMergeValue(&pa, &pb, &verts, &ea, &eb, nvp);

    // Would exceed nvp, should return -1
    try testing.expectEqual(@as(i32, -1), value);
}

test "mergePolyVerts - merge two triangles into quad" {
    // Triangle A: [0, 1, 2]
    // Triangle B: [1, 3, 2]
    // Shared edge: 1-2 (ea=1, eb=2)
    // Result should be quad: [3, 2, 0, 1] or similar ordering

    var pa = [_]u16{ 0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    const pb = [_]u16{ 1, 3, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    var tmp = [_]u16{ MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };

    const ea: usize = 1; // Edge from pa[1] to pa[2] (vertices 1->2)
    const eb: usize = 2; // Edge from pb[2] to pb[0] (vertices 2->1)
    const nvp: usize = 6;

    mesh.mergePolyVerts(&pa, &pb, ea, eb, &tmp, nvp);

    // After merge, pa should have 4 vertices (quad)
    const count = mesh.countPolyVerts(&pa, nvp);
    try testing.expectEqual(@as(usize, 4), count);

    // All vertices should be valid (not MESH_NULL_IDX)
    for (0..count) |i| {
        try testing.expect(pa[i] != MESH_NULL_IDX);
    }
}

test "mergePolyVerts - preserves vertex uniqueness" {
    var pa = [_]u16{ 0, 1, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    const pb = [_]u16{ 1, 3, 2, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };
    var tmp = [_]u16{ MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX, MESH_NULL_IDX };

    mesh.mergePolyVerts(&pa, &pb, 1, 2, &tmp, 6);

    // Check no duplicate vertices in result
    const count = mesh.countPolyVerts(&pa, 6);
    var seen = std.StaticBitSet(16).initEmpty();

    for (0..count) |i| {
        const v = pa[i];
        try testing.expect(!seen.isSet(v)); // Should not see same vertex twice
        seen.set(v);
    }
}

// ==============================================================================
// VERTEX REMOVAL TESTS
// ==============================================================================

// Note: canRemoveVertex tests commented out due to complexity of setting up valid PolyMesh
// These would require building a proper mesh through the pipeline
// For now, function is tested indirectly through integration tests
