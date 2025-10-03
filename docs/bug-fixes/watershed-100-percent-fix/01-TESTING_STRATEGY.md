# Testing Strategy: Two Approaches for Full Validation

## Current Status

**Pipeline Test Results:**
- **C++ (Original)**: 432 vertices, 206 polygons, 44 contours
- **Zig (Port)**: 431 vertices, 203 polygons, 42 contours
- **Current Accuracy**: 98.5%+

**Overall Method Coverage**: 17/97 methods tested (17.5%)

## Variant A: Comprehensive Full Coverage

### Approach
Test ALL 97 methods across Recast/Detour/DetourCrowd/DetourTileCache immediately with nav_test.obj data.

### Implementation Plan
1. Create comprehensive C++ test executable covering all 97 methods
2. Create identical Zig test suite
3. Compare outputs for each method
4. Fix discrepancies one by one
5. Repeat until 100% match across all methods

### Advantages
✅ Ensures complete API coverage
✅ Validates entire implementation thoroughly
✅ No risk of missing untested methods

### Disadvantages
❌ Very time-consuming (potentially days/weeks)
❌ May find issues in methods not used by main pipeline
❌ Harder to isolate root causes when testing everything at once

### Estimated Effort
- **Phase 1 (Recast)**: 12 untested methods
- **Phase 2 (Detour)**: 25 untested methods
- **Phase 3 (DetourCrowd)**: 29 untested methods
- **Phase 4 (DetourTileCache)**: 14 untested methods
- **Total**: 80 untested methods to validate

---

## Variant B: Perfect Pipeline First ✅ (SELECTED)

### Approach
**Step 1**: Achieve 100% accuracy on main pipeline (eliminate 2 contour / 3 polygon difference)
**Step 2**: Expand to comprehensive coverage once pipeline is perfect

### Implementation Plan

#### Phase 1: Perfect Pipeline Accuracy
1. **Deep Investigation**:
   - Add detailed logging at every pipeline step
   - Compare region building between C++ and Zig
   - Compare contour generation vertex-by-vertex
   - Identify exact divergence point

2. **Root Cause Analysis**:
   - Analyze region-to-contour mapping differences
   - Check for floating-point precision issues
   - Verify flag usage in all pipeline steps
   - Examine edge cases in region merging

3. **Fix & Validate**:
   - Apply fixes to achieve exact match
   - Document root cause
   - Verify 100% accuracy: 432 vertices, 206 polygons, 44 contours

#### Phase 2: Expand Coverage
Once pipeline is perfect, systematically add tests for remaining 80 methods following the same C++/Zig comparison approach.

### Advantages
✅ Focuses on most critical path first
✅ Easier to isolate issues in known pipeline
✅ Builds confidence incrementally
✅ Pipeline perfection validates core algorithms

### Disadvantages
❌ Leaves some methods untested temporarily
❌ May discover issues later when testing remaining methods

### Estimated Effort
- **Phase 1 (Pipeline Perfect)**: 1-3 days
- **Phase 2 (Expand Coverage)**: 1-2 weeks

---

## Decision: Variant B

**Rationale:**
- Main pipeline is foundation of entire library
- 98.5% is close but not acceptable for production
- Perfect pipeline = validated core algorithms
- Easier to debug focused scope
- Incremental confidence building

**Success Criteria for Phase 1:**
```
C++: 432 vertices, 206 polygons, 44 contours
Zig: 432 vertices, 206 polygons, 44 contours
     ^^^          ^^^           ^^
     MUST MATCH EXACTLY
```

## Next Actions

1. ✅ Create this strategy document
2. 🔄 Add verbose logging to C++ integration test
3. 🔄 Add verbose logging to Zig integration test
4. 🔄 Run both and compare step-by-step outputs
5. ⏸️ Identify exact divergence point
6. ⏸️ Fix root cause
7. ⏸️ Validate 100% accuracy
8. ⏸️ Document findings
9. ⏸️ Proceed to Phase 2 (remaining 80 methods)
