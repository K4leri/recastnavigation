//! Per-function micro-benchmark — ENTRY POINT.
//!
//! This file only aggregates the modular bench GROUPS (bench/microbench/*.zig) and
//! hands them to the core runner. Add a function bench to the matching group file;
//! add an analog to the matching analogs_*.zig — never pile benches in here. See
//! dev/research/PERFUNC_BENCH_GOAL.md.
//!
//!   bench/microbench/core.zig          — timer, Bench, measure, CSV runner
//!   bench/microbench/bench_math.zig     — math leaf functions (orig)
//!   bench/microbench/analogs_math.zig   — math analogs (proven identical)
//!   bench/microbench/bench_recast.zig   — recast leaf helpers
//!   (future) bench_recast_stage.zig     — class-B stages with prerequisite setup
//!
//! CLI: microbench <out_csv>   (default microbench_trace_<variant>.csv)

const std = @import("std");
const core = @import("microbench/core.zig");

const bench_math = @import("microbench/bench_math.zig");
const analogs_math = @import("microbench/analogs_math.zig");
const bench_recast = @import("microbench/bench_recast.zig");
const analogs_recast = @import("microbench/analogs_recast.zig");
const bench_recast_stage = @import("microbench/bench_recast_stage.zig");
// leaf groups wired per source file (class-A coverage: recast.detail/contour/area/mesh/
// rasterization, detour.common/builder, detour_crowd.obstacle_avoidance)
const bench_detail = @import("microbench/bench_detail.zig");
const bench_contour = @import("microbench/bench_contour.zig");
const bench_area = @import("microbench/bench_area.zig");
const bench_mesh = @import("microbench/bench_mesh.zig");
const bench_detour = @import("microbench/bench_detour.zig");
const bench_crowd = @import("microbench/bench_crowd.zig");
const bench_tilecache = @import("microbench/bench_tilecache.zig");

/// All bench groups, concatenated at comptime. Append new groups here.
const all_benches = bench_math.benches ++ analogs_math.benches ++
    bench_recast.benches ++ analogs_recast.benches ++ bench_recast_stage.benches ++
    bench_detail.benches ++ bench_contour.benches ++ bench_area.benches ++
    bench_mesh.benches ++ bench_detour.benches ++ bench_crowd.benches ++
    bench_tilecache.benches;

pub fn main(init: std.process.Init) !void {
    try core.run(&all_benches, init);
}
