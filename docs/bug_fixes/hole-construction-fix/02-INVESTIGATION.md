# Investigation Process

## Deep Dive into removeVertex

Having identified that the divergence occurs in `removeVertex()`, we added more granular logging.

## Additional Logging Added

### Hole Size Logging

Added to both implementations at the point where holes are constructed:

```cpp
// C++ (RecastMesh.cpp:873)
printf("[DEBUG_HOLE] polysWithRem=%d, nedges=%d, nhole=%d, ntris=%d\n",
       polysWithRem, nedges, nhole, (ntris < 0 ? -ntris : ntris));
```

### Edge Collection Logging

```cpp
// Track which edges are collected for the hole
[DEBUG_EDGE #N] Edge from v0=X to v1=Y, reg=R, area=A
[DEBUG_USED] nedges=N (used edges), total collected=M
```

## First Divergence Point

### First Hole Construction

When removing the first vertex (vertex 0), we saw:

```
C++: [DEBUG_HOLE] polysWithRem=1, nedges=0, nhole=10, ntris=8
Zig: [DEBUG_HOLE] polysWithRem=1, nedges=3, nhole=21, ntris=19
```

**Critical difference:**
- **C++**: 10 hole vertices, 0 unused edges
- **Zig**: 21 hole vertices, 3 unused edges

This is **2.1x more vertices** in the Zig hole!

### Why This Matters

More hole vertices → More triangles during triangulation → More polygons after merging

```
Hole vertices (nverts) → Triangles = nverts - 2

C++ hole:  10 vertices → 8 triangles  → merges to ~2-3 polygons
Zig hole:  21 vertices → 19 triangles → merges to ~5-6 polygons
```

## Edge Collection Analysis

### The Algorithm

The `removeVertex()` function:
1. Finds all polygons containing the vertex to remove
2. Collects edges from those polygons that **don't touch** the vertex
3. Connects these edges into a continuous hole boundary
4. Triangulates the hole
5. Merges triangles back into polygons

### Edge Collection Code

Looking at the edge collection loop:

```zig
// mesh.zig:817-830
var nedges: usize = 0;
for (polys, 0..) |poly_idx, j| {
    const p = poly_idx * nvp * 2;
    var nv: usize = 0;
    var k: usize = 0;
    while (k < nvp) : (k += 1) {
        if (mesh.polys[p + k] == RC_MESH_NULL_IDX) break;
        nv += 1;
    }

    // Collect edges that don't contain the vertex
    for (0..nv) |k_idx| {
        const k0: u16 = @intCast(k_idx);
        const k1: u16 = @intCast((k_idx + 1) % nv);
        if (mesh.polys[p + k0] != rem and mesh.polys[p + k1] != rem) {
            // Store edge
            edges[nedges * 4 + 0] = mesh.polys[p + k0];
            // ... store more data
            nedges += 1;
        }
    }
}
```

Both C++ and Zig collected **9 edges** in the first iteration.

### Hole Construction Code

This is where edges are connected into a continuous boundary:

```zig
// mesh.zig:837-861 (BUGGY VERSION)
var nhole: usize = 0;

// Start with first edge
pushBack(edges[0], hole, &nhole);
pushBack(edges[2], hreg, &nhole);   // ❌ BUG HERE!
pushBack(edges[3], harea, &nhole);  // ❌ BUG HERE!

// Connect remaining edges
for (0..nedges - 1) |_| {
    var bestScore: i32 = -1;
    var bestIdx: usize = std.math.maxInt(usize);

    for (1..nedges) |i| {
        if (used[i]) continue;

        // Try to connect edge to hole boundary
        const ea = edges[i * 4 + 0];
        const eb = edges[i * 4 + 1];

        if (hole[0] == eb) {
            pushFront(ea, hole, &nhole);
            pushFront(r, hreg, &nhole);    // ❌ BUG HERE!
            pushFront(a, harea, &nhole);   // ❌ BUG HERE!
            // ...
        } else if (hole[nhole - 1] == ea) {
            pushBack(eb, hole, &nhole);
            pushBack(r, hreg, &nhole);     // ❌ BUG HERE!
            pushBack(a, harea, &nhole);    // ❌ BUG HERE!
            // ...
        }
    }
}
```

## The Pattern

### What We Observed

```
C++: 9 edges collected → 9 edges used   → 10-vertex hole
Zig: 9 edges collected → 6 edges used   → 21-vertex hole
```

**Zig left 3 edges unused!** This meant those edges weren't properly connected to the hole boundary.

### Hypothesized Cause

The hole construction uses three parallel arrays:
1. `hole[]` - vertex indices forming the boundary
2. `hreg[]` - region ID for each edge in the hole
3. `harea[]` - area ID for each edge in the hole

If these arrays get out of sync, edges won't connect properly.

## Code Review: C++ Reference

Looking at the C++ implementation (`RecastMesh.cpp:796-861`):

```cpp
// C++ (CORRECT VERSION)
int nhole = 0;
int nhreg = 0;   // ✅ Separate counter!
int nharea = 0;  // ✅ Separate counter!

// Start with first edge
pushBack(edges[0], hole, nhole);
pushBack(edges[2], hreg, nhreg);    // ✅ Uses nhreg
pushBack(edges[3], harea, nharea);  // ✅ Uses nharea

// Connect edges
for (int i = 0; i < nedges - 1; ++i) {
    // ...
    if (hole[0] == eb) {
        pushFront(ea, hole, nhole);
        pushFront(r, hreg, nhreg);   // ✅ Uses nhreg
        pushFront(a, harea, nharea); // ✅ Uses nharea
    } else if (hole[nhole - 1] == ea) {
        pushBack(eb, hole, nhole);
        pushBack(r, hreg, nhreg);    // ✅ Uses nhreg
        pushBack(a, harea, nharea);  // ✅ Uses nharea
    }
}
```

**THREE separate counters!**

## Code Review: Zig Implementation

Looking at our Zig code:

```zig
// Zig (BUGGY VERSION)
var nhole: usize = 0;
// ❌ MISSING: var nhreg: usize = 0;
// ❌ MISSING: var nharea: usize = 0;

pushBack(edges[0], hole, &nhole);
pushBack(edges[2], hreg, &nhole);   // ❌ Should use &nhreg
pushBack(edges[3], harea, &nhole);  // ❌ Should use &nharea
```

**BUG FOUND!** Using `&nhole` for all three arrays instead of separate counters.

## Impact Analysis

### What Happens with Wrong Counters

```
Initial state:
  nhole = 0

After first edge:
  pushBack(edges[0], hole, &nhole)   → hole[0] = v5, nhole = 1
  pushBack(edges[2], hreg, &nhole)   → hreg[1] = r2, nhole = 2  ❌
  pushBack(edges[3], harea, &nhole)  → harea[2] = a3, nhole = 3 ❌

Expected state:
  hole  = [v5], nhole = 1
  hreg  = [r2], nhreg = 1  ✅
  harea = [a3], nharea = 1 ✅

Actual state:
  hole  = [v5], nhole = 3  ❌
  hreg  = [?, r2], nhreg = undefined
  harea = [?, ?, a3], nharea = undefined
```

### Consequence

When the code tries to connect the next edge:
```zig
if (hole[0] == eb) {  // Checks hole[0] = v5
    // Should connect if eb = v5
}
if (hole[nhole - 1] == ea) {  // Checks hole[2] ❌ (should be hole[0])
    // Wrong index due to nhole=3 instead of 1
}
```

**Edges don't connect properly → Hole boundary breaks → Unused edges remain → Larger hole created**

## Verification

To verify this hypothesis, we need to:
1. Add the missing `nhreg` and `nharea` variables
2. Change all `pushBack(hreg, &nhole)` to `pushBack(hreg, &nhreg)`
3. Change all `pushBack(harea, &nhole)` to `pushBack(harea, &nharea)`
4. Same for `pushFront` calls

Next: Root cause documentation and fix implementation.
