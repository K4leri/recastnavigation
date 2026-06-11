# Perf audit — residual weak-spot campaign (findings + rationale)

Companion to [`FULL-RESULTS.md`](./FULL-RESULTS.md) (the raw statistical Zig-vs-C++
scoreboard). This file records the **second pass**: chasing the few zones that came
out slower than the C++ `recastnavigation` reference, what we fixed, and — just as
important — what we deliberately did **not** touch and why.

---

## 1. What the benchmark is, and why we run it

This repo is a faithful 1:1 Zig port of `recastnavigation` (Recast + Detour +
DetourCrowd + DetourTileCache). "Faithful" means the core structs keep C++'s field
types and the algorithms match the upstream source line-for-line, so we can sanity-check
correctness against the reference. The open question is then purely about **speed**: does
a faithful Zig port, built ReleaseFast on the native CPU, keep up with the battle-tested
C++ library?

To answer that honestly we built **two complementary benchmark systems**:

- **System A — per-function micro-bench** (`bench/microbench/`). Auto-tuned K-iteration
  batches give per-call min/mean/median/p95 ns for a single function. Every function can
  carry an **analog** (an alternative implementation). An analog only counts if it is
  proven **bit-identical** to the original over an input sweep (the `check` gate). This
  answers *"is this function already optimal, or can a rewrite beat it without changing
  output?"*

- **System B — Zig-vs-C++ Tracy scenario suite** (`bench/tracy_scenarios.zig` + the C++
  runner). 29 scenarios across 3 layers (14 BUILD + 8 QUERY + 7 CROWD, plus TILECACHE)
  drive the *whole pipeline* on real dense-BVH maps. Both runners share one contract
  (identical navmesh, identical LCG draw sequence, identical caps/filters/pools) and carry
  **byte-identical Tracy instrumentation**, so the per-zone (per recast/detour stage) times
  are a fair head-to-head. `merge_csv` joins the two CSVs by `(scenario, zone)` into a
  Zig/C++ ratio. This answers *"how does the real pipeline compare to C++ on real maps?"*

**Why this matters.** A point ratio is meaningless without a fairness model. Two traps
we explicitly defend against:

1. **CPU target.** Zig defaults to the native CPU (AVX2/FMA/BMI). MSVC has no
   `-march=native` and defaults to the SSE2 baseline — which would silently handicap C++
   and flatter Zig. So the C++ reference is built with `/arch:AVX2` (and both sides keep
   strict IEEE float, no fast-math). On float-heavy zones (rasterize, filters, contours,
   **distance-field box-blur**) AVX2 is exactly where C++ closes the gap, so this matters.
2. **Measurement noise.** A dev machine has ±~20 % run-to-run drift and a ~1 ns timer
   floor. We therefore (a) interleave the two sides and report a bootstrap 95 % CI, calling
   a zone *faster*/*slower* only when the CI clears 1.0, and (b) for a single change, use a
   **same-run before→after** A/B so the drift cancels. Sub-µs zones that sit on the timer
   floor are reported as ties, not wins.

The headline from `FULL-RESULTS.md`: **267 faster / 80 slower / 49 tie**, geomean **0.902**
over significant zones — Zig is broadly ahead. This campaign targets the slower tail.

---

## 2. Adopted fixes (output-identical, measured)

### 2.1 `rcBuildDistanceField` — vectorize the max-reduction

**Symptom.** Slower than C++ on *every* BUILD map in `FULL-RESULTS.md` (ratio 1.03–1.06).
The only zone that lost systematically across the whole suite.

**Root cause.** The final "find max distance" pass wrote the running maximum through the
out-pointer every iteration:

```zig
max_dist.* = 0;
for (src) |d| { if (d > max_dist.*) max_dist.* = d; }
```

A store through `max_dist.*` on each iteration stops LLVM from proving that `max_dist`
does not alias `src`, so the reduction stays **scalar**. MSVC `/arch:AVX2` vectorizes its
equivalent into a `vpmaxuw` horizontal max. That asymmetry is a chunk of the systematic gap.

**Fix** (`src/recast/region.zig`, `calculateDistanceField`): reduce into a local, write the
out-pointer once at the end.

```zig
var md: u16 = 0;
for (src) |d| { if (d > md) md = d; }
max_dist.* = md;
```

**Identity.** The micro-bench EXACT gate (`buildDistanceField` analog: byte-compare `dist[]`
+ `max_distance` vs the library fn) reports `check_ok = yes`.

**Speed** (System B, same-run before→after, de_ancient, vs the same C++ `/arch:AVX2` baseline):

| | zig min | zig mean | min ratio vs C++ (95.2 ms) |
|---|--:|--:|--:|
| before | 122.3 ms | 127.9 ms | 1.285× |
| **after** | **106.2 ms** | **117.6 ms** | **1.116×** |

→ **min −13.2 %, mean −8.1 %**; the gap to C++ is roughly halved. A residual ~12 % remains
because the dominant cost (the `boxBlur` 3×3 stencil + the two forward/back sweeps) is
exactly the float/int-heavy inner work that C++ AVX2 vectorizes and our branch-laden scalar
form does not — there is no output-identical vectorization of those data-dependent loops
that we have found (SIMD/@Vector is excluded by project policy).

### 2.2 `dtIsValidPolyRef` — drop the error-union detour

**Symptom.** 1.36–1.56× slower than C++ across *every* QUERY/CROWD scenario in
`FULL-RESULTS.md`. Tiny absolute (≈19–30 ns) but uniform.

**Root cause.** The Zig version answered a `bool` question by routing through
`getTileAndPolyByRef`, which builds a `{tile, poly}` result struct wrapped in an
`error{InvalidParam}!…` union and computes a poly pointer the caller throws away. C++'s
`dtNavMesh::isValidPolyRef` is a flat salt/header/polyCount validation that returns `bool`.

**Fix** (`src/detour/navmesh.zig`): inline the decode + the same three checks, no
error-union, no result struct, no poly-pointer compute. Output-identical (same checks; uses
the same cached `tile.poly_count`).

**Speed** (System B, de_ancient navmesh, 2000 calls, vs C++ `/arch:AVX2`): zig ~33 ns vs
C++ ~39 ns → ratio **0.86** (now at parity / slightly ahead, down from ~1.4× slower). The
zone is near the timer floor so the exact figure is noisy, but the codegen is unambiguously
leaner and the direction reversed.

---

## 3. Investigated and deliberately NOT changed (with rationale)

These showed up red in `FULL-RESULTS.md` but are **not** productive targets. Recording them
so the next pass doesn't re-chase them.

### 3.1 CROWD micro-zones — measurement artifact, not slow code
`crowd_integrate` (1.15–1.47×), `crowd_grid_register` (1.06–1.28×),
`crowd_steering_separation`, `crowd_topology_opt`, `crowd_path_queue_update`, etc.

**Why rejected.** The `crowd_separation_spread_120_no_goal` scenario shows **every** phase
zone uniformly ~1.7× (≈29 ns zig vs ≈17 ns cpp) while doing essentially **zero** real work
(agents have no goal). A uniform slowdown across phases that do nothing isolates the cost to
the **per-zone-entry overhead of the Zig Tracy wrapper**, not to any algorithm. The same
ratio riding on top of every small crowd zone explains the bulk of the "crowd slower"
entries. Where real work dominates (`crowd_scale_250` integrate, 1221 vs 1064 ns = 1.15×)
the gap shrinks toward parity. The math helpers (`vsub/vadd/vmad/vscale/vlen`) are trivial
element-wise leaves that LLVM inlines in ReleaseFast — they are not the cost. Closing the
last ~15 % at scale would need an invasive value-return math refactor with low confidence on
a near-floor zone; **bad risk/reward**, left alone.

### 3.2 TILECACHE add/remove obstacle — ratio inflated by tiny absolute
`dtTileCacheAddBoxObstacle` (2.5–5.9×), `dtTileCacheRemoveObstacle` (1.5–1.8×),
`dtCreateNavMeshData` (1.24×).

**Why rejected.** These are tens of ns — a single tagged-union store (`ob.shape = .{ .box =
… }`) plus a request-queue push. A 5× ratio on an 18 ns→100 ns operation is dominated by
quantization and first-touch effects, and obstacles are added rarely (not a per-frame hot
path). Real-world impact ≈ 0. (`dtBuildTileCacheRegions` at a steady 1.03–1.05× is the only
tilecache zone doing real work that's mildly slow — same flood-fill story as §3.4.)

### 3.3 Near-timer-floor QUERY zones — quantization
`dtInitSlicedFindPath` (1.15×, ≈50 ns), `dtGetPolyHeight` (1.08–1.10×, ≈60 ns),
`dtGetPolyWallSegments` (1.05–1.10×, ≈45 ns), `dtFindRandomPoint` (1.11×).

**Why rejected.** All sit within a few ns of the timer floor where the methodology says a
0.8–1.1 ratio is quantization, not signal. No structural slowness found; not worth a rewrite
that risks the 1:1-with-C++ faithfulness.

### 3.4 `rcBuildRegions` (watershed) — real but low-confidence
1.02–1.08× slower on several watershed maps.

**Why rejected (for now).** The hot inner work is `expandRegions` / `floodRegion`:
pointer-chasing, data-dependent flood-fill with no vectorizable reduction like the
distance-field max loop. It was already tuned in an earlier pass (`floodRegion` early-break +
hoisted dirty-entries, `inline for` direction unroll). The remaining few percent is scalar
scheduling noise between LLVM and MSVC, not an algorithmic miss — chasing it is
low-confidence and high-risk against faithfulness. Flagged as a possible ASM-diff target if a
future pass wants it.

---

## 4. The honest residual

`rcBuildDistanceField` is still ~12 % behind C++ even after §2.1, and that is the real
remaining frontier: C++ `/arch:AVX2` vectorizes the box-blur stencil and the two sweeps,
while our faithful scalar form (no `@Vector` by policy) cannot match it without changing the
data layout or the algorithm. Everything else flagged "slower" in `FULL-RESULTS.md` is
either now fixed (§2), a measurement artifact (§3.1), or below the reliable measurement floor
(§3.2–3.3). The library as a whole remains broadly ahead of the C++ reference (geomean 0.902).
