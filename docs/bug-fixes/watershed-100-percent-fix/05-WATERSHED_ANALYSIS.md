# Watershed Algorithm Analysis: Region Assignment Discrepancies

## Critical Discovery

The problem is **NOT** in `mergeAndFilterRegions`. The problem is in the **watershed partitioning algorithm** itself - spans are being assigned to the wrong regions.

## Evidence

Both C++ and Zig create **44 regions** after watershed, but the **contents** of those regions are different.

### Region Span Count Comparison (Before Merging)

| Region | C++ Spans | Zig Spans | Difference | Status |
|--------|-----------|-----------|------------|--------|
| 1      | 2045      | 2045      | 0          | ✅ Match |
| 2      | 1893      | 1893      | 0          | ✅ Match |
| 3      | 1567      | 1567      | 0          | ✅ Match |
| 4      | 1883      | 1883      | 0          | ✅ Match |
| 5      | 1486      | 1486      | 0          | ✅ Match |
| 6      | 2017      | 2051      | **+34**    | ❌ Mismatch |
| 7      | 1437      | 1437      | 0          | ✅ Match |
| 8      | 1041      | 1041      | 0          | ✅ Match |
| 9      | 667       | 667       | 0          | ✅ Match |
| 10     | 698       | 698       | 0          | ✅ Match |
| 11     | 434       | 873       | **+439**   | ❌ LARGE Mismatch |
| 12     | 873       | 570       | **-303**   | ❌ LARGE Mismatch |
| 13     | 574       | 1311      | **+737**   | ❌ LARGE Mismatch |
| 14     | 1311      | 434       | **-877**   | ❌ LARGE Mismatch |
| 15     | 302       | 302       | 0          | ✅ Match |
| 16     | 493       | 220       | **-273**   | ❌ LARGE Mismatch |
| 17     | 220       | 343       | **+123**   | ❌ Mismatch |
| 18     | 343       | 493       | **+150**   | ❌ Mismatch |
| 19     | 210       | 210       | 0          | ✅ Match |
| 20     | 212       | 212       | 0          | ✅ Match |
| 21     | 255       | 319       | **+64**    | ❌ Mismatch |
| 22     | 203       | 203       | 0          | ✅ Match |
| 23     | 179       | 179       | 0          | ✅ Match |
| 24     | 254       | 254       | 0          | ✅ Match |
| 25     | 116       | 158       | **+42**    | ❌ Mismatch |
| 26     | 160       | 160       | 0          | ✅ Match |
| 27     | 169       | 169       | 0          | ✅ Match |
| 28     | 257       | 257       | 0          | ✅ Match |
| 29     | 122       | 25        | **-97**    | ❌ LARGE Mismatch |
| 30     | 107       | 30        | **-77**    | ❌ Mismatch |
| 31     | 74        | 29        | **-45**    | ❌ Mismatch |
| 32     | 25        | 88        | **+63**    | ❌ Mismatch |
| 33     | 30        | 22        | **-8**     | ❌ Mismatch |
| 34     | 29        | 135       | **+106**   | ❌ LARGE Mismatch |
| 35     | 22        | 125       | **+103**   | ❌ LARGE Mismatch |
| 36     | 56        | 75        | **+19**    | ❌ Mismatch |
| 37     | 125       | 99        | **-26**    | ❌ Mismatch |
| 38     | 75        | 75        | 0          | ✅ Match |
| 39     | 99        | 29        | **-70**    | ❌ Mismatch |
| 40     | 75        | 22        | **-53**    | ❌ Mismatch |
| 41     | 29        | 44        | **+15**    | ❌ Mismatch |
| 42     | 22        | 127       | **+105**   | ❌ LARGE Mismatch |
| **43** | **44**    | **1**     | **-43**    | ❌ **CRITICAL** |
| **44** | **127**   | **2**     | **-125**   | ❌ **CRITICAL** |

## Key Observations

### 1. Region Swapping Pattern
Regions 11-14 appear to have swapped span assignments:
- C++ regions: 434, 873, 574, 1311
- Zig regions: 873, 570, 1311, 434

This suggests a different traversal or expansion order during watershed.

### 2. Critical Tiny Regions in Zig
**Region 43 and 44 in Zig are catastrophically small:**
- Region 43: Only **1 span** (C++ has 44)
- Region 44: Only **2 spans** (C++ has 127)

These regions were **correctly removed** by mergeAndFilterRegions (< 8 minRegionArea), but they should have had the correct span counts in the first place.

### 3. Missing Spans
The spans that SHOULD be in regions 43-44 are scattered into other regions (likely 41-42 and others).

## Root Cause Analysis

The issue is in one of these stages BEFORE mergeAndFilterRegions:

### 1. Distance Field Calculation (`buildDistanceField`)
- Calculates distance to nearest border for each span
- Different distance values could lead to different watershed behavior
- **Needs verification**: Compare distance field values between C++ and Zig

### 2. Region Seed Selection (`buildRegions` line ~521)
- Seeds are selected based on local maxima in distance field
- Non-deterministic iteration order could select different seeds
- **Check**: Are the same 44 seeds being selected at the same positions?

### 3. Region Expansion (`expandRegions`)
- Expands regions from seeds using flood-fill
- Traversal order matters when multiple regions compete for a span
- **Check**: Is the expansion order deterministic?

### 4. Stack/Queue Ordering
- Different stack management in Zig vs C++
- Pop order might differ if using ArrayList vs std::vector

## After mergeAndFilterRegions

Once regions 43-44 are removed by mergeAndFilterRegions:

**C++**: 44 regions → 44 regions (no regions removed)
- All regions are >= 8 spans

**Zig**: 44 regions → 42 regions (2 regions removed)
- Regions 43 and 44 are < 8 spans

## Impact

**Final Results:**
- C++: 432 vertices, 206 polygons, 44 contours
- Zig: 431 vertices, 203 polygons, 42 contours
- **Difference**: -1 vertex, -3 polygons, -2 contours

## Next Steps

1. ✅ Confirmed: mergeAndFilterRegions works correctly
2. ✅ Identified: Watershed assigns spans to wrong regions
3. 🔄 **Next**: Add logging to compare distance field values
4. ⏸️ **Then**: Compare region seed positions
5. ⏸️ **Then**: Compare expansion order
6. ⏸️ **Finally**: Fix watershed to match C++ exactly

## Conclusion

The mergeAndFilterRegions implementation is **CORRECT** ✅

The problem is **earlier in the pipeline** - in the watershed partitioning algorithm that assigns spans to regions. We need to trace through buildRegions step-by-step to find where the assignment diverges.
