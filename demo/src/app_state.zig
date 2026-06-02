//! AppState — глобальное состояние демо (аналог RecastDemo/AppState.h).
//! Камера, viewport, выбранный меш, папки, флаги UI-панелей.

const std = @import("std");
const Camera = @import("camera.zig").Camera;

pub const AppState = struct {
    camera: Camera = .{},
    viewport: [4]i32 = .{ 0, 0, 1280, 720 },

    mesh_name: ?[]const u8 = null,
    meshes_folder: []const u8 = "test_data", // .obj меши (#23 формализует ассеты)
    test_cases_folder: []const u8 = "TestCases",

    show_menu: bool = true,
    show_log: bool = false,
    show_tools: bool = true,
    show_test_cases: bool = false,
    log_scroll: i32 = 0,

    pub fn aspect(self: *const AppState) f32 {
        return @as(f32, @floatFromInt(self.viewport[2])) / @as(f32, @floatFromInt(self.viewport[3]));
    }
};
