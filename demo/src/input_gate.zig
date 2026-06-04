//! UI input gating for the demo. Names the two predicates that were previously
//! inlined as the `ui_mouse` / `ui_keyboard` flags in main.zig, so call-sites
//! stop repeating `!ui_mouse` / `!ui_keyboard`. Behaviour is identical — this
//! only gives the predicates a home and a name.
//!
//! - pointer_over_ui: the cursor is over a floating dvui panel/window this frame
//!   (was `ui_mouse`). Gates camera rotate, wheel zoom and scene picking.
//! - text_focused: a dvui text field has keyboard focus (was `ui_keyboard`).
//!   Gates scene hotkeys.

const std = @import("std");

pub const InputGate = struct {
    pointer_over_ui: bool = false,
    text_focused: bool = false,

    /// Refresh once per frame from the dvui frame results (after `win.end`).
    pub fn update(self: *InputGate, pointer_over_ui: bool, text_focused: bool) void {
        self.pointer_over_ui = pointer_over_ui;
        self.text_focused = text_focused;
    }

    /// The pointer is in the 3D scene (not over a panel): RMB-rotate, wheel-zoom,
    /// LMB-pick. Replaces `!ui_mouse`.
    pub fn pointerInScene(self: InputGate) bool {
        return !self.pointer_over_ui;
    }

    /// No text field is capturing keys: scene hotkeys may fire. Replaces
    /// `!ui_keyboard`.
    pub fn keyboardFree(self: InputGate) bool {
        return !self.text_focused;
    }
};

test "InputGate predicates mirror the old flags" {
    var g = InputGate{};
    try std.testing.expect(g.pointerInScene());
    try std.testing.expect(g.keyboardFree());

    g.update(true, false);
    try std.testing.expect(!g.pointerInScene());
    try std.testing.expect(g.keyboardFree());

    g.update(false, true);
    try std.testing.expect(g.pointerInScene());
    try std.testing.expect(!g.keyboardFree());

    g.update(true, true);
    try std.testing.expect(!g.pointerInScene());
    try std.testing.expect(!g.keyboardFree());
}
