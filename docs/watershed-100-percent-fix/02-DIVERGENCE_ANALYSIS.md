# Pipeline Divergence Analysis: C++ vs Zig

## Summary
The Zig implementation produces **different region assignments** compared to C++, leading to different contour and polygon counts.

## Identical Results (✅)
- **Mesh Loading**: 884 vertices, 1560 triangles
- **Bounds**: min=(-28.89, -4.87, -46.30) max=(62.49, 17.01, 31.05)
- **Grid Size**: 305x258
- **Rasterization**: 1560 triangles
- **Compact Heightfield**: 55226 spans
- **Region Count**: 44 regions

## Divergence Point: Region Building (❌)

### Region Span Count Comparison

| Region | C++ Spans | Zig Spans | Difference |
|--------|-----------|-----------|------------|
| 1      | 2045      | 2045      | 0          |
| 2      | 1893      | 1893      | 0          |
| 3      | 1567      | 1567      | 0          |
| 4      | 1883      | 1883      | 0          |
| 5      | 1486      | 1486      | 0          |
| **6**  | **2017**  | **2051**  | **+34**    |
| 7      | 1437      | 1437      | 0          |
| 8      | 1041      | 1041      | 0          |
| 9      | 667       | 667       | 0          |
| 10     | 698       | 698       | 0          |
| **11** | **434**   | **873**   | **+439**   |
| **12** | **873**   | **570**   | **-303**   |
| **13** | **574**   | **1311**  | **+737**   |
| **14** | **1311**  | **434**   | **-877**   |
| 15     | 302       | 302       | 0          |
| **16** | **493**   | **220**   | **-273**   |
| **17** | **220**   | **343**   | **+123**   |
| **18** | **343**   | **493**   | **+150**   |
| 19     | 210       | 210       | 0          |
| 20     | 212       | 212       | 0          |
| **21** | **255**   | **319**   | **+64**    |
| 22     | 203       | 203       | 0          |
| 23     | 179       | 179       | 0          |
| 24     | 254       | 254       | 0          |
| **25** | **116**   | **158**   | **+42**    |
| 26     | 160       | 160       | 0          |
| 27     | 169       | 169       | 0          |
| 28     | 257       | 257       | 0          |
| **29** | **122**   | **25**    | **-97**    |
| **30** | **107**   | **30**    | **-77**    |
| **31** | **74**    | **29**    | **-45**    |
| **32** | **25**    | **88**    | **+63**    |
| **33** | **30**    | **22**    | **-8**     |
| **34** | **29**    | **135**   | **+106**   |
| **35** | **22**    | **125**   | **+103**   |
| **36** | **56**    | **75**    | **+19**    |
| **37** | **125**   | **99**    | **-26**    |
| **38** | **75**    | **75**    | 0          |
| **39** | **99**    | **29**    | **-70**    |
| **40** | **75**    | **22**    | **-53**    |
| **41** | **29**    | **44**    | **+15**    |
| **42** | **22**    | **127**   | **+105**   |
| **43** | **44**    | **1**     | **-43**    |
| **44** | **127**   | **2**     | **-125**   |

### Key Observations

1. **Region Swapping Pattern**:
   - Regions 11-14 appear to have their span counts permuted
   - Regions 16-18 show similar swapping behavior
   - This suggests different region expansion order

2. **Tiny Regions at End**:
   - C++ ends with regions 43-44 having 44 and 127 spans
   - Zig ends with regions 43-44 having only 1 and 2 spans
   - These tiny regions in Zig suggest failed region merging

3. **Impact on Contours**:
   - C++: 44 contours (one per region)
   - Zig: 42 contours (missing 2 contours)
   - The 2 missing contours correspond to the tiny regions 43-44

## Contour Comparison

### Missing Contours in Zig

C++ has these contours that Zig is missing (or has merged):

**C++ Contour 16**: nverts=9, reg=29, first_vert=(50,21,150)
**C++ Contour 22**: nverts=10, reg=30, first_vert=(110,13,147)

Zig has these instead:
- Zig Contour 16: nverts=6, reg=32, first_vert=(56,27,145) ← Different!
- Zig Contour 22: nverts=15, reg=34, first_vert=(111,13,160) ← Different!

### Vertex Count Difference

**C++ Contour 15**: nverts=37, reg=6
**Zig Contour 15**: nverts=38, reg=6 (+1 vertex)

This single vertex difference in the same region suggests contour simplification is also affected.

## Root Cause Analysis

### Primary Issue: Non-Deterministic Region Building

The watershed region building algorithm in `buildRegions` is producing different region assignments. Possible causes:

1. **Different Traversal Order**
   - Stack/queue iteration order differs between C++ and Zig
   - Hash map iteration order (if used) is non-deterministic

2. **Tie-Breaking in Region Expansion**
   - When multiple regions can claim a span, which one wins?
   - C++ and Zig may have different tie-breaking logic

3. **Region Merging Logic**
   - Small regions should be merged with neighbors
   - Zig appears to be failing to merge regions 43-44 properly

4. **Flood Fill Implementation**
   - Different stack management
   - Different recursion patterns

### Files to Investigate

- `src/recast/region.zig` - buildRegions implementation
- Specifically look at:
  - Region expansion loop order
  - Span neighbor traversal order
  - Region merging logic
  - Any use of hash maps or sets with undefined iteration order

## Impact on Final Results

**C++**: 432 vertices, 206 polygons, 44 contours
**Zig**: 431 vertices, 203 polygons, 42 contours

- **1 vertex difference** (likely from contour simplification difference)
- **3 polygon difference** (from missing contours)
- **2 contour difference** (from region building)

## Next Steps

1. ✅ Identify divergence point: **Region building**
2. 🔄 Investigate buildRegions algorithm for non-determinism
3. ⏸️ Fix region building to match C++ behavior exactly
4. ⏸️ Verify 100% match after fix
