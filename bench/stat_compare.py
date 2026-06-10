#!/usr/bin/env python3
"""Professional A/B statistical comparison of the Zig vs C++ benchmark runners.

Unlike compare_min.py (which keeps the single BEST run per side = a point estimate
with no confidence), this runs each scenario K times per side, INTERLEAVED
(zig,cpp,zig,cpp,...) to cancel slow thermal/load drift, then for each zone reports:

  - median ratio (zig/cpp)
  - 95% bootstrap confidence interval of that ratio
  - a significance verdict: FASTER / SLOWER if the CI excludes 1.0, else TIE
    (indistinguishable from parity within this machine's noise)
  - the per-side coefficient of variation (CV%) so you SEE the noise floor

A zone can only claim a sub-% difference if its CI is tight AND excludes 1.0.
On a contended dev machine most small zones come back TIE — that is the honest
answer, not a fabricated ratio.

Usage:
  python bench/stat_compare.py <scenario|csv-list> --k 15 [--metric auto|min_ns|mean_ns]

Env overrides: ZEXE, CPPEXE, GEOM (same as compare.ps1).
"""
import csv, os, subprocess, sys, statistics, random

# ANSI colors (enabled on a tty or with FORCE_COLOR)
_C = sys.stdout.isatty() or os.environ.get("FORCE_COLOR")
R = "\033[0m" if _C else ""; B = "\033[1m" if _C else ""; DIM = "\033[2m" if _C else ""
GRN = "\033[92m" if _C else ""; RED = "\033[91m" if _C else ""
YEL = "\033[93m" if _C else ""; MAG = "\033[95m" if _C else ""; CYN = "\033[96m" if _C else ""

def vcol(verdict):
    return {"FASTER": GRN, "SLOWER": RED, "tie(noise)": YEL,
            "COUNT-MISMATCH": MAG}.get(verdict, "")

def rcol(ratio):
    return GRN if ratio < 0.97 else (RED if ratio > 1.03 else YEL)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARENT = os.path.dirname(ROOT)
ZEXE = os.environ.get("ZEXE", os.path.join(ROOT, "zig-out", "bin", "tracy_scenarios.exe"))
CPPEXE = os.environ.get("CPPEXE", os.path.join(PARENT, "recastnavigation-bench", "build_bench", "Bench", "Release", "tracy_scenarios.exe"))
GEOM = os.environ.get("GEOM", os.path.join(PARENT, "zig-recast-tracy", "test_data", "bench_geom"))
TMP = os.path.join(ROOT, "dev", "research", "performance_analysis", "_stat_tmp")


def metric_for(scenario, override):
    if override != "auto":
        return override
    return "min_ns" if scenario.startswith("build") and "tiled" not in scenario else "mean_ns"


def run_once(exe, scenario, out_csv):
    subprocess.run([exe, scenario, GEOM, out_csv], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False)
    rows = {}
    if os.path.isfile(out_csv):
        with open(out_csv, newline="") as f:
            for r in csv.DictReader(f):
                rows[r["zone"]] = r
    return rows


def collect(exe, scenario, k, tag):
    """k runs; returns {zone: [metric values]} and {zone: count}."""
    vals, counts = {}, {}
    for i in range(k):
        rows = run_once(exe, scenario, os.path.join(TMP, f"{tag}_{i}.csv"))
        for z, r in rows.items():
            try:
                v = float(r[METRIC]); c = int(r["count"])
            except (ValueError, KeyError):
                continue
            if v <= 0:
                continue
            vals.setdefault(z, []).append(v)
            counts.setdefault(z, []).append(c)
    return vals, counts


def cv(xs):
    if len(xs) < 2:
        return 0.0
    m = statistics.mean(xs)
    return 100.0 * statistics.pstdev(xs) / m if m else 0.0


def bootstrap_ci(zig, cpp, b=3000):
    """95% CI of median(zig)/median(cpp) via resampling. Seeded => reproducible."""
    rng = random.Random(12345)
    nz, nc = len(zig), len(cpp)
    ratios = []
    for _ in range(b):
        mz = statistics.median(zig[rng.randrange(nz)] for _ in range(nz))
        mc = statistics.median(cpp[rng.randrange(nc)] for _ in range(nc))
        if mc > 0:
            ratios.append(mz / mc)
    ratios.sort()
    lo = ratios[int(0.025 * len(ratios))]
    hi = ratios[int(0.975 * len(ratios)) - 1]
    return lo, hi


# Scenario ids are already the public map tokens (map_1 … map_6); nothing to remap.
def anon(s):
    return s


def main():
    global METRIC
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    k = 15
    metric_override = "auto"
    out_csv_path = None
    for a in sys.argv[1:]:
        if a.startswith("--k"):
            k = int(a.split("=")[-1]) if "=" in a else int(sys.argv[sys.argv.index(a) + 1])
        if a.startswith("--metric"):
            metric_override = a.split("=")[-1] if "=" in a else sys.argv[sys.argv.index(a) + 1]
        if a.startswith("--out-csv"):
            out_csv_path = a.split("=")[-1] if "=" in a else sys.argv[sys.argv.index(a) + 1]
    table_rows = []  # collected for machine-readable output
    scenarios = args[0].split(",") if args else []
    if not scenarios:
        print("usage: stat_compare.py <scenario|list> --k 15")
        sys.exit(2)
    os.makedirs(TMP, exist_ok=True)
    for exe, name in ((ZEXE, "zig"), (CPPEXE, "cpp")):
        if not os.path.isfile(exe):
            print(f"missing {name} exe: {exe}"); sys.exit(2)

    print(f"K={k} samples/side, interleaved. metric=auto (build=min_ns, else mean_ns)")
    print(f"{'zone':42}{'ratio':>8}{'  95% CI':>16}{'  verdict':>14}{'  noise(z/c)':>14}")
    print("-" * 96)
    all_ratios = []
    for scenario in scenarios:
        METRIC = metric_for(scenario, metric_override)
        # interleave: zig run, cpp run, alternating, k each
        zig_vals, zig_cnt = {}, {}
        cpp_vals, cpp_cnt = {}, {}
        for i in range(k):
            for z, r in run_once(ZEXE, anon(scenario), os.path.join(TMP, f"z_{i}.csv")).items():
                try:
                    v = float(r[METRIC])
                except (ValueError, KeyError):
                    continue
                if v > 0:
                    zig_vals.setdefault(z, []).append(v); zig_cnt.setdefault(z, []).append(r["count"])
            for z, r in run_once(CPPEXE, scenario, os.path.join(TMP, f"c_{i}.csv")).items():
                try:
                    v = float(r[METRIC])
                except (ValueError, KeyError):
                    continue
                if v > 0:
                    cpp_vals.setdefault(z, []).append(v); cpp_cnt.setdefault(z, []).append(r["count"])
        print(f"{B}{CYN}# {scenario}{R}  {DIM}({METRIC}){R}")
        for z in sorted(set(zig_vals) & set(cpp_vals)):
            zs, cs = zig_vals[z], cpp_vals[z]
            if len(zs) < 3 or len(cs) < 3:
                continue
            # count-parity check
            if zig_cnt.get(z) and cpp_cnt.get(z) and zig_cnt[z][0] != cpp_cnt[z][0]:
                verdict = "COUNT-MISMATCH"
                ratio = statistics.median(zs) / statistics.median(cs)
                lo = hi = float("nan")
            else:
                ratio = statistics.median(zs) / statistics.median(cs)
                lo, hi = bootstrap_ci(zs, cs)
                if hi < 1.0:
                    verdict = "FASTER"
                elif lo > 1.0:
                    verdict = "SLOWER"
                else:
                    verdict = "tie(noise)"
                all_ratios.append((ratio, verdict))
            rt = f"{rcol(ratio)}{ratio:8.3f}{R}"
            vt = f"{vcol(verdict)}{verdict:>14}{R}"
            ci = f"[{lo:5.3f},{hi:5.3f}]" if lo == lo else f"{MAG}[  n/a , n/a ]{R}"
            print(f"  {z:40}{rt}  {ci}{vt}   {DIM}{cv(zs):4.1f}%/{cv(cs):4.1f}%{R}")
            table_rows.append({
                "scenario": anon(scenario), "zone": z,
                "layer": scenario.split("_", 1)[0], "metric": METRIC,
                "n_zig": len(zs), "n_cpp": len(cs),
                "median_zig_ns": statistics.median(zs),
                "median_cpp_ns": statistics.median(cs),
                "ratio_median": ratio,
                "ci_lo": lo, "ci_hi": hi,
                "cv_zig_pct": cv(zs), "cv_cpp_pct": cv(cs),
                "verdict": verdict,
            })
    # overall
    sig = [r for r, v in all_ratios if v in ("FASTER", "SLOWER")]
    tie = [r for r, v in all_ratios if v == "tie(noise)"]
    faster = sum(1 for r, v in all_ratios if v == "FASTER")
    slower = sum(1 for r, v in all_ratios if v == "SLOWER")
    print("-" * 96)
    print(f"zones: {GRN}{faster} FASTER(sig){R}  {RED}{slower} SLOWER(sig){R}  "
          f"{YEL}{len(tie)} tie(within noise){R}")
    if all_ratios:
        import math
        g = math.exp(sum(math.log(r) for r, _ in all_ratios) / len(all_ratios))
        print(f"{B}geomean ratio (all trusted zones): {rcol(g)}{g:.4f}{R}{B}  (<1 = Zig faster){R}")
    print("NOTE: 'tie(noise)' = the CI spans 1.0 -> difference is below this machine's "
          "noise floor; a sub-% claim there is NOT supported.")

    if out_csv_path and table_rows:
        cols = ["scenario", "zone", "layer", "metric", "n_zig", "n_cpp",
                "median_zig_ns", "median_cpp_ns", "ratio_median",
                "ci_lo", "ci_hi", "cv_zig_pct", "cv_cpp_pct", "verdict"]
        write_header = not os.path.isfile(out_csv_path)
        with open(out_csv_path, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            if write_header:
                w.writeheader()
            for row in table_rows:
                w.writerow(row)
        print(f"appended {len(table_rows)} rows -> {out_csv_path}")


if __name__ == "__main__":
    main()
