#!/usr/bin/env python3
"""Run the Zig-vs-C++ compare driver repeatedly and collapse by min-of-runs.

The campaign plan treats single-run layer geomeans as unreliable. This wrapper
runs the normal Zig-vs-C++ driver N times, reads each run's per-scenario CSVs,
and emits a stable scoreboard using the best observed per-zone metric on each
side:

  * build scenarios: min_ns
  * query/crowd/tilecache scenarios: mean_ns

Rows where either side is below the QPC trust floor are preserved but flagged;
those ratios should be routed to System-A micro-bench instead of trusted here.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import pathlib
import subprocess
import sys
import time
from dataclasses import dataclass, field


DEFAULT_SCENARIOS = [
    "build_solo_watershed_map_6",
    "build_solo_watershed_map_5",
    "build_solo_watershed_map_2",
    "build_solo_watershed_map_4",
    "build_solo_watershed_map_1",
    "build_solo_watershed_map_3",
    "build_solo_monotone_map_1",
    "build_solo_layers_map_1",
    "build_solo_watershed_map_1_coarse",
    "build_solo_watershed_map_1_fat_agent",
    "build_solo_watershed_map_1_dense_detail",
    "build_tiled_watershed_map_3_region",
    "build_tiled_layers_map_4_region",
    "build_tiled_watershed_map_2_region",
    "build_tiled_watershed_map_1_region",
    "build_solo_offmesh_map_1",
    "query_findnearestpoly_flood",
    "query_findpath_flood",
    "query_findpath_long_diagonal",
    "query_findstraightpath_flood",
    "query_findstraightpath_crossings",
    "query_raycast_flood",
    "query_movealongsurface_flood",
    "query_findpolysaroundcircle_radius_sweep",
    "query_findpolysaroundshape_convex_sweep",
    "query_findlocalneighbourhood_radius_sweep",
    "query_findrandompoint_area_weighted",
    "query_findrandompointaroundcircle_radius_sweep",
    "query_finddistancetowall_radius_sweep",
    "query_getpolyheight_snapped",
    "query_isvalidpolyref_snapped",
    "query_getpolywallsegments_portals",
    "query_slicedpath_budget32",
    "query_multitile_findpath",
    "query_multitile_straightpath",
    "query_multitile_raycast",
    "crowd_baseline_25_oa_low",
    "crowd_100_oa_high",
    "crowd_100_no_avoidance",
    "crowd_choke_funnel_60_oa_high",
    "crowd_mass_repath_100_shared_moving_goal",
    "crowd_separation_spread_120_no_goal",
    "crowd_scale_250_oa_med",
    "tilecache_obstacles_map_2",
    "tilecache_cylinders_map_2",
    "tilecache_orientedbox_map_2",
    "tilecache_dense_box_map_2",
    "tilecache_obstacles_map_3",
]


@dataclass
class SideBest:
    value: float = math.inf
    run: int = -1
    count: str = ""
    counts: set[str] = field(default_factory=set)


@dataclass
class Joined:
    scenario: str
    zone: str
    metric: str
    zig: SideBest = field(default_factory=SideBest)
    cpp: SideBest = field(default_factory=SideBest)


def layer_of(scenario: str) -> str:
    return scenario.split("_", 1)[0]


def metric_of(scenario: str) -> str:
    # SOLO build = min_ns (one full rebuild/iter; min-of-mins cancels noise).
    # TILED build = mean_ns: the zone aggregates over ALL tiles (count=tiles), so
    # min_ns reports the single EMPTIEST tile (fixed per-call overhead), not
    # throughput. mean_ns is the representative tiled metric. (Verified: by mean,
    # tiled rcBuild* are Zig-faster 0.72-0.94; min_ns showed false 1.2-3.0.)
    if scenario.startswith("build") and "tiled" not in scenario:
        return "min_ns"
    return "mean_ns"


def geomean(values: list[float]) -> float:
    values = [v for v in values if v > 0 and math.isfinite(v)]
    if not values:
        return 0.0
    return math.exp(sum(math.log(v) for v in values) / len(values))


def parse_scenarios(raw: str) -> list[str]:
    if raw in ("", "all"):
        return DEFAULT_SCENARIOS
    return [s for part in raw.split(",") for s in part.split() if s]


def update_side(path: pathlib.Path, run_idx: int, metric: str, side: str, rows: dict[tuple[str, str], Joined], missing: list[str]) -> None:
    if not path.exists():
        missing.append(str(path))
        return
    with path.open("r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            scenario = row.get("scenario", "")
            zone = row.get("zone", "")
            if not scenario or not zone or zone == "__SKIPPED_BUDGET__":
                continue
            try:
                value = float(row[metric])
            except (KeyError, ValueError):
                continue
            key = (scenario, zone)
            joined = rows.setdefault(key, Joined(scenario=scenario, zone=zone, metric=metric))
            best = joined.zig if side == "zig" else joined.cpp
            count = row.get("count", "")
            best.counts.add(count)
            if value > 0 and value < best.value:
                best.value = value
                best.run = run_idx
                best.count = count


def run_compare(repo: pathlib.Path, driver: str, scenarios_arg: str, out_dir: pathlib.Path, run_idx: int, rebuild_cpp: bool) -> None:
    per_dir = out_dir / f"run_{run_idx:02d}" / "per_cmp"
    per_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    for name in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
        env[name] = ""
    if driver == "ps1":
        cmd = [
            "powershell",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(repo / "bench" / "compare.ps1"),
            "-Scenarios",
            scenarios_arg,
            "-PerDir",
            str(per_dir),
        ]
        if rebuild_cpp and run_idx == 1:
            cmd.append("-RebuildCpp")
    elif driver == "bash":
        cmd = ["bash", "bench/compare.sh", scenarios_arg, "--per-dir", str(per_dir).replace("\\", "/")]
        if rebuild_cpp and run_idx == 1:
            cmd.append("--rebuild-cpp")
    else:
        raise ValueError(f"unknown driver: {driver}")
    print(f"### min-run {run_idx}: {' '.join(cmd)}")
    subprocess.run(cmd, cwd=repo, env=env, check=True)


def write_scoreboard(rows: dict[tuple[str, str], Joined], scenarios: list[str], out_csv: pathlib.Path, floor_ns: float) -> list[Joined]:
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    scenario_order = {s: i for i, s in enumerate(scenarios)}
    ordered = sorted(
        rows.values(),
        key=lambda r: (
            scenario_order.get(r.scenario, len(scenario_order)),
            0 if math.isfinite(r.zig.value) and math.isfinite(r.cpp.value) else 1,
            -(r.zig.value / r.cpp.value) if math.isfinite(r.zig.value) and math.isfinite(r.cpp.value) and r.cpp.value else 0,
            r.zone,
        ),
    )
    floor_backlog: list[Joined] = []
    with out_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "scenario",
                "zone",
                "layer",
                "metric",
                "zig_best_ns",
                "cpp_best_ns",
                "ratio",
                "zig_best_run",
                "cpp_best_run",
                "zig_count",
                "cpp_count",
                "count_parity",
                "below_floor",
                "zig_count_values",
                "cpp_count_values",
            ]
        )
        for r in ordered:
            both = math.isfinite(r.zig.value) and math.isfinite(r.cpp.value)
            ratio = r.zig.value / r.cpp.value if both and r.cpp.value > 0 else math.inf
            below_floor = both and (r.zig.value < floor_ns or r.cpp.value < floor_ns)
            if below_floor:
                floor_backlog.append(r)
            w.writerow(
                [
                    r.scenario,
                    r.zone,
                    layer_of(r.scenario),
                    r.metric,
                    "" if not math.isfinite(r.zig.value) else f"{r.zig.value:.6f}",
                    "" if not math.isfinite(r.cpp.value) else f"{r.cpp.value:.6f}",
                    "inf" if not math.isfinite(ratio) else f"{ratio:.6f}",
                    "" if r.zig.run < 0 else r.zig.run,
                    "" if r.cpp.run < 0 else r.cpp.run,
                    r.zig.count,
                    r.cpp.count,
                    "yes" if both and r.zig.count == r.cpp.count else "no",
                    "yes" if below_floor else "no",
                    "|".join(sorted(r.zig.counts)),
                    "|".join(sorted(r.cpp.counts)),
                ]
            )
    return floor_backlog


def write_floor_backlog(floor_rows: list[Joined], out_csv: pathlib.Path) -> None:
    with out_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "scenario",
                "zone",
                "layer",
                "metric",
                "zig_best_ns",
                "cpp_best_ns",
                "ratio",
                "suggested_route",
            ]
        )
        for r in sorted(floor_rows, key=lambda x: (layer_of(x.scenario), x.scenario, x.zone)):
            ratio = r.zig.value / r.cpp.value if r.cpp.value > 0 else math.inf
            w.writerow(
                [
                    r.scenario,
                    r.zone,
                    layer_of(r.scenario),
                    r.metric,
                    f"{r.zig.value:.6f}",
                    f"{r.cpp.value:.6f}",
                    "inf" if not math.isfinite(ratio) else f"{ratio:.6f}",
                    "System-A microbench required; System-B ratio below QPC floor",
                ]
            )


def write_metadata(repo: pathlib.Path, out_dir: pathlib.Path, args: argparse.Namespace, scenarios: list[str], missing: list[str]) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    zig = pathlib.Path(r"C:\Program Files\zig\zig-x86_64-windows-0.16.0\zig.exe")
    cpp = repo.parent / "recastnavigation-bench" / "build_bench" / "Bench" / "Release" / "tracy_scenarios.exe"
    md = {
        "captured_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "repo": str(repo),
        "branch": None,
        "commit": None,
        "git_probe_note": "intentionally not probed here; run git rev-parse/status before publication",
        "dirty_note": "dirty tree not enumerated here; run git status --short before publication",
        "os": None,
        "python": sys.version.split()[0],
        "system_probe_note": "intentionally not probed here; avoid slow Windows metadata calls during benchmark guards",
        "zig_path": str(zig),
        "zig_version": None,
        "cpp_exe": str(cpp),
        "cpp_exe_mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(cpp.stat().st_mtime)) if cpp.exists() else None,
        "runs": args.runs,
        "floor_ns": args.floor_ns,
        "scenarios": scenarios,
        "allow_missing": args.allow_missing,
        "missing_csvs": missing,
        "command": " ".join(sys.argv),
    }
    with (out_dir / "run-metadata.json").open("w", encoding="utf-8") as f:
        json.dump(md, f, indent=2)


def print_summary(rows: dict[tuple[str, str], Joined], floor_ns: float) -> None:
    by_layer: dict[str, list[float]] = {}
    by_layer_trusted: dict[str, list[float]] = {}
    mismatches: list[str] = []
    floor_rows = 0
    for r in rows.values():
        if not (math.isfinite(r.zig.value) and math.isfinite(r.cpp.value) and r.cpp.value > 0):
            continue
        ratio = r.zig.value / r.cpp.value
        layer = layer_of(r.scenario)
        by_layer.setdefault(layer, []).append(ratio)
        below_floor = r.zig.value < floor_ns or r.cpp.value < floor_ns
        if below_floor:
            floor_rows += 1
        else:
            by_layer_trusted.setdefault(layer, []).append(ratio)
        if r.zig.count != r.cpp.count:
            mismatches.append(f"{r.scenario}/{r.zone} {r.zig.count}vs{r.cpp.count}")

    print("\n### min-of-runs scoreboard")
    print(f"{'layer':<11}{'all':>9}{'trusted':>11}{'zones':>7}{'floor':>7}  (<1.0 = Zig faster)")
    all_ratios: list[float] = []
    trusted_ratios: list[float] = []
    for layer in ("build", "query", "crowd", "tilecache"):
        values = by_layer.get(layer, [])
        trusted = by_layer_trusted.get(layer, [])
        all_ratios.extend(values)
        trusted_ratios.extend(trusted)
        if values:
            print(f"{layer:<11}{geomean(values):>9.3f}{geomean(trusted):>11.3f}{len(values):>7}{len(values)-len(trusted):>7}")
    print(f"{'OVERALL':<11}{geomean(all_ratios):>9.3f}{geomean(trusted_ratios):>11.3f}{len(all_ratios):>7}{floor_rows:>7}")
    if mismatches:
        print("\n!! count-mismatch (invalid pairs, inspect first):")
        for item in mismatches[:20]:
            print(f"  {item}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenarios", nargs="?", default="all", help="'all', comma-separated ids, or whitespace-separated ids in quotes")
    parser.add_argument("--runs", type=int, default=3, help="number of compare.sh runs; campaign default is >=3")
    parser.add_argument("--out-dir", default=None, help="directory for run CSVs and the collapsed scoreboard")
    parser.add_argument("--floor-ns", type=float, default=200.0, help="two-sided QPC trust floor in ns")
    parser.add_argument("--rebuild-cpp", action="store_true", help="force C++ rebuild on the first run")
    parser.add_argument(
        "--driver",
        choices=("auto", "ps1", "bash"),
        default="auto",
        help="compare driver to run; auto uses ps1 on Windows and bash elsewhere",
    )
    parser.add_argument("--no-run", action="store_true", help="only collapse existing run_XX/per_cmp CSVs under --out-dir")
    parser.add_argument("--allow-missing", action="store_true", help="write a partial scoreboard even if some per-scenario CSVs are missing")
    args = parser.parse_args()

    if args.runs < 1:
        parser.error("--runs must be >= 1")

    repo = pathlib.Path(__file__).resolve().parent.parent
    driver = args.driver
    if driver == "auto":
        driver = "ps1" if os.name == "nt" else "bash"
    scenarios = parse_scenarios(args.scenarios)
    scenarios_arg = "all" if args.scenarios in ("", "all") else ",".join(scenarios)
    out_dir = pathlib.Path(args.out_dir).resolve() if args.out_dir else repo / "dev" / "research" / "performance_analysis" / f"min_of_runs_{time.strftime('%Y%m%d_%H%M%S')}"

    if not args.no_run:
        for i in range(1, args.runs + 1):
            run_compare(repo, driver, scenarios_arg, out_dir, i, args.rebuild_cpp)

    rows: dict[tuple[str, str], Joined] = {}
    missing: list[str] = []
    for i in range(1, args.runs + 1):
        per = out_dir / f"run_{i:02d}" / "per_cmp"
        for scenario in scenarios:
            metric = metric_of(scenario)
            update_side(per / f"zig_{scenario}.csv", i, metric, "zig", rows, missing)
            update_side(per / f"cpp_{scenario}.csv", i, metric, "cpp", rows, missing)

    write_metadata(repo, out_dir, args, scenarios, missing)
    if missing and not args.allow_missing:
        print("missing per-scenario CSVs; refusing to write a misleading scoreboard:", file=sys.stderr)
        for p in missing[:40]:
            print(f"  {p}", file=sys.stderr)
        if len(missing) > 40:
            print(f"  ... {len(missing) - 40} more", file=sys.stderr)
        print(f"metadata written to {out_dir / 'run-metadata.json'}", file=sys.stderr)
        return 2

    scoreboard = out_dir / "MIN_OF_RUNS_SCOREBOARD.csv"
    floor_rows = write_scoreboard(rows, scenarios, scoreboard, args.floor_ns)
    floor_csv = out_dir / "QPC_FLOOR_BACKLOG.csv"
    write_floor_backlog(floor_rows, floor_csv)
    print_summary(rows, args.floor_ns)
    print(f"\nwrote {scoreboard}")
    print(f"wrote {floor_csv}")
    print(f"wrote {out_dir / 'run-metadata.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
