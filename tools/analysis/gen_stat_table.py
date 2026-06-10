#!/usr/bin/env python3
"""Generate the statistically rigorous results table from a stat_compare CSV.

Input: STAT_SCOREBOARD.csv produced by `bench/stat_compare.py --out-csv` (K samples
per side, interleaved). Each row already carries median times, the median ratio, its
95 % bootstrap CI, per-side CV%, and a significance verdict.

Output: a markdown table fit for a scientific write-up — per (scenario, function):
sample size, median Zig/C++ time, median ratio, 95 % CI, noise (CV%), and whether the
difference is statistically significant (CI excludes 1.0) or a tie (CI spans 1.0).

Usage:
  python tools/analysis/gen_stat_table.py <STAT_SCOREBOARD.csv> [out.md]
"""
import csv, math, os, sys


def fmt_ns(v):
    try:
        v = float(v)
    except (ValueError, TypeError):
        return "n/a"
    if v >= 1e6:
        return f"{v/1e6:.3f} ms"
    if v >= 1e3:
        return f"{v/1e3:.3f} µs"
    return f"{v:.1f} ns"


def geomean(xs):
    xs = [x for x in xs if x > 0 and math.isfinite(x)]
    return math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else float("nan")


def main():
    if len(sys.argv) < 2:
        print("usage: gen_stat_table.py <STAT_SCOREBOARD.csv> [out.md]")
        sys.exit(2)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(src), "STATISTICAL-RESULTS.md")
    with open(src, newline="") as f:
        rows = list(csv.DictReader(f))

    # one K per layer (we ran fast layers at K=15, build at K=7); report the actual n.
    by_layer = {}
    for r in rows:
        by_layer.setdefault(r.get("layer", "?"), []).append(r)

    L = []
    L.append("# Statistical results — Zig vs C++ (median + 95 % CI)\n")
    L.append(f"Auto-generated from `{os.path.basename(src)}` by "
             "`tools/analysis/gen_stat_table.py`.\n")
    L.append(
        "## Method\n\n"
        "Each (scenario, function) was measured **K times per side, interleaved** "
        "(zig, cpp, zig, cpp, …) so slow thermal/load drift hits both sides equally. "
        "Within one measurement the function runs many times and the runner emits one "
        "aggregate (solo-build = `min_ns`, everything else = `mean_ns`); the **K such "
        "aggregates per side** are the sample. We report:\n\n"
        "- **n** — samples per side (K). Fast layers K=15; BUILD K=7 (its run-to-run "
        "CV is 2–5 %, so the median is already stable).\n"
        "- **median t_zig / t_cpp** — median of the K per-run aggregates.\n"
        "- **ratio** = median(t_zig) / median(t_cpp). **< 1.0 = Zig faster.**\n"
        "- **95 % CI** — bootstrap (3000 resamples, seeded) confidence interval of the "
        "median ratio.\n"
        "- **CV%** — coefficient of variation of each side's samples (the machine noise "
        "floor; high CV ⇒ a small ratio difference is not trustworthy).\n"
        "- **verdict** — **faster**/**slower** only if the 95 % CI *excludes 1.0* "
        "(statistically significant on this machine); otherwise **tie** (the difference "
        "is within noise — a sub-% claim is NOT supported, even if the point ratio ≠ 1).\n\n"
        "> A **tie** is the honest result for most sub-µs zones: the timer/scheduler "
        "noise on a dev machine is larger than the true difference. Only zones whose CI "
        "clears 1.0 are claimed as wins or losses.\n")

    order = ["build", "query", "crowd", "tilecache"]
    layers = [l for l in order if l in by_layer] + [
        l for l in by_layer if l not in order]

    # overall significant-only tally
    tot_f = tot_s = tot_t = 0
    sig_ratebox = []

    for layer in layers:
        lr = by_layer[layer]

        def rk(r):
            try:
                return float(r["ratio_median"])
            except (ValueError, TypeError):
                return 9e9
        lr = sorted(lr, key=rk)
        nK = max((int(r["n_zig"]) for r in lr if r.get("n_zig")), default=0)
        faster = sum(1 for r in lr if r["verdict"] == "FASTER")
        slower = sum(1 for r in lr if r["verdict"] == "SLOWER")
        tie = sum(1 for r in lr if r["verdict"] == "tie(noise)")
        mism = sum(1 for r in lr if r["verdict"] == "COUNT-MISMATCH")
        tot_f += faster; tot_s += slower; tot_t += tie
        # geomean over significant zones only (the defensible aggregate)
        sig = [float(r["ratio_median"]) for r in lr
               if r["verdict"] in ("FASTER", "SLOWER")]
        g_sig = geomean(sig)
        sig_ratebox.extend(sig)
        L.append(
            f"\n## {layer.upper()} — {len(lr)} zones (K={nK}/side)\n\n"
            f"**{faster} faster (sig) / {slower} slower (sig) / {tie} tie (within "
            f"noise){'' if not mism else f' / {mism} count-mismatch'}.** "
            f"Significant-only geomean ratio: **{g_sig:.3f}** "
            f"(over the {len(sig)} zones whose 95 % CI clears 1.0).\n")
        L.append("| scenario / function | n | median t_zig | median t_cpp | ratio | "
                 "95 % CI | CV z/c | verdict |")
        L.append("|---|--:|--:|--:|--:|:--:|--:|:--|")
        for r in lr:
            try:
                rt = f"{float(r['ratio_median']):.3f}"
            except (ValueError, TypeError):
                rt = "n/a"
            try:
                ci = f"[{float(r['ci_lo']):.3f}, {float(r['ci_hi']):.3f}]"
            except (ValueError, TypeError):
                ci = "n/a"
            cvz = f"{float(r['cv_zig_pct']):.1f}/{float(r['cv_cpp_pct']):.1f}%"
            vmap = {"FASTER": "**faster**", "SLOWER": "**slower**",
                    "tie(noise)": "tie", "COUNT-MISMATCH": "mismatch"}
            vd = vmap.get(r["verdict"], r["verdict"])
            name = f"{r['scenario']} / {r['zone']}"
            L.append(f"| {name} | {r['n_zig']} | {fmt_ns(r['median_zig_ns'])} | "
                     f"{fmt_ns(r['median_cpp_ns'])} | {rt} | {ci} | {cvz} | {vd} |")

    g_all = geomean(sig_ratebox)
    L.insert(3, f"**Headline (significant zones only): {tot_f} faster / {tot_s} slower "
                f"/ {tot_t} tie; geomean ratio over significant zones = "
                f"{g_all:.3f}** (< 1.0 = Zig faster).\n")

    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print(f"wrote {out}  ({len(rows)} zones, {tot_f} faster / {tot_s} slower / "
          f"{tot_t} tie significant)")


if __name__ == "__main__":
    main()
