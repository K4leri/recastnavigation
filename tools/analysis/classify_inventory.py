#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
classify_inventory.py — first-pass isolatability classification of the raw function
inventory (microbench_inventory_raw.csv) into the A/B/C/D classes from
PERFUNC_BENCH_GOAL.md, with prerequisites + an improvable flag. Nothing is skipped:
every function gets a row. Classes are heuristics meant to be refined as functions
are wired into the runner.

  A pure/leaf        — plain value/slice inputs, no pipeline state
  B stage-w-prereq   — public build/query stage; needs upstream pipeline state
  C internal helper  — private helper inside a stage file
  D not-isolatable   — alloc/init/deinit/dispatcher/large-state

Usage: python classify_inventory.py <microbench_dir>
Reads microbench_inventory_raw.csv, writes microbench_inventory.csv.
"""
from __future__ import annotations
import csv, os, re, sys

# leaf-name patterns (pure math / geometry predicates / small helpers)
LEAF_RE = re.compile(
    r"^(v[a-z0-9]+|tri[A-Z]|dist|distance|closest|overlap|point|next|ilog|align|sqr|abs|min|max|clamp|swap|"
    r"calc[A-Z]|insertSort|cross|dot|lerp|normalize|isfinite|visfinite|intersect)",
)
# stage (class B) — public pipeline entry points
STAGE_NAMES = {
    "rasterizeTriangles", "rasterizeTriangle", "buildCompactHeightfield", "erodeWalkableArea",
    "medianFilterWalkableArea", "markBoxArea", "markConvexPolyArea", "markCylinderArea",
    "filterLowHangingWalkableObstacles", "filterLedgeSpans", "filterWalkableLowHeightSpans",
    "buildDistanceField", "buildRegions", "buildRegionsMonotone", "buildLayerRegions",
    "buildHeightfieldLayers", "buildContours", "buildPolyMesh", "buildPolyMeshDetail",
    "mergePolyMeshes", "createHeightfield", "calcGridSize", "calcBounds",
}
STAGE_PREFIX = ("build", "rasterize", "erode", "filter", "mark", "create")
# not-isolatable (class D) — lifecycle / dispatch / heavy state
D_RE = re.compile(r"^(init|deinit|alloc|free|reset|create|destroy|add|remove|set|get|update|run|main)")
ALLOC_HINT = re.compile(r"allocator|!void|!bool|try ")


def classify(module, file, vis, name, sig):
    is_pub = vis == "pub"
    fbase = os.path.basename(file)
    # class B: known stage or build-prefixed public recast entry
    if module == "recast" and is_pub and (name in STAGE_NAMES or name.startswith(STAGE_PREFIX)):
        return "B", "region-partitioned pipeline state (run prereq chain once)", "maybe"
    # class A: leaf math / pure predicate (math.zig, or leaf-named pure helper, no allocator)
    if (fbase == "math.zig" or LEAF_RE.match(name)) and "allocator" not in sig:
        return "A", "plain value/slice inputs", "maybe" if not _trivial(name) else "no"
    # class D: lifecycle / dispatcher / allocator-driven
    if D_RE.match(name) or "allocator" in sig:
        return "D", "lifecycle/dispatch or allocator-driven state", "no"
    # class C: private helper inside a stage file
    if not is_pub:
        return "C", "internal to enclosing stage (drive via stage or reconstruct args)", "maybe"
    return "C", "public helper; needs enclosing-stage context", "maybe"


def _trivial(name):
    return name in {"min", "max", "abs", "sqr", "swap", "vcopy", "vmin", "vmax", "vequal",
                    "vdot", "vdot2D", "vadd", "vsub", "vscale", "vlenSqr", "align4", "isfinite"}


def main(d):
    raw = os.path.join(d, "microbench_inventory_raw.csv")
    out = os.path.join(d, "microbench_inventory.csv")
    counts = {"A": 0, "B": 0, "C": 0, "D": 0}
    with open(raw) as f, open(out, "w", newline="", encoding="utf-8") as o:
        w = csv.writer(o)
        w.writerow(["module", "file", "line", "visibility", "name", "class", "prerequisites", "improvable", "signature_head"])
        for r in csv.DictReader(f):
            cls, prereq, impr = classify(r["module"], r["file"], r["visibility"], r["name"], r["signature_head"])
            counts[cls] += 1
            w.writerow([r["module"], r["file"], r["line"], r["visibility"], r["name"], cls, prereq, impr, r["signature_head"]])
    total = sum(counts.values())
    print(f"classified {total} functions -> {out}")
    print(f"  A pure/leaf:        {counts['A']}")
    print(f"  B stage-w-prereq:   {counts['B']}")
    print(f"  C internal helper:  {counts['C']}")
    print(f"  D not-isolatable:   {counts['D']}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
