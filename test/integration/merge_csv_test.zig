//! Tests for the merge_csv tool (`tools/analysis/merge_csv.zig`) — Task 6.2.
//!
//! merge_csv joins the Zig and C++ per-zone benchmark CSVs (the
//! `scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns` contract that
//! both `bench/tracy_scenarios.zig` and `Bench/tracy_scenarios.cpp` emit) into one
//! comparison table keyed by (scenario, zone).
//!
//! These tests exercise the PURE in-memory core (`mergeToWriter`) so they need no
//! temp files: feed two CSV strings + a small floor, capture the merged output in
//! an allocating writer, then parse the rows and assert ratio / delta_pct /
//! presence / sort order / the top-offender summary.
//!
//! Imported via a repo-root shim (`merge_csv_test_root.zig`) because the test pulls
//! in the tool by the relative path `../../tools/analysis/merge_csv.zig`; Zig 0.16
//! forbids importing outside a module's root directory, so the module is rooted at
//! the repo root (mirrors the `bench_obj_loader_test_root.zig` precedent).

const std = @import("std");
const merge = @import("../../tools/analysis/merge_csv.zig");

// Input CSVs share the contract header. self_ns is the 5th column (index 4).
const header = "scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns\n";

// zig side:
//   rcBuildRegions: self=2000 incl=2000 count=4   (2x slower than cpp -> top offender)
//   dtFindPath:     self=500           count=2000
//   zonly_zone:     self=100                       (zig-only)
const zig_csv =
    header ++
    "build_x,rcBuildRegions,4,2000,2000,500,100,900\n" ++
    "build_x,dtFindPath,2000,9000,500,4,1,9\n" ++
    "build_x,zonly_zone,1,100,100,100,100,100\n";

// cpp side:
//   rcBuildRegions: self=1000 count=4
//   dtFindPath:     self=400  count=2000
//   cponly_zone:    self=100               (cpp-only)
const cpp_csv =
    header ++
    "build_x,rcBuildRegions,4,1000,1000,250,80,500\n" ++
    "build_x,dtFindPath,2000,7000,400,3,1,8\n" ++
    "build_x,cponly_zone,1,100,100,100,100,100\n";

/// One parsed output row of ZIG_VS_CPP.csv. Numeric ns columns parsed as u64;
/// ratio/delta parsed as the raw field text (so an empty/`inf` guard stays visible).
const Row = struct {
    scenario: []const u8,
    zone: []const u8,
    zig_self_ns: u64,
    cpp_self_ns: u64,
    self_ratio: []const u8,
    self_delta_pct: []const u8,
    zig_incl_ns: u64,
    cpp_incl_ns: u64,
    zig_count: u64,
    cpp_count: u64,
    presence: []const u8,
};

/// Split the merged CSV body into Row structs (header skipped, blank lines ignored).
/// Field slices alias `out` — keep `out` alive for the lifetime of the returned rows.
fn parseOutput(allocator: std.mem.Allocator, out: []const u8) ![]Row {
    var rows = std.array_list.Managed(Row).init(allocator);
    errdefer rows.deinit();
    var lines = std.mem.splitScalar(u8, out, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (first) {
            first = false; // skip the header row
            continue;
        }
        var fields: [11][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, ',');
        var n: usize = 0;
        while (it.next()) |f| : (n += 1) {
            if (n >= 11) break;
            fields[n] = f;
        }
        try std.testing.expect(n == 11);
        try rows.append(.{
            .scenario = fields[0],
            .zone = fields[1],
            .zig_self_ns = try std.fmt.parseInt(u64, fields[2], 10),
            .cpp_self_ns = try std.fmt.parseInt(u64, fields[3], 10),
            .self_ratio = fields[4],
            .self_delta_pct = fields[5],
            .zig_incl_ns = try std.fmt.parseInt(u64, fields[6], 10),
            .cpp_incl_ns = try std.fmt.parseInt(u64, fields[7], 10),
            .zig_count = try std.fmt.parseInt(u64, fields[8], 10),
            .cpp_count = try std.fmt.parseInt(u64, fields[9], 10),
            .presence = fields[10],
        });
    }
    return rows.toOwnedSlice();
}

fn findRow(rows: []const Row, zone: []const u8) ?Row {
    for (rows) |r| if (std.mem.eql(u8, r.zone, zone)) return r;
    return null;
}

test "merge joins by (scenario,zone): ratio, delta, presence" {
    const a = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    var summary = try merge.mergeToWriter(a, zig_csv, cpp_csv, &aw.writer, .{ .ratio_floor_ns = 10_000 });
    defer summary.deinit();

    const out = aw.written();

    // Header is the documented column contract.
    try std.testing.expect(std.mem.indexOf(u8, out, "scenario,zone,zig_self_ns,cpp_self_ns,self_ratio,self_delta_pct,zig_incl_ns,cpp_incl_ns,zig_count,cpp_count,presence") != null);

    const rows = try parseOutput(a, out);
    defer a.free(rows);

    // rcBuildRegions: zig 2000 vs cpp 1000 -> ratio 2.0, delta +100.0, both.
    const rb = findRow(rows, "rcBuildRegions").?;
    try std.testing.expectEqualStrings("both", rb.presence);
    try std.testing.expectEqual(@as(u64, 2000), rb.zig_self_ns);
    try std.testing.expectEqual(@as(u64, 1000), rb.cpp_self_ns);
    try std.testing.expectEqualStrings("2.0000", rb.self_ratio);
    try std.testing.expectEqualStrings("100.0", rb.self_delta_pct);
    try std.testing.expectEqual(@as(u64, 4), rb.zig_count);
    try std.testing.expectEqual(@as(u64, 4), rb.cpp_count);

    // dtFindPath: zig 500 vs cpp 400 -> ratio 1.25, delta +25.0, both.
    const fp = findRow(rows, "dtFindPath").?;
    try std.testing.expectEqualStrings("both", fp.presence);
    try std.testing.expectEqualStrings("1.2500", fp.self_ratio);
    try std.testing.expectEqualStrings("25.0", fp.self_delta_pct);

    // zonly_zone: present only on the zig side.
    const zo = findRow(rows, "zonly_zone").?;
    try std.testing.expectEqualStrings("zig_only", zo.presence);
    try std.testing.expectEqual(@as(u64, 100), zo.zig_self_ns);
    try std.testing.expectEqual(@as(u64, 0), zo.cpp_self_ns);

    // cponly_zone: present only on the cpp side.
    const co = findRow(rows, "cponly_zone").?;
    try std.testing.expectEqualStrings("cpp_only", co.presence);
    try std.testing.expectEqual(@as(u64, 0), co.zig_self_ns);
    try std.testing.expectEqual(@as(u64, 100), co.cpp_self_ns);

    // Summary counts.
    try std.testing.expectEqual(@as(usize, 2), summary.both_count);
    try std.testing.expectEqual(@as(usize, 1), summary.zig_only_count);
    try std.testing.expectEqual(@as(usize, 1), summary.cpp_only_count);

    // Top offender among `both` rows with cpp_self_ns > floor (10us). Only
    // dtFindPath (cpp_self 7000 incl... wait: cpp_self for ratio-floor is the
    // SELF column). With floor=10_000, neither both-row qualifies by self_ns; so
    // we lower the floor in the dedicated top-offender test below. Here, just
    // assert the offenders slice is sorted by ratio when populated.
    if (summary.top_offenders.len > 0) {
        try std.testing.expectEqualStrings("rcBuildRegions", summary.top_offenders[0].zone);
    }
}

test "top offender = rcBuildRegions (highest ratio above the floor)" {
    const a = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    // floor below both rows' cpp_self_ns (1000 and 400) so both qualify; the
    // worst Zig-vs-C++ ratio (rcBuildRegions, 2.0) must sort first.
    var summary = try merge.mergeToWriter(a, zig_csv, cpp_csv, &aw.writer, .{ .ratio_floor_ns = 100 });
    defer summary.deinit();

    try std.testing.expect(summary.top_offenders.len >= 2);
    try std.testing.expectEqualStrings("rcBuildRegions", summary.top_offenders[0].zone);
    try std.testing.expectEqualStrings("dtFindPath", summary.top_offenders[1].zone);
    // Descending ratio.
    try std.testing.expect(summary.top_offenders[0].self_ratio >= summary.top_offenders[1].self_ratio);
}

test "rows sorted by (scenario asc, then descending self_ratio for both rows)" {
    const a = std.testing.allocator;

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    var summary = try merge.mergeToWriter(a, zig_csv, cpp_csv, &aw.writer, .{ .ratio_floor_ns = 100 });
    defer summary.deinit();

    const out = aw.written();
    // Within scenario build_x, rcBuildRegions (ratio 2.0) must appear before
    // dtFindPath (ratio 1.25).
    const i_rb = std.mem.indexOf(u8, out, "build_x,rcBuildRegions,").?;
    const i_fp = std.mem.indexOf(u8, out, "build_x,dtFindPath,").?;
    try std.testing.expect(i_rb < i_fp);
}

test "cpp_self_ns==0 yields inf ratio sentinel and guarded delta" {
    const a = std.testing.allocator;

    const zig_only =
        header ++
        "s,zoneA,1,500,500,500,1,500\n";
    const cpp_zero =
        header ++
        "s,zoneA,1,0,0,0,0,0\n";

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    var summary = try merge.mergeToWriter(a, zig_only, cpp_zero, &aw.writer, .{ .ratio_floor_ns = 100 });
    defer summary.deinit();

    const out = aw.written();
    const rows = try parseOutput(a, out);
    defer a.free(rows);

    const r = findRow(rows, "zoneA").?;
    try std.testing.expectEqualStrings("both", r.presence);
    // cpp_self_ns == 0 -> ratio is the `inf` sentinel, delta guarded to `inf`.
    try std.testing.expectEqualStrings("inf", r.self_ratio);
    try std.testing.expectEqualStrings("inf", r.self_delta_pct);
}

test "skipped-budget marker rows do not crash and are excluded from joins" {
    const a = std.testing.allocator;

    const zig_marker =
        header ++
        "build_skip,__SKIPPED_BUDGET__,0,0,0,0,0,0\n" ++
        "build_x,rcBuildRegions,4,2000,2000,500,100,900\n";
    const cpp_marker =
        header ++
        "build_skip,__SKIPPED_BUDGET__,0,0,0,0,0,0\n" ++
        "build_x,rcBuildRegions,4,1000,1000,250,80,500\n";

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    var summary = try merge.mergeToWriter(a, zig_marker, cpp_marker, &aw.writer, .{ .ratio_floor_ns = 100 });
    defer summary.deinit();

    const out = aw.written();
    const rows = try parseOutput(a, out);
    defer a.free(rows);

    // The marker zone is NOT emitted as a comparison row.
    try std.testing.expect(findRow(rows, "__SKIPPED_BUDGET__") == null);
    // The real zone IS emitted.
    try std.testing.expect(findRow(rows, "rcBuildRegions") != null);
    try std.testing.expectEqual(@as(usize, 1), summary.both_count);
    // Skipped scenario recorded on both sides.
    try std.testing.expectEqual(@as(usize, 1), summary.skipped_count);
}

test "trailing empty line and CRLF tolerated" {
    const a = std.testing.allocator;

    const zig_crlf = "scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns\r\n" ++
        "s,z,1,10,10,10,10,10\r\n\r\n";
    const cpp_crlf = "scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns\r\n" ++
        "s,z,1,20,20,20,20,20\r\n";

    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();

    var summary = try merge.mergeToWriter(a, zig_crlf, cpp_crlf, &aw.writer, .{ .ratio_floor_ns = 100 });
    defer summary.deinit();

    const out = aw.written();
    const rows = try parseOutput(a, out);
    defer a.free(rows);

    const r = findRow(rows, "z").?;
    try std.testing.expectEqual(@as(u64, 10), r.zig_self_ns);
    try std.testing.expectEqual(@as(u64, 20), r.cpp_self_ns);
    try std.testing.expectEqualStrings("0.5000", r.self_ratio);
    try std.testing.expectEqualStrings("-50.0", r.self_delta_pct);
}
