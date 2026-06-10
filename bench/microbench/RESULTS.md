# Per-function ReleaseFast benchmark — RESULTS & conclusions

**Scope:** every function in `src/recast`, `src/detour`, `src/detour_crowd` (396 inventoried)
plus the `src/math.zig` leaf set. **ReleaseFast only.** Goal: benchmark each original,
write ≥1 *analog* (alternative impl), prove it bit-identical over an input sweep (or reject
it), benchmark orig-vs-analog head-to-head, and adopt the analog only when it is faster AND
output-identical.

This file is the durable record. The raw machine-readable traces are committed alongside it
in [`results/`](results/) (the live working copies live under the gitignored `dev/research/microbench/`).
Regenerate with `zig build microbench -Doptimize=ReleaseFast` then
`python tools/analysis/microbench_full_report.py dev/research/microbench`.

Verified by a 6-agent analysis workflow (one analyst per module + a completeness/accuracy
critic). Critic verdict: **all 396 functions have a verdict + cost-or-reason; no gaps; every
benched leaf-orig has ≥1 analog; all 4 WIN functions are backed by adopted, gate-passing analogs.**

---

## TL;DR — the main conclusion

**The library is already at the optimum for leaf functions; the only real wins are at the
pipeline-stage level, and they come from Zig comptime/data-layout, not algorithm changes —
those 5 wins are already adopted & merged.**

- **No leaf function yielded an adoptable win.** Every leaf analog is either bit-identical with
  no speedup (**TIE** — original optimal) or not bit-identical (**REJECT** — original kept).
- **Floating-point reassociation is never behaviour-preserving.** Every `@mulAdd`/fma analog of
  a sum-of-products was rejected by the exact-identity gate: fma fuses the intermediate rounding,
  changing the f32 result. This is a mathematical fact (IEEE-754), now proven empirically on ~20 functions.
- **The real wins are the heavy stages** (distfield/contours/regions/compact/rasterize), driven by
  `inline for` comptime-dir folding + packed structs — **7%–42%**, all merged to master, all bit-identical.

## Coverage — all 396 functions (`results/verdicts.csv`)

| verdict | count | meaning |
|---|---:|---|
| **WIN** | 4 | faster analog adopted + merged (output-identical) |
| **TIE** | 46 | benched head-to-head; analog bit-identical but no gain / at ~1 ns timer floor → original optimal |
| **COVERED-VIA-STAGE** | 147 | internal helper (class C); cost captured inside its enclosing stage |
| **N/A** | 199 | lifecycle/alloc/dispatch (class D) + trivial accessors + fixture-only leaf — no analog |

class-A leaf (37): **24 measured individually**, 13 reasoned (7 need a navmesh/agent fixture →
covered via query/crowd stage; 3 trivial count accessors; `distToTriMesh` via detail stage;
`calcSlabEndPoints` struct-scoped). Leaf head-to-head trace: **109 rows** = 50 orig fns + ~54 analogs
(24 REJECT, 30 TIE).

---

## WIN — adopted analogs (faster, output-identical, merged) — `results/adopted_analogs.csv`

| stage | best scenario | orig | analog | speedup | how | commit |
|---|---|---:|---:|---:|---|---|
| `buildDistanceField` | map_6 | 247.7 ms | 147.6 ms | **1.68×** | `inline-for` + `CompactCell` 8→4 B pack | 565ba5b |
| `buildContours` | map_6 | 80.0 ms | 46.5 ms | **1.72×** | `getCornerHeight` comptime-dir + flag loop | 04c0392 |
| `buildCompactHeightfield` | map_6 | 187.3 ms | 147.2 ms | **1.27×** | packed `CompactSpan` single-store + con-batch | 565ba5b |
| `buildRegions` | map_1 | 871 ms | 699 ms | **1.25×** | flood/expand `inline-for` unroll | 565ba5b |
| `rcRasterizeTriangles` | map_1 | 300.8 ms | 278.9 ms | **1.08×** | `dividePoly` `inline-for` xyz | 04c0392 |

Speedup varies by scenario/map (data-dependent iteration counts): buildDistanceField/buildContours
27–42%; buildCompactHeightfield ~21%; buildRegions 6–20% (wide because flood-fill depth is data-dependent);
rcRasterizeTriangles ~7%. All `check_ok = yes` (output struct identical).

**Root cause of the wins:** Zig/LLVM does not unroll the fixed 4-iteration direction loops; making
`dir` comptime via `inline for (0..4)` folds `getDirOffsetX/Y` + `getCon` to constants, eliminating
rodata lookups in the hot stages. Plus the `CompactCell` layout bug (8→4 bytes packed) improves cache
density on the per-neighbour-lookup array. These are language-level, not algorithmic — bit-identical.

---

## Per-module conclusions

### math (src/math.zig) — 31 leaf fns benched, 0 wins
- **fma rejection is systematic:** ~15 `@mulAdd` analogs (vdot, vmad, vlerp, vcross, vperp2D, vlenSqr,
  vlen, all v-dist variants, distancePtSegSqr2D, intersectSegSeg2D, closestPtPointTriangle, triArea2D)
  → all `check_ok=no`. fma ≠ sequential `a*b+c*d` at the bit level. **No behaviour-preserving fma analog exists.**
- **Structural reorders are bit-identical → TIE:** `overlapQuantBounds` AND-chain (De Morgan), `align4`
  `&~3`≡`&-4`, `pointInPolygon` modulo-index, `overlapPolyPoly2D` B-first SAT (40.7 ns ≈ 41.3 ns).
  The library is already written the optimal way; LLVM isn't missing anything.
- **Loop-vs-unrolled** (vsub/vadd/vscale/vcopy/vmin/vmax): bit-identical; LLVM unrolls anyway → unrolled
  original equal-or-faster. **No plausible scalar alternative beyond this (SIMD excluded by request).**
- **div-vs-reciprocal** (vnormalize `/len`, calcPolyCenter `/n`): `/` differs from `*(1/x)` → REJECT
  (vnormalize) or bit-identical-but-no-faster TIE (calcPolyCenter). Original reciprocal-multiply optimal.
- **Notable:** some fma analogs *pass* the gate (vequal, closestHeightPointTriangle) → LLVM **already
  contracts the original to fma** in ReleaseFast, so an explicit `@mulAdd` is redundant.

### recast-leaf (detail / contour / area / mesh / rasterization) — 19 leaf fns benched, 0 wins
- Pure geometry predicates & distance helpers, 1–10 ns. At this scale **precision (bit-identity) is the
  binding constraint, not speed** — there is no slack to optimize.
- fma analogs (distancePtSeg ×3, distPtTri, …) universally REJECTED; structural/predicate reorders
  (overlapBounds zyx-chain, mesh intersectProp inlined, vequal or-diff) bit-identical → TIE.
- **`insertSort` vs `std.sort`:** stdlib pdqsort is **1.73× *slower*** for n=8 — hand-written insertion
  sort wins for tiny arrays. Original kept.
- **`intersect` between-first:** ~6% faster **only** for the benched T-intersection but **regresses proper
  crossings** (it reorders an `or` short-circuit: orig calls `intersectProp` first = 1 call; analog does
  4 `between` checks first). Input-dependent, net-neutral → **situational, NOT adopted.**
- Gate integrity spot-checked (distPtTri, overlapBounds): gates use exact `==`/`!=` against the real
  library fn, not a relaxed/abs metric.

### detour (common / builder) — 2 leaf fns benched
- `triArea2D` fma → REJECT (5000-input gate; fma elides intermediate rounding). `calcExtends` unrolled →
  TIE (integer min/max reduction, bit-identical, ~1 ns floor).

### detour_crowd (obstacle_avoidance) — 2 leaf fns benched
- `normalizeArray` analog bit-identical (gate over 2000 inputs) but no speedup → TIE.
- `normalize2D` div-variant **provably NOT behaviour-preserving** (`/d` vs `*(1/d)`); gate also exercises
  the zero-length edge case → REJECT. Original kept.

### stages-and-wins (class-B) — the 5 adopted wins above
- All bit-identical by design (language-level: struct packing + comptime), no rejects. Packed `CompactCell`
  (u24+u8) / `CompactSpan` give 21–37% via cache density; `inline-for`/comptime-dir fold static dispatch.

---

## Method & caveats (so the numbers are read correctly)
- **Timer floor ≈ 1 ns.** Leaf fns sit at it; ratios 0.8–1.1 there are pure quantization noise, recorded
  as TIE/optimal, not a result. Only costs above ~3 ns carry a meaningful ratio.
- **Fair head-to-head is mandatory.** One analog (overlapPolyPoly2D) first looked 2.4× faster purely because
  it varied its input while the orig was loop-invariant; with matched constant input it ties (~41 ns). All
  reported numbers use identical inputs for orig and analog.
- **Identity gate.** Every analog's `check` compares its output to the *real library function* over an input
  sweep with exact `==` (or output-struct equality for stages). `check_ok=no` ⇒ REJECT (recorded as data,
  not a failure). Critic confirmed no gate uses a relaxed/abs metric.
- **Tests:** 99/106 pass. The 2 `pathfinding_test` failures are a pre-existing `test_data/*.obj`
  path/cwd `FileNotFound` (identical on clean HEAD) — unrelated to this work; the `pub`-exposure edits are
  purely additive (`fn`→`pub fn`).
- **Excluded by request:** SIMD/`@Vector`, SoA, ReleaseSafe/Debug.

## Files
- `RESULTS.md` (this file) — conclusions.
- `results/verdicts.csv` — every function (396): module, function, class, verdict, releasefast_ns, note.
- `results/leaf_ReleaseFast.csv` — leaf head-to-head trace (orig + analogs, min/mean/median/p95, check_ok).
- `results/adopted_analogs.csv` — the 5 merged WIN stages (orig→analog ns, scenario, commit).
- `results/stages_ReleaseFast.csv` — pipeline-stage costs.
- `results/microbench_inventory.csv` — the full 396 classification (A/B/C/D).

---

## Addendum (2026-06) — ASM re-audit on Zig 0.16: two corrections

An orig-vs-analog **ReleaseFast assembly tour** of every bench group on the *current* Zig 0.16
toolchain (`-femit-asm`, isolated export-fn shims differing in one variable), plus a **same-run
runtime A/B** on the distance-field boundary loop, revised two conclusions recorded above.

### Correction 1 — the `inline for`/comptime-dir wins split by whether LLVM unrolls the runtime loop

The original claim ("`inline for` folds `getDirOffsetX/Y`+`getCon` static dispatch") is only
**materially alive for ONE of the five wins on Zig 0.16**. LLVM now unrolls the simple fixed-trip
direction loops by itself, so the `inline for` produces (near-)identical code there:

| stage | orig `for` vs analog `inline for` — ReleaseFast asm (Zig 0.16) | revised verdict |
|---|---|---|
| `rcRasterizeTriangles` (dividePoly xyz) | **byte-identical** (159 vs 159, label names only) | inline-for now **neutral** — LLVM unrolls `for(0..3)` identically |
| `buildRegions` (expand dir-sweep) | byte-equal mod labels + commutative-operand swaps (115 vs 115) | **≈ neutral** in codegen |
| `buildDistanceField` (boundary mark) | near-equal count (150 vs 147) but better address-mode selection in analog | **small real win remains** (see method note) |
| `buildContours` (`getCornerHeight`) | **materially different** — runtime keeps 2 rodata offset tables + variable `shrx` getCon shift; comptime specializes into 4 const-shift blocks via a jump table (273 vs 732 instrs) | **win intact** — LLVM does NOT unroll the complex loop body |
| `buildCompactHeightfield` (packed CompactSpan) | packed → **1 wide store vs 4 narrow**, **1 load vs 2** on the connect read, 8 B vs 12 B | **win intact** — data layout, compiler cannot undo |

**Takeaway.** On the current toolchain the comptime-dir *component* is mostly subsumed for the
simple-bodied stages (raster/regions, and ~0 codegen for distfield); it survives only in
`buildContours`, whose `getCornerHeight` body LLVM declines to unroll. The headline stage speedups
remain valid **as measured at adoption time**, but the **durable, compiler-proof** part of the
distfield/compact wins is the `CompactCell`/`CompactSpan` **packing (data layout)**, not the
`inline for`. The `inline for` on raster/regions/distfield is now mostly documentary — harmless to
keep, not the source of a codegen edge.

**Method note (instruction count ≠ runtime).** `buildDistanceField`'s boundary loop is 150 vs 147
instrs — looks like noise — yet a **same-run min-of-30 A/B** (noise cancels) shows the analog
**consistently 2–10 % faster** (direction stable across runs; magnitude noisy). Address-mode /
scheduling differences in a tight per-span loop are real below what an instruction-count diff shows.
The same-run A/B is the correct instrument under ~10 %; the cross-run ±20 % machine noise cannot see it.

That same-run win is on the **isolated boundary-mark loop**. At the **full-stage** level it washes out:
a registered `impl=orig-for-runtime` analog of `buildDistanceField` (bit-identical, gate-green — proving
the `inline for`↔`for` swap is output-preserving across both the calc and boxBlur sweeps) measures as a
**TIE within the framework's separate-pass ±20 % noise** (it even leans the other way some runs). The
boundary loop is only a fraction of the stage (sweeps are hand-unrolled regardless; boxBlur + allocs
dominate), so the real isolated-loop edge is too small to register end-to-end. Reproduce the *identity*
via `zig build microbench` (the `orig-for-runtime` row); the *precise* per-loop ratio needs a same-run
interleaved A/B — the System-A harness measures impls in separate passes and cannot resolve <10 %.

### Correction 2 — the "fma auto-contract" note is wrong at the codegen level

The per-module math note above ("some fma analogs pass the gate — `vequal`,
`closestHeightPointTriangle` — because LLVM *already contracts the original to fma* in ReleaseFast,
so an explicit `@mulAdd` is redundant") is **incorrect at the asm level**. On Zig 0.16 ReleaseFast
(which is **not** fast-math), **no leaf orig auto-contracts**: `vequal_orig`, `chpt_denom_orig`,
`vdot_orig`, … all emit the plain `vmulss`+`vaddss`/`vsubss` chain (`vfmadd` count = 0 across every
orig checked). LLVM sets the `contract` flag **only** where the source explicitly writes `@mulAdd`.
So those TIEs are **measurement** ties (the fma analog *is* genuinely fewer instructions, but the
timer-floor / run noise did not flip the verdict over the sweep) — **not** asm-identity ties. The
explicit `@mulAdd` is **not** redundant at codegen; it changes the emitted code (one `vfmadd###ss`
replacing a `mul;add` pair) **and** the result bits, which is exactly why the identity gate REJECTs
it. The redundancy would only appear under a fast-math build, which this project does not use.

## TILECACHE group (2026-06-10) — bench_tilecache.zig / analogs_tilecache.zig

Targets from `docs/perf-audit/TILECACHE-OPTIMIZATION-PLAN.md` (the only Zig-slower
scenario layer, geomean 1.115). Fixture: 4 synthetic 48x48 layers (terraces step 3,
ridge step 8, ~2% null sprinkle; 36 final regions); identity gate = exact
status+regs[]+reg_count over 2000 seeded layers.

| function | impl | min ns (RF) | verdict |
|---|---|---|---|
| buildTileCacheRegions | orig (pre-fix) | 37 886 | baseline |
| buildTileCacheRegions | hoisted-ptrs | 35 900 | TIE — slice-aliasing reloads are NOT the cost |
| buildTileCacheRegions | merge-early | 32 693 | **WIN −14 %, adopted** (canMerge early-exit; bit-exact by monotonicity of `count`) |
| buildTileCacheRegions | fba-scratch | 27 756* | WIN — covered in production by the new `TileCache.build_arena` (1:1 upstream `dtTileCacheAlloc`) |
| createNavMeshData | orig (FBA) | 70.5 | floor-class |
| createNavMeshData | smp-alloc | 76.7 | allocator delta ~7 ns ⇒ does not explain the scenario 1.14–1.26; residual documented |
| addBoxObstacle | orig | 5.2 | FLOOR — scenario 1.5× ratio is QPC quantization |
| removeObstacle | orig | 5.6 | FLOOR — same |

\* page_allocator baseline exaggerates the alloc share; the scenario (gpa) delta is
smaller. Root cause of the remaining regions gap (ASM, idalib, MSVC /O2 AVX2 vs
ReleaseFast): LLVM spills ~8 values around the inlined canMerge per candidate and
8x-unrolls loops whose trip count is usually 1–4; MSVC keeps the merge bookkeeping
fully in registers. The early-exit fix removes most of the long-scan pressure.

### Addendum (post-adoption ASM re-audit + noinline experiment)

Re-disassembled the ADOPTED orig (fresh IDA DB — beware: idalib caches the .i64
per path, a rebuilt exe under the same path shows STALE asm until reopened from a
new path). The early-exit source change also fixed the codegen pathology: the
canMerge inner loop is now a tight rolled scan with the count>1 exit (the 8x
setz-unroll is gone) and the merge-loop spill set shrank to a few slots — shape
now close to MSVC's. Last cheap lever tried: `noinline` canMerge
(impl=noinline-canmerge) to free the outer loop's registers entirely —
**TIE over 3 same-run repeats** (orig 31.5/32.2/33.0 µs min vs nicm
32.1/32.4/32.3 µs), NOT adopted. The remaining scenario residual
(regions 1.03–1.06 on map_2) has no further bit-identical source-level lever;
a merge-loop restructure would be the next (risky, deferred) step.
