#!/usr/bin/env bash
# ============================================================================
# Universal Zig-vs-C++ benchmark driver.  ONE command:
#   1. builds the C++ reference (MSVC /O2 + /arch:AVX2 — fair vs Zig's native CPU)
#   2. builds the Zig scenario runner (ReleaseFast, native, -Dbench)
#   3. runs every scenario on BOTH (per-scenario, a crash in one doesn't abort the rest)
#   4. prints the per-layer Zig/C++ geomean + flags any count-mismatch (invalid pair)
#
# Usage:
#   bash bench/compare.sh                 # all viable scenarios
#   bash bench/compare.sh <id1,id2,...>   # a subset
#   bash bench/compare.sh all --rebuild-cpp   # force a clean C++ rebuild
#   bash bench/compare.sh "" --build-only     # just build both sides, don't run
#   bash bench/compare.sh all --per-dir <dir> # write per-scenario CSVs elsewhere
#
# Fairness note: Zig defaults to the native CPU (AVX2/FMA/BMI). MSVC defaults to
# SSE2 baseline (no -march=native exists for MSVC), so we pass /arch:AVX2 to match.
# Both sides keep strict IEEE float (no fast-math).
# ============================================================================
set -u

to_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  elif command -v wslpath >/dev/null 2>&1; then
    wslpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

to_shell_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  elif command -v wslpath >/dev/null 2>&1; then
    wslpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

default_zig() {
  if command -v wslpath >/dev/null 2>&1; then
    printf '%s\n' "/mnt/c/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe"
  else
    printf '%s\n' "/c/Program Files/zig/zig-x86_64-windows-0.16.0/zig.exe"
  fi
}

default_cmake() {
  if command -v wslpath >/dev/null 2>&1; then
    printf '%s\n' "/mnt/c/Program Files/CMake/bin/cmake.exe"
  else
    printf '%s\n' "C:/Program Files/CMake/bin/cmake.exe"
  fi
}

SCRIPT_DIR_UNIX="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_UNIX="$(cd "$SCRIPT_DIR_UNIX/.." && pwd)"
ROOT_UNIX="$(cd "$SELF_UNIX/.." && pwd)"
SELF="$(to_win_path "$SELF_UNIX")"
ROOT="$(to_win_path "$ROOT_UNIX")"

ZIG="${ZIG:-$(default_zig)}"
CMAKE="${CMAKE:-$(default_cmake)}"
BF="${BF:-$SELF/build.zig}"
GEOM="${GEOM:-$ROOT/zig-recast-tracy/test_data/bench_geom}"
PA="${PA:-$SELF/dev/research/performance_analysis}"
CPPBUILD="${CPPBUILD:-$ROOT/recastnavigation-bench/build_bench}"
CPPEXE="${CPPEXE:-$CPPBUILD/Bench/Release/tracy_scenarios.exe}"
ZEXE="${ZEXE:-$SELF/zig-out/bin/tracy_scenarios.exe}"
PA_SH="$SELF_UNIX/dev/research/performance_analysis"
CPPBUILD_SH="$ROOT_UNIX/recastnavigation-bench/build_bench"
CPPEXE_SH="$CPPBUILD_SH/Bench/Release/tracy_scenarios.exe"
ZEXE_SH="$SELF_UNIX/zig-out/bin/tracy_scenarios.exe"
export http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY=

# All viable scenarios. EXCLUDES build_solo_watershed_map_1_fine (cs=1.088 -> 24M
# cells -> rcBuildPolyMesh TooManyVertices, a real 16-bit-index limit, both langs).
DEFAULT_SCEN="build_solo_watershed_map_6 build_solo_watershed_map_5 \
build_solo_watershed_map_2 build_solo_watershed_map_4 build_solo_watershed_map_1 \
build_solo_watershed_map_3 build_solo_monotone_map_1 build_solo_layers_map_1 \
build_solo_watershed_map_1_coarse build_solo_watershed_map_1_fat_agent \
build_solo_watershed_map_1_dense_detail build_tiled_watershed_map_3_region \
build_tiled_layers_map_4_region build_tiled_watershed_map_2_region build_tiled_watershed_map_1_region build_solo_offmesh_map_1 query_findnearestpoly_flood query_findpath_flood \
query_findpath_long_diagonal query_findstraightpath_flood query_findstraightpath_crossings query_raycast_flood \
query_movealongsurface_flood query_findpolysaroundcircle_radius_sweep query_findpolysaroundshape_convex_sweep \
query_findlocalneighbourhood_radius_sweep query_findrandompoint_area_weighted query_findrandompointaroundcircle_radius_sweep \
query_finddistancetowall_radius_sweep query_getpolyheight_snapped query_isvalidpolyref_snapped query_getpolywallsegments_portals query_slicedpath_budget32 \
query_multitile_findpath query_multitile_straightpath query_multitile_raycast \
crowd_baseline_25_oa_low crowd_100_oa_high crowd_100_no_avoidance crowd_choke_funnel_60_oa_high \
crowd_mass_repath_100_shared_moving_goal crowd_separation_spread_120_no_goal crowd_scale_250_oa_med \
tilecache_obstacles_map_2 tilecache_cylinders_map_2 tilecache_orientedbox_map_2 tilecache_dense_box_map_2 tilecache_obstacles_map_3"

ARG1="${1:-all}"
REBUILD_CPP=0; BUILD_ONLY=0; PER_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rebuild-cpp) REBUILD_CPP=1; shift ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --per-dir) PER_OVERRIDE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$ARG1" in all|""|--*) SCEN="$DEFAULT_SCEN" ;; *) SCEN="${ARG1//,/ }" ;; esac

echo "### [1/4] C++ reference (MSVC /O2 /arch:AVX2) ###"
if [ ! -f "$CPPEXE_SH" ] || [ "$REBUILD_CPP" = "1" ]; then
  "$CMAKE" "$CPPBUILD" -DCMAKE_CXX_FLAGS="/DWIN32 /D_WINDOWS /EHsc /arch:AVX2" \
                       -DCMAKE_C_FLAGS="/DWIN32 /D_WINDOWS /arch:AVX2" >/dev/null 2>&1 \
    || { echo "  cmake configure FAILED (build_bench must be configured once with RN_TRACY=ON)"; exit 1; }
  "$CMAKE" --build "$CPPBUILD" --config Release --target tracy_scenarios 2>&1 \
    | grep -iE "error|->.*\.exe" | tail -3
fi
[ -f "$CPPEXE_SH" ] || { echo "  C++ exe missing"; exit 1; }

echo "### [2/4] Zig runner (native, ReleaseFast, -Dbench — registry-only, no ztracy) ###"
mkdir -p "$PA_SH"
if ! "$ZIG" build run-tracy-scenarios -Doptimize=ReleaseFast -Dbench=true --build-file "$BF" \
       -- build_solo_watershed_map_2 "$GEOM" "$PA/_smoke.csv" >"$PA_SH/_zbuild.log" 2>&1; then
  echo "  Zig build FAILED:"; grep -iE "error" "$PA_SH/_zbuild.log" | head; exit 1
fi
[ -f "$ZEXE_SH" ] || { echo "  Zig exe missing"; exit 1; }

[ "$BUILD_ONLY" = "1" ] && { echo "### build-only done ###"; exit 0; }

echo "### [3/4] Run $(echo $SCEN | wc -w) scenarios x2 (Zig + C++) ###"
PER="${PER_OVERRIDE:-${COMPARE_PER:-$PA/per_cmp}}"
PER_SH="$(to_shell_path "$PER")"
mkdir -p "$PER_SH"
for id in $SCEN; do
  "$ZEXE_SH"   "$id" "$GEOM" "$PER/zig_$id.csv" >/dev/null 2>&1 || echo "  zig FAIL: $id"
  "$CPPEXE_SH" "$id" "$GEOM" "$PER/cpp_$id.csv" >/dev/null 2>&1 || echo "  cpp FAIL: $id"
done

echo "### [4/4] Zig/C++ comparison (build=min, query/crowd/tilecache=mean) ###"
python3 - "$PER_SH" "$SCEN" <<'PY'
import csv,sys,os,math,collections
per=sys.argv[1]; scen=sys.argv[2].split()
def load(side,sid):
    p=os.path.join(per,f"{side}_{sid}.csv"); d={}
    if os.path.exists(p):
        for r in csv.DictReader(open(p,encoding="utf-8")): d[r["zone"]]=r
    return d
def metric(sid): return "min_ns" if sid.startswith("build") else "mean_ns"
def gm(v):
    v=[x for x in v if x>0]
    return math.exp(sum(math.log(x) for x in v)/len(v)) if v else 0
cat=collections.defaultdict(list); mism=[]
for sid in scen:
    Z=load("zig",sid); C=load("cpp",sid); m=metric(sid)
    for z in sorted(set(Z)&set(C)):
        zv,cv=float(Z[z][m]),float(C[z][m])
        if zv>0 and cv>0:
            cat[sid.split('_')[0]].append(zv/cv)
            if Z[z]["count"]!=C[z]["count"]:
                mism.append(f"{sid}/{z} {Z[z]['count']}vs{C[z]['count']}")
allr=[x for v in cat.values() for x in v]
print(f"{'layer':<11}{'Zig/C++':>9}{'zones':>7}  (<1.0 = Zig faster)")
for c in ("build","query","crowd","tilecache"):
    if cat[c]:
        v=cat[c]; print(f"{c:<11}{gm(v):>9.3f}{len(v):>7}   faster<0.95:{sum(1 for x in v if x<0.95)} slower>1.05:{sum(1 for x in v if x>1.05)}")
print(f"{'OVERALL':<11}{gm(allr):>9.3f}{len(allr):>7}")
if mism: print("\n!! count-mismatch (invalid pairs, fix parity):", mism[:8])
PY
echo "### DONE ###"
