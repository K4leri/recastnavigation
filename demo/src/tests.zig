//! Агрегатор тестов demo-модулей, которым достаточно recast-nav
//! (без zgl/dvui). Модули с GL/UI проверяются через `zig build demo`.

test {
    _ = @import("mat.zig");
    _ = @import("camera.zig");
    _ = @import("sample.zig");
    _ = @import("build_context.zig");
    _ = @import("app_state.zig");
    _ = @import("io_util.zig");
    _ = @import("input_geom.zig");
    _ = @import("convex_surface.zig");
    _ = @import("render/color_scheme.zig");
    _ = @import("render/poly_visit.zig");
    _ = @import("render/isolation.zig");
    _ = @import("render/legend.zig");
    _ = @import("persist/registry_io.zig");
    _ = @import("persist/scene_io.zig");
    _ = @import("persist/tile_store.zig");
    _ = @import("persist/manifest.zig");
    _ = @import("persist/scene_container.zig");
    _ = @import("edit/undo_stack.zig");
    _ = @import("edit/edit_op.zig");
    _ = @import("edit/selection.zig");
    _ = @import("edit/snap.zig");
    _ = @import("edit/clipboard.zig");
    _ = @import("edit/presets.zig");
    _ = @import("edit/inspector.zig");
}
