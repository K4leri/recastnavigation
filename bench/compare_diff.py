#!/usr/bin/env python3
"""Diff two MIN_OF_RUNS_SCOREBOARD.csv files.

By default this ignores below-floor rows because System-B ratios there are not
trusted. Output is sorted by largest absolute ratio delta first, so regressions
and wins are visible without hand-filtering CSVs.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Row:
    scenario: str
    zone: str
    layer: str
    metric: str
    ratio: float
    below_floor: bool
    count_parity: bool


def parse_ratio(raw: str) -> float:
    if raw == "inf":
        return math.inf
    return float(raw)


def load(path: Path, include_floor: bool) -> dict[tuple[str, str], Row]:
    rows: dict[tuple[str, str], Row] = {}
    with path.open("r", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            below_floor = r.get("below_floor", "no") == "yes"
            if below_floor and not include_floor:
                continue
            key = (r["scenario"], r["zone"])
            rows[key] = Row(
                scenario=r["scenario"],
                zone=r["zone"],
                layer=r.get("layer", r["scenario"].split("_", 1)[0]),
                metric=r.get("metric", ""),
                ratio=parse_ratio(r["ratio"]),
                below_floor=below_floor,
                count_parity=r.get("count_parity", "no") == "yes",
            )
    return rows


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("old_csv", type=Path)
    p.add_argument("new_csv", type=Path)
    p.add_argument("--include-floor", action="store_true", help="include rows below the QPC floor")
    p.add_argument("--top", type=int, default=30)
    p.add_argument("--regression-threshold", type=float, default=0.05, help="ratio delta considered a regression")
    p.add_argument("--win-threshold", type=float, default=-0.05, help="ratio delta considered a win")
    args = p.parse_args()

    old = load(args.old_csv, args.include_floor)
    new = load(args.new_csv, args.include_floor)
    common = sorted(set(old) & set(new))
    missing_old = sorted(set(new) - set(old))
    missing_new = sorted(set(old) - set(new))

    deltas = []
    for key in common:
        o = old[key]
        n = new[key]
        if not (math.isfinite(o.ratio) and math.isfinite(n.ratio)):
            continue
        delta = n.ratio - o.ratio
        deltas.append((abs(delta), delta, o, n))
    deltas.sort(reverse=True, key=lambda x: x[0])

    regressions = [x for x in deltas if x[1] >= args.regression_threshold]
    wins = [x for x in deltas if x[1] <= args.win_threshold]

    print(f"common={len(common)} new_only={len(missing_old)} old_only={len(missing_new)}")
    print(f"regressions(delta>={args.regression_threshold:+.3f})={len(regressions)} wins(delta<={args.win_threshold:+.3f})={len(wins)}")
    print()
    print(f"{'delta':>9} {'old':>9} {'new':>9}  scenario / zone")
    for _, delta, o, n in deltas[: args.top]:
        parity = "" if n.count_parity else " count-mismatch"
        print(f"{delta:>+9.3f} {o.ratio:>9.3f} {n.ratio:>9.3f}  {n.scenario} / {n.zone}{parity}")

    if missing_old:
        print("\nnew-only rows:")
        for scenario, zone in missing_old[: args.top]:
            print(f"  {scenario} / {zone}")
    if missing_new:
        print("\nold-only rows:")
        for scenario, zone in missing_new[: args.top]:
            print(f"  {scenario} / {zone}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
