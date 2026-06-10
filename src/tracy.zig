//! Thin Tracy wrapper over ztracy + the in-process timing registry.
//!
//! A zone NAME is a comptime string literal and is the cross-language CSV
//! contract key (the C++ `rn_registry` must use the byte-identical names).
//!
//! ## Build gates
//!
//! Three comptime flags (from `build_options`):
//!   - `enable_registry` (-Dbench=true OR -Dtracy=true): records CSV zones into
//!     the in-process registry. No ztracy C library involved.
//!   - `enable_tracy`    (-Dtracy=true): ALSO emits ztracy GUI zones. Implies
//!     registry. ztracy is only @imported when this is true.
//!   - `enable_tracy_deep` (-Dtracy-deep=true): enables inner-loop zoneDeep().
//!
//! ## Zero-cost when both flags are false
//!
//! When neither `enable_registry` nor `enable_tracy` is set, every zone returns
//! a `noop()` whose start/stop are genuine no-ops. The `Zone` struct holds
//! `ztx: void` and `active=false`; `end()` touches nothing. The compiler folds
//! the whole thing away.
//!
//! ## Two zone tiers
//!
//!   * `zone`     — coarse / per-pass zones. Active when `-Dbench` or `-Dtracy`.
//!   * `zoneDeep` — inner-loop zones. Active ONLY when both `-Dtracy=true` and
//!                  `-Dtracy-deep=true`. A TRUE no-op otherwise (no registry
//!                  record, no ztracy emit), so hot loops pay nothing unless the
//!                  deep tier is explicitly requested.
//!
//! ## Benchmark fairness (-Dbench=true)
//!
//! With -Dbench=true the registry timer runs but ztracy.ZoneN() is NOT called.
//! This matches the C++ reference which is registry-only (no Tracy C library),
//! so per-zone instrumentation overhead is symmetric across both languages.

const std = @import("std");
const opts = @import("build_options");
// Imported BY NAME (not relative) so that every consumer shares the ONE
// registry module instance the build graph provides. A relative
// `@import("tracy_registry.zig")` would create a second module instance with
// its own process-global aggregate state — zones recorded through the wrapper
// would then be invisible to code reading the named `tracy_registry` module.
const registry = @import("tracy_registry");

/// ztracy GUI gate: true only when -Dtracy=true. Controls ztracy.ZoneN() calls
/// and ztracy C-library linkage. When false, ztracy is never imported.
pub const enabled: bool = opts.enable_tracy;
/// Registry gate: true when -Dbench=true OR -Dtracy=true. Controls CSV recording.
/// Independent of ztracy — a -Dbench=true build records without ztracy overhead.
pub const registry_enabled: bool = opts.enable_registry;
pub const deep_enabled: bool = opts.enable_tracy and opts.enable_tracy_deep;

// Only imported (and thus only analyzed) when ztracy is enabled (-Dtracy=true).
// With tracy off the `else struct {}` keeps the symbol present but empty, and
// no `ztracy.*` expression is ever reached at comptime. A registry-only build
// (-Dbench=true) never imports ztracy, keeping the C library out of the link.
const ztracy = if (enabled) @import("ztracy") else struct {};

/// A live (or no-op) profiling scope. Must call `end()` exactly once.
///
/// `active` is the single source of truth for whether `ztx` is a real ztracy
/// context. It is true ONLY on a real (non-noop) zone created while ztracy is
/// enabled. `end()` gates the `ztx.End()` call on `active`, so the `undefined`
/// `ztx` produced by a registry-only or deep no-op zone is never read.
///
/// `timer` is a real ScopeTimer when `registry_enabled`, else a noop. The
/// registry and ztracy gates are INDEPENDENT: -Dbench records without ztracy.
pub const Zone = struct {
    ztx: if (enabled) ztracy.ZoneCtx else void,
    timer: registry.ScopeTimer,
    /// True only when ztracy is enabled AND this is a live (non-noop) zone.
    /// Gates ztx.End() — does NOT gate timer.stop() (that is always safe).
    active: bool,

    pub inline fn end(self: *Zone) void {
        self.timer.stop();
        if (enabled and self.active) self.ztx.End();
    }
};

/// Open a coarse profiling zone. `name` must be a comptime 0-terminated literal
/// (its lifetime is 'static — required by the registry which borrows the key).
///
/// With -Dbench=true: records registry CSV only (no ztracy call).
/// With -Dtracy=true: records registry AND emits a ztracy GUI zone.
/// With neither:      full no-op (zero cost).
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    if (!registry_enabled and !enabled) {
        return .{ .ztx = {}, .timer = registry.ScopeTimer.noop(), .active = false };
    }
    // Start the registry timer when registry is enabled (bench or tracy).
    const timer = if (registry_enabled) registry.ScopeTimer.start(name) else registry.ScopeTimer.noop();
    if (!enabled) {
        // Registry-only path (-Dbench): no ztracy call.
        return .{ .ztx = {}, .timer = timer, .active = false };
    }
    // ztracy path (-Dtracy): emit GUI zone AND record registry.
    return .{
        .ztx = ztracy.ZoneN(src, name.ptr),
        .timer = timer,
        .active = true,
    };
}

/// Open an inner-loop profiling zone. Active only when `-Dtracy-deep` (and
/// `-Dtracy`). A full no-op otherwise: no registry record, no ztracy emit.
pub inline fn zoneDeep(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    if (!deep_enabled) return .{
        // `ztx` is `void` when ztracy is off, or an undefined ztracy context
        // when ztracy is on but deep is off. Either way `active=false`
        // guarantees `end()` never reads it.
        .ztx = if (enabled) undefined else {},
        .timer = registry.ScopeTimer.noop(),
        .active = false,
    };
    return .{
        .ztx = ztracy.ZoneN(src, name.ptr),
        .timer = registry.ScopeTimer.start(name),
        .active = true,
    };
}

/// Record a named scalar plot sample. Goes to ztracy (GUI) and the registry.
/// No-op when tracy is disabled.
pub inline fn plot(comptime name: [:0]const u8, val: f64) void {
    if (enabled) {
        ztracy.PlotF(name.ptr, val);
        registry.plot(name, val);
    }
}

/// Mark a frame boundary for the Tracy GUI. No-op when tracy is disabled.
pub inline fn frameMark() void {
    if (enabled) ztracy.FrameMark();
}

/// Name the current thread in the Tracy GUI. No-op when tracy is disabled.
pub inline fn setThreadName(comptime name: [:0]const u8) void {
    if (enabled) ztracy.SetThreadName(name.ptr);
}
