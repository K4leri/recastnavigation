//! Live navmesh CLIPPING + ISOLATION selection (cluster E, P0-2). Global so the
//! Properties UI (main.zig) and the sample render paths (sample_*.zig) share one
//! source of truth without threading a Filter through every call — mirrors
//! scheme_state.zig. Default `.{}` (clip off / iso none) reproduces the faithful
//! navmesh draw exactly (active() == false).

const isolation = @import("isolation.zig");

pub var active: isolation.Filter = .{};
