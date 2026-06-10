# Zone reference — what each benchmarked function does

A **zone** is one timed function inside a layer (e.g. `dtFindPath`). This file is the
glossary the perf reports point at: it maps every zone name that appears in
[FINAL-REPORT.md](FINAL-REPORT.md) and [FULL-RESULTS.md](FULL-RESULTS.md) to a one-line
description of what that function computes, grouped by layer.

- Names are the canonical Recast/Detour symbol names (`rc*` = Recast build,
  `dt*` = Detour runtime, `crowd_*` = a phase of one `crowd.update()` tick).
- For *which* scenarios exercise each zone, see §1.1 of FINAL-REPORT.md and the
  cross-language contract in `dev/research/performance_analysis/scenarios.md`.
- For the measured ns/ratio of each zone, see FULL-RESULTS.md.

---

## BUILD — Recast pipeline (`rc*`), offline navmesh construction

| zone | does |
|---|---|
| `rcRasterizeTriangles` | voxelize input triangles into a heightfield |
| `rcFilterLowHangingWalkableObstacles` | mark small steps (curbs) as walkable |
| `rcFilterLedgeSpans` | drop spans next to drop-offs (ledges) |
| `rcFilterWalkableLowHeightSpans` | drop spans with too little headroom |
| `rcBuildCompactHeightfield` | compact the heightfield for neighbour walking |
| `rcErodeWalkableArea` | shrink walkable area by agent radius |
| `rcBuildDistanceField` | distance-to-border field (for watershed regions) |
| `rcBuildRegions` / `…Monotone` / `rcBuildLayerRegions` | partition walkable area into regions (3 algorithms) |
| `rcBuildContours` | trace region outlines into contours |
| `rcBuildPolyMesh` | contours → convex polygon mesh |
| `rcBuildPolyMeshDetail` | add height detail to the polygon mesh |
| `dtCreateNavMeshData` | serialize the mesh into a Detour tile blob |

## QUERY — Detour runtime (`dt*`), search over the finished navmesh

| zone | does |
|---|---|
| `dtFindNearestPoly` | snap a world point to the nearest navmesh polygon |
| `dtFindPath` | A* search → corridor of polygons start→goal |
| `dtFindStraightPath` | corridor → list of waypoint corners |
| `dtRaycast` | walkable straight-line check along the surface |
| `dtMoveAlongSurface` | slide an agent along the surface (hugging walls) |
| `dtFindPolysAroundCircle` / `…Shape` | Dijkstra: polys within a radius / convex shape |
| `dtFindLocalNeighbourhood` | non-overlapping polys around a point |
| `dtFindDistanceToWall` | distance from a point to the nearest wall |
| `dtFindRandomPoint` / `…AroundCircle` | uniform random point on the mesh |
| `dtGetPolyHeight` | interpolated floor height at a point on a poly |
| `dtIsValidPolyRef` | is this polygon reference still valid? |
| `dtGetPolyWallSegments` | the wall edges of a polygon |
| `dtInit/Update/FinalizeSlicedFindPath` | budgeted A* split across frames |

## CROWD — Detour crowd, the `crowd_*` phases of one `crowd.update()` tick

| zone | does |
|---|---|
| `crowd_check_path_validity` | re-validate each agent's path |
| `crowd_update_move_request` | service queued path requests |
| `crowd_path_queue_update` | advance the async path-find queue |
| `crowd_grid_register` | insert agents into the proximity grid |
| `crowd_neighbor_find` | find each agent's neighbours |
| `crowd_find_corners` | next steering corners from the corridor |
| `crowd_steering_separation` | separation steering force |
| `crowd_velocity_planning_oa` | obstacle-avoidance velocity sampling |
| `crowd_integrate` | clamp acceleration + advance position |
| `crowd_collision_resolve` | push overlapping agents apart |
| `crowd_move_position` | move each agent along its corridor |
| `crowd_topology_opt` | incremental path-corridor optimization |
| `crowd_update_total` | the whole tick (sum) |

## TILECACHE — `dtTileCache*`, dynamic-obstacle rebuild

| zone | does |
|---|---|
| `dtTileCacheAddBoxObstacle` / `…RemoveObstacle` | queue an obstacle add/remove |
| `dtTileCacheUpdate` | drive the rebuild of affected tiles |
| `dtDecompressTileCacheLayer` | unpack a compressed tile layer (bench compressor is a no-op store) |
| `dtBuildTileCacheRegions` / `…Contours` / `…PolyMesh` | rebuild the tile's nav polygons |
| `dtTileCacheBuildNavMeshTile` | assemble + swap in the rebuilt tile |
