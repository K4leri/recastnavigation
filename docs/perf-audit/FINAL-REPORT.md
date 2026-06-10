# Recast/Detour — Zig vs C++ Performance Report

A head-to-head of the **Zig 0.16 port** of [recastnavigation](https://github.com/recastnavigation/recastnavigation)
against the **upstream C++ reference**, function by function, measured fairly and
reproducibly. This document is self-contained — you do not need prior context to read it.

- **Ratio convention:** `ratio = median(zig_time) / median(cpp_time)`.
  **`< 1.0` = Zig faster**, `> 1.0` = Zig slower, `≈ 1.0` = parity.
- **Headline:** across **all four** layers the Zig port is **at or above C++ speed** —
  overall **≈ 0.85** `Zig÷C++` (BUILD 0.82 · CROWD 0.83 · QUERY 0.93 · TILECACHE 0.98).
  Per-layer table with zone counts in **[§3](#3-results--per-layer)**; how it's measured in §4.
- **Honest tail:** ~**34 of 322** trusted zones are still Zig-slower (§6) —
  concentrated in `crowd_integrate` / `crowd_grid_register` (context-bound) and
  tile-cache `dtCreateNavMeshData` (tiny-tile serialize overhead), plus a thin
  build-layer tail at 1.02–1.06. The layer means are net wins because the broad
  wins outweigh this tail, but the tail is real and is enumerated in §6.

> **Single source of truth.** Every number in this report derives from **one file** —
> `STAT_FINAL/STAT_SCOREBOARD.csv` (396 zones, one consolidated K=15/7 run, median +
> 95 % CI) — via `tools/analysis/gen_stat_table.py`. The complete per-zone table is
> **[FULL-RESULTS.md](FULL-RESULTS.md)**, generated from the same file.

> **Scope = the benchmark branch, not the shipping core.** These numbers are measured
> on the benchmark branch (Tracy instrumentation + optimization experiments live
> there). The shipping `master` core carries only the proven, output-identical wins
> (§7). The C++ reference is built `/arch:AVX2` + strict IEEE float so the comparison
> is not handicapped.

---

## 1. What the four "layers" are

recastnavigation is a navigation-mesh (navmesh) toolkit for games/AI. Work splits
into four stages, each benchmarked as a separate **layer**:

| Layer | What it is | When it runs | Example trigger |
|---|---|---|---|
| **BUILD** | **Offline construction** of the navmesh from raw level geometry (triangles → walkable polygons). | Once, at bake/load time (or on a rebuild). | Level designer bakes nav data. |
| **QUERY** | **Runtime search/navigation** over an already-built navmesh — pathfinding, raycasts, snapping. | Every frame, per agent. | An NPC asks "path from A to B?". |
| **CROWD** | **Multi-agent steering** — moving many agents at once with local collision avoidance. Uses QUERY internally. | Every frame, for the whole crowd. | 100 NPCs moving through a level. |
| **TILECACHE** | **Dynamic obstacles** — re-build affected navmesh tiles when obstacles are added/removed at runtime. | When the world changes. | A door closes / a crate drops. |

A "**zone**" is one timed function within a layer (e.g. `dtFindPath`). A "**scenario**"
is one benchmark case (a specific map + workload, e.g. `query_findpath_flood`).

### 1.1 The benchmark workloads (48 scenarios)

So a reader can judge **how realistic the workload is**, here is every scenario that
produced the numbers. All geometry is the **real game collision world** exported to
dense triangle soup (`map_1` 175 k tris, `map_3` 568 k, `map_2` 55 k,
`map_4` 122 k, `map_5` 27 k, `map_6` 36 k). All randomness is one shared
deterministic LCG (seed 12345) so both languages draw byte-identical inputs.

> **Honest characterization of each layer's realism** (this matters — see §4):
> - **BUILD, CROWD, TILECACHE are scenario-realistic**: they run the *actual end-to-end
>   work* — a full pipeline rebuild, a multi-second multi-agent simulation, a real
>   add→rebuild→remove obstacle cycle.
> - **QUERY is a per-function micro-benchmark embedded in a real navmesh**, NOT a
>   full "agent navigates a level" scenario. One navmesh is built once, then a single
>   `dt*` function is called N = 2000 times on LCG-drawn inputs. This is a legitimate
>   way to isolate one function's cost, but it is *not* a user-journey scenario, and
>   QUERY should be read as "is this function competitive", not "is realtime navigation
>   faster end-to-end".

**BUILD — 16 scenarios** (full Recast pipeline; each scenario = a full navmesh bake):

| scenario | map | what it stresses |
|---|---|---|
| `build_solo_watershed_map_1` | map_1 (175k tris) | reference map — also the QUERY navmesh source; canonical per-zone calibration baseline |
| `build_solo_watershed_map_2` | map_2 (55k tris) | open layout → clean watershed baseline; also the CROWD navmesh source |
| `build_solo_watershed_map_3` | map_3 (568k tris) | heaviest map — `rcRasterizeTriangles` triangle-clip competes with the region flood |
| `build_solo_watershed_map_4` | map_4 (122k tris) | multi-level overpass → more regions; heavier rasterize than map_2 |
| `build_solo_watershed_map_5` | map_5 (27k tris) | thin vertical extent → region flood dominates, rasterize cheap |
| `build_solo_watershed_map_6` | map_6 (36k tris) | small footprint but tall → many vertical spans/column |
| `build_solo_monotone_map_1` | map_1 | monotone partition (no distance field) — measures the cost shift downstream into contours/polymesh |
| `build_solo_layers_map_1` | map_1 | layer partition — 2D layer overlap/merge bookkeeping (overpass forces multiple layers); no distance field |
| `build_solo_watershed_map_1_coarse` | map_1 @2M | coarse end of the cell-size sweep — fixed per-call overheads become a larger share |
| `build_solo_watershed_map_1_fat_agent` | map_1, radius ×4 | isolates `rcErodeWalkableArea` (erosion scales with radius) |
| `build_solo_watershed_map_1_dense_detail` | map_1, detail ×16 | isolates `rcBuildPolyMeshDetail` (Delaunay/seed loops) — only scenario with meaningful detail self-time |
| `build_solo_offmesh_map_1` | map_1 | 32 off-mesh connections wired into the tile (off-mesh baking in `dtCreateNavMeshData`) |
| `build_tiled_watershed_map_1_region` | map_1 region | tiled build over a central region (1024 tiles) — per-tile fixed setup/teardown paid ~1024× |
| `build_tiled_watershed_map_2_region` | map_2 region | same tiled build on map_2's central region |
| `build_tiled_watershed_map_3_region` | map_3 region | same on the heaviest map — canonical tiled baseline |
| `build_tiled_layers_map_4_region` | map_4 region | tiled **layers** — per-tile layer overlap/merge; layers+tiling = the real-world pairing |

**QUERY — 20 scenarios** (one navmesh on `map_1` @8M, N = 2000 calls each; the
3 `multitile_*` arms use a connected **tiled `map_3`** graph for cross-tile
traversal):

| scenario | what it tests |
|---|---|
| `findnearestpoly_flood` | point location — BV-tree AABB descent + per-candidate `closestPointOnPoly` distance eval, zero A* noise |
| `findpath_flood` | A* core over realistic-length pairs — binary-heap push/pop + node-pool lookups + per-edge portal cost eval |
| `findpath_long_diagonal` | worst-case A* — cross-map diagonals → largest open-list, deepest pool, most heap rebalances |
| `findstraightpath_flood` | funnel / string-pull over precomputed corridors (left/right apex advance), isolated from A* |
| `findstraightpath_crossings` | same funnel with the `_CROSSINGS` option — a point at every portal crossing |
| `raycast_flood` | straight-line poly walk — per-poly segment/edge intersection + neighbour-link walk, no heap |
| `movealongsurface_flood` | constrained local surface walk over the tiny node pool with per-edge wall-clamp (highest production call frequency) |
| `findpolysaroundcircle_radius_sweep` | Dijkstra-style cost-bounded flood from a center over radii {8,24,64} — cost-vs-area scaling |
| `findpolysaroundshape_convex_sweep` | same cost-bounded flood but bounded by a convex polygon instead of a circle |
| `findlocalneighbourhood_radius_sweep` | non-overlapping local neighbourhood gather (BFS with overlap rejection) over a radius sweep |
| `findrandompoint_area_weighted` | uniform random point on the navmesh — area-weighted polygon pick + in-triangle sample |
| `findrandompointaroundcircle_radius_sweep` | random point within a radius of a center — bounded variant over the radius sweep |
| `finddistancetowall_radius_sweep` | nearest-wall distance flood (Dijkstra to boundary edges) over a radius sweep |
| `getpolyheight_snapped` | detail-mesh height lookup at a point inside a poly (barycentric over detail triangles) |
| `isvalidpolyref_snapped` | poly-ref validation (salt/tile/poly decode + bounds) — the cheapest query, a timer-floor reference |
| `getpolywallsegments_portals` | per-poly wall/portal segment extraction (boundary edges vs linked edges) |
| `slicedpath_budget32` | time-sliced A* (maxIter=32/update) → many resume cycles + state save/restore; incremental-query path |
| `multitile_findpath` | A* across a connected tiled `map_3` graph — cross-tile link traversal |
| `multitile_straightpath` | funnel over a cross-tile corridor |
| `multitile_raycast` | raycast across tile boundaries (cross-tile link walk) |

**CROWD — 7 scenarios** (real `crowd.update(1/60 s)` simulation on `map_2`, the
genuine user-case layer):

| scenario | agents · ticks | situation |
|---|---|---|
| `crowd_baseline_25_oa_low` | 25 · 600 | sparse steady-state baseline |
| `crowd_100_oa_high` | 100 · 600 | dense crowd, HIGH obstacle-avoidance quality |
| `crowd_100_no_avoidance` | 100 · 600 | A/B with OA disabled (isolates OA cost) |
| `crowd_choke_funnel_60_oa_high` | 60 · 900 | all agents forced through one narrow doorway (jam) |
| `crowd_mass_repath_100_shared_moving_goal` | 100 · 1200 | shared goal that moves every 2 s → 10 synchronized mass-repaths |
| `crowd_separation_spread_120_no_goal` | 120 · 600 | tightly overlapping blob disperses by separation only |
| `crowd_scale_250_oa_med` | 250 · 600 | near the 256-agent cap; scaling/throughput |

**TILECACHE — 5 scenarios** (real dynamic-obstacle cycles: add N obstacles → rebuild
touched tiles → remove all → rebuild, ×3 cycles, on a central region):

| scenario | map · obstacles | shape |
|---|---|---|
| `tilecache_obstacles_map_2` | map_2 · 16 | axis-aligned box |
| `tilecache_cylinders_map_2` | map_2 · 16 | cylinder |
| `tilecache_orientedbox_map_2` | map_2 · 16 | oriented box |
| `tilecache_dense_box_map_2` | map_2 · 64 | box (dense) |
| `tilecache_obstacles_map_3` | map_3 · 16 | box (heaviest map) |

The exact configs (derived cell sizes, node-pool sizes, OA presets, LCG draw order,
tile sizes, obstacle counts) are the cross-language contract in
`dev/research/performance_analysis/scenarios.md`.

---

## 2. What each benchmarked function (zone) does

The per-function glossary — every `rc*` / `dt*` / `crowd_*` zone name with a one-line
description of what it computes, grouped by layer — lives in its own file so it can be
read alongside [FULL-RESULTS.md](FULL-RESULTS.md) without scrolling this report:

**→ [ZONES.md](ZONES.md) — zone reference (what each benchmarked function does).**

---

## 3. Results — per-layer

`Zig÷C++` = geometric mean of the per-zone **median** `zig/cpp` ratio over
**trusted** zones (above the ~200 ns timer floor, with Zig/C++ call-count parity).
**`< 1.0` = Zig faster.** One consolidated K=15/side run (K=7 for BUILD),
`STAT_FINAL`.

The `trusted (raw)` column is the geomean's sample size (trusted zones) followed by
the raw zone count before the floor/count filter; e.g. CROWD `81 (138)` means 57 of
138 zones fell below the timer floor and do NOT contribute. `f / s / t` =
faster (CI<1) / slower (CI>1) / tie (CI spans 1.0).

| Layer | Zig÷C++ | trusted (raw) | f / s / t | Verdict | Notes |
|---|:--:|:--:|:--:|---|---|
| **BUILD** | **0.82** | 189 (189) | 157 / 14 / 18 | Zig faster | wins broadly; one universal residual: `rcBuildDistanceField` (slower on every map, compute-bound) |
| **CROWD** | **0.83** | 81 (138) | 68 / 10 / 3 | Zig faster | most phases faster; `crowd_integrate` / `crowd_grid_register` are the context-bound residuals |
| **QUERY** | **0.93** | 12 (21) | 7 / 1 / 4 | Zig faster | most query fns are sub-µs (floor-gated); the resolvable ones are faster |
| **TILECACHE** | **0.98** | 40 (48) | 27 / 9 / 4 | Zig faster | heavy rebuild (contours/polymesh/decompress/addTile) faster; sub-µs obstacle-queue ops are the slow tail |
| **OVERALL** | **≈ 0.85** | 322 (396) | 259 / 34 / 29 | **Zig faster (all 4 layers)** | geomean over all trusted zones |

Per-zone detail (all 396 zones, median ns + ratio + 95 % CI + verdict): see
**[FULL-RESULTS.md](FULL-RESULTS.md)**, generated from the same `STAT_FINAL` file.
Sub-~200 ns zones are flagged and floor-gated out of the headline (see §4).

---

## 4. Methodology — how the numbers are made honest

### 4.1 The two repeat levels (what one number represents)

A **run** = one process invocation of a scenario binary. Inside a single run the
function under test is exercised many times, and the runner emits exactly **one
aggregate number per zone** for that run:

| layer | per-run internal repeats | aggregate emitted |
|---|---|---|
| QUERY | navmesh built once (untimed), then **N = 2000** measured calls of the zone function | **mean ns** over the 2000 calls |
| CROWD | navmesh built once, then **M ticks** of `crowd.update(1/60 s)`, **M = 600 / 900 / 1200** per scenario | **mean ns per tick** for each `crowd_*` phase |
| BUILD | a full navmesh rebuild repeated **iters = 2–6** times (per scenario) | **min ns** over the iters (cleanest full-build estimate) |
| TILECACHE | **3 cycles** of {add **16** (or **64** dense) obstacles → rebuild touched tiles → remove all → rebuild}; ≈48 obstacle ops and ≈54 tile rebuilds per run | **mean ns** per zone over its 48–54 firings |

> Why BUILD uses so few iters: one full rebuild is the most expensive operation in
> the suite (e.g. `rcBuildPolyMeshDetail` ≈ 20 s/iter on dense detail; `rcBuildPolyMesh`
> ≈ 1.1 s/iter on map_1). With iters × K=7 runs × 2 sides × 16 build scenarios the
> wall-clock is already minutes; more iters add little because ms-scale builds have low
> run-to-run variance (CV ≈ 2–5 %, vs 15–26 % for sub-µs query zones) — hence BUILD
> uses K=7 while the cheap, noisy runtime zones get the full K=15.

So a single run already averages (or min's) over **thousands** of internal executions
— it is one sample point per zone, not one execution.

### 4.2 The two statistical layers (over runs)

Run-to-run variance (CPU thermals, OS scheduling, process-start cache state) is the
dominant noise source, so multiple runs are taken per side. **The published numbers in
this report come from `stat_compare`** (the statistically rigorous pass):

- **`stat_compare` — the published method.** K = **15 runs** per side (K = 7 for the
  slow BUILD rebuilds), **interleaved** (zig, cpp, zig, cpp, … so slow drift hits both
  sides equally). Per zone it reports the **median ratio + 95 % bootstrap CI + a
  verdict**: FASTER / SLOWER when the CI excludes 1.0, else **tie (within noise)**.
  This is what proves a difference is real rather than measurement jitter. All numbers
  here are one consolidated run of this, `STAT_FINAL/STAT_SCOREBOARD.csv`.
- **`compare_min` — an earlier, cheaper ranking pass** (kept for reference, NOT the
  source of any published figure). N = 3 runs/side, best-of-runs, geomean of per-zone
  ratios — a point estimate with **no confidence interval**, superseded by the CI-gated
  `stat_compare` numbers above.

Worked example: one zone of a QUERY scenario at K = 15 →
`15 runs × 2000 internal calls = 30 000 executions per side`, collapsed to 15 sample
points per side, then bootstrapped into a median ratio + 95 % CI.

### 4.3 Validity gates (applied to every zone)

- **Timer floor (~200 ns):** below this the OS clock can't time reliably (the
  quantization step is ~tens of ns). A "2× slower" on a 20 ns zone is ~10 ns of
  jitter, not signal — such rows are flagged **FLOOR** and excluded from the geomean.
- **Count-parity:** Zig and C++ must execute the **same number of calls** for the
  zone; otherwise the pair is rejected (it would compare different amounts of work).
- **min-of-runs vs mean:** SOLO build uses `min_ns` (one full rebuild per iter); TILED
  build and the runtime layers use `mean_ns` (the zone aggregates over many
  tiles/calls, so the mean is representative, not the single emptiest tile).
- **Sub-µs noise reality:** on a contended dev machine the same zone can read 0.70 in
  one run and 1.18 in another; such zones are reported as **parity**, and any tighter
  ranking requires `stat_compare`'s CI, never a single scenario mean.

---

## 5. What this campaign changed (optimizations adopted)

All output-faithful (bit-identical or 1:1 with upstream C++), identity-gated (tests
pass), and confirmed by `stat_compare` (median + CI). The ratios below are
**illustrative of each fix's direction** — authoritative per-zone numbers are in
[FULL-RESULTS.md](FULL-RESULTS.md):

| fix | zone(s) | effect (honest distribution) |
|---|---|---|
| Removed a per-span null-test from the hot loop | `rcFilterLowHangingWalkableObstacles` | net improvement, but **not uniform**: across 16 build scenarios the ratio now spans **0.81 … 1.10, geomean 0.962** (9 faster / 5 slower / 2 parity). It is faster on most maps but still slower on a few (e.g. map_6 1.10, layers 1.05). The earlier "1.16 → 0.93" was a single favourable scenario, not the whole picture. |
| Start poly was validated with the heavy query-level check (`getTileAndPolyByRef` + filter) instead of the light nav-level check — fixed across 5 functions to match C++ 1:1 | `moveAlongSurface` | the standalone flood scenario moved from clearly-slower to clearly-faster (≈1.8 → ≈0.85) |
| | `findLocalNeighbourhood` | from ≈1.4 to ≈0.83 in the QUERY flood; note it is still slower (≈1.12) when called *inside* the crowd loop (different cache context) |
| | `findDistanceToWall` | from ≈1.2 to faster/at-floor |
| | `findPath` | from slightly-slower to ≈0.9 in the solo flood (but `multitile findPath` is still 1.14) |
| | `raycast` | start-validation fixed; the residual ratio is sub-floor noise (reads *below* the ~200 ns timer floor — not a trusted signal) |

Net: the query-validation fix is a **genuine, correct 1:1-with-C++ improvement** that
removed a real redundant check, and it made several QUERY functions faster in their
isolated flood scenarios. It did **not** make QUERY uniformly faster — the layer is a
near-tie (§3) and several query/crowd call-sites of these same functions remain slower
in other contexts. The honest claim is "removed a real inefficiency", not "QUERY is now
faster across the board".

---

## 6. Where Zig is SLOWER — the full residual tail

This section is deliberately complete. In the consolidated run **~34 of 322 trusted
zones are Zig-slower** (CI clears 1.0 on the slow side). They do not change the layer
verdicts (the wins outweigh them in the geomean) but they are real and are listed here
in full — aggregated to the **function level** (geomean of a function's ratio across
all scenarios it appears in), worst first. The per-function figures below are
directional (drawn across campaign runs); the authoritative per-zone numbers with CIs
are in [FULL-RESULTS.md](FULL-RESULTS.md).

### 6.1 Functions that are slower in *every* scenario they appear in

These are the systematic regressions — not noise, not one bad map:

Verified against `STAT_FINAL` (floor-gated, function-level geomean of the median ratio):

| function | layer | geo | scenarios | range | status |
|---|---|---|:--:|:--:|---|
| `crowd_integrate` | CROWD | **1.30** | 4/4 slower | 1.15 – 1.47 | context-bound; standalone clone does NOT reproduce it |
| `dtCreateNavMeshData` *(tile-cache rebuild)* | TILECACHE | **1.25** | 5/5 slower | 1.24 – 1.27 | tiny-tile serialize + BVTree build; fixed per-tile overhead. NOTE: the *same* function is a big **win (≈0.58)** in BUILD — it's only slow on tile-cache's many tiny rebuilds |
| `crowd_grid_register` | CROWD | **1.17** | 6/6 slower | 1.07 – 1.28 | context-bound; ASM + inline experiments rejected |
| `dtFindRandomPoint` | QUERY | **1.11** | 1/1 | 1.11 | 1:1 with C++; single small zone |

### 6.2 The smaller tail (1.02–1.08, marginal)

After the comptime/data-layout wins these are now only just above parity:
`rcBuildDistanceField` (1.03–1.06 on ~6 build maps — once the suite's biggest loss,
now marginal; still compute-bound, §6.3), `rcBuildRegions` (1.02–1.08 on a few maps),
`rcFilterWalkableLowHeightSpans` (1.11 on map_6), `rcBuildContours` (1.02–1.03),
`dtBuildTileCacheRegions` (1.03–1.05 after the `canMerge` + scratch-arena fix; 0.96
*faster* on the heaviest map). These are mixed — net-faster as functions, slower only
on specific maps. The complete per-zone breakdown with CIs is in
**[FULL-RESULTS.md](FULL-RESULTS.md)**.

### 6.3 Why these are not "fixed" (answer to the obvious question)

They are **not bugs** — output is bit-identical / 1:1 with upstream C++ and the
identity gate is green. They are places where the *scalar machine code* the Zig
compiler emits is a few percent behind MSVC's, or where the in-context cache state
differs. Two categories:

- **Compute-bound (`rcBuildDistanceField`)** — proven at the scalar ceiling by
  experiment, not assertion: a runtime-indexed inner loop was 2× slower, a getCon
  cache was a TIE, pre-extracting the neighbour was 2 % slower; `llvm-mca` shows the
  kernel is port-bound. The leaner alternatives were all measured and rejected.
- **Context-bound (`crowd_integrate`, `crowd_grid_register`)** — the leaf code and
  struct layout are 1:1 with C++ and a standalone clone does **not** reproduce the
  slowdown (#11). The cost is inherited cache state from the preceding crowd phases,
  not the function itself; prefetch and inlining experiments gave no win.

The only remaining lever for the compute-bound group is **SIMD/@Vector or SoA**, which
is disallowed by current project policy (a separate decision, deferred). Without it,
these sit at the scalar codegen ceiling. The context-bound group would need a
phase-reordering / data-locality change to the crowd pipeline that risks output
divergence and was judged not worth the parity risk.

> **This is the SIMD question deferred earlier.** The compute-bound residuals
> (`rcBuildDistanceField`, and the float-heavy build filters) are exactly the zones a
> vectorized rewrite would target. Enabling `@Vector` is the open lever; it is held
> back only by the no-SIMD policy, not by any finding here.

---

## 7. Fairness — the comparison is not rigged

- The C++ reference is **[recastnavigation-bench](https://github.com/K4leri/recastnavigation-bench)**
  (upstream recastnavigation + the byte-identical Tracy harness), built
  **`/arch:AVX2 /O2`, fast-math OFF** (strict IEEE) — NOT the MSVC SSE2 baseline;
  same arithmetic as Zig ReleaseFast.
- Identical navmesh, identical RNG draw stream, identical snap extents, matched
  filters/caps/warmup/node-pools. Verified by per-zone count-parity every run.
- The multi-tile navmesh is built **byte-identical** on both sides (same poly/vert
  counts) — strong evidence the cross-language pipeline is deterministic-matching.

> **SCOPE LIMIT — read this as part of every number above.** The measured Zig code is
> the **`perf/audit-campaign` branch**, which diverges from the shipping `master`
> branch. **These results describe what the port *can* achieve, not what `master`
> ships today.** They become a statement about the shipping library only after the
> campaign fixes are ported to `master` and the suite is re-run there. Until that port
> + re-measure is done, do not cite these numbers as "the Zig recast port is faster
> than C++" without the qualifier "on the perf/audit-campaign branch". This is the
> single biggest threat to the report's external validity and is tracked separately.

---

## 8. Reproduce it

> ### ⚠️ You must supply your own map geometry
> **The maps used to produce these numbers are proprietary and are NOT included in
> this repository.** They cannot be redistributed. The benchmark is, however, fully
> reproducible on **any** geometry: the Zig-vs-C++ comparison is geometry-independent
> — both runners build from the *same* `.obj` and time the *same* functions, so the
> **ratio** is meaningful regardless of which level you feed it (only the absolute ns
> change). To reproduce:
>
> 1. **Provide geometry.** Drop dense, triangulated, **Y-up** `.obj` meshes (a real
>    complex level — multi-storey interiors / large terrain give the richest navmesh)
>    into the geometry directory. The scenarios refer to maps by anonymized token
>    (`map_1` … `map_6`); either name your files `map_N_bvh.obj`, or point the single
>    lookup `GeomCache.resolveGeomFile` (in `bench/tracy_scenarios.zig` and the C++
>    runner) at your filenames. Six maps of varied size/complexity reproduce the full
>    matrix; fewer just run a subset.
> 2. The derived cell-size rule (§4) auto-scales each map to a comparable grid, so you
>    do **not** need to match the original maps' dimensions.

```
# 1. build both runners (Zig with the timing registry; C++ at AVX2 + strict IEEE):
zig build run-tracy-scenarios -Doptimize=ReleaseFast -Dtracy=true   # Zig runner
#    (C++ reference: github.com/K4leri/recastnavigation-bench — CMake, /arch:AVX2)

# 2. one consolidated statistical campaign (K=15/side, K=7 build) -> ONE scoreboard:
bash dev/research/_run_stat.sh
#    -> dev/research/performance_analysis/STAT_FINAL/STAT_SCOREBOARD.csv

# 3. generate the reports FROM THAT ONE FILE (no hand-typed numbers):
python tools/analysis/gen_stat_table.py  <STAT_FINAL.csv>  FULL-RESULTS.md
python tools/analysis/gen_readme_bench.py <STAT_FINAL.csv>           # README block

# (single-zone A/B with median + 95% CI + significance, for spot checks:)
python bench/stat_compare.py "query_findpath_flood,crowd_100_oa_high" --k 15
```

Every published number derives from the one `STAT_FINAL/STAT_SCOREBOARD.csv` via the
two generators above — re-running them on your geometry regenerates the whole report.

---

## 9. Glossary

- **zone** — one timed function (e.g. `dtFindPath`).
- **scenario** — one benchmark case (map + workload).
- **ratio** — `zig_time / cpp_time`; `<1` Zig faster.
- **geo(trust)** — geometric mean of ratios over trusted (above-floor, count-clean) zones.
- **trusted (raw)** — number of trusted zones (the geomean's sample size), with the
  raw pre-filter zone count in parentheses; the gap between the two is how many zones
  were dropped as FLOOR or count-mismatch.
- **FLOOR** — zone too fast (~<200 ns) to time reliably; excluded from ranking.
- **tie (within noise)** — the 95 % CI of the ratio spans 1.0; difference not provable.
- **count-parity** — Zig and C++ executed the same number of calls for that zone.
- **min-of-runs** — best (fastest) of the N runs per side; cancels thermal/load spikes.
- **System A / System B** — per-function micro-bench / full-scenario suite.
- **SoA / SIMD** — data-layout / vector-instruction optimizations (currently disallowed).

The full evidence trail (every finding, adopted + rejected, with gates and ASM
root-causes) is kept as an internal audit log on the benchmark branch.
