//! Compile + behavior smoke for the thin Tracy wrapper (src/tracy.zig).
//!
//! The wrapper needs a `build_options` module, the timing registry, and
//! (when -Dtracy) ztracy — so it cannot be `zig test`-ed standalone. The
//! `test-tracy-wrapper` build step wires those imports and runs this file.
//!
//! With tracy OFF: zones are pure no-ops (nothing lands in the registry).
//! With tracy ON: `zone` records into the registry; `zoneDeep` records only
//! when -Dtracy-deep is also set. We assert the registry side here (ztracy
//! emits to a GUI server we cannot observe headless, but the calls must at
//! least compile and not crash).

const std = @import("std");
const tracy = @import("tracy");
const reg = @import("tracy_registry");

test "zone() compiles and is callable; registry side respects -Dtracy" {
    reg.reset();
    {
        var z = tracy.zone(@src(), "wrapper_smoke");
        z.end();
    }
    const s = reg.get("wrapper_smoke");
    if (tracy.enabled) {
        // tracy on → the coarse zone must have recorded exactly one activation.
        try std.testing.expect(s != null);
        try std.testing.expect(s.?.count == 1);
    } else {
        // tracy off → zero-cost: nothing recorded.
        try std.testing.expect(s == null);
    }
}

test "zoneDeep() is a true no-op unless -Dtracy-deep" {
    reg.reset();
    {
        var z = tracy.zoneDeep(@src(), "wrapper_deep_smoke");
        z.end();
    }
    const s = reg.get("wrapper_deep_smoke");
    if (tracy.deep_enabled) {
        try std.testing.expect(s != null);
        try std.testing.expect(s.?.count == 1);
    } else {
        // Either tracy fully off, or tracy on but deep off: must record nothing.
        try std.testing.expect(s == null);
    }
}

test "plot / frameMark / setThreadName compile and don't crash" {
    reg.reset();
    tracy.plot("wrapper_plot", 42.0);
    tracy.frameMark();
    tracy.setThreadName("wrapper_thread");
    const p = reg.getPlot("wrapper_plot");
    if (tracy.enabled) {
        try std.testing.expect(p != null);
        try std.testing.expect(p.?.last == 42.0);
    } else {
        try std.testing.expect(p == null);
    }
}
