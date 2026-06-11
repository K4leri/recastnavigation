# Statistical results — Zig vs C++ (median + 95 % CI)

Auto-generated from `STAT_SCOREBOARD.csv` by `tools/analysis/gen_stat_table.py`.

> **Follow-up:** the slower-tail audit — what was fixed, what was investigated and
> deliberately left alone (with rationale), and the honest residual — is in
> [`AUDIT-FINDINGS.md`](./AUDIT-FINDINGS.md). It also explains what the benchmark is and
> why we run it.

## Method

Each (scenario, function) was measured **K times per side, interleaved** (zig, cpp, zig, cpp, …) so slow thermal/load drift hits both sides equally. Within one measurement the function runs many times and the runner emits one aggregate (solo-build = `min_ns`, everything else = `mean_ns`); the **K such aggregates per side** are the sample. We report:

- **n** — samples per side (K). Fast layers K=15; BUILD K=7 (its run-to-run CV is 2–5 %, so the median is already stable).
- **median t_zig / t_cpp** — median of the K per-run aggregates.
- **ratio** = median(t_zig) / median(t_cpp). **< 1.0 = Zig faster.**
- **95 % CI** — bootstrap (3000 resamples, seeded) confidence interval of the median ratio.
- **CV%** — coefficient of variation of each side's samples (the machine noise floor; high CV ⇒ a small ratio difference is not trustworthy).
- **verdict** — **faster**/**slower** only if the 95 % CI *excludes 1.0* (statistically significant on this machine); otherwise **tie** (the difference is within noise — a sub-% claim is NOT supported, even if the point ratio ≠ 1).

> A **tie** is the honest result for most sub-µs zones: the timer/scheduler noise on a dev machine is larger than the true difference. Only zones whose CI clears 1.0 are claimed as wins or losses.

**Headline (significant zones only): 267 faster / 80 slower / 49 tie; geomean ratio over significant zones = 0.902** (< 1.0 = Zig faster).


## BUILD — 189 zones (K=7/side)

**157 faster (sig) / 14 slower (sig) / 18 tie (within noise).** Significant-only geomean ratio: **0.806** (over the 171 zones whose 95 % CI clears 1.0).

| scenario / function | n | median t_zig | median t_cpp | ratio | 95 % CI | CV z/c | verdict |
|---|--:|--:|--:|--:|:--:|--:|:--|
| build_solo_watershed_map_1_fat_agent / dtCreateNavMeshData | 7 | 1.153 ms | 2.160 ms | 0.534 | [0.530, 0.539] | 0.5/0.8% | **faster** |
| build_solo_watershed_map_1_coarse / dtCreateNavMeshData | 7 | 1.168 ms | 2.112 ms | 0.553 | [0.545, 0.559] | 1.1/0.5% | **faster** |
| build_solo_watershed_map_2 / dtCreateNavMeshData | 7 | 3.802 ms | 6.765 ms | 0.562 | [0.555, 0.570] | 1.1/1.1% | **faster** |
| build_solo_offmesh_map_1 / dtCreateNavMeshData | 7 | 8.718 ms | 15.484 ms | 0.563 | [0.557, 0.574] | 1.2/1.5% | **faster** |
| build_solo_watershed_map_1 / dtCreateNavMeshData | 7 | 8.617 ms | 15.288 ms | 0.564 | [0.558, 0.566] | 0.3/0.7% | **faster** |
| build_tiled_watershed_map_3_region / rcRasterizeTriangles | 7 | 2.444 ms | 4.327 ms | 0.565 | [0.545, 0.645] | 6.1/4.6% | **faster** |
| build_solo_monotone_map_1 / dtCreateNavMeshData | 7 | 9.025 ms | 15.968 ms | 0.565 | [0.560, 0.569] | 0.5/0.4% | **faster** |
| build_solo_watershed_map_5 / dtCreateNavMeshData | 7 | 1.711 ms | 3.015 ms | 0.567 | [0.562, 0.576] | 1.2/0.2% | **faster** |
| build_solo_watershed_map_4 / dtCreateNavMeshData | 7 | 3.325 ms | 5.818 ms | 0.572 | [0.568, 0.581] | 1.1/0.5% | **faster** |
| build_solo_layers_map_1 / dtCreateNavMeshData | 7 | 8.800 ms | 15.322 ms | 0.574 | [0.566, 0.578] | 0.5/0.7% | **faster** |
| build_solo_watershed_map_3 / dtCreateNavMeshData | 7 | 3.950 ms | 6.855 ms | 0.576 | [0.571, 0.580] | 0.6/0.7% | **faster** |
| build_solo_watershed_map_1_dense_detail / dtCreateNavMeshData | 7 | 9.289 ms | 15.946 ms | 0.583 | [0.570, 0.600] | 2.5/1.4% | **faster** |
| build_tiled_watershed_map_3_region / rcFilterLedgeSpans | 7 | 210.535 µs | 354.479 µs | 0.594 | [0.574, 0.644] | 3.6/3.6% | **faster** |
| build_tiled_layers_map_4_region / rcFilterLedgeSpans | 7 | 185.777 µs | 310.721 µs | 0.598 | [0.583, 0.606] | 1.1/4.0% | **faster** |
| build_solo_watershed_map_6 / rcFilterLedgeSpans | 7 | 57.598 ms | 95.567 ms | 0.603 | [0.594, 0.622] | 1.3/2.5% | **faster** |
| build_tiled_watershed_map_1_region / rcFilterLedgeSpans | 7 | 285.524 µs | 472.236 µs | 0.605 | [0.561, 0.667] | 4.5/4.6% | **faster** |
| build_solo_watershed_map_6 / dtCreateNavMeshData | 7 | 151.200 µs | 244.200 µs | 0.619 | [0.604, 0.636] | 1.0/1.8% | **faster** |
| build_tiled_watershed_map_1_region / rcRasterizeTriangles | 7 | 1.003 ms | 1.586 ms | 0.632 | [0.570, 0.719] | 5.7/6.3% | **faster** |
| build_tiled_layers_map_4_region / rcBuildCompactHeightfield | 7 | 222.444 µs | 347.643 µs | 0.640 | [0.626, 0.655] | 1.1/4.6% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildCompactHeightfield | 7 | 227.586 µs | 354.834 µs | 0.641 | [0.618, 0.698] | 3.8/4.0% | **faster** |
| build_tiled_watershed_map_2_region / rcFilterLedgeSpans | 7 | 385.308 µs | 595.816 µs | 0.647 | [0.612, 0.667] | 3.4/2.4% | **faster** |
| build_tiled_watershed_map_1_region / rcBuildCompactHeightfield | 7 | 269.644 µs | 416.955 µs | 0.647 | [0.600, 0.715] | 5.1/4.7% | **faster** |
| build_tiled_watershed_map_2_region / rcBuildCompactHeightfield | 7 | 328.189 µs | 499.842 µs | 0.657 | [0.630, 0.677] | 3.0/2.4% | **faster** |
| build_tiled_layers_map_4_region / rcRasterizeTriangles | 7 | 770.339 µs | 1.171 ms | 0.658 | [0.642, 0.674] | 1.5/5.8% | **faster** |
| build_solo_watershed_map_6 / rcBuildCompactHeightfield | 7 | 97.707 ms | 144.050 ms | 0.678 | [0.659, 0.689] | 2.0/0.9% | **faster** |
| build_solo_watershed_map_5 / rcFilterLedgeSpans | 7 | 44.278 ms | 64.335 ms | 0.688 | [0.684, 0.695] | 0.5/0.5% | **faster** |
| build_solo_offmesh_map_1 / rcBuildPolyMesh | 7 | 912.501 ms | 1307.506 ms | 0.698 | [0.683, 0.717] | 1.5/2.6% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcBuildPolyMesh | 7 | 908.236 ms | 1300.170 ms | 0.699 | [0.689, 0.719] | 1.2/2.9% | **faster** |
| build_solo_watershed_map_2 / rcFilterLedgeSpans | 7 | 88.578 ms | 126.502 ms | 0.700 | [0.682, 0.711] | 0.7/1.6% | **faster** |
| build_solo_watershed_map_4 / rcBuildPolyMesh | 7 | 322.126 ms | 459.732 ms | 0.701 | [0.696, 0.705] | 0.4/0.6% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcBuildPolyMesh | 7 | 51.394 ms | 72.736 ms | 0.707 | [0.702, 0.722] | 1.1/0.7% | **faster** |
| build_solo_watershed_map_1 / rcFilterLedgeSpans | 7 | 108.524 ms | 153.463 ms | 0.707 | [0.694, 0.726] | 0.9/1.8% | **faster** |
| build_solo_watershed_map_5 / rcBuildPolyMesh | 7 | 137.380 ms | 194.107 ms | 0.708 | [0.700, 0.714] | 0.7/0.7% | **faster** |
| build_solo_layers_map_1 / rcBuildPolyMesh | 7 | 1670.628 ms | 2358.225 ms | 0.708 | [0.705, 0.716] | 0.9/0.5% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcFilterLedgeSpans | 7 | 108.451 ms | 152.633 ms | 0.711 | [0.706, 0.722] | 0.9/0.6% | **faster** |
| build_tiled_watershed_map_2_region / rcRasterizeTriangles | 7 | 597.720 µs | 839.891 µs | 0.712 | [0.686, 0.738] | 2.8/3.0% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcFilterLedgeSpans | 7 | 108.988 ms | 153.062 ms | 0.712 | [0.687, 0.722] | 2.5/3.1% | **faster** |
| build_solo_watershed_map_4 / rcFilterLedgeSpans | 7 | 70.796 ms | 99.374 ms | 0.712 | [0.709, 0.717] | 0.7/0.3% | **faster** |
| build_solo_watershed_map_1 / rcBuildPolyMesh | 7 | 909.545 ms | 1275.262 ms | 0.713 | [0.703, 0.717] | 0.6/0.8% | **faster** |
| build_solo_monotone_map_1 / rcFilterLedgeSpans | 7 | 108.576 ms | 152.179 ms | 0.713 | [0.706, 0.723] | 0.6/0.8% | **faster** |
| build_solo_monotone_map_1 / rcBuildPolyMesh | 7 | 340.720 ms | 477.133 ms | 0.714 | [0.709, 0.719] | 0.2/0.8% | **faster** |
| build_tiled_watershed_map_1_region / dtCreateNavMeshData | 7 | 12.215 µs | 17.051 µs | 0.716 | [0.645, 0.776] | 5.1/5.0% | **faster** |
| build_solo_watershed_map_2 / rcBuildCompactHeightfield | 7 | 74.081 ms | 103.321 ms | 0.717 | [0.698, 0.750] | 3.8/2.6% | **faster** |
| build_solo_offmesh_map_1 / rcFilterLedgeSpans | 7 | 109.749 ms | 153.039 ms | 0.717 | [0.683, 0.740] | 4.3/2.7% | **faster** |
| build_tiled_watershed_map_3_region / dtCreateNavMeshData | 7 | 9.772 µs | 13.623 µs | 0.717 | [0.700, 0.776] | 3.6/3.7% | **faster** |
| build_solo_watershed_map_3 / rcBuildPolyMesh | 7 | 131.348 ms | 182.531 ms | 0.720 | [0.713, 0.722] | 0.7/0.5% | **faster** |
| build_solo_layers_map_1 / rcFilterLedgeSpans | 7 | 108.470 ms | 150.716 ms | 0.720 | [0.709, 0.733] | 2.1/0.8% | **faster** |
| build_solo_watershed_map_2 / rcBuildPolyMesh | 7 | 107.887 ms | 149.676 ms | 0.721 | [0.690, 0.747] | 1.7/3.6% | **faster** |
| build_solo_watershed_map_6 / rcBuildPolyMesh | 7 | 383.414 ms | 528.870 ms | 0.725 | [0.704, 0.746] | 1.9/2.2% | **faster** |
| build_tiled_layers_map_4_region / dtCreateNavMeshData | 7 | 8.007 µs | 11.037 µs | 0.725 | [0.699, 0.743] | 1.9/3.5% | **faster** |
| build_solo_watershed_map_6 / rcBuildPolyMeshDetail | 7 | 1395.276 ms | 1917.101 ms | 0.728 | [0.700, 0.760] | 2.6/2.3% | **faster** |
| build_solo_watershed_map_1_coarse / rcFilterLedgeSpans | 7 | 31.935 ms | 43.765 ms | 0.730 | [0.722, 0.741] | 0.4/1.1% | **faster** |
| build_solo_watershed_map_1_coarse / rcBuildPolyMesh | 7 | 16.900 ms | 23.077 ms | 0.732 | [0.726, 0.738] | 1.1/0.6% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildPolyMesh | 7 | 97.077 µs | 131.851 µs | 0.736 | [0.717, 0.800] | 4.7/3.3% | **faster** |
| build_tiled_watershed_map_1_region / rcBuildPolyMesh | 7 | 97.637 µs | 132.253 µs | 0.738 | [0.685, 0.836] | 5.6/4.3% | **faster** |
| build_solo_watershed_map_5 / rcBuildCompactHeightfield | 7 | 44.129 ms | 59.694 ms | 0.739 | [0.733, 0.750] | 1.1/1.3% | **faster** |
| build_tiled_watershed_map_2_region / dtCreateNavMeshData | 7 | 7.036 µs | 9.512 µs | 0.740 | [0.709, 0.760] | 3.2/2.2% | **faster** |
| build_tiled_layers_map_4_region / rcBuildPolyMesh | 7 | 118.333 µs | 159.863 µs | 0.740 | [0.720, 0.747] | 1.6/4.0% | **faster** |
| build_solo_watershed_map_5 / rcFilterLowHangingWalkableObstacles | 7 | 5.603 ms | 7.562 ms | 0.741 | [0.711, 0.781] | 3.9/3.5% | **faster** |
| build_solo_watershed_map_5 / rcFilterWalkableLowHeightSpans | 7 | 5.442 ms | 7.341 ms | 0.741 | [0.723, 0.790] | 2.5/3.8% | **faster** |
| build_solo_watershed_map_1 / rcBuildCompactHeightfield | 7 | 88.468 ms | 117.997 ms | 0.750 | [0.714, 0.796] | 2.9/3.4% | **faster** |
| build_tiled_watershed_map_1_region / rcFilterWalkableLowHeightSpans | 7 | 16.169 µs | 21.538 µs | 0.751 | [0.690, 0.852] | 4.8/6.0% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcBuildCompactHeightfield | 7 | 89.721 ms | 118.641 ms | 0.756 | [0.726, 0.782] | 6.0/3.2% | **faster** |
| build_solo_watershed_map_3 / rcFilterLedgeSpans | 7 | 108.352 ms | 142.367 ms | 0.761 | [0.747, 0.767] | 0.4/1.1% | **faster** |
| build_solo_offmesh_map_1 / rcBuildCompactHeightfield | 7 | 90.053 ms | 117.901 ms | 0.764 | [0.729, 0.799] | 3.3/2.9% | **faster** |
| build_solo_monotone_map_1 / rcBuildCompactHeightfield | 7 | 88.437 ms | 115.140 ms | 0.768 | [0.752, 0.781] | 1.3/1.2% | **faster** |
| build_solo_watershed_map_4 / rcBuildCompactHeightfield | 7 | 60.923 ms | 79.315 ms | 0.768 | [0.746, 0.781] | 2.0/1.1% | **faster** |
| build_solo_watershed_map_3 / rcBuildCompactHeightfield | 7 | 70.585 ms | 91.877 ms | 0.768 | [0.754, 0.798] | 1.3/2.1% | **faster** |
| build_tiled_watershed_map_3_region / rcFilterWalkableLowHeightSpans | 7 | 16.555 µs | 21.491 µs | 0.770 | [0.730, 0.848] | 3.4/5.3% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcBuildCompactHeightfield | 7 | 89.156 ms | 115.588 ms | 0.771 | [0.756, 0.781] | 0.9/0.7% | **faster** |
| build_solo_layers_map_1 / rcBuildCompactHeightfield | 7 | 87.399 ms | 113.088 ms | 0.773 | [0.762, 0.795] | 2.8/1.4% | **faster** |
| build_tiled_layers_map_4_region / rcBuildPolyMeshDetail | 7 | 184.389 µs | 238.236 µs | 0.774 | [0.763, 0.792] | 1.1/5.1% | **faster** |
| build_tiled_watershed_map_1_region / rcBuildRegions | 7 | 429.301 µs | 551.805 µs | 0.778 | [0.724, 0.880] | 4.6/4.7% | **faster** |
| build_solo_watershed_map_1_coarse / rcBuildCompactHeightfield | 7 | 16.592 ms | 21.303 ms | 0.779 | [0.759, 0.782] | 0.7/1.0% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildPolyMeshDetail | 7 | 174.496 µs | 221.227 µs | 0.789 | [0.763, 0.865] | 3.1/4.4% | **faster** |
| build_tiled_watershed_map_1_region / rcBuildPolyMeshDetail | 7 | 243.673 µs | 308.176 µs | 0.791 | [0.729, 0.897] | 4.7/5.4% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildRegions | 7 | 364.358 µs | 460.651 µs | 0.791 | [0.770, 0.853] | 3.2/3.8% | **faster** |
| build_tiled_watershed_map_2_region / rcBuildPolyMesh | 7 | 63.267 µs | 79.966 µs | 0.791 | [0.753, 0.805] | 2.6/2.1% | **faster** |
| build_tiled_watershed_map_2_region / rcBuildPolyMeshDetail | 7 | 248.625 µs | 313.847 µs | 0.792 | [0.744, 0.796] | 2.5/2.6% | **faster** |
| build_tiled_watershed_map_2_region / rcBuildRegions | 7 | 599.439 µs | 753.620 µs | 0.795 | [0.765, 0.815] | 2.7/2.2% | **faster** |
| build_solo_watershed_map_1 / rcFilterWalkableLowHeightSpans | 7 | 14.158 ms | 17.636 ms | 0.803 | [0.746, 0.997] | 6.9/9.9% | **faster** |
| build_tiled_watershed_map_1_region / rcFilterLowHangingWalkableObstacles | 7 | 17.861 µs | 21.986 µs | 0.812 | [0.758, 0.923] | 5.1/5.7% | **faster** |
| build_solo_watershed_map_1_coarse / rcFilterLowHangingWalkableObstacles | 7 | 3.462 ms | 4.185 ms | 0.827 | [0.626, 0.953] | 13.8/10.2% | **faster** |
| build_solo_offmesh_map_1 / rcBuildRegions | 7 | 626.790 ms | 751.292 ms | 0.834 | [0.814, 0.861] | 2.1/1.5% | **faster** |
| build_tiled_watershed_map_1_region / rcErodeWalkableArea | 7 | 210.263 µs | 251.333 µs | 0.837 | [0.777, 0.937] | 3.9/5.5% | **faster** |
| build_solo_watershed_map_5 / rcRasterizeTriangles | 7 | 62.729 ms | 74.926 ms | 0.837 | [0.830, 0.862] | 2.0/0.9% | **faster** |
| build_solo_watershed_map_3 / rcFilterLowHangingWalkableObstacles | 7 | 14.714 ms | 17.488 ms | 0.841 | [0.807, 0.859] | 2.4/2.1% | **faster** |
| build_solo_watershed_map_6 / rcRasterizeTriangles | 7 | 444.816 ms | 527.088 ms | 0.844 | [0.815, 0.864] | 1.6/2.4% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcBuildRegions | 7 | 628.406 ms | 744.167 ms | 0.844 | [0.804, 0.868] | 1.7/2.5% | **faster** |
| build_tiled_watershed_map_3_region / rcFilterLowHangingWalkableObstacles | 7 | 19.090 µs | 22.534 µs | 0.847 | [0.786, 0.898] | 3.6/5.2% | **faster** |
| build_solo_watershed_map_3 / rcBuildRegions | 7 | 271.091 ms | 319.819 ms | 0.848 | [0.844, 0.858] | 1.1/0.4% | **faster** |
| build_solo_watershed_map_2 / rcFilterLowHangingWalkableObstacles | 7 | 10.394 ms | 12.243 ms | 0.849 | [0.817, 0.900] | 4.3/2.4% | **faster** |
| build_solo_watershed_map_1 / rcBuildRegions | 7 | 620.378 ms | 730.405 ms | 0.849 | [0.825, 0.868] | 1.0/2.2% | **faster** |
| build_tiled_watershed_map_2_region / rcErodeWalkableArea | 7 | 252.207 µs | 296.841 µs | 0.850 | [0.820, 0.860] | 1.9/2.1% | **faster** |
| build_tiled_watershed_map_3_region / rcErodeWalkableArea | 7 | 202.952 µs | 237.722 µs | 0.854 | [0.824, 0.925] | 3.0/4.2% | **faster** |
| build_tiled_watershed_map_2_region / rcFilterWalkableLowHeightSpans | 7 | 19.630 µs | 22.976 µs | 0.854 | [0.800, 0.890] | 3.9/3.8% | **faster** |
| build_solo_watershed_map_2 / rcBuildPolyMeshDetail | 7 | 151.119 ms | 176.547 ms | 0.856 | [0.833, 0.869] | 0.6/2.1% | **faster** |
| build_tiled_layers_map_4_region / rcErodeWalkableArea | 7 | 206.191 µs | 240.354 µs | 0.858 | [0.839, 0.875] | 0.9/4.6% | **faster** |
| build_solo_monotone_map_1 / rcFilterWalkableLowHeightSpans | 7 | 14.091 ms | 16.359 ms | 0.861 | [0.849, 0.933] | 3.0/5.0% | **faster** |
| build_solo_watershed_map_4 / rcFilterLowHangingWalkableObstacles | 7 | 10.413 ms | 12.025 ms | 0.866 | [0.824, 0.911] | 4.6/2.4% | **faster** |
| build_solo_watershed_map_6 / rcErodeWalkableArea | 7 | 88.066 ms | 101.117 ms | 0.871 | [0.865, 0.883] | 1.2/0.7% | **faster** |
| build_solo_watershed_map_2 / rcRasterizeTriangles | 7 | 120.510 ms | 137.742 ms | 0.875 | [0.853, 0.883] | 1.4/1.3% | **faster** |
| build_solo_layers_map_1 / rcRasterizeTriangles | 7 | 185.710 ms | 210.910 ms | 0.881 | [0.873, 0.896] | 0.8/1.0% | **faster** |
| build_tiled_layers_map_4_region / rcFilterWalkableLowHeightSpans | 7 | 16.696 µs | 18.878 µs | 0.884 | [0.867, 0.904] | 1.2/5.9% | **faster** |
| build_solo_watershed_map_4 / rcRasterizeTriangles | 7 | 123.507 ms | 139.558 ms | 0.885 | [0.877, 0.896] | 1.0/0.5% | **faster** |
| build_solo_watershed_map_2 / rcFilterWalkableLowHeightSpans | 7 | 10.474 ms | 11.813 ms | 0.887 | [0.817, 0.927] | 4.5/4.6% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcRasterizeTriangles | 7 | 186.969 ms | 210.678 ms | 0.887 | [0.881, 0.895] | 0.6/0.6% | **faster** |
| build_solo_watershed_map_1_coarse / rcBuildRegions | 7 | 72.406 ms | 81.370 ms | 0.890 | [0.882, 0.897] | 0.5/0.5% | **faster** |
| build_solo_watershed_map_1 / rcRasterizeTriangles | 7 | 186.812 ms | 209.592 ms | 0.891 | [0.873, 0.903] | 0.7/1.1% | **faster** |
| build_solo_monotone_map_1 / rcRasterizeTriangles | 7 | 186.698 ms | 208.921 ms | 0.894 | [0.888, 0.899] | 0.6/0.3% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcRasterizeTriangles | 7 | 189.031 ms | 211.476 ms | 0.894 | [0.859, 0.902] | 1.2/2.2% | **faster** |
| build_tiled_layers_map_4_region / rcBuildLayerRegions | 7 | 179.000 µs | 199.578 µs | 0.897 | [0.876, 0.919] | 1.3/5.1% | **faster** |
| build_solo_watershed_map_4 / rcFilterWalkableLowHeightSpans | 7 | 10.010 ms | 11.136 ms | 0.899 | [0.847, 0.947] | 4.4/2.6% | **faster** |
| build_solo_offmesh_map_1 / rcRasterizeTriangles | 7 | 189.664 ms | 209.903 ms | 0.904 | [0.878, 0.913] | 1.3/1.3% | **faster** |
| build_tiled_watershed_map_2_region / rcFilterLowHangingWalkableObstacles | 7 | 19.985 µs | 22.087 µs | 0.905 | [0.879, 0.952] | 2.8/2.3% | **faster** |
| build_solo_watershed_map_1_coarse / rcFilterWalkableLowHeightSpans | 7 | 2.761 ms | 3.048 ms | 0.906 | [0.821, 0.926] | 1.1/6.1% | **faster** |
| build_tiled_layers_map_4_region / rcFilterLowHangingWalkableObstacles | 7 | 17.184 µs | 18.960 µs | 0.906 | [0.873, 0.926] | 1.3/5.6% | **faster** |
| build_solo_watershed_map_1_coarse / rcRasterizeTriangles | 7 | 77.289 ms | 85.254 ms | 0.907 | [0.899, 0.916] | 0.4/0.5% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcErodeWalkableArea | 7 | 62.795 ms | 69.119 ms | 0.909 | [0.899, 0.953] | 3.2/2.3% | **faster** |
| build_solo_layers_map_1 / rcFilterLowHangingWalkableObstacles | 7 | 15.470 ms | 17.021 ms | 0.909 | [0.876, 0.957] | 1.8/3.4% | **faster** |
| build_solo_watershed_map_3 / rcRasterizeTriangles | 7 | 249.746 ms | 273.908 ms | 0.912 | [0.904, 0.922] | 0.6/0.8% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcBuildContours | 7 | 48.962 ms | 53.697 ms | 0.912 | [0.821, 1.063] | 8.0/6.3% | tie |
| build_solo_watershed_map_2 / rcErodeWalkableArea | 7 | 53.692 ms | 58.754 ms | 0.914 | [0.896, 0.931] | 1.4/1.2% | **faster** |
| build_solo_offmesh_map_1 / rcBuildPolyMeshDetail | 7 | 240.189 ms | 262.721 ms | 0.914 | [0.897, 0.963] | 1.5/2.7% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcBuildPolyMeshDetail | 7 | 130.622 ms | 142.296 ms | 0.918 | [0.908, 0.930] | 0.9/0.9% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcFilterWalkableLowHeightSpans | 7 | 15.157 ms | 16.497 ms | 0.919 | [0.870, 0.979] | 8.3/5.1% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildContours | 7 | 113.225 µs | 123.039 µs | 0.920 | [0.884, 1.013] | 4.0/4.9% | tie |
| build_solo_watershed_map_1_fat_agent / rcErodeWalkableArea | 7 | 61.106 ms | 66.311 ms | 0.922 | [0.918, 0.935] | 0.6/0.3% | **faster** |
| build_solo_monotone_map_1 / rcFilterLowHangingWalkableObstacles | 7 | 15.714 ms | 17.034 ms | 0.923 | [0.886, 0.953] | 2.7/2.0% | **faster** |
| build_solo_watershed_map_3 / rcFilterWalkableLowHeightSpans | 7 | 14.891 ms | 16.140 ms | 0.923 | [0.877, 0.969] | 1.2/4.0% | **faster** |
| build_solo_monotone_map_1 / rcBuildPolyMeshDetail | 7 | 237.822 ms | 256.739 ms | 0.926 | [0.919, 0.933] | 0.6/1.1% | **faster** |
| build_solo_watershed_map_2 / rcBuildRegions | 7 | 316.603 ms | 341.696 ms | 0.927 | [0.897, 0.957] | 0.9/2.4% | **faster** |
| build_solo_offmesh_map_1 / rcFilterWalkableLowHeightSpans | 7 | 15.726 ms | 16.917 ms | 0.930 | [0.828, 0.991] | 6.4/5.2% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcFilterLowHangingWalkableObstacles | 7 | 16.227 ms | 17.448 ms | 0.930 | [0.854, 0.953] | 4.4/3.5% | **faster** |
| build_solo_offmesh_map_1 / rcErodeWalkableArea | 7 | 62.756 ms | 67.444 ms | 0.930 | [0.911, 0.940] | 1.3/1.5% | **faster** |
| build_solo_watershed_map_1 / rcBuildPolyMeshDetail | 7 | 234.872 ms | 252.357 ms | 0.931 | [0.900, 0.937] | 0.5/1.7% | **faster** |
| build_solo_watershed_map_1 / rcFilterLowHangingWalkableObstacles | 7 | 16.027 ms | 17.218 ms | 0.931 | [0.849, 0.989] | 2.9/5.1% | **faster** |
| build_solo_layers_map_1 / rcBuildPolyMeshDetail | 7 | 236.717 ms | 254.147 ms | 0.931 | [0.924, 0.941] | 1.6/0.6% | **faster** |
| build_solo_watershed_map_1 / rcErodeWalkableArea | 7 | 62.690 ms | 67.280 ms | 0.932 | [0.927, 0.942] | 0.5/0.8% | **faster** |
| build_solo_layers_map_1 / rcErodeWalkableArea | 7 | 62.524 ms | 67.067 ms | 0.932 | [0.929, 0.942] | 0.7/0.5% | **faster** |
| build_solo_offmesh_map_1 / rcFilterLowHangingWalkableObstacles | 7 | 16.702 ms | 17.894 ms | 0.933 | [0.873, 0.968] | 3.7/2.6% | **faster** |
| build_solo_monotone_map_1 / rcErodeWalkableArea | 7 | 62.501 ms | 66.958 ms | 0.933 | [0.927, 0.937] | 0.2/0.6% | **faster** |
| build_solo_watershed_map_4 / rcBuildRegions | 7 | 215.197 ms | 230.240 ms | 0.935 | [0.922, 0.951] | 0.5/1.3% | **faster** |
| build_solo_watershed_map_4 / rcBuildPolyMeshDetail | 7 | 135.803 ms | 144.822 ms | 0.938 | [0.931, 0.953] | 0.8/0.7% | **faster** |
| build_solo_watershed_map_1_dense_detail / rcFilterLowHangingWalkableObstacles | 7 | 16.568 ms | 17.624 ms | 0.940 | [0.892, 0.978] | 5.4/2.1% | **faster** |
| build_solo_watershed_map_1 / rcBuildContours | 7 | 47.982 ms | 51.005 ms | 0.941 | [0.855, 0.976] | 2.0/5.9% | **faster** |
| build_solo_offmesh_map_1 / rcBuildContours | 7 | 52.758 ms | 56.069 ms | 0.941 | [0.885, 1.034] | 3.1/5.6% | tie |
| build_tiled_watershed_map_1_region / rcBuildContours | 7 | 118.598 µs | 125.908 µs | 0.942 | [0.845, 1.054] | 4.7/6.2% | tie |
| build_solo_watershed_map_1_dense_detail / rcBuildPolyMeshDetail | 7 | 17761.239 ms | 18767.497 ms | 0.946 | [0.886, 1.055] | 4.4/5.0% | tie |
| build_solo_watershed_map_3 / rcErodeWalkableArea | 7 | 50.897 ms | 53.776 ms | 0.946 | [0.941, 0.956] | 0.3/0.5% | **faster** |
| build_solo_watershed_map_1_coarse / rcBuildContours | 7 | 8.973 ms | 9.475 ms | 0.947 | [0.931, 0.958] | 1.7/0.8% | **faster** |
| build_solo_watershed_map_4 / rcErodeWalkableArea | 7 | 45.766 ms | 48.314 ms | 0.947 | [0.945, 0.953] | 0.4/0.3% | **faster** |
| build_solo_layers_map_1 / rcFilterWalkableLowHeightSpans | 7 | 13.884 ms | 14.656 ms | 0.947 | [0.896, 1.043] | 8.8/3.4% | tie |
| build_solo_watershed_map_5 / rcBuildPolyMeshDetail | 7 | 285.469 ms | 301.101 ms | 0.948 | [0.943, 0.950] | 0.2/0.6% | **faster** |
| build_tiled_layers_map_4_region / rcBuildContours | 7 | 111.708 µs | 117.069 µs | 0.954 | [0.931, 0.973] | 1.2/5.7% | **faster** |
| build_solo_watershed_map_1_fat_agent / rcFilterWalkableLowHeightSpans | 7 | 15.064 ms | 15.786 ms | 0.954 | [0.880, 0.979] | 5.4/2.8% | **faster** |
| build_solo_watershed_map_1_coarse / rcBuildPolyMeshDetail | 7 | 291.088 ms | 304.436 ms | 0.956 | [0.953, 0.966] | 1.1/0.6% | **faster** |
| build_solo_watershed_map_3 / rcBuildPolyMeshDetail | 7 | 507.380 ms | 528.880 ms | 0.959 | [0.942, 0.964] | 0.7/0.9% | **faster** |
| build_solo_layers_map_1 / rcBuildContours | 7 | 46.685 ms | 48.646 ms | 0.960 | [0.933, 0.983] | 1.7/3.0% | **faster** |
| build_solo_monotone_map_1 / rcBuildContours | 7 | 49.234 ms | 51.153 ms | 0.963 | [0.941, 1.010] | 2.8/4.1% | tie |
| build_tiled_watershed_map_1_region / rcBuildDistanceField | 7 | 290.441 µs | 300.850 µs | 0.965 | [0.902, 1.118] | 4.5/6.0% | tie |
| build_solo_watershed_map_5 / rcErodeWalkableArea | 7 | 37.550 ms | 38.859 ms | 0.966 | [0.958, 0.971] | 0.3/0.5% | **faster** |
| build_tiled_watershed_map_2_region / rcBuildContours | 7 | 130.780 µs | 134.777 µs | 0.970 | [0.931, 0.988] | 2.3/2.4% | **faster** |
| build_solo_watershed_map_1_coarse / rcErodeWalkableArea | 7 | 13.620 ms | 14.034 ms | 0.970 | [0.964, 0.973] | 0.4/0.2% | **faster** |
| build_solo_layers_map_1 / rcBuildLayerRegions | 7 | 69.863 ms | 71.618 ms | 0.976 | [0.966, 0.985] | 0.9/0.7% | **faster** |
| build_tiled_watershed_map_3_region / rcBuildDistanceField | 7 | 275.189 µs | 280.643 µs | 0.981 | [0.949, 1.076] | 3.4/4.6% | tie |
| build_solo_watershed_map_4 / rcBuildContours | 7 | 31.173 ms | 31.728 ms | 0.983 | [0.935, 1.023] | 2.1/2.1% | tie |
| build_solo_watershed_map_2 / rcBuildContours | 7 | 35.596 ms | 36.123 ms | 0.985 | [0.955, 1.028] | 2.9/4.3% | tie |
| build_solo_watershed_map_3 / rcBuildContours | 7 | 34.438 ms | 34.879 ms | 0.987 | [0.938, 1.006] | 2.2/2.6% | tie |
| build_solo_monotone_map_1 / rcBuildRegionsMonotone | 7 | 92.349 ms | 92.820 ms | 0.995 | [0.980, 1.017] | 1.7/2.9% | tie |
| build_tiled_watershed_map_2_region / rcBuildDistanceField | 7 | 355.760 µs | 351.702 µs | 1.012 | [0.966, 1.025] | 2.3/2.4% | tie |
| build_solo_watershed_map_1_dense_detail / rcBuildDistanceField | 7 | 78.865 ms | 77.666 ms | 1.015 | [0.993, 1.043] | 2.6/2.0% | tie |
| build_solo_offmesh_map_1 / rcBuildDistanceField | 7 | 79.054 ms | 77.839 ms | 1.016 | [0.995, 1.049] | 1.7/2.0% | tie |
| build_solo_watershed_map_5 / rcBuildRegions | 7 | 241.616 ms | 236.825 ms | 1.020 | [1.011, 1.041] | 0.9/1.3% | **slower** |
| build_solo_watershed_map_6 / rcBuildContours | 7 | 43.315 ms | 42.279 ms | 1.025 | [1.001, 1.055] | 1.6/1.5% | **slower** |
| build_solo_watershed_map_6 / rcFilterLowHangingWalkableObstacles | 7 | 8.473 ms | 8.264 ms | 1.025 | [0.945, 1.037] | 1.7/3.9% | tie |
| build_solo_watershed_map_3 / rcBuildDistanceField | 7 | 65.040 ms | 63.259 ms | 1.028 | [1.021, 1.041] | 0.3/0.8% | **slower** |
| build_solo_watershed_map_5 / rcBuildContours | 7 | 23.738 ms | 23.033 ms | 1.031 | [1.009, 1.048] | 1.3/1.4% | **slower** |
| build_solo_watershed_map_1 / rcBuildDistanceField | 7 | 78.832 ms | 76.203 ms | 1.034 | [1.016, 1.055] | 0.7/1.6% | **slower** |
| build_solo_watershed_map_2 / rcBuildDistanceField | 7 | 72.588 ms | 70.127 ms | 1.035 | [1.013, 1.062] | 1.3/1.4% | **slower** |
| build_solo_watershed_map_6 / rcBuildRegions | 7 | 1493.804 ms | 1441.310 ms | 1.036 | [1.009, 1.065] | 1.4/1.9% | **slower** |
| build_solo_watershed_map_1_fat_agent / rcBuildContours | 7 | 24.948 ms | 24.066 ms | 1.037 | [0.990, 1.050] | 1.4/2.7% | tie |
| build_solo_watershed_map_1_fat_agent / rcBuildDistanceField | 7 | 82.839 ms | 79.482 ms | 1.042 | [1.033, 1.045] | 0.4/0.5% | **slower** |
| build_solo_watershed_map_6 / rcBuildDistanceField | 7 | 137.248 ms | 131.171 ms | 1.046 | [1.033, 1.080] | 1.7/1.7% | **slower** |
| build_solo_watershed_map_4 / rcBuildDistanceField | 7 | 59.430 ms | 56.470 ms | 1.052 | [1.048, 1.061] | 0.5/0.5% | **slower** |
| build_solo_watershed_map_1_coarse / rcBuildDistanceField | 7 | 17.027 ms | 16.073 ms | 1.059 | [1.054, 1.064] | 0.4/0.3% | **slower** |
| build_solo_watershed_map_5 / rcBuildDistanceField | 7 | 50.332 ms | 47.397 ms | 1.062 | [1.052, 1.069] | 0.5/0.6% | **slower** |
| build_solo_watershed_map_1_fat_agent / rcBuildRegions | 7 | 289.002 ms | 268.527 ms | 1.076 | [1.065, 1.101] | 1.0/0.9% | **slower** |
| build_solo_watershed_map_6 / rcFilterWalkableLowHeightSpans | 7 | 8.545 ms | 7.731 ms | 1.105 | [1.041, 1.155] | 2.3/3.1% | **slower** |

## QUERY — 21 zones (K=15/side)

**10 faster (sig) / 4 slower (sig) / 7 tie (within noise).** Significant-only geomean ratio: **0.950** (over the 14 zones whose 95 % CI clears 1.0).

| scenario / function | n | median t_zig | median t_cpp | ratio | 95 % CI | CV z/c | verdict |
|---|--:|--:|--:|--:|:--:|--:|:--|
| query_findlocalneighbourhood_radius_sweep / dtFindLocalNeighbourhood | 15 | 202.0 ns | 272.0 ns | 0.743 | [0.697, 0.792] | 81.0/25.4% | **faster** |
| query_findstraightpath_crossings / dtFindStraightPath | 15 | 649.0 ns | 771.0 ns | 0.842 | [0.820, 0.854] | 24.7/1.7% | **faster** |
| query_multitile_raycast / dtRaycast | 15 | 170.0 ns | 198.0 ns | 0.859 | [0.837, 0.896] | 2.3/7.0% | **faster** |
| query_finddistancetowall_radius_sweep / dtFindDistanceToWall | 15 | 160.0 ns | 184.0 ns | 0.870 | [0.849, 0.917] | 9.6/9.4% | **faster** |
| query_findpolysaroundshape_convex_sweep / dtFindPolysAroundShape | 15 | 96.0 ns | 110.0 ns | 0.873 | [0.761, 0.971] | 5.6/15.8% | **faster** |
| query_multitile_straightpath / dtFindStraightPath | 15 | 716.0 ns | 802.0 ns | 0.893 | [0.854, 0.928] | 4.5/20.7% | **faster** |
| query_findpolysaroundcircle_radius_sweep / dtFindPolysAroundCircle | 15 | 223.0 ns | 249.0 ns | 0.896 | [0.690, 0.922] | 5.8/16.0% | **faster** |
| query_findnearestpoly_flood / dtFindNearestPoly | 15 | 399.0 ns | 444.0 ns | 0.899 | [0.888, 0.925] | 19.8/3.7% | **faster** |
| query_slicedpath_budget32 / dtUpdateSlicedFindPath | 15 | 853.0 ns | 943.0 ns | 0.905 | [0.891, 0.936] | 4.6/12.7% | **faster** |
| query_findstraightpath_flood / dtFindStraightPath | 15 | 455.0 ns | 477.0 ns | 0.954 | [0.919, 0.974] | 14.8/12.8% | **faster** |
| query_raycast_flood / dtRaycast | 15 | 113.0 ns | 118.0 ns | 0.958 | [0.933, 1.076] | 18.9/11.1% | tie |
| query_multitile_findpath / dtFindPath | 15 | 4.505 µs | 4.595 µs | 0.980 | [0.958, 1.004] | 4.4/6.1% | tie |
| query_movealongsurface_flood / dtMoveAlongSurface | 15 | 126.0 ns | 126.0 ns | 1.000 | [0.955, 1.032] | 2.0/8.3% | tie |
| query_findpath_flood / dtFindPath | 15 | 1.793 µs | 1.788 µs | 1.003 | [0.972, 1.036] | 3.3/11.6% | tie |
| query_findpath_long_diagonal / dtFindPath | 15 | 1.762 µs | 1.743 µs | 1.011 | [0.999, 1.038] | 3.1/8.6% | tie |
| query_findrandompointaroundcircle_radius_sweep / dtFindRandomPointAroundCircle | 15 | 432.0 ns | 421.0 ns | 1.026 | [0.938, 1.130] | 11.0/61.1% | tie |
| query_getpolyheight_snapped / dtGetPolyHeight | 15 | 105.0 ns | 97.0 ns | 1.082 | [0.982, 1.115] | 4.3/28.8% | tie |
| query_getpolywallsegments_portals / dtGetPolyWallSegments | 15 | 54.0 ns | 49.0 ns | 1.102 | [1.019, 1.167] | 32.3/12.5% | **slower** |
| query_findrandompoint_area_weighted / dtFindRandomPoint | 15 | 334.467 µs | 300.582 µs | 1.113 | [1.047, 1.215] | 8.4/4.3% | **slower** |
| query_slicedpath_budget32 / dtInitSlicedFindPath | 15 | 53.0 ns | 46.0 ns | 1.152 | [1.106, 1.178] | 3.1/18.1% | **slower** |
| query_isvalidpolyref_snapped / dtIsValidPolyRef | 15 | 30.0 ns | 22.0 ns | 1.364 | [1.304, 1.455] | 11.0/52.0% | **slower** |

## CROWD — 138 zones (K=15/side)

**73 faster (sig) / 45 slower (sig) / 20 tie (within noise).** Significant-only geomean ratio: **0.966** (over the 118 zones whose 95 % CI clears 1.0).

| scenario / function | n | median t_zig | median t_cpp | ratio | 95 % CI | CV z/c | verdict |
|---|--:|--:|--:|--:|:--:|--:|:--|
| crowd_choke_funnel_60_oa_high / crowd_velocity_planning_oa | 15 | 21.480 µs | 40.196 µs | 0.534 | [0.518, 0.564] | 7.0/4.1% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_velocity_planning_oa | 15 | 27.317 µs | 47.857 µs | 0.571 | [0.560, 0.589] | 2.5/3.0% | **faster** |
| crowd_baseline_25_oa_low / crowd_velocity_planning_oa | 15 | 2.346 µs | 3.931 µs | 0.597 | [0.556, 0.608] | 4.3/7.2% | **faster** |
| crowd_100_oa_high / crowd_velocity_planning_oa | 15 | 22.110 µs | 36.910 µs | 0.599 | [0.575, 0.617] | 3.5/2.7% | **faster** |
| crowd_scale_250_oa_med / crowd_velocity_planning_oa | 15 | 37.314 µs | 59.746 µs | 0.625 | [0.608, 0.643] | 2.2/4.9% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_update_total | 15 | 45.933 µs | 71.355 µs | 0.644 | [0.617, 0.667] | 7.4/4.1% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_collision_resolve | 15 | 329.0 ns | 490.0 ns | 0.671 | [0.642, 0.745] | 13.3/8.1% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_neighbor_find | 15 | 5.041 µs | 7.399 µs | 0.681 | [0.662, 0.718] | 8.7/5.5% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_neighbor_find | 15 | 8.065 µs | 11.783 µs | 0.684 | [0.667, 0.716] | 4.6/5.5% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_update_total | 15 | 65.475 µs | 95.508 µs | 0.686 | [0.670, 0.711] | 3.5/3.8% | **faster** |
| crowd_baseline_25_oa_low / dtRaycast | 15 | 207.0 ns | 297.0 ns | 0.697 | [0.659, 0.719] | 2.0/5.7% | **faster** |
| crowd_100_no_avoidance / crowd_collision_resolve | 15 | 549.0 ns | 778.0 ns | 0.706 | [0.672, 0.736] | 6.0/8.2% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_collision_resolve | 15 | 553.0 ns | 770.0 ns | 0.718 | [0.699, 0.754] | 5.8/12.1% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_check_path_validity | 15 | 3.788 µs | 5.247 µs | 0.722 | [0.697, 0.759] | 6.8/3.5% | **faster** |
| crowd_baseline_25_oa_low / crowd_neighbor_find | 15 | 2.982 µs | 4.124 µs | 0.723 | [0.680, 0.731] | 2.7/5.2% | **faster** |
| crowd_100_oa_high / crowd_check_path_validity | 15 | 59.236 µs | 81.493 µs | 0.727 | [0.714, 0.777] | 4.4/2.8% | **faster** |
| crowd_100_no_avoidance / dtRaycast | 15 | 211.0 ns | 289.0 ns | 0.730 | [0.717, 0.760] | 4.7/2.4% | **faster** |
| crowd_scale_250_oa_med / crowd_check_path_validity | 15 | 152.734 µs | 208.651 µs | 0.732 | [0.717, 0.759] | 3.0/4.3% | **faster** |
| crowd_scale_250_oa_med / dtRaycast | 15 | 227.0 ns | 310.0 ns | 0.732 | [0.720, 0.758] | 4.1/5.4% | **faster** |
| crowd_baseline_25_oa_low / crowd_check_path_validity | 15 | 14.707 µs | 20.077 µs | 0.733 | [0.695, 0.753] | 1.8/5.7% | **faster** |
| crowd_100_oa_high / crowd_neighbor_find | 15 | 12.548 µs | 17.029 µs | 0.737 | [0.715, 0.789] | 6.0/2.7% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_update_move_request | 15 | 220.0 ns | 298.0 ns | 0.738 | [0.725, 0.768] | 10.0/4.2% | **faster** |
| crowd_100_oa_high / dtRaycast | 15 | 213.0 ns | 288.0 ns | 0.740 | [0.699, 0.755] | 3.8/3.5% | **faster** |
| crowd_separation_spread_120_no_goal / crowd_update_move_request | 15 | 230.0 ns | 308.0 ns | 0.747 | [0.730, 0.776] | 8.6/14.4% | **faster** |
| crowd_100_no_avoidance / crowd_check_path_validity | 15 | 59.830 µs | 79.918 µs | 0.749 | [0.739, 0.770] | 3.6/2.5% | **faster** |
| crowd_baseline_25_oa_low / crowd_collision_resolve | 15 | 154.0 ns | 205.0 ns | 0.751 | [0.689, 0.767] | 5.9/7.4% | **faster** |
| crowd_100_oa_high / crowd_collision_resolve | 15 | 587.0 ns | 781.0 ns | 0.752 | [0.694, 0.935] | 16.8/7.6% | **faster** |
| crowd_100_oa_high / crowd_update_total | 15 | 186.129 µs | 245.973 µs | 0.757 | [0.730, 0.799] | 5.1/2.7% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_check_path_validity | 15 | 6.588 µs | 8.700 µs | 0.757 | [0.740, 0.777] | 2.8/6.0% | **faster** |
| crowd_100_no_avoidance / crowd_neighbor_find | 15 | 12.726 µs | 16.722 µs | 0.761 | [0.736, 0.782] | 4.5/2.5% | **faster** |
| crowd_baseline_25_oa_low / crowd_update_total | 15 | 43.292 µs | 56.884 µs | 0.761 | [0.710, 0.780] | 2.1/7.0% | **faster** |
| crowd_separation_spread_120_no_goal / crowd_update_total | 15 | 1.029 µs | 1.342 µs | 0.767 | [0.756, 0.783] | 6.8/11.5% | **faster** |
| crowd_scale_250_oa_med / crowd_update_total | 15 | 471.917 µs | 611.226 µs | 0.772 | [0.754, 0.798] | 3.7/5.3% | **faster** |
| crowd_baseline_25_oa_low / crowd_topology_opt | 15 | 681.0 ns | 880.0 ns | 0.774 | [0.704, 0.803] | 4.2/11.2% | **faster** |
| crowd_scale_250_oa_med / crowd_neighbor_find | 15 | 40.173 µs | 51.224 µs | 0.784 | [0.755, 0.810] | 4.7/5.4% | **faster** |
| crowd_baseline_25_oa_low / crowd_find_corners | 15 | 15.172 µs | 19.323 µs | 0.785 | [0.730, 0.807] | 2.4/8.3% | **faster** |
| crowd_100_no_avoidance / crowd_update_total | 15 | 165.499 µs | 207.577 µs | 0.797 | [0.779, 0.822] | 4.5/2.7% | **faster** |
| crowd_100_no_avoidance / crowd_find_corners | 15 | 60.763 µs | 75.917 µs | 0.800 | [0.792, 0.843] | 5.4/3.0% | **faster** |
| crowd_scale_250_oa_med / crowd_find_corners | 15 | 163.716 µs | 203.930 µs | 0.803 | [0.777, 0.826] | 4.4/6.3% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_update_move_request | 15 | 310.0 ns | 386.0 ns | 0.803 | [0.777, 0.857] | 4.3/8.1% | **faster** |
| crowd_baseline_25_oa_low / dtGetPolyWallSegments | 15 | 37.0 ns | 46.0 ns | 0.804 | [0.755, 0.826] | 5.3/7.5% | **faster** |
| crowd_100_oa_high / crowd_find_corners | 15 | 61.925 µs | 76.423 µs | 0.810 | [0.769, 0.863] | 5.4/3.2% | **faster** |
| crowd_scale_250_oa_med / crowd_topology_opt | 15 | 1.288 µs | 1.582 µs | 0.814 | [0.771, 0.884] | 7.3/7.2% | **faster** |
| crowd_100_oa_high / crowd_topology_opt | 15 | 1.008 µs | 1.238 µs | 0.814 | [0.787, 0.903] | 8.8/3.6% | **faster** |
| crowd_baseline_25_oa_low / crowd_update_move_request | 15 | 603.0 ns | 737.0 ns | 0.818 | [0.741, 0.832] | 3.5/8.3% | **faster** |
| crowd_100_oa_high / crowd_update_move_request | 15 | 2.705 µs | 3.278 µs | 0.825 | [0.802, 0.944] | 8.0/4.9% | **faster** |
| crowd_choke_funnel_60_oa_high / crowd_move_position | 15 | 13.033 µs | 15.721 µs | 0.829 | [0.800, 0.856] | 7.5/4.4% | **faster** |
| crowd_100_no_avoidance / crowd_topology_opt | 15 | 1.023 µs | 1.220 µs | 0.839 | [0.813, 0.868] | 5.2/4.1% | **faster** |
| crowd_scale_250_oa_med / crowd_update_move_request | 15 | 5.399 µs | 6.422 µs | 0.841 | [0.779, 0.896] | 5.9/8.6% | **faster** |
| crowd_100_no_avoidance / crowd_update_move_request | 15 | 2.739 µs | 3.151 µs | 0.869 | [0.826, 0.913] | 5.9/5.5% | **faster** |
| crowd_100_oa_high / crowd_move_position | 15 | 23.067 µs | 26.474 µs | 0.871 | [0.841, 0.952] | 6.5/3.3% | **faster** |
| crowd_baseline_25_oa_low / dtUpdateSlicedFindPath | 15 | 718.0 ns | 824.0 ns | 0.871 | [0.806, 0.897] | 3.8/8.0% | **faster** |
| crowd_scale_250_oa_med / crowd_path_queue_update | 15 | 2.820 µs | 3.200 µs | 0.881 | [0.833, 0.908] | 3.5/7.1% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_move_position | 15 | 20.537 µs | 23.253 µs | 0.883 | [0.843, 0.910] | 4.8/3.9% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / dtFindNearestPoly | 15 | 380.0 ns | 430.0 ns | 0.884 | [0.553, 1.371] | 42.4/52.7% | tie |
| crowd_scale_250_oa_med / crowd_move_position | 15 | 61.483 µs | 69.429 µs | 0.886 | [0.853, 0.916] | 4.6/6.4% | **faster** |
| crowd_scale_250_oa_med / crowd_collision_resolve | 15 | 2.497 µs | 2.792 µs | 0.894 | [0.877, 0.918] | 2.9/3.1% | **faster** |
| crowd_scale_250_oa_med / dtFindStraightPath | 15 | 331.0 ns | 370.0 ns | 0.895 | [0.852, 0.924] | 5.0/7.1% | **faster** |
| crowd_100_no_avoidance / dtFindStraightPath | 15 | 301.0 ns | 336.0 ns | 0.896 | [0.874, 0.947] | 6.4/3.4% | **faster** |
| crowd_baseline_25_oa_low / crowd_move_position | 15 | 5.548 µs | 6.189 µs | 0.896 | [0.818, 0.910] | 2.5/7.5% | **faster** |
| crowd_100_no_avoidance / crowd_move_position | 15 | 23.442 µs | 26.119 µs | 0.898 | [0.869, 0.936] | 5.0/3.0% | **faster** |
| crowd_baseline_25_oa_low / dtFindStraightPath | 15 | 298.0 ns | 332.0 ns | 0.898 | [0.819, 0.909] | 2.9/10.8% | **faster** |
| crowd_100_oa_high / crowd_path_queue_update | 15 | 1.354 µs | 1.498 µs | 0.904 | [0.847, 0.940] | 6.1/4.0% | **faster** |
| crowd_scale_250_oa_med / dtUpdateSlicedFindPath | 15 | 908.0 ns | 1.001 µs | 0.907 | [0.833, 0.939] | 4.8/6.8% | **faster** |
| crowd_100_no_avoidance / crowd_path_queue_update | 15 | 1.367 µs | 1.507 µs | 0.907 | [0.874, 0.932] | 4.1/5.4% | **faster** |
| crowd_100_oa_high / dtFindStraightPath | 15 | 304.0 ns | 334.0 ns | 0.910 | [0.871, 1.000] | 7.0/3.3% | tie |
| crowd_scale_250_oa_med / crowd_steering_separation | 15 | 1.981 µs | 2.173 µs | 0.912 | [0.886, 0.941] | 2.6/6.8% | **faster** |
| crowd_100_oa_high / crowd_steering_separation | 15 | 816.0 ns | 894.0 ns | 0.913 | [0.885, 0.969] | 5.9/3.2% | **faster** |
| crowd_baseline_25_oa_low / crowd_path_queue_update | 15 | 306.0 ns | 333.0 ns | 0.919 | [0.839, 0.933] | 2.6/7.3% | **faster** |
| crowd_100_oa_high / dtUpdateSlicedFindPath | 15 | 878.0 ns | 953.0 ns | 0.921 | [0.870, 1.000] | 6.9/4.3% | tie |
| crowd_100_no_avoidance / crowd_steering_separation | 15 | 817.0 ns | 881.0 ns | 0.927 | [0.918, 0.979] | 8.6/3.3% | **faster** |
| crowd_100_no_avoidance / dtUpdateSlicedFindPath | 15 | 893.0 ns | 961.0 ns | 0.929 | [0.902, 0.967] | 3.9/4.6% | **faster** |
| crowd_baseline_25_oa_low / dtFindLocalNeighbourhood | 15 | 138.0 ns | 146.0 ns | 0.945 | [0.897, 0.979] | 3.4/9.2% | **faster** |
| crowd_choke_funnel_60_oa_high / dtGetPolyHeight | 15 | 72.0 ns | 76.0 ns | 0.947 | [0.909, 0.961] | 10.6/4.6% | **faster** |
| crowd_100_no_avoidance / crowd_velocity_planning_oa | 15 | 110.0 ns | 116.0 ns | 0.948 | [0.899, 0.991] | 8.3/5.2% | **faster** |
| crowd_mass_repath_100_shared_moving_goal / crowd_find_corners | 15 | 80.0 ns | 84.0 ns | 0.952 | [0.905, 1.012] | 7.0/4.3% | tie |
| crowd_scale_250_oa_med / dtFindLocalNeighbourhood | 15 | 148.0 ns | 155.0 ns | 0.955 | [0.914, 1.013] | 4.6/7.9% | tie |
| crowd_choke_funnel_60_oa_high / dtMoveAlongSurface | 15 | 58.0 ns | 60.0 ns | 0.967 | [0.934, 1.017] | 7.8/5.2% | tie |
| crowd_baseline_25_oa_low / crowd_steering_separation | 15 | 228.0 ns | 235.0 ns | 0.970 | [0.886, 0.983] | 2.3/8.0% | **faster** |
| crowd_100_oa_high / dtGetPolyWallSegments | 15 | 41.0 ns | 42.0 ns | 0.976 | [0.929, 1.071] | 7.5/4.0% | tie |
| crowd_100_no_avoidance / dtGetPolyWallSegments | 15 | 41.0 ns | 42.0 ns | 0.976 | [0.932, 1.049] | 6.2/4.7% | tie |
| crowd_100_oa_high / dtFindLocalNeighbourhood | 15 | 143.0 ns | 143.0 ns | 1.000 | [0.966, 1.095] | 8.0/3.0% | tie |
| crowd_100_oa_high / dtMoveAlongSurface | 15 | 60.0 ns | 60.0 ns | 1.000 | [0.951, 1.082] | 6.8/3.7% | tie |
| crowd_100_no_avoidance / dtFindLocalNeighbourhood | 15 | 144.0 ns | 144.0 ns | 1.000 | [0.966, 1.075] | 6.7/3.4% | tie |
| crowd_100_no_avoidance / dtMoveAlongSurface | 15 | 61.0 ns | 61.0 ns | 1.000 | [0.952, 1.049] | 5.6/3.8% | tie |
| crowd_scale_250_oa_med / dtMoveAlongSurface | 15 | 65.0 ns | 64.0 ns | 1.016 | [0.941, 1.031] | 4.9/6.2% | tie |
| crowd_mass_repath_100_shared_moving_goal / dtMoveAlongSurface | 15 | 60.0 ns | 59.0 ns | 1.017 | [0.967, 1.051] | 4.8/5.2% | tie |
| crowd_baseline_25_oa_low / dtMoveAlongSurface | 15 | 56.0 ns | 55.0 ns | 1.018 | [0.949, 1.056] | 3.5/7.0% | tie |
| crowd_choke_funnel_60_oa_high / crowd_find_corners | 15 | 55.0 ns | 54.0 ns | 1.019 | [0.964, 1.057] | 11.8/6.0% | tie |
| crowd_scale_250_oa_med / dtGetPolyHeight | 15 | 73.0 ns | 71.0 ns | 1.028 | [0.987, 1.088] | 6.2/8.8% | tie |
| crowd_choke_funnel_60_oa_high / crowd_topology_opt | 15 | 42.0 ns | 40.0 ns | 1.050 | [1.024, 1.175] | 13.5/22.7% | **slower** |
| crowd_scale_250_oa_med / dtGetPolyWallSegments | 15 | 42.0 ns | 40.0 ns | 1.050 | [1.024, 1.077] | 4.4/5.8% | **slower** |
| crowd_choke_funnel_60_oa_high / crowd_grid_register | 15 | 544.0 ns | 509.0 ns | 1.069 | [1.017, 1.115] | 28.4/6.5% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_grid_register | 15 | 29.0 ns | 27.0 ns | 1.074 | [1.000, 1.148] | 9.3/16.2% | tie |
| crowd_100_oa_high / dtGetPolyHeight | 15 | 66.0 ns | 61.0 ns | 1.082 | [1.016, 1.200] | 7.8/4.4% | **slower** |
| crowd_100_no_avoidance / dtGetPolyHeight | 15 | 66.0 ns | 60.0 ns | 1.100 | [1.032, 1.183] | 6.9/4.5% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / dtGetPolyHeight | 15 | 55.0 ns | 50.0 ns | 1.100 | [1.059, 1.163] | 6.3/5.7% | **slower** |
| crowd_baseline_25_oa_low / dtGetPolyHeight | 15 | 62.0 ns | 56.0 ns | 1.107 | [0.984, 1.145] | 4.5/13.5% | tie |
| crowd_mass_repath_100_shared_moving_goal / crowd_topology_opt | 15 | 65.0 ns | 57.0 ns | 1.140 | [1.033, 1.204] | 8.3/7.0% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / crowd_grid_register | 15 | 882.0 ns | 772.0 ns | 1.142 | [1.083, 1.234] | 5.9/6.8% | **slower** |
| crowd_choke_funnel_60_oa_high / crowd_steering_separation | 15 | 47.0 ns | 41.0 ns | 1.146 | [1.047, 1.268] | 13.9/10.4% | **slower** |
| crowd_scale_250_oa_med / crowd_integrate | 15 | 1.221 µs | 1.064 µs | 1.148 | [1.131, 1.187] | 11.4/5.9% | **slower** |
| crowd_baseline_25_oa_low / dtInitSlicedFindPath | 15 | 51.0 ns | 44.0 ns | 1.159 | [1.061, 1.244] | 5.4/22.9% | **slower** |
| crowd_100_oa_high / crowd_grid_register | 15 | 1.262 µs | 1.088 µs | 1.160 | [1.127, 1.233] | 5.3/2.7% | **slower** |
| crowd_scale_250_oa_med / dtInitSlicedFindPath | 15 | 58.0 ns | 50.0 ns | 1.160 | [1.098, 1.289] | 7.1/22.0% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / crowd_steering_separation | 15 | 67.0 ns | 57.0 ns | 1.175 | [1.121, 1.236] | 6.3/5.0% | **slower** |
| crowd_baseline_25_oa_low / crowd_grid_register | 15 | 320.0 ns | 271.0 ns | 1.181 | [1.104, 1.216] | 3.5/8.0% | **slower** |
| crowd_choke_funnel_60_oa_high / dtGetPolyWallSegments | 15 | 45.0 ns | 38.0 ns | 1.184 | [0.902, 1.314] | 16.0/22.8% | tie |
| crowd_choke_funnel_60_oa_high / dtFindLocalNeighbourhood | 15 | 235.0 ns | 196.0 ns | 1.199 | [1.134, 1.223] | 9.7/9.3% | **slower** |
| crowd_100_no_avoidance / crowd_grid_register | 15 | 1.297 µs | 1.076 µs | 1.205 | [1.147, 1.246] | 5.3/8.3% | **slower** |
| crowd_100_oa_high / dtInitSlicedFindPath | 15 | 58.0 ns | 48.0 ns | 1.208 | [1.120, 1.326] | 11.3/6.0% | **slower** |
| crowd_100_oa_high / crowd_integrate | 15 | 495.0 ns | 405.0 ns | 1.222 | [1.199, 1.314] | 17.0/13.2% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / dtGetPolyWallSegments | 15 | 49.0 ns | 40.0 ns | 1.225 | [1.047, 1.300] | 18.6/17.0% | **slower** |
| crowd_100_no_avoidance / dtInitSlicedFindPath | 15 | 56.0 ns | 45.0 ns | 1.244 | [1.074, 1.341] | 7.5/50.0% | **slower** |
| crowd_scale_250_oa_med / crowd_grid_register | 15 | 3.668 µs | 2.859 µs | 1.283 | [1.248, 1.356] | 5.0/6.6% | **slower** |
| crowd_choke_funnel_60_oa_high / crowd_path_queue_update | 15 | 30.0 ns | 22.0 ns | 1.364 | [1.261, 1.500] | 9.2/7.3% | **slower** |
| crowd_baseline_25_oa_low / crowd_integrate | 15 | 140.0 ns | 102.0 ns | 1.373 | [1.318, 1.414] | 3.5/6.4% | **slower** |
| crowd_100_no_avoidance / crowd_integrate | 15 | 501.0 ns | 358.0 ns | 1.399 | [1.357, 1.427] | 5.0/2.7% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / dtFindLocalNeighbourhood | 15 | 214.0 ns | 152.0 ns | 1.408 | [1.237, 1.513] | 13.7/13.0% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_path_queue_update | 15 | 31.0 ns | 22.0 ns | 1.409 | [1.280, 1.524] | 6.6/15.0% | **slower** |
| crowd_choke_funnel_60_oa_high / crowd_integrate | 15 | 267.0 ns | 185.0 ns | 1.443 | [1.419, 1.505] | 7.2/4.4% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / crowd_integrate | 15 | 438.0 ns | 298.0 ns | 1.470 | [1.407, 1.545] | 4.1/4.0% | **slower** |
| crowd_baseline_25_oa_low / dtIsValidPolyRef | 15 | 28.0 ns | 19.0 ns | 1.474 | [1.474, 1.556] | 1.6/6.8% | **slower** |
| crowd_choke_funnel_60_oa_high / dtIsValidPolyRef | 15 | 28.0 ns | 19.0 ns | 1.474 | [1.421, 1.556] | 5.9/6.4% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / dtIsValidPolyRef | 15 | 28.0 ns | 19.0 ns | 1.474 | [1.474, 1.611] | 3.6/2.7% | **slower** |
| crowd_scale_250_oa_med / dtIsValidPolyRef | 15 | 28.0 ns | 19.0 ns | 1.474 | [1.474, 1.611] | 3.0/4.4% | **slower** |
| crowd_mass_repath_100_shared_moving_goal / crowd_path_queue_update | 15 | 32.0 ns | 21.0 ns | 1.524 | [1.409, 1.600] | 6.5/17.3% | **slower** |
| crowd_100_oa_high / dtIsValidPolyRef | 15 | 28.0 ns | 18.0 ns | 1.556 | [1.474, 1.611] | 4.6/2.7% | **slower** |
| crowd_100_no_avoidance / dtIsValidPolyRef | 15 | 28.0 ns | 18.0 ns | 1.556 | [1.474, 1.611] | 3.1/3.3% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_check_path_validity | 15 | 29.0 ns | 18.0 ns | 1.611 | [1.526, 1.706] | 6.4/9.9% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_move_position | 15 | 29.0 ns | 18.0 ns | 1.611 | [1.556, 1.875] | 9.1/10.7% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_collision_resolve | 15 | 32.0 ns | 19.0 ns | 1.684 | [1.550, 1.778] | 7.0/11.2% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_integrate | 15 | 29.0 ns | 17.0 ns | 1.706 | [1.556, 1.812] | 8.6/9.9% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_steering_separation | 15 | 29.0 ns | 17.0 ns | 1.706 | [1.611, 1.812] | 9.0/7.1% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_find_corners | 15 | 28.0 ns | 16.0 ns | 1.750 | [1.647, 1.933] | 8.0/11.9% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_neighbor_find | 15 | 30.0 ns | 17.0 ns | 1.765 | [1.667, 1.882] | 6.7/12.0% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_topology_opt | 15 | 30.0 ns | 17.0 ns | 1.765 | [1.667, 1.824] | 7.8/11.9% | **slower** |
| crowd_separation_spread_120_no_goal / crowd_velocity_planning_oa | 15 | 30.0 ns | 17.0 ns | 1.765 | [1.579, 1.938] | 9.5/11.9% | **slower** |

## TILECACHE — 48 zones (K=15/side)

**27 faster (sig) / 17 slower (sig) / 4 tie (within noise).** Significant-only geomean ratio: **1.146** (over the 44 zones whose 95 % CI clears 1.0).

| scenario / function | n | median t_zig | median t_cpp | ratio | 95 % CI | CV z/c | verdict |
|---|--:|--:|--:|--:|:--:|--:|:--|
| tilecache_dense_box_map_2 / dtBuildTileCacheContours | 15 | 2.977 µs | 3.423 µs | 0.870 | [0.845, 0.881] | 2.1/5.5% | **faster** |
| tilecache_orientedbox_map_2 / dtBuildTileCacheContours | 15 | 3.130 µs | 3.577 µs | 0.875 | [0.868, 0.888] | 1.0/2.2% | **faster** |
| tilecache_obstacles_map_3 / dtBuildTileCacheContours | 15 | 3.362 µs | 3.836 µs | 0.876 | [0.850, 0.893] | 15.1/12.2% | **faster** |
| tilecache_dense_box_map_2 / dtBuildTileCachePolyMesh | 15 | 1.285 µs | 1.465 µs | 0.877 | [0.847, 0.900] | 2.7/4.5% | **faster** |
| tilecache_obstacles_map_2 / dtBuildTileCacheContours | 15 | 2.966 µs | 3.372 µs | 0.880 | [0.867, 0.894] | 3.1/2.2% | **faster** |
| tilecache_cylinders_map_2 / dtBuildTileCacheContours | 15 | 3.127 µs | 3.550 µs | 0.881 | [0.870, 0.890] | 1.7/0.7% | **faster** |
| tilecache_dense_box_map_2 / dtAddTile | 15 | 1.497 µs | 1.693 µs | 0.884 | [0.851, 0.913] | 9.7/8.8% | **faster** |
| tilecache_obstacles_map_2 / dtAddTile | 15 | 1.150 µs | 1.288 µs | 0.893 | [0.875, 0.915] | 1.7/2.4% | **faster** |
| tilecache_orientedbox_map_2 / dtAddTile | 15 | 1.244 µs | 1.373 µs | 0.906 | [0.892, 0.921] | 2.6/4.3% | **faster** |
| tilecache_obstacles_map_3 / dtTileCacheUpdate | 15 | 19.981 µs | 21.646 µs | 0.923 | [0.900, 0.941] | 13.9/10.4% | **faster** |
| tilecache_obstacles_map_3 / dtTileCacheBuildNavMeshTile | 15 | 19.552 µs | 21.160 µs | 0.924 | [0.903, 0.943] | 13.8/10.4% | **faster** |
| tilecache_cylinders_map_2 / dtAddTile | 15 | 1.168 µs | 1.261 µs | 0.926 | [0.908, 0.939] | 2.8/1.8% | **faster** |
| tilecache_obstacles_map_3 / dtAddTile | 15 | 3.821 µs | 4.123 µs | 0.927 | [0.889, 0.947] | 7.6/5.5% | **faster** |
| tilecache_obstacles_map_3 / dtBuildTileCachePolyMesh | 15 | 1.995 µs | 2.151 µs | 0.927 | [0.906, 0.938] | 10.8/6.3% | **faster** |
| tilecache_obstacles_map_3 / dtBuildTileCacheRegions | 15 | 7.915 µs | 8.521 µs | 0.929 | [0.917, 0.965] | 16.5/12.9% | **faster** |
| tilecache_orientedbox_map_2 / dtBuildTileCachePolyMesh | 15 | 1.257 µs | 1.352 µs | 0.930 | [0.891, 0.940] | 2.0/3.2% | **faster** |
| tilecache_obstacles_map_2 / dtBuildTileCachePolyMesh | 15 | 1.312 µs | 1.411 µs | 0.930 | [0.909, 0.937] | 1.6/1.9% | **faster** |
| tilecache_dense_box_map_2 / dtDecompressTileCacheLayer | 15 | 326.0 ns | 350.0 ns | 0.931 | [0.865, 0.989] | 7.3/13.6% | **faster** |
| tilecache_cylinders_map_2 / dtBuildTileCachePolyMesh | 15 | 1.511 µs | 1.622 µs | 0.932 | [0.921, 0.948] | 1.7/1.0% | **faster** |
| tilecache_obstacles_map_2 / dtDecompressTileCacheLayer | 15 | 303.0 ns | 322.0 ns | 0.941 | [0.855, 1.000] | 14.3/10.9% | tie |
| tilecache_dense_box_map_2 / dtTileCacheBuildNavMeshTile | 15 | 17.506 µs | 18.376 µs | 0.953 | [0.929, 0.981] | 2.4/5.1% | **faster** |
| tilecache_dense_box_map_2 / dtTileCacheUpdate | 15 | 17.954 µs | 18.838 µs | 0.953 | [0.928, 0.982] | 2.4/5.1% | **faster** |
| tilecache_cylinders_map_2 / dtDecompressTileCacheLayer | 15 | 311.0 ns | 322.0 ns | 0.966 | [0.926, 1.028] | 9.7/5.4% | tie |
| tilecache_obstacles_map_2 / dtTileCacheUpdate | 15 | 17.811 µs | 18.407 µs | 0.968 | [0.958, 0.985] | 1.6/2.0% | **faster** |
| tilecache_obstacles_map_2 / dtTileCacheBuildNavMeshTile | 15 | 17.385 µs | 17.885 µs | 0.972 | [0.960, 0.988] | 1.6/2.0% | **faster** |
| tilecache_orientedbox_map_2 / dtTileCacheUpdate | 15 | 18.027 µs | 18.501 µs | 0.974 | [0.966, 0.985] | 1.7/4.1% | **faster** |
| tilecache_orientedbox_map_2 / dtTileCacheBuildNavMeshTile | 15 | 17.635 µs | 18.075 µs | 0.976 | [0.966, 0.987] | 1.7/3.9% | **faster** |
| tilecache_cylinders_map_2 / dtTileCacheUpdate | 15 | 18.383 µs | 18.750 µs | 0.980 | [0.977, 0.987] | 1.9/0.8% | **faster** |
| tilecache_cylinders_map_2 / dtTileCacheBuildNavMeshTile | 15 | 17.964 µs | 18.292 µs | 0.982 | [0.978, 0.989] | 1.8/0.8% | **faster** |
| tilecache_orientedbox_map_2 / dtDecompressTileCacheLayer | 15 | 301.0 ns | 305.0 ns | 0.987 | [0.930, 1.030] | 4.6/28.8% | tie |
| tilecache_obstacles_map_3 / dtDecompressTileCacheLayer | 15 | 330.0 ns | 331.0 ns | 0.997 | [0.948, 1.234] | 20.5/14.7% | tie |
| tilecache_dense_box_map_2 / dtBuildTileCacheRegions | 15 | 9.991 µs | 9.702 µs | 1.030 | [1.007, 1.041] | 2.5/4.9% | **slower** |
| tilecache_orientedbox_map_2 / dtBuildTileCacheRegions | 15 | 10.060 µs | 9.697 µs | 1.037 | [1.030, 1.060] | 2.3/2.6% | **slower** |
| tilecache_obstacles_map_2 / dtBuildTileCacheRegions | 15 | 10.150 µs | 9.740 µs | 1.042 | [1.025, 1.061] | 1.3/1.7% | **slower** |
| tilecache_cylinders_map_2 / dtBuildTileCacheRegions | 15 | 10.314 µs | 9.818 µs | 1.051 | [1.041, 1.060] | 1.6/0.8% | **slower** |
| tilecache_obstacles_map_3 / dtCreateNavMeshData | 15 | 488.0 ns | 393.0 ns | 1.242 | [1.152, 1.414] | 16.9/9.8% | **slower** |
| tilecache_obstacles_map_2 / dtCreateNavMeshData | 15 | 344.0 ns | 277.0 ns | 1.242 | [1.129, 1.293] | 8.3/8.7% | **slower** |
| tilecache_dense_box_map_2 / dtCreateNavMeshData | 15 | 323.0 ns | 260.0 ns | 1.242 | [1.119, 1.327] | 6.5/9.6% | **slower** |
| tilecache_cylinders_map_2 / dtCreateNavMeshData | 15 | 357.0 ns | 283.0 ns | 1.261 | [1.237, 1.321] | 11.5/4.0% | **slower** |
| tilecache_orientedbox_map_2 / dtCreateNavMeshData | 15 | 333.0 ns | 263.0 ns | 1.266 | [1.188, 1.366] | 6.1/14.1% | **slower** |
| tilecache_obstacles_map_2 / dtTileCacheRemoveObstacle | 15 | 27.0 ns | 18.0 ns | 1.500 | [1.389, 2.071] | 10.5/19.5% | **slower** |
| tilecache_dense_box_map_2 / dtTileCacheRemoveObstacle | 15 | 27.0 ns | 17.0 ns | 1.588 | [1.421, 1.800] | 11.2/13.5% | **slower** |
| tilecache_cylinders_map_2 / dtTileCacheRemoveObstacle | 15 | 27.0 ns | 16.0 ns | 1.688 | [1.500, 2.071] | 15.4/22.2% | **slower** |
| tilecache_orientedbox_map_2 / dtTileCacheRemoveObstacle | 15 | 27.0 ns | 16.0 ns | 1.688 | [1.350, 2.071] | 13.9/28.4% | **slower** |
| tilecache_obstacles_map_3 / dtTileCacheRemoveObstacle | 15 | 33.0 ns | 18.0 ns | 1.833 | [1.409, 2.071] | 15.0/18.8% | **slower** |
| tilecache_dense_box_map_2 / dtTileCacheAddBoxObstacle | 15 | 48.0 ns | 19.0 ns | 2.526 | [2.286, 2.667] | 7.5/11.3% | **slower** |
| tilecache_obstacles_map_3 / dtTileCacheAddBoxObstacle | 15 | 110.0 ns | 22.0 ns | 5.000 | [3.613, 6.000] | 14.9/34.5% | **slower** |
| tilecache_obstacles_map_2 / dtTileCacheAddBoxObstacle | 15 | 106.0 ns | 18.0 ns | 5.889 | [5.000, 7.000] | 13.8/24.9% | **slower** |
