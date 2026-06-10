//! merge_csv — join the Zig and C++ per-zone benchmark CSVs into one comparison
//! table (Task 6.2 of the Tracy Zig-vs-C++ Recast/Detour/Crowd benchmark).
//!
//! Both runners (`bench/tracy_scenarios.zig`, `Bench/tracy_scenarios.cpp`) emit the
//! same per-(scenario,zone) CSV — the contract:
//!
//!     scenario,zone,count,inclusive_ns,self_ns,mean_ns,min_ns,max_ns
//!
//! plus optional skipped-scenario marker rows of the form
//!
//!     <scenario>,__SKIPPED_BUDGET__,0,0,0,0,0,0
//!
//! This tool reads both, joins by KEY = (scenario, zone), and writes
//! `ZIG_VS_CPP.csv`:
//!
//!     scenario,zone,zig_self_ns,cpp_self_ns,self_ratio,self_delta_pct,
//!     zig_incl_ns,cpp_incl_ns,zig_count,cpp_count,presence
//!
//!   - self_ratio     = zig_self_ns / cpp_self_ns  (4 decimals; `inf` when
//!                       cpp_self_ns == 0).
//!   - self_delta_pct = (zig_self_ns - cpp_self_ns) / cpp_self_ns * 100  (1 decimal;
//!                       `inf` when cpp_self_ns == 0).
//!   - presence       = both | zig_only | cpp_only. Rows present on only one side are
//!                       still emitted, the missing side's numeric columns are 0.
//!   - zig_count/cpp_count let an analyst spot structural divergence (e.g. different
//!     poly counts -> different per-zone activation counts).
//!
//! ## Sort order (deterministic)
//!
//! Rows are sorted by (scenario ASC, then a per-presence tier, then a key within the
//! tier):
//!   1. `both` rows first, by DESCENDING self_ratio — so the worst Zig-vs-C++
//!      offenders sort to the TOP within each scenario. Equal ratios break by zone
//!      name ASC.
//!   2. then `zig_only` rows, by zone name ASC.
//!   3. then `cpp_only` rows, by zone name ASC.
//! Scenario order is alphabetical. Marker (`__SKIPPED_BUDGET__`) rows never become
//! comparison rows; they are counted in the summary and otherwise dropped.
//!
//! ## stdout summary
//!
//! Prints: total zones compared (both), zig_only / cpp_only counts, skipped
//! scenarios, and the TOP 10 (scenario,zone) by self_ratio among `both` rows whose
//! cpp_self_ns exceeds a small floor (default 10us) — the floor keeps tiny-denominator
//! noise ratios out of the offender list.
//!
//! CLI: `merge_csv <zig_csv> <cpp_csv> <out_csv>`
//!
//! Zig 0.16: file IO lives behind `std.Io` (no `std.fs.cwd()`); `main` takes a
//! `std.process.Init` for the gpa + io + args (mirrors bench/tracy_scenarios.zig).
//! The pure join core (`mergeToWriter`) works over in-memory strings + a
//! `std.Io.Writer`, so it is unit-tested without touching the filesystem.

const std = @import("std");

// The marker zone name a runner emits for a budget-skipped scenario.
const skipped_marker = "__SKIPPED_BUDGET__";

/// One side's parsed per-zone aggregate (only the columns merge_csv needs).
/// `scenario`/`zone` alias the input CSV buffer (NOT the composite map key, which
/// is freed with the ParsedSide) so merged rows + offenders stay valid after the
/// ParsedSide is torn down, as long as the caller keeps the input CSV alive.
const Stat = struct {
    scenario: []const u8,
    zone: []const u8,
    self_ns: u64,
    incl_ns: u64,
    count: u64,
};

/// Which side(s) a joined (scenario,zone) row came from.
const Presence = enum {
    both,
    zig_only,
    cpp_only,

    fn label(self: Presence) []const u8 {
        return switch (self) {
            .both => "both",
            .zig_only => "zig_only",
            .cpp_only => "cpp_only",
        };
    }

    /// Sort tier: `both` (0) before `zig_only` (1) before `cpp_only` (2).
    fn tier(self: Presence) u8 {
        return switch (self) {
            .both => 0,
            .zig_only => 1,
            .cpp_only => 2,
        };
    }
};

/// A fully joined output row (one per (scenario,zone) present on either side).
const MergedRow = struct {
    scenario: []const u8,
    zone: []const u8,
    zig: Stat,
    cpp: Stat,
    presence: Presence,

    /// zig_self / cpp_self. Infinity when cpp_self == 0 (used for sorting +
    /// the `inf` sentinel on output).
    fn selfRatio(self: MergedRow) f64 {
        if (self.cpp.self_ns == 0) return std.math.inf(f64);
        return @as(f64, @floatFromInt(self.zig.self_ns)) / @as(f64, @floatFromInt(self.cpp.self_ns));
    }
};

/// A single top-offender entry (a `both` row above the ratio floor), exposed to
/// callers (tests + the stdout summary).
pub const Offender = struct {
    scenario: []const u8,
    zone: []const u8,
    self_ratio: f64,
    zig_self_ns: u64,
    cpp_self_ns: u64,
};

/// Result of a merge: the headline counts + the top offenders. Field slices
/// (`scenario`/`zone`) ALIAS the input CSV buffers passed to `mergeToWriter`, so
/// keep those buffers alive while inspecting a Summary. Call `deinit` to free the
/// owned `top_offenders` slice.
pub const Summary = struct {
    both_count: usize,
    zig_only_count: usize,
    cpp_only_count: usize,
    /// Number of scenarios skipped by the budget guard on EITHER side (a scenario
    /// counts once even if both sides skipped it).
    skipped_count: usize,
    /// Top-N `both` offenders (cpp_self_ns above the floor), DESCENDING by ratio.
    /// Owned by this Summary (freed in `deinit`).
    top_offenders: []Offender,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Summary) void {
        self.allocator.free(self.top_offenders);
        self.* = undefined;
    }
};

/// Options controlling the merge.
pub const Options = struct {
    /// Offender floor: only `both` rows whose cpp_self_ns is strictly greater than
    /// this many ns are eligible for the top-offenders list (avoids tiny-denominator
    /// noise ratios). Default 10us.
    ratio_floor_ns: u64 = 10_000,
    /// How many offenders to keep in the summary. Default 10.
    top_n: usize = 10,
};

const max_offenders_default = 10;

// ---------------------------------------------------------------------------
// CSV parsing
// ---------------------------------------------------------------------------

/// Parse one CSV body into a map keyed by "scenario\x00zone" -> Stat. Marker rows
/// (`__SKIPPED_BUDGET__`) are NOT inserted as zones; instead their scenario id is
/// added to `skipped`. The header row is skipped; blank/short lines are tolerated;
/// trailing `\r` is trimmed. Map keys and the scenario/zone slices stored in the
/// `Stat`-adjacent maps ALIAS `content` (no dup) — keep `content` alive.
///
/// Returns nothing; fills the caller-provided maps. `keys` (composite "scen\x00zone")
/// alias `content` via the dedicated key buffer built per row, so we DO own those
/// composite-key strings (they are not contiguous in `content`) — they are allocated
/// from `allocator` and tracked by the caller for freeing.
const ParsedSide = struct {
    /// Composite-key map: key = "<scenario>\x00<zone>" (owned strings) -> Stat.
    stats: std.StringHashMap(Stat),
    /// scenario id -> {} for scenarios that emitted a skipped-budget marker.
    skipped: std.StringHashMap(void),
    /// Owned composite-key buffers (freed on deinit).
    owned_keys: std.array_list.Managed([]u8),

    fn init(allocator: std.mem.Allocator) ParsedSide {
        return .{
            .stats = std.StringHashMap(Stat).init(allocator),
            .skipped = std.StringHashMap(void).init(allocator),
            .owned_keys = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *ParsedSide) void {
        const a = self.owned_keys.allocator;
        for (self.owned_keys.items) |k| a.free(k);
        self.owned_keys.deinit();
        self.stats.deinit();
        self.skipped.deinit();
    }
};

/// Build the composite key "<scenario>\x00<zone>" (NUL separator can't appear in a
/// CSV field, so it is an unambiguous join key). Caller owns the returned buffer.
fn makeKey(allocator: std.mem.Allocator, scenario: []const u8, zone: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, scenario.len + 1 + zone.len);
    @memcpy(buf[0..scenario.len], scenario);
    buf[scenario.len] = 0;
    @memcpy(buf[scenario.len + 1 ..], zone);
    return buf;
}

fn parseSide(allocator: std.mem.Allocator, content: []const u8) !ParsedSide {
    var side = ParsedSide.init(allocator);
    errdefer side.deinit();

    var lines = std.mem.splitScalar(u8, content, '\n');
    var seen_header = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // First non-blank line is the header (starts with "scenario,"). Skip it.
        // Be tolerant: if the file is missing a header, the first data row would
        // start with a scenario id, not "scenario," — but our contract always
        // emits the header, so skip exactly one header occurrence.
        if (!seen_header and std.mem.startsWith(u8, line, "scenario,")) {
            seen_header = true;
            continue;
        }

        // Tokenize fields. We need indices: 0=scenario, 1=zone, 2=count,
        // 3=inclusive_ns, 4=self_ns. Tolerate extra trailing columns; require >=5.
        var fields: [8][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |f| : (n += 1) {
            if (n < 8) fields[n] = f;
        }
        if (n < 5) continue; // malformed / too short — skip defensively.

        const scenario = fields[0];
        const zone = fields[1];

        // Marker row: record the scenario as skipped, don't treat as a zone.
        if (std.mem.eql(u8, zone, skipped_marker)) {
            try side.skipped.put(scenario, {});
            continue;
        }

        const count = std.fmt.parseInt(u64, std.mem.trim(u8, fields[2], " \t"), 10) catch continue;
        const incl = std.fmt.parseInt(u64, std.mem.trim(u8, fields[3], " \t"), 10) catch continue;
        const self_ns = std.fmt.parseInt(u64, std.mem.trim(u8, fields[4], " \t"), 10) catch continue;

        const key = try makeKey(allocator, scenario, zone);
        // If a duplicate (scenario,zone) appears, keep the first and free the dup
        // key (a runner emits one row per zone; duplicates would be a data bug).
        const gop = try side.stats.getOrPut(key);
        if (gop.found_existing) {
            allocator.free(key);
        } else {
            try side.owned_keys.append(key);
            // scenario/zone alias `content` (the caller-owned CSV), so the stored
            // slices outlive the composite key buffer freed in ParsedSide.deinit.
            gop.value_ptr.* = .{ .scenario = scenario, .zone = zone, .self_ns = self_ns, .incl_ns = incl, .count = count };
        }
    }
    return side;
}

// ---------------------------------------------------------------------------
// Merge + emit
// ---------------------------------------------------------------------------

/// Output CSV header — the documented column contract.
pub const out_header = "scenario,zone,zig_self_ns,cpp_self_ns,self_ratio,self_delta_pct,zig_incl_ns,cpp_incl_ns,zig_count,cpp_count,presence\n";

fn lessThanRow(_: void, a: MergedRow, b: MergedRow) bool {
    // 1. scenario ascending.
    const sc = std.mem.order(u8, a.scenario, b.scenario);
    if (sc != .eq) return sc == .lt;
    // 2. presence tier: both < zig_only < cpp_only.
    const ta = a.presence.tier();
    const tb = b.presence.tier();
    if (ta != tb) return ta < tb;
    // 3a. within `both`: descending self_ratio (worst offenders first).
    if (a.presence == .both) {
        const ra = a.selfRatio();
        const rb = b.selfRatio();
        if (ra != rb) return ra > rb; // descending
    }
    // 3b. tie / single-side tiers: zone name ascending (deterministic).
    return std.mem.order(u8, a.zone, b.zone) == .lt;
}

fn offenderLessThan(_: void, a: Offender, b: Offender) bool {
    if (a.self_ratio != b.self_ratio) return a.self_ratio > b.self_ratio; // descending
    return std.mem.order(u8, a.zone, b.zone) == .lt; // deterministic tiebreak
}

/// Pure merge core: parse both CSVs, join by (scenario,zone), write the merged
/// table to `writer` (header + sorted rows), and return a Summary. No filesystem
/// access — `zig_csv`/`cpp_csv` are full in-memory file bodies.
///
/// Slices in the returned Summary alias `zig_csv`/`cpp_csv`; keep them alive while
/// reading it. Call `Summary.deinit` to free the owned offenders slice.
pub fn mergeToWriter(
    allocator: std.mem.Allocator,
    zig_csv: []const u8,
    cpp_csv: []const u8,
    writer: *std.Io.Writer,
    opts: Options,
) !Summary {
    var zig_side = try parseSide(allocator, zig_csv);
    defer zig_side.deinit();
    var cpp_side = try parseSide(allocator, cpp_csv);
    defer cpp_side.deinit();

    // Build the union of keys. Each key is "scenario\x00zone".
    var rows = std.array_list.Managed(MergedRow).init(allocator);
    defer rows.deinit();

    // Zig keys first (both + zig_only), then cpp-only keys. scenario/zone alias the
    // input CSV buffers (via the Stat), so the rows stay valid after the ParsedSides
    // (and their composite key buffers) are torn down.
    const zero_stat = Stat{ .scenario = "", .zone = "", .self_ns = 0, .incl_ns = 0, .count = 0 };
    {
        var it = zig_side.stats.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const zs = e.value_ptr.*;
            if (cpp_side.stats.get(key)) |cs| {
                try rows.append(.{ .scenario = zs.scenario, .zone = zs.zone, .zig = zs, .cpp = cs, .presence = .both });
            } else {
                try rows.append(.{ .scenario = zs.scenario, .zone = zs.zone, .zig = zs, .cpp = zero_stat, .presence = .zig_only });
            }
        }
    }
    {
        var it = cpp_side.stats.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            if (zig_side.stats.contains(key)) continue; // already emitted as `both`
            const cs = e.value_ptr.*;
            try rows.append(.{ .scenario = cs.scenario, .zone = cs.zone, .zig = zero_stat, .cpp = cs, .presence = .cpp_only });
        }
    }

    std.mem.sort(MergedRow, rows.items, {}, lessThanRow);

    // Emit.
    try writer.writeAll(out_header);
    var both_count: usize = 0;
    var zig_only_count: usize = 0;
    var cpp_only_count: usize = 0;
    for (rows.items) |r| {
        switch (r.presence) {
            .both => both_count += 1,
            .zig_only => zig_only_count += 1,
            .cpp_only => cpp_only_count += 1,
        }
        try writeRow(writer, r);
    }

    // Skipped scenarios = union of the two sides' skipped sets.
    var skipped_union = std.StringHashMap(void).init(allocator);
    defer skipped_union.deinit();
    {
        var it = zig_side.skipped.keyIterator();
        while (it.next()) |k| try skipped_union.put(k.*, {});
        var it2 = cpp_side.skipped.keyIterator();
        while (it2.next()) |k| try skipped_union.put(k.*, {});
    }

    // Top offenders: `both` rows with cpp_self_ns > floor, descending by ratio.
    var offenders = std.array_list.Managed(Offender).init(allocator);
    defer offenders.deinit();
    for (rows.items) |r| {
        if (r.presence != .both) continue;
        if (r.cpp.self_ns <= opts.ratio_floor_ns) continue;
        try offenders.append(.{
            .scenario = r.scenario,
            .zone = r.zone,
            .self_ratio = r.selfRatio(),
            .zig_self_ns = r.zig.self_ns,
            .cpp_self_ns = r.cpp.self_ns,
        });
    }
    std.mem.sort(Offender, offenders.items, {}, offenderLessThan);
    const keep = @min(offenders.items.len, if (opts.top_n == 0) max_offenders_default else opts.top_n);
    const top = try allocator.alloc(Offender, keep);
    @memcpy(top, offenders.items[0..keep]);

    return Summary{
        .both_count = both_count,
        .zig_only_count = zig_only_count,
        .cpp_only_count = cpp_only_count,
        .skipped_count = skipped_union.count(),
        .top_offenders = top,
        .allocator = allocator,
    };
}

/// Write one merged row. Formats self_ratio (4 dp) and self_delta_pct (1 dp) with
/// the `inf` sentinel when cpp_self_ns == 0 (division guard).
fn writeRow(writer: *std.Io.Writer, r: MergedRow) !void {
    try writer.print("{s},{s},{d},{d},", .{ r.scenario, r.zone, r.zig.self_ns, r.cpp.self_ns });

    if (r.cpp.self_ns == 0) {
        // Guard /0: ratio + delta undefined. Emit the `inf` sentinel for both.
        try writer.writeAll("inf,inf,");
    } else {
        const ratio = @as(f64, @floatFromInt(r.zig.self_ns)) / @as(f64, @floatFromInt(r.cpp.self_ns));
        const zig_f: f64 = @floatFromInt(r.zig.self_ns);
        const cpp_f: f64 = @floatFromInt(r.cpp.self_ns);
        const delta_pct = (zig_f - cpp_f) / cpp_f * 100.0;
        try writer.print("{d:.4},{d:.1},", .{ ratio, delta_pct });
    }

    try writer.print("{d},{d},{d},{d},{s}\n", .{
        r.zig.incl_ns,
        r.cpp.incl_ns,
        r.zig.count,
        r.cpp.count,
        r.presence.label(),
    });
}

// ---------------------------------------------------------------------------
// File IO + CLI (Zig 0.16 std.Io)
// ---------------------------------------------------------------------------

fn readWholeFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Collect args ([zig_csv, cpp_csv, out_csv] after skipping argv[0]) — mirrors
    // bench/tracy_scenarios.zig (std.process.argsAlloc is gone in 0.16).
    var arg_list = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (arg_list.items) |a| allocator.free(a);
        arg_list.deinit();
    }
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
        defer it.deinit();
        _ = it.skip(); // argv[0]
        while (it.next()) |a| try arg_list.append(try allocator.dupe(u8, a));
    }
    const args = arg_list.items;

    if (args.len != 3) {
        std.debug.print(
            \\usage: merge_csv <zig_csv> <cpp_csv> <out_csv>
            \\  joins the Zig + C++ per-zone benchmark CSVs by (scenario,zone)
            \\  into <out_csv> (the ZIG_VS_CPP comparison table).
            \\
        , .{});
        return error.BadUsage;
    }

    const zig_path = args[0];
    const cpp_path = args[1];
    const out_path = args[2];

    const zig_csv = try readWholeFile(allocator, io, zig_path);
    defer allocator.free(zig_csv);
    const cpp_csv = try readWholeFile(allocator, io, cpp_path);
    defer allocator.free(cpp_csv);

    // Write the merged table to the output file via a buffered File.Writer.
    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    var write_buf: [16 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &write_buf);
    const w = &fw.interface;

    var summary = try mergeToWriter(allocator, zig_csv, cpp_csv, w, .{});
    defer summary.deinit();
    try w.flush();

    // stdout summary.
    std.debug.print(
        "[merge_csv] wrote {s}: {d} zones compared (both), {d} zig_only, {d} cpp_only, {d} skipped scenario(s)\n",
        .{ out_path, summary.both_count, summary.zig_only_count, summary.cpp_only_count, summary.skipped_count },
    );
    if (summary.top_offenders.len == 0) {
        std.debug.print("[merge_csv] no `both` zones above the {d}ns offender floor.\n", .{@as(u64, 10_000)});
    } else {
        std.debug.print("[merge_csv] top {d} Zig-vs-C++ offenders (self_ratio, cpp_self > floor):\n", .{summary.top_offenders.len});
        for (summary.top_offenders, 0..) |o, i| {
            std.debug.print(
                "  {d:>2}. {d:.4}x  {s} / {s}  (zig_self={d}ns cpp_self={d}ns)\n",
                .{ i + 1, o.self_ratio, o.scenario, o.zone, o.zig_self_ns, o.cpp_self_ns },
            );
        }
    }
}
