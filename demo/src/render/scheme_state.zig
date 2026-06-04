//! Live navmesh-colouring selection (foundation render layer, §3.c). Global so
//! the Properties UI (main.zig) and the sample render path (sample_*.zig) share
//! one source of truth without threading it through every call. Default `.area`
//! reproduces the original look exactly.

const ColorScheme = @import("color_scheme.zig").ColorScheme;

pub var active: ColorScheme = .area;
