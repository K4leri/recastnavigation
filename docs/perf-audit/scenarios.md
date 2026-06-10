# Benchmark Scenarios — Single Source of Truth (v3)

> **v3 (current).** The canonical run is **48 scenarios** (16 BUILD / 20 QUERY /
> 7 CROWD / 5 TILECACHE) — see §6 for the authoritative list and §7 for the
> un-deferred tilecache contract. Section bodies below still carry the v2 narrative for
> the original 29; the v3 additions are specified in §6/§7 and in `compare_min.py`'s
> `DEFAULT_SCENARIOS`. Where this file and `DEFAULT_SCENARIOS` disagree, the code wins.

This file is the **SINGLE SOURCE OF TRUTH** for the Tracy benchmark scenarios run by
**both** the Zig runner (`bench/tracy_scenarios.zig`) and the C++ runner
(`Bench/tracy_scenarios.cpp`). Every `scenario_id`, geometry name, config value,
iteration count, RNG seed/recurrence, metric-zone name, and caller-owned buffer cap
defined here is a **cross-language contract**: the two runners MUST implement
identical behavior so that per-zone Tracy self-times are directly comparable and the
CSV merge by `scenario_id` + zone name lines up exactly.

> **v2 vs v1 — what changed and why.** v1 assumed a single *sparse nav-area* mesh
> (`map_1.obj` / `_x4` / `_x16`) built at a **fixed `cs=0.3`**. That is
> **infeasible** for the real geometry: the dense BVH world meshes at `cs=0.3` produce
> 90M–825M heightfield cells per map (map_1 solo @cs0.3 ≈ 176M+ cells → OOM/hang).
> v2 therefore (1) switches all geometry to the **real dense BVH world meshes**
> (`<map>_bvh.obj`), and (2) **DERIVES the cell size** from a target cell budget so
> every map yields a comparable, feasible grid (~8M cells for the solo tier). A
> **hard cell-budget guard** (64M cells) is the safety net. Tiled scenarios keep a
> realistic fine `cs=0.3` but build only a **bounded central region** so tile count is
> finite. The LCG, query buffer caps / node pools / default filter / half_extents, the
> crowd OA presets / `update_flags` / 256-agent cap, and the "identical both languages"
> framing are **carried over unchanged** from v1.

Rules that hold for the whole file:

- A `scenario_id` is a unique `snake_case` key and is also the CSV column/row key.
- All numeric config is concrete and identical across languages. Where a value is
  derived (e.g. `cs = sqrt((dx*dz)/target_cells)`, `border_size = walkable_radius + 3`),
  the formula AND the resolved number per map are stated.
- Metric-zone names are the EXACT canonical Tracy `ZoneScopedN` / zone names. They
  must match byte-for-byte across Zig and C++ or the CSV merge breaks.
- The navmesh is built deterministically from the shared `.obj` geometry; the LCG
  draw **sequence** (including warmup draws and accept/reject re-rolls) is part of
  the contract and must be reproduced draw-for-draw in both languages.
- The **derived cell size** is computed identically in both languages from the loaded
  `.obj`'s XZ bounding box. Both runners MUST load the same `.obj`, derive the same
  bounds, and arrive at the same `cs`/`width`/`height` before building.

---

## 1. Geometry — Dense BVH World Meshes

All scenarios consume **dense BVH world meshes** exported from the test maps:
walkable-filtered triangle soup in **Recast Y-up space**, written to
`test_data/bench_geom/<map>_bvh.obj`. These are the *real collision world*, not the
sparse nav-area meshes assumed in v1.

Real measured per-map data (after walkable filtering, Recast Y-up):

| map | kept_tris | dx (X) | dy (height) | dz (Z) |
|---|---|---|---|---|
| `map_6`  | 36675  | 2751.8  | 14559.0 | 2981.1 |
| `map_5`     | 27111  | 11568.0 | 1538.9  | 6417.0 |
| `map_2`    | 55527  | 6729.0  | 1176.3  | 6440.1 |
| `map_4` | 122348 | 6126.0  | 1606.2  | 6904.0 |
| `map_1`  | 175551 | 5443.7  | 1389.8  | 5219.7 |
| `map_3`  | 568538 | 6917.1  | 1684.1  | 6600.2 |

`dx`/`dy`/`dz` are the bounding-box extents (`bmax - bmin`) along X/Y/Z. `dx`,`dz` are
the XZ footprint that drives the heightfield `width`×`height`; `dy` is the vertical
extent. **At `cs=0.3` the XZ grid is `(dx/cs)·(dz/cs)` = 90M–825M cells (infeasible);**
the derived-cs rule in §2 brings every map to ~8M cells.

### 1.1 Regeneration

The `.obj` files are **gitignored** (`test_data/bench_geom/` is in `.gitignore`; the
meshes are large and locally regenerable). Regenerate each map locally with the
exporter before running:

```
export_bench_geom.exe --bvh <map> test_data/bench_geom/<map>_bvh.obj
```

e.g. `export_bench_geom.exe --bvh map_1 test_data/bench_geom/map_1_bvh.obj`.
The walkable filter (slope/area) is applied inside the exporter, so the on-disk `.obj`
is already the `kept_tris` count above. Both runners load these files verbatim and
derive bounds from the loaded vertices.

---

## 2. Global Configuration

### 2.1 Deterministic RNG (LCG) — unchanged from v1

All randomness (sample points, start/goal pairs, agent spawns, goals, obstacle
placement, jitter, direction vectors, accept/reject re-rolls) is driven by a single
Linear Congruential Generator with a fixed seed. Both languages MUST use this exact
recurrence and seed:

```
seed    = 12345
state_0 = 12345
state_{n+1} = (state_n * 1664525 + 1013904223) mod 2^32   ; Numerical Recipes LCG
```

- 32-bit unsigned arithmetic, wrap mod 2^32 (overflow wraps; `u32` in both langs).
- **CONTRACT — advance first, then use the new state**: `state = next(state);
  f = state / 4294967296.0` (i.e. `state * 2^-32`), giving `f ∈ [0,1)`. Both langs
  identical.
- The draw sequence is global per scenario run: warmup draws consume from the same
  stream BEFORE the measured loop; re-rolls on rejected samples consume the next
  draws. The accept/reject decision must be byte-identical so both languages produce
  the same N valid samples/pairs.

### 2.2 DERIVED CELL SIZE — the key v2 contract

For **SOLO BUILD scenarios** (and the single navmeshes the QUERY/CROWD layers build),
the cell size is **NOT fixed**. It is DERIVED from a per-scenario `target_cells`
budget so that every map — regardless of footprint — lands at ~`target_cells` and is
both feasible and cross-map comparable. Compute it **identically** in Zig and C++ from
the loaded `.obj`'s XZ bounding box (`dx = bmax.x - bmin.x`, `dz = bmax.z - bmin.z`):

```
cs     = sqrt( (dx * dz) / target_cells )   // dx, dz from the loaded mesh's XZ bbox
ch     = cs * 0.5                            // cell height = half the cell size (fixed ratio)
width  = ceil( dx / cs )                     // integer ceil
height = ceil( dz / cs )                     // integer ceil
```

**Rounding contract (must be byte-identical):**
- `cs` is kept in **full f32 precision** (the raw `sqrt` result — do NOT round/snap it).
- `ch` = `cs * 0.5` in f32.
- `width`, `height` are computed by **integer ceil** of `dx/cs`, `dz/cs`
  (`(int)ceilf(dx/cs)`). Both runners use the same f32 division then `ceil`.
- Because `width·height = ceil(dx/cs)·ceil(dz/cs)` and `cs` is chosen so
  `(dx/cs)·(dz/cs) = target_cells`, the realized grid is `target_cells` plus at most
  one extra row+column of ceil slack (≈ `+width+height` cells) — well within tolerance.

Resolved derived values per map at `target_cells = 8,000,000` (the solo tier):

| map | dx | dz | cs (f32) | ch | width | height | grid cells |
|---|---|---|---|---|---|---|---|
| `map_6`  | 2751.8  | 2981.1 | 1.0126 | 0.5063 | 2718 | 2944 | 8,001,792 |
| `map_5`     | 11568.0 | 6417.0 | 3.0461 | 1.5230 | 3798 | 2107 | 8,002,386 |
| `map_2`    | 6729.0  | 6440.1 | 2.3274 | 1.1637 | 2892 | 2768 | 8,005,056 |
| `map_4` | 6126.0  | 6904.0 | 2.2993 | 1.1497 | 2665 | 3003 | 8,002,995 |
| `map_1`  | 5443.7  | 5219.7 | 1.8846 | 0.9423 | 2889 | 2770 | 8,002,530 |
| `map_3`  | 6917.1  | 6600.2 | 2.3889 | 1.1944 | 2896 | 2763 | 8,001,648 |

map_1 cs-sensitivity variants:

| target_cells | cs (f32) | ch | width | height | grid cells |
|---|---|---|---|---|---|
| 2,000,000  (coarse) | 3.7692 | 1.8846 | 1445 | 1385 | 2,001,325 |
| 8,000,000  (base)   | 1.8846 | 0.9423 | 2889 | 2770 | 8,002,530 |
| 24,000,000 (fine)   | 1.0881 | 0.5440 | 5003 | 4798 | 24,004,394 |

All of the above are **well under the 64M guard** (§2.3). The largest single solo grid
in the suite is map_1_fine @ 24M = 24.0M cells.

### 2.3 HARD CELL BUDGET GUARD — the safety net

Independent of the derived-cs math, **every scenario** (solo *and* tiled) computes its
total grid before building. The total grid is:
- solo: `width · height` (the derived grid above);
- tiled: `region_width · region_height` (the bounded central region, §2.5 — the full
  region grid, not per-tile).

If `total_grid_cells > 64_000_000` the runner **SKIPS** the scenario entirely (builds
nothing) and emits a single marker CSV row:

```
<scenario_id>,__SKIPPED_BUDGET__,0,0,0,0,0,0
```

(the `__SKIPPED_BUDGET__` sentinel takes the zone-name column; the remaining numeric
columns are all `0`). The merge tooling treats `__SKIPPED_BUDGET__` as "scenario did
not run". The `target_cells` values used in this file are all comfortably under the
cap, so the guard should never fire in practice — it exists only to catch a future
mistake (a bad `target_cells`, an over-large region, or a mis-loaded mesh).

### 2.4 Default Recast Build Config

Baseline build config shared by the BUILD scenarios (and the single navmeshes built
by QUERY/CROWD). `cs`/`ch` are **DERIVED per §2.2** (solo) or **fixed `cs=0.3`,
`ch=0.15`** (tiled). Per-scenario `config` columns override individual fields;
everything not overridden inherits these defaults.

| Field | Value | Notes |
|---|---|---|
| `cs` (cell size, xz) | **derived** (solo) / `0.3` (tiled) | §2.2 / §2.5 |
| `ch` (cell height, y) | **`cs * 0.5`** (solo) / `0.15` (tiled) | fixed ratio |
| `walkable_slope_angle` | `45` deg | |
| `walkable_height` | `10` cells | |
| `walkable_climb` | `4` cells | |
| `walkable_radius` | `2` cells | base agent; fat-agent probe uses `8`; query/crowd use `2` |
| `max_edge_len` | `12` | |
| `max_simplification_error` | `1.3` | |
| `min_region_area` | `8` | |
| `merge_region_area` | `20` | layers partition takes NO merge arg |
| `max_verts_per_poly` | `6` | |
| `detail_sample_dist` | `6.0` | dense-detail probe uses `1.5` |
| `detail_sample_max_error` | `1.0` | dense-detail probe uses `0.5` |
| `border_size` | `0` (solo) / `walkable_radius + 3 = 5` (tiled, radius=2) | recast convention `rcConfig.borderSize = walkableRadius + 3` |
| `tile_size` | `0` (solo) / `128`/`256` voxels (tiled) | in VOXELS; the contract is the voxel count, not world meters |
| `build_bv_tree` | `true` | required for findNearestPoly/queryPolygons BV descent |

> **Note on `walkable_height`/`climb`/`radius` units.** These are in **cells**. Because
> `cs`/`ch` are now derived and *coarser* than v1's 0.3/0.2 (e.g. map_1 `cs≈1.88`,
> `ch≈0.94`), a fixed cell count maps to a larger world span than in v1. This is
> accepted: the contract is the **cell count** (identical both langs), not the world
> meters. v1's larger cell counts (wh=20, climb=9, radius=8) were tuned for the fine
> 0.3/0.2 grid; v2 uses the coarser walkable defaults above so the eroded/walkable
> world-space stays sane on the derived grid.

### 2.5 TILED region rule

Tiled scenarios use a **FIXED `cs = 0.3`, `ch = 0.15`** (the realistic fine per-tile
resolution) but build only a **bounded central region** so the tile count is finite.

```
center = ( (bmin.x + bmax.x) / 2 , (bmin.z + bmax.z) / 2 )   // XZ center of the loaded mesh
region half-extent = 600 world units about center, on each of X and Z
region.xmin = max( bmin.x, center.x - 600 )
region.xmax = min( bmax.x, center.x + 600 )
region.zmin = max( bmin.z, center.z - 600 )
region.zmax = min( bmax.z, center.z + 600 )   // clamp to map bounds
```

This is a ~`1200 × 1200` world-unit region (clamped to map extents). At `cs=0.3` that
is `ceil(1200/0.3) = 4000` cells per side → **`4000 × 4000 = 16,000,000` region cells**
(under the 64M guard). With `tile_size = 128` voxels that is
`ceil(4000/128) = 32` tiles per side → **`32 × 32 = 1024` tiles** built independently.
`iters` is kept small (1–3) because the tiled region is heavy.

> **rcMergePolyMeshes is a Zig STUB (NotImplemented)** — carried over from v1. No tiled
> scenario merges polys across tiles; each tile is built and `dtAddTile`'d
> independently. The `rcMergePolyMeshes` zone is ABSENT/zero in tiled runs — do not
> expect it in the CSV.

### 2.6 Cross-cutting contracts — carried over from v1

- **Iteration counts are tuned inversely to per-build cost** so total wall-time stays
  comparable across BUILD scenarios. Each BUILD iteration is a FULL rebuild; Tracy
  self-time is averaged. Iteration counts MUST be identical in both languages.
- **QUERY default filter** = `include_flags=0xffff`, `exclude_flags=0`,
  `area_cost[*]=1.0` (matches C++ `dtQueryFilter` default). `half_extents={8,2000,8}` for
  all `findNearestPoly` snaps (SNAP-FIX: query points are drawn at the AABB y-center and
  map_1 is very tall — a small y-extent never reaches the floor → ref=0 → trivial
  findPath; the tall y-extent lets every XZ draw snap to its floor). Node pool sizes:
  `2048` for medium floods, `4096` for
  long-diagonal + sliced; `moveAlongSurface` uses the default tiny node pool.
  Caller-owned buffer caps (identical both langs): `findNearestPoly` internal poly
  buffer = 128 (hardcoded, not tunable); path 512 (flood) / 1024 (long+sliced);
  straight_path 256 verts; raycast hit 256; moveAlongSurface visited 16;
  findPolysAroundCircle result 512.
- **CROWD hard cap:** `Crowd.updateDebug` uses a fixed `[256]*CrowdAgent active_list`,
  so AT MOST 256 active agents are simulated per tick. The 500-agent tier is NOT
  safely realizable; `crowd_scale_250` uses 250 (largest fully-simulated count).
  Raising this requires an identical change on both sides.
- **CROWD obstacle-avoidance quality presets** (set via `setObstacleAvoidanceParams`,
  selected per-agent via `obstacle_avoidance_type`). Common to all:
  `grid_size=33, vel_bias=0.5, weight_des_vel=2.0, weight_cur_vel=0.75,
  weight_side=0.75, weight_toi=2.5, horiz_time=2.5`. Only the adaptive triple varies:

  | type | preset | adaptive_divs | adaptive_rings | adaptive_depth |
  |---|---|---|---|---|
  | 0 | LOW | 5 | 2 | 1 |
  | 1 | MEDIUM | 5 | 2 | 2 |
  | 2 | HIGH | 7 | 2 | 3 |
  | 3 | ULTRA | 7 | 3 | 3 |

- **CROWD update_flags:** `ALL = 31` (`anticipate_turns=1 | obstacle_avoid=2 |
  separation=4 | optimize_vis=8 | optimize_topo=16`). No-avoidance variant uses `29`
  (ALL minus `obstacle_avoid=2`). Scenarios set `update_flags` explicitly.
- Spatial setups (chokepoint, cluster center, corner-bands) are derived from the
  navmesh `bmin`/`bmax` and hardcoded per `scenario_id` as fixed world coords so they
  land on identical polys in both ports.

---

## 3. BUILD Layer (14 scenarios)

Recast pipeline run per-zone on the dense BVH geometry. Solo = single-tile (derived
`cs`/`ch` per §2.2, `border_size=0`); tiled = bounded central region (`cs=0.3`,
`ch=0.15`, §2.5) split into a voxel grid, each tile built and `dtAddTile`'d
independently (no merge). `target_cells` is the solo budget that fixes the derived
`cs`. Zone names are the canonical Recast `ZoneScopedN` names. Default recast params
per §2.4 unless overridden in the config cell.

**metric_zones (BUILD, full pipeline):** `rcRasterizeTriangles`,
`rcFilterLowHangingWalkableObstacles`, `rcFilterLedgeSpans`,
`rcFilterWalkableLowHeightSpans`, `rcBuildCompactHeightfield`, `rcErodeWalkableArea`,
`rcBuildDistanceField` *(watershed only)*, `rcBuildRegions` / `rcBuildRegionsMonotone`
/ `rcBuildLayerRegions` *(per partition)*, `rcBuildContours`, `rcBuildPolyMesh`,
`rcBuildPolyMeshDetail`, `dtCreateNavMeshData`. Each row's `metric_zones` lists the
subset that fires for that partition/probe.

| scenario_id | geometry | derived/fixed cs & key cfg | partition | iters | metric_zones | expected_bottleneck |
|---|---|---|---|---|---|---|
| `build_solo_watershed_map_6` | `map_6_bvh` | SOLO derived: target_cells=8M → cs≈1.0126, ch≈0.5063, w=2718,h=2944 (8.00M cells); border_size=0; defaults §2.4 | watershed | 5 | full pipeline (incl. rcBuildDistanceField + rcBuildRegions) | rcBuildDistanceField + rcBuildRegions (watershed flood). Smallest map by footprint but tall (dy=14559) → many vertical spans/column; rasterize + filter notable. |
| `build_solo_watershed_map_5` | `map_5_bvh` | SOLO derived: target_cells=8M → cs≈3.0461, ch≈1.5230, w=3798,h=2107 (8.00M cells); border_size=0; defaults §2.4 | watershed | 5 | full pipeline | rcBuildDistanceField + rcBuildRegions. Lowest tri count (27k) + thin vertical extent → rasterize cheap, region flood dominates. |
| `build_solo_watershed_map_2` | `map_2_bvh` | SOLO derived: target_cells=8M → cs≈2.3274, ch≈1.1637, w=2892,h=2768 (8.01M cells); border_size=0; defaults §2.4 | watershed | 5 | full pipeline | rcBuildDistanceField + rcBuildRegions. Mid tri count, open layout → clean watershed baseline; also the CROWD navmesh source. |
| `build_solo_watershed_map_4` | `map_4_bvh` | SOLO derived: target_cells=8M → cs≈2.2993, ch≈1.1497, w=2665,h=3003 (8.00M cells); border_size=0; defaults §2.4 | watershed | 4 | full pipeline | rcBuildDistanceField + rcBuildRegions; 122k tris pushes rcRasterizeTriangles up vs dust2. Multi-level overpass geometry → more regions. |
| `build_solo_watershed_map_1` | `map_1_bvh` | SOLO derived: target_cells=8M → cs≈1.8846, ch≈0.9423, w=2889,h=2770 (8.00M cells); border_size=0; defaults §2.4 | watershed | 4 | full pipeline | rcBuildDistanceField + rcBuildRegions. The reference map: also the QUERY navmesh source. Canonical per-zone calibration baseline. |
| `build_solo_watershed_map_3` | `map_3_bvh` | SOLO derived: target_cells=8M → cs≈2.3889, ch≈1.1944, w=2896,h=2763 (8.00M cells); border_size=0; defaults §2.4 | watershed | 3 | full pipeline | rcRasterizeTriangles climbs hard (568k tris, ~3–15x the others) → triangle-clip front competes with rcBuildDistanceField. Heaviest solo build (fewest iters). |
| `build_solo_monotone_map_1` | `map_1_bvh` | SOLO derived: target_cells=8M → cs≈1.8846, ch≈0.9423, w=2889,h=2770; monotone (NO distance field); border_size=0; defaults §2.4 | monotone (`rcBuildRegionsMonotone`) | 4 | rcRasterizeTriangles, rcFilter*, rcBuildCompactHeightfield, rcErodeWalkableArea, rcBuildRegionsMonotone, rcBuildContours, rcBuildPolyMesh, rcBuildPolyMeshDetail, dtCreateNavMeshData | rcBuildRegionsMonotone skips the distance field and sweeps in scanlines → region self-time far below watershed, BUT longer/less-regular boundaries shift cost downstream into rcBuildContours + rcBuildPolyMesh. The interesting delta is the downstream shift vs `build_solo_watershed_map_1`. |
| `build_solo_layers_map_1` | `map_1_bvh` | SOLO derived: target_cells=8M → cs≈1.8846, ch≈0.9423, w=2889,h=2770; layers (`rcBuildLayerRegions`; takes min_region_area, **NO merge_region_area arg**); border_size=0; defaults §2.4 | layers (`rcBuildLayerRegions`) | 4 | rcRasterizeTriangles, rcFilter*, rcBuildCompactHeightfield, rcErodeWalkableArea, rcBuildLayerRegions, rcBuildContours, rcBuildPolyMesh, rcBuildPolyMeshDetail, dtCreateNavMeshData | rcBuildLayerRegions: monotone-style sweep + 2D-layer overlap/merge bookkeeping; NO distance field. map_1's overpass/balcony overlap forces multiple layers, exercising the layer-merge loops unique to this path. |
| `build_solo_watershed_map_1_coarse` | `map_1_bvh` | SOLO derived: target_cells=**2M** → cs≈3.7692, ch≈1.8846, w=1445,h=1385 (2.00M cells); border_size=0; defaults §2.4 | watershed | 6 | full pipeline | Coarse end of the cs-sensitivity sweep: ~1/4 the cells of base → rcBuildDistanceField/rcBuildRegions shrink super-linearly; fixed per-call overheads (alloc, header) become a larger share. Lower bound of per-zone-vs-resolution curve on map_1. |
| `build_solo_watershed_map_1_fine` | `map_1_bvh` | SOLO derived: target_cells=**24M** → cs≈1.0881, ch≈0.5440, w=5003,h=4798 (24.0M cells); border_size=0; defaults §2.4 | watershed | 2 | full pipeline | Fine end of the cs-sensitivity sweep: ~3x base cells → rcBuildDistanceField + rcBuildRegions explode super-linearly (per-span neighbor walks → cache pressure); rcRasterizeTriangles grows (more spans/triangle). Largest single solo grid in the suite (still < 64M guard). |
| `build_solo_watershed_map_1_fat_agent` | `map_1_bvh` | SOLO derived: target_cells=8M → cs≈1.8846, ch≈0.9423, w=2889,h=2770; **walkable_radius=8** (4x base); border_size=0; other defaults §2.4 | watershed | 4 | rcErodeWalkableArea, rcBuildDistanceField, rcBuildRegions, rcBuildContours | rcErodeWalkableArea: erosion scales with walkable_radius (boundary pushed inward radius times via repeated neighbor passes), so 4x radius makes this normally-cheap stage prominent. Dedicated probe for the erosion sweep on the derived grid. |
| `build_solo_watershed_map_1_dense_detail` | `map_1_bvh` | SOLO derived: target_cells=8M → cs≈1.8846, ch≈0.9423, w=2889,h=2770; **detail_sample_dist=1.5, detail_sample_max_error=0.5** (DENSE, 4x finer); other defaults §2.4 | watershed | 3 | rcBuildPolyMesh, rcBuildPolyMeshDetail | rcBuildPolyMeshDetail: detail cost ∝ 1/detail_sample_dist; cutting 6.0→1.5 multiplies sample points ~16x/poly and drives Delaunay/seed-point loops. Detail mesh becomes the single largest stage. Only scenario with meaningful detail-mesh self-time. |
| `build_tiled_watershed_map_3_region` | `map_3_bvh` | TILED FIXED: cs=0.3, ch=0.15; central 600-unit half-extent region (1200×1200 → 4000×4000=16.0M region cells); tile_size=128 voxels (32×32=1024 tiles); border_size=walkable_radius+3=5; defaults §2.4 | watershed (per tile) | 2 | rcRasterizeTriangles, rcBuildCompactHeightfield, rcBuildDistanceField, rcBuildRegions, rcBuildContours, rcBuildPolyMesh, rcBuildPolyMeshDetail, dtCreateNavMeshData | Aggregate over 1024 tiles: every zone fires once PER TILE, so fixed per-call setup/teardown + border-span (border_size=5) handling are paid ~1024×. dtCreateNavMeshData + rcBuildContours + rcBuildPolyMesh rise from the per-tile fixed cost. Canonical tiled baseline on the heaviest map's central region. |
| `build_tiled_layers_map_4_region` | `map_4_bvh` | TILED FIXED: cs=0.3, ch=0.15; central 600-unit half-extent region (4000×4000=16.0M region cells); tile_size=128 voxels (32×32=1024 tiles); layers partition (NO merge_region_area); border_size=walkable_radius+3=5; defaults §2.4 | layers (`rcBuildLayerRegions`, per tile) | 2 | rcRasterizeTriangles, rcBuildCompactHeightfield, rcBuildLayerRegions, rcBuildContours, rcBuildPolyMesh, dtCreateNavMeshData | rcBuildLayerRegions aggregated over all tiles: layer-overlap/merge bookkeeping per tile (its whole purpose for tiled builds). Overpass's multi-level geometry produces several layers per tile; skips rcBuildDistanceField entirely. Layers+tiling = the intended real-world pairing. |

---

## 4. QUERY Layer (8 scenarios)

> **SNAP-FIX (applied — both languages now agree).** All `findNearestPoly` snaps use
> `half_extents = {8, 2000, 8}` and **uniform-AABB draws for ALL pairs** (the corner-band variant is
> retired; the long-diagonal and sliced scenarios draw both endpoints with the same uniform-AABB
> helper as the flood scenarios — the `long`/`long_pair` flag is kept at the call sites for clarity
> but no longer changes the draw). Reason: query points are drawn at the AABB y-center and map_1
> is very tall (y∈[-212,1178]), so a small y-extent (`4`) snaps essentially NOWHERE → `findNearestPoly`
> returns ref=0 → `findPath(0,0)` early-returns InvalidParam in ~0.074 µs and the comparison measures
> NOTHING. The tall y-extent lets every XZ draw over walkable surface snap to its floor regardless of
> elevation. Draw-sequence parity is preserved: `drawPointInAabb` consumes exactly 2 LCG draws (x then
> z; y = AABB center, no draw), the same count the retired `drawPointInCorner` consumed, so the cross-
> language LCG stream stays identical draw-for-draw. Mirrors C++ `kHalfExtentsDefault = {8,2000,8}` and
> `drawValidPair`'s `(void)long_pair;` in `recastnavigation-bench/Bench/tracy_scenarios.cpp`.

The navmesh is built **ONCE** for all QUERY scenarios via watershed, solo single-mesh
on **`map_1_bvh`** at the derived `target_cells=8M` config (`cs≈1.8846,
ch≈0.9423, w=2889, h=2770`) — one large connected graph → max A* pressure. The QUERY
recast cfg is the standard derived-cs build with `walkable_radius=2` and the other
defaults from §2.4 (`walkable_height=10, walkable_climb=4, max_edge_len=12,
max_simplification_error=1.3, min_region_area=8, merge_region_area=20,
max_verts_per_poly=6, detail_sample_dist=6.0, detail_sample_max_error=1.0,
border_size=0, build_bv_tree=true`). The graph is byte-identical across all 8 QUERY
scenarios so only the function-under-test varies. Prerequisite snaps / precomputed
corridors run OUTSIDE the measured zone.

**metric_zones (QUERY)** = the `dt*` query functions + their deep helpers, per row.

| scenario_id | geometry (navmesh) | config | metric_zones | expected_bottleneck |
|---|---|---|---|---|
| `query_findnearestpoly_flood` | `map_1_bvh` @8M | node_pool=2048; N=2000 points uniform in navmesh AABB (x,z uniform; y=AABB center); half_extents={8,2000,8}; default filter; findNearestPoly per point, no pathfinding; warmup=200 points (consume same stream) | dtFindNearestPoly, queryPolygons, dtQueryPolygonsInTile, closestPointOnPoly, closestPointOnPolyBoundary | BVTree AABB descent in queryPolygons (dtQueryPolygonsInTile) + per-candidate closestPointOnPoly distance eval; pure point-location with zero A* noise. Deep BV tree, many candidate polys per query box. |
| `query_findpath_flood` | `map_1_bvh` @8M | node_pool=2048; N=2000 (start,goal) pairs: draw 2 points in AABB, snap via findNearestPoly(half_extents={8,2000,8}); if either ref==0 re-roll from same stream until both valid; path cap=512; default filter; findPath only (snap measured separately/excluded); warmup=50 pairs | dtFindPath, dtNode_pool_get, getPortalPoints, getEdgeMidPoint, passLinkFilter, dtNodeQueue_push_pop | A* core: binary-heap push/pop + node-pool hash lookups + per-edge getPortalPoints/getEdgeMidPoint cost eval over realistic length/branching distribution. node_pool=2048 may saturate on longer pairs (pool-full handling identical both langs). |
| `query_findpath_long_diagonal` | `map_1_bvh` @8M | node_pool=4096; N=2000 pairs: draw 2 points uniform in AABB (uniform-AABB, NOT corner-band — the corner-band variant is retired under the SNAP-FIX; the `long` flag is kept at the call site but no longer changes the draw, matching C++ `(void)long_pair;`), snap both (half_extents={8,2000,8}), re-roll invalid from same stream; path cap=1024; default filter; findPath only; warmup=50 | dtFindPath, dtNodeQueue_push_pop, dtNode_pool_get, getEdgeMidPoint, passLinkFilter | Worst-case A* expansion: max graph diameter → largest open-list, deepest node-pool, most heap rebalances. node_pool=4096 avoids premature OUT_OF_NODES truncation. Heaviest single-query path zones of the suite (cross-map diagonals). |
| `query_findstraightpath_flood` | `map_1_bvh` @8M | node_pool=2048; N=2000 pairs (identical stream to query_findpath_flood); precompute findPath corridors ONCE (excluded), store corridors+endpoints; measured loop: findStraightPath per corridor; straight_path cap=256; options=0 (no _CROSSINGS); flags+refs buffers populated; default filter; warmup=50 corridors | dtFindStraightPath, appendVertex, appendPortals, getPortalPoints, triArea2D_vequal | Funnel/string-pulling: left/right apex advance (triArea2D) + per-portal getPortalPoints + appendVertex buffer writes, isolated from A*. Long real corridors → many portals per pull. |
| `query_raycast_flood` | `map_1_bvh` @8M | node_pool=2048; N=2000 (start,end): draw start in AABB, snap via findNearestPoly(half_extents={8,2000,8}) → start_ref (re-roll invalid from same stream); end = start_pos + unit_dir·35.0 (dir = normalize(rx-0.5, rz-0.5) from next 2 LCG draws); RaycastHit path cap=256; options=0; prev_ref=0; default filter; raycast; warmup=50 | dtRaycast, getPortalPoints, intersectSegmentPoly2D, getPolyHeight, dtNextLink_iterate | Per-poly segment/edge intersection (intersectSegmentPoly2D) + neighbor-link walk along the ray. Fixed 35u ray crosses several polys; pure straight-line walk, no heap → isolates the raycast inner loop. |
| `query_movealongsurface_flood` | `map_1_bvh` @8M | tiny_node_pool=default; N=2000: draw start, snap via findNearestPoly(half_extents={8,2000,8}) → start_ref (re-roll invalid from same stream); end_pos = start_pos + dir·5.0 (dir from 2 LCG draws, normalized); visited cap=16; default filter; moveAlongSurface; warmup=50 | dtMoveAlongSurface, tinyNodePool_get, getPortalPoints, distancePtSegSqr2D, intersectSegmentPoly2D | Constrained surface walk over the tiny node pool: local poly-neighbor BFS + per-edge wall-clamp (distancePtSegSqr2D). step=5u keeps it local; tests the small-allocation hot path distinct from full A*. Highest production call frequency. |
| `query_findpolysaroundcircle_radius_sweep` | `map_1_bvh` @8M | node_pool=2048; N=2000 centers: draw center, snap via findNearestPoly(half_extents={8,2000,8}) → start_ref (re-roll invalid from same stream); radius = [8.0, 24.0, 64.0][i % 3] world units; result_ref/parent/cost caps=512; default filter; findPolysAroundCircle; warmup=50 | dtFindPolysAroundCircle, dtNodeQueue_push_pop, dtNode_pool_get, getPortalPoints, passLinkFilter | Dijkstra-style cost-bounded flood from center: open-list churn + node-pool fill growing with radius. radius=64 fills hundreds of polys (approaches 512 cap / pool 2048 pressure); radius=8 tiny. 3-radius sweep maps cost-vs-area scaling. |
| `query_slicedpath_budget32` | `map_1_bvh` @8M | node_pool=4096; N=2000 uniform-AABB pairs (identical stream to query_findpath_long_diagonal — both now uniform-AABB, corner-band retired), snap both (half_extents={8,2000,8}); default filter; options=0 (no any-angle); per pair: initSlicedFindPath, loop updateSlicedFindPath(max_iter=32, &done_iters) until status≠in_progress, finalizeSlicedFindPath(path cap=1024); count total update calls; warmup=20 pairs | initSlicedFindPath, updateSlicedFindPath, finalizeSlicedFindPath, dtNodeQueue_push_pop, getEdgeMidPoint | Time-sliced A* with maxIter=32 → many resume cycles per long path; per-update zone shows fixed 32-node expansion + state save/restore between slices. Long diagonals maximize update-call count; finalize runs full back-trace + reverse. Incremental-query path distinct from one-shot findPath. |

---

## 5. CROWD Layer (7 scenarios)

The navmesh is built **ONCE** at startup (build cost NOT measured) via watershed, solo
single-mesh on **`map_2_bvh`** at the derived `target_cells=8M` config (`cs≈2.3274,
ch≈1.1637, w=2892, h=2768`) — a real open map, well suited to crowds — then the M-tick
crowd loop is profiled. Common recast cfg = the standard derived-cs build with
`walkable_radius=2` (§2.4). Also export the scalar `getVelocitySampleCount()` per tick
(cleanest proxy for total OA work). OA quality presets and `update_flags` per §2.6.
Spatial setups (choke / cluster) are derived from the navmesh `bmin`/`bmax` and
hardcoded as fixed world coords so both langs land on identical polys.

**metric_zones (CROWD)** = the crowd phase zones: `crowd_update_total`,
`crowd_check_path_validity`, `crowd_update_move_request`, `crowd_path_queue_update`,
`crowd_grid_register`, `crowd_neighbor_find`, `crowd_find_corners`,
`crowd_optimize_visibility` *(merged into `crowd_find_corners` — see note)*,
`crowd_steering_separation`, `crowd_velocity_planning_oa`, `crowd_integrate`,
`crowd_collision_resolve`, `crowd_move_position`, `crowd_topology_opt`. Each row lists
the subset of interest.

> **`crowd_optimize_visibility` note:** the visibility-optimization pass is **merged
> into `crowd_find_corners`** (it runs inside the corner-finding phase). If a runner
> does not emit a separate `crowd_optimize_visibility` zone, its cost is accounted for
> inside `crowd_find_corners`; both langs must treat it identically (either both split
> it out or both fold it in — the contract is: fold into `crowd_find_corners`).

| scenario_id | geometry (navmesh) | config | metric_zones | expected_bottleneck |
|---|---|---|---|---|
| `crowd_baseline_25_oa_low` | `map_2_bvh` @8M | N=25 agents; ticks=600 (10s @ dt=1/60); agent: radius=0.6, height=2.0, max_acceleration=8.0, max_speed=3.5, collision_query_range=2.5, path_optimization_range=30.0, separation_weight=2.0, update_flags=ALL(31), oa_type=0 (LOW: divs=5,rings=2,depth=1); fixed per-agent cross-map goals at add (LCG seed=12345), no re-target; Crowd.init(max_agents=50, max_agent_radius=0.6) | crowd_update_total, crowd_check_path_validity, crowd_update_move_request, crowd_path_queue_update, crowd_grid_register, crowd_neighbor_find, crowd_find_corners, crowd_steering_separation, crowd_velocity_planning_oa, crowd_integrate, crowd_collision_resolve, crowd_move_position, crowd_topology_opt | crowd_velocity_planning_oa (sampleVelocityAdaptive) + crowd_move_position (corridor.movePosition → moveAlongSurface) dominate steady-state; at 25 sparse agents neighbor lists are small so per-agent OA sample cost is the single biggest term. Clean per-agent cost floor that all crowd scenarios are read against. |
| `crowd_100_oa_high` | `map_2_bvh` @8M | as baseline; N=100; ticks=600; agent params identical EXCEPT oa_type=2 (HIGH: divs=7,rings=2,depth=3); fixed per-agent goals (LCG seed=12345), no re-target; Crowd.init(max_agents=200, max_agent_radius=0.6) | crowd_update_total, crowd_check_path_validity, crowd_update_move_request, crowd_path_queue_update, crowd_grid_register, crowd_neighbor_find, crowd_find_corners, crowd_steering_separation, crowd_velocity_planning_oa, crowd_integrate, crowd_collision_resolve, crowd_move_position, crowd_topology_opt | crowd_velocity_planning_oa balloons: depth=3 + divs=7 → far more sample evals/agent; at 100 agents neighbor lists (cap MAX_NEIGHBOURS=6) consistently full so each sample iterates 6 circles + boundary segments. velocity_sample_count is the primary scalar; crowd_neighbor_find second as density rises. |
| `crowd_100_no_avoidance` | `map_2_bvh` @8M | identical to crowd_100_oa_high in EVERY way (N=100, ticks=600, same goals) EXCEPT update_flags=29 (clears obstacle_avoid=2); oa_type irrelevant; Crowd.init(max_agents=200, max_agent_radius=0.6) | crowd_update_total, crowd_check_path_validity, crowd_update_move_request, crowd_path_queue_update, crowd_grid_register, crowd_neighbor_find, crowd_find_corners, crowd_steering_separation, crowd_velocity_planning_oa, crowd_integrate, crowd_collision_resolve, crowd_move_position | crowd_velocity_planning_oa collapses to a trivial vcopy(nvel←dvel) per agent (else-branch, velocity_sample_count==0). Bottleneck shifts to crowd_move_position + crowd_collision_resolve (4-iter penetration solver runs UNCONDITIONALLY) + crowd_neighbor_find. A/B vs crowd_100_oa_high quantifies the absolute cost of the entire obstacle-avoidance subsystem. |
| `crowd_choke_funnel_60_oa_high` | `map_2_bvh` @8M | N=60; ticks=900 (15s); agent: radius=0.6, height=2.0, max_acceleration=8.0, max_speed=3.5, collision_query_range=3.0, path_optimization_range=30.0, separation_weight=4.0 (aggressive), update_flags=ALL(31), oa_type=3 (ULTRA: divs=7,rings=3,depth=3); SPATIAL: all 60 spawned one side of the narrowest walkable funnel on map_2 (~2-3m doorway via hardcoded bmin/bmax band) with a SINGLE shared goal poly far side → all forced through same chokepoint; no re-target; Crowd.init(max_agents=128, max_agent_radius=0.6) | crowd_update_total, crowd_neighbor_find, crowd_steering_separation, crowd_velocity_planning_oa, crowd_collision_resolve, crowd_move_position, crowd_check_path_validity, crowd_find_corners | crowd_collision_resolve + crowd_velocity_planning_oa both spike during the jam: every agent's 6 neighbor slots saturated → 4-iter solver does max work; ULTRA OA + nearly all sample dirs blocked → highest velocity_sample_count of any scenario (deep adaptive recursion). crowd_move_position rises (repeated wall clamps); secondary crowd_check_path_validity replan churn. |
| `crowd_mass_repath_100_shared_moving_goal` | `map_2_bvh` @8M | N=100 spread (deterministic LCG starts); ticks=1200 (20s); agent params identical to crowd_100_oa_high (oa_type=2 HIGH, update_flags=ALL(31), separation_weight=2.0); BEHAVIOR: single shared goal that MOVES — every 120 ticks (2s) compute one new shared goal poly (next point on a fixed deterministic patrol loop, same sequence both langs) and requestMoveTarget(idx, sharedRef, &sharedPos) to ALL 100 agents on the SAME tick → 10 synchronized mass-repath events; Crowd.init(max_agents=200, max_agent_radius=0.6) | crowd_update_total, crowd_update_move_request, crowd_path_queue_update, crowd_check_path_validity, crowd_find_corners, crowd_velocity_planning_oa, crowd_neighbor_find, crowd_move_position | crowd_update_move_request becomes a periodic giant spike on the 10 repath ticks: updateMoveRequest runs a SYNCHRONOUS navquery.findPath per requesting agent → all 100 A* simultaneously (plus path_queue.request submissions feeding crowd_path_queue_update). Metric of interest: per-tick max/distribution of crowd_update_move_request vs near-zero steady-state. Isolates findPath-from-crowd cost. |
| `crowd_separation_spread_120_no_goal` | `map_2_bvh` @8M | N=120 TIGHTLY CLUSTERED in one open area (~6m radius blob, deterministic LCG jitter around one center poly, heavily overlapping); ticks=600 (10s); agent: radius=0.6, height=2.0, max_acceleration=8.0, max_speed=3.5, collision_query_range=4.0 (wide), path_optimization_range=30.0, separation_weight=4.0 (strong), update_flags=ALL(31), oa_type=1 (MEDIUM: divs=5,rings=2,depth=2); BEHAVIOR: NO move target (target_state=target_none) so dvel comes only from separation push-apart; agents disperse via separation + collision; Crowd.init(max_agents=200, max_agent_radius=0.6) | crowd_update_total, crowd_grid_register, crowd_neighbor_find, crowd_steering_separation, crowd_collision_resolve, crowd_velocity_planning_oa, crowd_move_position, crowd_check_path_validity | Early ticks: crowd_collision_resolve + crowd_steering_separation dominate (120 agents mutually overlapping, every neighbor slot full, the dist<0.0001 co-located fallback fires often). crowd_neighbor_find/crowd_grid_register stressed by dense proximity-grid queryItems (range=4.0). With target_none, crowd_find_corners/crowd_update_move_request near-zero → cleanly isolates separation+collision subsystem from path following. |
| `crowd_scale_250_oa_med` | `map_2_bvh` @8M | N=250 (just under hard 256-agent cap); ticks=600 (10s); agent: radius=0.6, height=2.0, max_acceleration=8.0, max_speed=3.5, collision_query_range=2.5, path_optimization_range=30.0, separation_weight=2.0, update_flags=ALL(31), oa_type=1 (MEDIUM: divs=5,rings=2,depth=2); fixed per-agent long cross-map goals at add (LCG seed=12345), no re-target; Crowd.init(max_agents=256, max_agent_radius=0.6) | crowd_update_total, crowd_velocity_planning_oa, crowd_neighbor_find, crowd_grid_register, crowd_steering_separation, crowd_collision_resolve, crowd_move_position, crowd_find_corners, crowd_check_path_validity, crowd_update_move_request | Aggregate crowd_update_total scales ~linearly in agent count for O(N) phases (velocity_planning_oa, find_corners, move_position, integrate); crowd_neighbor_find scales with local density. At 250 the dominant absolute cost is crowd_velocity_planning_oa summed over all agents, crowd_move_position second. Throughput/scaling scenario on the real (large) map_2 map — no replica geometry needed; extract per-agent slope per language vs 25/100 points. |

---

## 6. Canonical scenario_id Set

The complete, de-duplicated set of `scenario_id` values the runners MUST implement.

> **v3 update (this is what the FINAL_campaign_v3 scoreboard actually ran).** The set
> grew from the original v2 29 to **48 scenarios: 16 BUILD + 20 QUERY + 7 CROWD +
> 5 TILECACHE**. Additions since v2: BUILD gained `build_solo_offmesh_map_1`
> (off-mesh connections) and 3 more tiled-region maps (`map_2`, `map_1` +
> the existing inferno/overpass); QUERY gained 12 functions (straightpath_crossings,
> findpolysaroundshape, findlocalneighbourhood, findrandompoint(+aroundcircle),
> finddistancetowall, getpolyheight, isvalidpolyref, getpolywallsegments) plus the
> 3 `multitile_*` arms; **TILECACHE is no longer deferred** — see the un-deferred §7.
> Two v2 ids were dropped from the default run: `build_solo_watershed_map_1_fine`
> (24 M-cell, very slow) and `query_findpath_long_diagonal` is retained. The
> authoritative list is `DEFAULT_SCENARIOS` in `bench/compare_min.py`.

```
build_solo_watershed_map_6
build_solo_watershed_map_5
build_solo_watershed_map_2
build_solo_watershed_map_4
build_solo_watershed_map_1
build_solo_watershed_map_3
build_solo_monotone_map_1
build_solo_layers_map_1
build_solo_watershed_map_1_coarse
build_solo_watershed_map_1_fat_agent
build_solo_watershed_map_1_dense_detail
build_solo_offmesh_map_1
build_tiled_watershed_map_3_region
build_tiled_layers_map_4_region
build_tiled_watershed_map_2_region
build_tiled_watershed_map_1_region
query_findnearestpoly_flood
query_findpath_flood
query_findpath_long_diagonal
query_findstraightpath_flood
query_findstraightpath_crossings
query_raycast_flood
query_movealongsurface_flood
query_findpolysaroundcircle_radius_sweep
query_findpolysaroundshape_convex_sweep
query_findlocalneighbourhood_radius_sweep
query_findrandompoint_area_weighted
query_findrandompointaroundcircle_radius_sweep
query_finddistancetowall_radius_sweep
query_getpolyheight_snapped
query_isvalidpolyref_snapped
query_getpolywallsegments_portals
query_slicedpath_budget32
query_multitile_findpath
query_multitile_straightpath
query_multitile_raycast
crowd_baseline_25_oa_low
crowd_100_oa_high
crowd_100_no_avoidance
crowd_choke_funnel_60_oa_high
crowd_mass_repath_100_shared_moving_goal
crowd_separation_spread_120_no_goal
crowd_scale_250_oa_med
tilecache_obstacles_map_2
tilecache_cylinders_map_2
tilecache_orientedbox_map_2
tilecache_dense_box_map_2
tilecache_obstacles_map_3
```

**QUERY multitile arms** (`query_multitile_{findpath,straightpath,raycast}`): a single
*connected tiled* `map_3_bvh` navmesh (central region, half-extent 300 world
units, `tile_size = 128` voxels, `cs = 0.3`, per-tile poly cap `2^14`,
`node_pool = 4096`); same per-kind measured loops (N = 2000) as the solo arms but over
cross-tile paths. **BUILD multimap tiled** (`build_tiled_watershed_de_{dust2,ancient}_region`):
same tiled rule as §2.5. **BUILD offmesh** (`build_solo_offmesh_map_1`): the
standard map_1 @8M solo build with **32 off-mesh connections** wired into the tile
(exercises `baseOffMeshLinks`), iters = 4.

---

## 7. TILECACHE Layer (5 scenarios) — un-deferred in v3

> **History.** The v1 tilecache layer was deferred because its zones were named
> map-region zones (`door_corridor`, …) that did not fit per-function comparison. v3
> re-introduces tilecache with **per-function engine zones** (the `dtTileCache*`
> rebuild chain), so it now fits the same self-time methodology as the other layers.

DetourTileCache dynamic-obstacle scenarios on a bounded central region. Each measured
run does **3 cycles** of `{ add N obstacles → dtTileCacheUpdate (rebuild touched tiles)
→ remove all → dtTileCacheUpdate }`. Both languages MUST place obstacles from the
shared LCG draw stream and rebuild byte-identically (count-parity gate enforces it).

**Geometry / region (identical both langs):** `map_2_bvh` (4 scenarios) or
`map_3_bvh` (1); central region **half-extent 300 world units** about the XZ
center; `cs = 0.3`, `ch = 0.15`; `tile_size = 48` voxels (interior, before border).
Build params: `walkable_slope_angle = 45`, `walkable_height = 10`, `walkable_climb = 4`,
`walkable_radius = 2`, `max_simplification_error = 1.3`.

**metric_zones (TILECACHE):** `dtTileCacheAddBoxObstacle` / `…AddObstacle`
(shape-dependent), `dtTileCacheUpdate`, `dtDecompressTileCacheLayer`,
`dtBuildTileCacheRegions`, `dtBuildTileCacheContours`, `dtBuildTileCachePolyMesh`,
`dtTileCacheBuildNavMeshTile`, `dtCreateNavMeshData`.

| scenario_id | geometry | obstacles / cycle | obstacle shape | notes |
|---|---|---|---|---|
| `tilecache_obstacles_map_2` | `map_2_bvh` | 16 | axis-aligned box | baseline box carve |
| `tilecache_cylinders_map_2` | `map_2_bvh` | 16 | cylinder | cylinder carve path |
| `tilecache_orientedbox_map_2` | `map_2_bvh` | 16 | oriented box | rotated-AABB carve path |
| `tilecache_dense_box_map_2` | `map_2_bvh` | 64 | box | density stress (4× obstacles) |
| `tilecache_obstacles_map_3` | `map_3_bvh` | 16 | box | heaviest map |

> **Bench compressor is a no-op (store-only memcpy).** `dtDecompressTileCacheLayer` in
> the bench therefore times header-parse + blob unpack, NOT real decompression — both
> languages use the identical no-op compressor so the comparison is still fair, but the
> absolute decompress cost is not representative of a real LZ compressor.
