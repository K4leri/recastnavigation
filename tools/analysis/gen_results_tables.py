#!/usr/bin/env python3
"""Generate FULL per-layer markdown results tables from a MIN_OF_RUNS_SCOREBOARD.csv.

Every zone gets a row: scenario/zone | zig | cpp | ratio | verdict. Grouped by layer
(BUILD/QUERY/CROWD/TILECACHE), sorted fastest-first, with a per-layer geomean line.
Output is a self-contained markdown appendix for the perf report.

Usage:
  python tools/analysis/gen_results_tables.py <scoreboard.csv> [out.md]
"""
import csv, math, os, sys


# Scenario ids are already the public map tokens (map_1 … map_6); nothing to remap.
def anon(s):
    return s


def fmt_ns(v):
    try:
        v = float(v)
    except (ValueError, TypeError):
        return "n/a"
    if v >= 1e6:
        return f"{v/1e6:.2f} ms"
    if v >= 1e3:
        return f"{v/1e3:.2f} µs"
    return f"{v:.0f} ns"


def verdict(r):
    if r.get("count_parity") != "yes":
        return "count-mismatch"
    if r.get("below_floor") == "yes":
        return "floor (noise)"
    try:
        ratio = float(r["ratio"])
    except (ValueError, TypeError):
        return "n/a"
    if not math.isfinite(ratio):
        return "n/a"
    if ratio < 0.97:
        return "Zig faster"
    if ratio > 1.03:
        return "Zig slower"
    return "parity"


def geomean(xs):
    xs = [x for x in xs if x > 0 and math.isfinite(x)]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def main():
    if len(sys.argv) < 2:
        print("usage: gen_results_tables.py <scoreboard.csv> [out.md]")
        sys.exit(2)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(src), "FULL-RESULTS.md")
    with open(src, newline="") as f:
        rows = list(csv.DictReader(f))

    by_layer = {}
    for r in rows:
        by_layer.setdefault(r.get("layer", "?"), []).append(r)

    lines = []
    lines.append("# Full benchmark results — every zone\n")
    lines.append(f"Auto-generated from `{os.path.basename(os.path.dirname(src))}/"
                 f"{os.path.basename(src)}` by `tools/analysis/gen_results_tables.py`.\n")
    lines.append(
        "Raw min-of-runs appendix. One row per (scenario, function). `zig`/`cpp` = "
        "per-run aggregate (solo-build `min_ns`, else `mean_ns`) collapsed to the best "
        "of N=3 runs; `ratio = zig/cpp`, **< 1.0 = Zig faster**. This is a point "
        "estimate with no confidence interval — for the statistically rigorous table "
        "(median, 95 % CI, significance) see **[STATISTICAL-RESULTS.md](STATISTICAL-RESULTS.md)**. "
        "`floor` = sub-~200 ns (timer noise, excluded); `count-mismatch` = unequal call "
        "counts (excluded).\n")

    order = ["build", "query", "crowd", "tilecache"]
    layers = [l for l in order if l in by_layer] + [
        l for l in by_layer if l not in order]
    for layer in layers:
        lr = by_layer[layer]
        def rk(r):
            try:
                return float(r["ratio"])
            except (ValueError, TypeError):
                return 9e9
        lr = sorted(lr, key=rk)
        trusted = [float(r["ratio"]) for r in lr
                   if r.get("count_parity") == "yes" and r.get("below_floor") == "no"
                   and r["ratio"] not in ("", None)]
        g = geomean(trusted)
        nf = sum(1 for x in trusted if x < 0.97)
        ns_ = sum(1 for x in trusted if x > 1.03)
        lines.append(f"\n## {layer.upper()} — {len(lr)} zones, "
                     f"trusted geomean **{g:.3f}** "
                     f"({nf} Zig-faster / {ns_} Zig-slower / "
                     f"{len(trusted)-nf-ns_} parity, {len(lr)-len(trusted)} floor/mismatch)\n")
        lines.append("| scenario / zone | zig | cpp | ratio | verdict |")
        lines.append("|---|---:|---:|---:|---|")
        for r in lr:
            try:
                rt = f"{float(r['ratio']):.3f}"
            except (ValueError, TypeError):
                rt = "n/a"
            name = f"{anon(r['scenario'])} / {r['zone']}"
            lines.append(f"| {name} | {fmt_ns(r['zig_best_ns'])} | "
                         f"{fmt_ns(r['cpp_best_ns'])} | {rt} | {verdict(r)} |")

    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {out}  ({sum(len(v) for v in by_layer.values())} zones across "
          f"{len(by_layer)} layers)")


if __name__ == "__main__":
    main()
