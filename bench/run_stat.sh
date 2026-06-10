#!/usr/bin/env bash
set -e
export http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY=
cd "$(cd "$(dirname "$0")/.." && pwd)"   # repo root (this script lives in bench/)
OUT=out/STAT_FINAL
mkdir -p "$OUT"
CSV="$OUT/STAT_SCOREBOARD.csv"
rm -f "$CSV"

QUERY=query_findnearestpoly_flood,query_findpath_flood,query_findpath_long_diagonal,query_findstraightpath_flood,query_findstraightpath_crossings,query_raycast_flood,query_movealongsurface_flood,query_findpolysaroundcircle_radius_sweep,query_findpolysaroundshape_convex_sweep,query_findlocalneighbourhood_radius_sweep,query_findrandompoint_area_weighted,query_findrandompointaroundcircle_radius_sweep,query_finddistancetowall_radius_sweep,query_getpolyheight_snapped,query_isvalidpolyref_snapped,query_getpolywallsegments_portals,query_slicedpath_budget32,query_multitile_findpath,query_multitile_straightpath,query_multitile_raycast
CROWD=crowd_baseline_25_oa_low,crowd_100_oa_high,crowd_100_no_avoidance,crowd_choke_funnel_60_oa_high,crowd_mass_repath_100_shared_moving_goal,crowd_separation_spread_120_no_goal,crowd_scale_250_oa_med
TILE=tilecache_obstacles_map_2,tilecache_cylinders_map_2,tilecache_orientedbox_map_2,tilecache_dense_box_map_2,tilecache_obstacles_map_3
BUILD=build_solo_watershed_map_6,build_solo_watershed_map_5,build_solo_watershed_map_2,build_solo_watershed_map_4,build_solo_watershed_map_1,build_solo_watershed_map_3,build_solo_monotone_map_1,build_solo_layers_map_1,build_solo_watershed_map_1_coarse,build_solo_watershed_map_1_fat_agent,build_solo_watershed_map_1_dense_detail,build_tiled_watershed_map_3_region,build_tiled_layers_map_4_region,build_tiled_watershed_map_2_region,build_tiled_watershed_map_1_region,build_solo_offmesh_map_1

echo "### QUERY K=15"
python bench/stat_compare.py "$QUERY" --k 15 --out-csv "$CSV" > "$OUT/query.log" 2>&1
echo "### CROWD K=15"
python bench/stat_compare.py "$CROWD" --k 15 --out-csv "$CSV" > "$OUT/crowd.log" 2>&1
echo "### TILECACHE K=15"
python bench/stat_compare.py "$TILE" --k 15 --out-csv "$CSV" > "$OUT/tilecache.log" 2>&1
echo "### BUILD K=7"
python bench/stat_compare.py "$BUILD" --k 7 --out-csv "$CSV" > "$OUT/build.log" 2>&1
echo "### DONE -> $CSV"
