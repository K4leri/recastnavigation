# Root Cause Analysis

## The Bug

**Location:** `src/recast/mesh.zig:837-861`

**Issue:** Using a single counter variable (`nhole`) to track the size of three parallel arrays (`hole`, `hreg`, `harea`).

## Code Comparison

### C++ Reference Implementation (CORRECT)

```cpp
// RecastMesh.cpp:793-798
int nhole = 0;
int nhreg = 0;    // ✅ Separate counter for region array
int nharea = 0;   // ✅ Separate counter for area array

// Start the hole with the first edge
pushBack(edges[0], hole, nhole);
pushBack(edges[2], hreg, nhreg);    // ✅ Each array uses its own counter
pushBack(edges[3], harea, nharea);  // ✅ Each array uses its own counter
```

### Zig Implementation (BUGGY)

```zig
// mesh.zig:837-839 (BEFORE FIX)
var nhole: usize = 0;
// ❌ MISSING: var nhreg: usize = 0;
// ❌ MISSING: var nharea: usize = 0;

// Start with one vertex, keep appending connected segments
pushBack(edges[0], hole, &nhole);
pushBack(edges[2], hreg, &nhole);   // ❌ Wrong counter! Should be &nhreg
pushBack(edges[3], harea, &nhole);  // ❌ Wrong counter! Should be &nharea
```

## Why This Bug Exists

### Porting Error

During the initial port from C++ to Zig, the separate counter variables were not recognized as necessary. The code appeared to work because:
1. All three arrays start at size 0
2. They all grow by 1 for each edge added
3. The bug only manifests when array sizes diverge

However, using a shared counter causes **incorrect index calculations** when accessing array elements.

## Detailed Impact Analysis

### The Data Structure

The hole construction uses **three parallel arrays**:

```zig
var hole: [max]u16 = undefined;   // Vertex indices forming hole boundary
var hreg: [max]u16 = undefined;   // Region ID for each edge
var harea: [max]u16 = undefined;  // Area ID for each edge
```

These arrays must stay synchronized: `hole[i]`, `hreg[i]`, and `harea[i]` describe the same edge.

### Example: First Edge Addition

**Expected behavior (with separate counters):**
```
Initial:
  nhole = 0, nhreg = 0, nharea = 0

After pushBack(edges[0], hole, &nhole):
  hole[0] = 142, nhole = 1

After pushBack(edges[2], hreg, &nhreg):
  hreg[0] = 5, nhreg = 1

After pushBack(edges[3], harea, &nharea):
  harea[0] = 63, nharea = 1

State: All arrays have 1 element, properly synchronized
```

**Actual behavior (with shared counter):**
```
Initial:
  nhole = 0

After pushBack(edges[0], hole, &nhole):
  hole[0] = 142, nhole = 1

After pushBack(edges[2], hreg, &nhole):
  hreg[1] = 5, nhole = 2  ❌ Wrong index!

After pushBack(edges[3], harea, &nhole):
  harea[2] = 63, nhole = 3  ❌ Wrong index!

State:
  hole  = [142, ?, ?]      nhole = 3
  hreg  = [?, 5, ?]        (no nhreg variable)
  harea = [?, ?, 63]       (no nharea variable)
```

### Consequence: Broken Edge Matching

When trying to connect the next edge:

```zig
for (1..nedges) |i| {
    if (used[i]) continue;

    const ea = edges[i * 4 + 0];  // Edge start vertex
    const eb = edges[i * 4 + 1];  // Edge end vertex

    // Try to connect edge to start of hole
    if (hole[0] == eb) {  // ✅ hole[0] is valid
        pushFront(ea, hole, &nhole);
        // ...
    }
    // Try to connect edge to end of hole
    else if (hole[nhole - 1] == ea) {  // ❌ nhole=3, should check hole[0]!
        pushBack(eb, hole, &nhole);
        // ...
    }
}
```

**Problem:** `hole[nhole - 1]` accesses `hole[2]` (uninitialized!) instead of `hole[0]` (the actual last element).

### Cascade Effect

1. **Edge doesn't connect** because index is wrong
2. **Edge marked as unused** (`used[i]` stays false)
3. **Next iteration** tries to find another edge
4. **Unused edges accumulate** (3 unused in first hole)
5. **Larger hole created** because unused edges create gaps
6. **More triangles generated** to fill larger hole (19 vs 8)
7. **More polygons after merging** (231 vs 171)

## Mathematical Impact

### Triangle Count

For a hole with `n` vertices, triangulation creates `n - 2` triangles.

```
C++ (correct):
  10 hole vertices → 8 triangles

Zig (buggy):
  21 hole vertices → 19 triangles

Extra triangles: 11 per hole
```

### Polygon Count

After merging triangles back into polygons:

```
First NavMesh:
  C++: 171 polygons
  Zig: 231 polygons
  Difference: 60 polygons (35% more)
```

Approximately **5.5 extra polygons per extra triangle** after merging.

## Why It's Hard to Spot

### Subtle Manifestation

1. **Code compiles without errors** - Zig allows using any counter
2. **Tests pass for simple cases** - Small meshes might not trigger edge cases
3. **Output is valid** - NavMesh is still functional, just has wrong topology
4. **No runtime errors** - Arrays are large enough, no out-of-bounds access
5. **Difference seems random** - 60 extra polygons doesn't immediately suggest counter bug

### Debugging Required

Only discovered through:
- Systematic logging of all operations
- Comparison with reference implementation
- Careful analysis of array sizes at each step
- Code review of C++ reference for subtle differences

## Lessons Learned

### Parallel Array Pattern

When working with parallel arrays:
```
✅ DO:   Use separate size counters for each array
❌ DON'T: Share a single counter across multiple arrays
```

### Port Validation

When porting code:
1. **Variable-by-variable review** - Don't assume similar variables can be merged
2. **Semantic meaning** - Understand WHY each variable exists
3. **Integration tests** - Compare outputs against reference implementation
4. **Logging** - Add comprehensive logging for complex algorithms

### Counter Variables Matter

Even though `nhole`, `nhreg`, and `nharea` have the same value in the C++ code, they have **different semantic meanings**:
- `nhole` - "size of vertex boundary array"
- `nhreg` - "size of region ID array"
- `nharea` - "size of area ID array"

Merging them breaks the semantic contract of the code.

## Next Steps

Implement the fix by:
1. Adding missing variable declarations
2. Correcting all counter usage in `pushBack()` calls
3. Correcting all counter usage in `pushFront()` calls
4. Verifying polygon counts match reference implementation
