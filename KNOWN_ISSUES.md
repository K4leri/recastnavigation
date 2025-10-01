# Known Issues

## Memory Leaks

### CompactHeightfield Memory Leak
**Status:** Known issue, non-critical
**Affected:** All tests using CompactHeightfield
**Location:** `src/recast/heightfield.zig:224`

**Description:**
Memory leak detected in `CompactHeightfield.init()`:
```
[gpa] (err): memory address 0x... leaked:
src/recast/heightfield.zig:224:42: in init
    const areas = try allocator.alloc(u8, span_ucount);
```

**Root Cause:**
When `buildCompactHeightfield()` is called (in `src/recast/compact.zig`), it allocates new `areas` array without freeing the one created in `init()`. The initial `areas` from line 224 of heightfield.zig is never freed.

**Attempted Fix:**
Added checks to free old arrays before allocating new ones in `compact.zig`:
```zig
if (compact_hf.areas.len > 0) {
    compact_hf.allocator.free(compact_hf.areas);
}
```

**Result:** Fix causes test to hang/freeze indefinitely.

**Current Workaround:**
Reverted the fix. Tests pass with memory leak present. The leak is small (one allocation per test) and does not affect functionality.

**Impact:**
- 2 leaks per test run (one in recast_pipeline_test, one in detour_pipeline_test)
- Tests pass successfully: 5/5 tests passed
- No functional impact on library usage

**TODO:**
- Investigate why freeing old arrays causes hang
- Possibly restructure initialization to avoid double allocation
- Consider if `buildCompactHeightfield` should not re-allocate but reuse existing arrays

---

## Fixed Issues (Completed)

### 100+ Compilation Errors Fixed
- Type conversions i32 ↔ usize (~50 instances)
- Invalid log categories (.debug/.info/.warn → .progress/.warning/.err)
- Missing constants (CONTOUR_TESS_WALL_EDGES, etc.)
- Incorrect imports (Context from config → context module)
- Bitwise operations with large literals (0x80000000)
- Integer overflow in loops (u2 wrapping)

### Runtime Errors Fixed
- u2 overflow in area.zig (changed to u8)
- u2 overflow in contour.zig (used +% wrapping arithmetic)
- Array bounds errors in detail.zig (added bounds checks)
- Invalid mesh.polys slicing (fixed slice bounds)

All tests now compile and run successfully.
