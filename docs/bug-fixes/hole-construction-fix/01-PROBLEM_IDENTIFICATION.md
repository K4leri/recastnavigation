# Problem Identification

## Initial Symptoms

### The Discrepancy

When running NavMesh generation tests, we observed a significant polygon count difference:

```
C++ Reference Implementation:  171 polygons
Zig Port Implementation:       231 polygons
Difference:                     60 polygons (35% more)
```

This was **after** the watershed fix that had previously achieved 100% accuracy for contour generation.

## Initial Hypothesis

Given that previous phases were working correctly (based on watershed fix), we hypothesized:
1. ✅ Heightfield rasterization - verified identical
2. ✅ Compact heightfield - verified identical
3. ✅ Distance field - verified identical
4. ✅ Region partitioning - verified identical (watershed fix)
5. ✅ Contour generation - verified identical
6. ❓ **Polygon mesh building** - suspected location

## Testing Strategy

### Phase 1: Add Comprehensive Logging

Added detailed logging to both C++ and Zig implementations:

#### Merge Operation Logging
```cpp
// C++ (RecastMesh.cpp:520-539)
[MERGE_VALUE #N] va=X, vb=Y, dx=DX, dy=DY, result=R (i64=R64)
[MERGE_CONTOUR #N iter I] Starting, npolys=N
[MERGE_CONTOUR #N iter I] Best: poly[A] + poly[B], value=V
[MERGE_CONTOUR #N iter I] Merged: npolys N->M
```

#### Vertex Removal Logging
```cpp
[DEBUG_HOLE] polysWithRem=N, nedges=E, nhole=H, ntris=T
[DEBUG_REMOVE] Removing vertex V (pass P/2)
[DEBUG_EDGE] Edge E: v0=A, v1=B, reg=R, area=AR
```

### Phase 2: Comparative Analysis

Compared logs from both implementations:
- First 50 merge value calculations
- All 633 contour merge operations
- Polygon counts at each stage

## Key Findings

### ✅ Merge Phase - IDENTICAL

All merge operations matched perfectly:

```
C++: [MERGE_VALUE #0] va=2, vb=0, dx=12, dy=-2, result=148
Zig: [MERGE_VALUE #0] va=2, vb=0, dx=12, dy=-2, result=148

C++: [MERGE_VALUE #1] va=4, vb=2, dx=8, dy=-18, result=388
Zig: [MERGE_VALUE #1] va=4, vb=2, dx=8, dy=-18, result=388

... 50 operations - ALL IDENTICAL
```

### ✅ Contour Processing - IDENTICAL

All 633 contour merge iterations matched:

```
C++: [MERGE_CONTOUR #0 iter 0] Starting, npolys=4
Zig: [MERGE_CONTOUR #0 iter 0] Starting, npolys=4

C++: [MERGE_CONTOUR #0 iter 0] Best: poly[2] + poly[3], value=468
Zig: [MERGE_CONTOUR #0 iter 0] Best: poly[2] + poly[3], value=468

... 633 operations - ALL IDENTICAL
```

### ✅ Pre-removeVertex Count - IDENTICAL

Both implementations had:
```
Polygons before removeVertex: 131
```

### ❌ removeVertex Phase - DIVERGENCE FOUND

After removeVertex:
```
C++: 131 → 171 polygons (+40)
Zig: 131 → 231 polygons (+100)
```

**Difference: 60 polygons created during vertex removal**

## Conclusion

The bug is **definitely** in the `removeVertex()` function or its helper functions. The divergence occurs specifically when:
1. Finding polygons that contain a vertex
2. Collecting edges that form a hole
3. Triangulating the hole
4. Merging triangles back into polygons

Next step: Deep dive into hole construction logic.

## Artifacts

### Log Files Generated
- `cpp_full_output.txt` - Complete C++ merge and remove operations
- `zig_merge_log.txt` - Complete Zig merge and remove operations
- `cpp_merge_log.txt` - Filtered C++ merge operations

### Code Changes for Logging
- Added merge value tracking with overflow detection
- Added per-contour iteration logging
- Added hole construction debugging
- Added edge collection tracking

## Timeline

1. **Discovery**: Noticed 171 vs 231 polygon discrepancy
2. **Logging Added**: Comprehensive debug output in both implementations
3. **Comparison**: First 50 merge values → identical
4. **Comparison**: All 633 contour merges → identical
5. **Discovery**: 131 pre-removeVertex → identical
6. **Discovery**: 40 vs 100 polygons added during removeVertex → **DIVERGENCE CONFIRMED**
