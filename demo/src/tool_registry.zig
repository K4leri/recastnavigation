//! Registry of demo scene-tools: the single source of truth for the Tools-panel
//! radio list and the on-screen control hint. Replaces the hardcoded radio block
//! and hint `switch` in main.zig. Per-tool click/render/drawMenu dispatch stays
//! in main.zig for now (vtable unification is a later shell increment).

const std = @import("std");

/// Active scene-tool. Same variants/order as the former `ActiveTool` enum.
pub const ToolId = enum { none, tester, prune, offmesh, convex, crowd, select };

pub const ToolEntry = struct {
    id: ToolId,
    label: []const u8, // Tools-panel radio label
    hint: []const u8, // bottom-of-screen control hint
    radio_id: u32, // dvui id_extra (kept identical to the old radios)
};

/// In display order (matches the previous radio order in main.zig).
pub const entries = [_]ToolEntry{
    .{ .id = .tester, .label = "Test Navmesh", .radio_id = 201, .hint = "LMB: set start   Shift+LMB: set end" },
    .{ .id = .prune, .label = "Prune NavMesh", .radio_id = 206, .hint = "LMB: click fill area" },
    .{ .id = .offmesh, .label = "Create Off-Mesh Connections", .radio_id = 202, .hint = "LMB: 1st=start, 2nd=end" },
    .{ .id = .convex, .label = "Create Convex Volumes", .radio_id = 203, .hint = "LMB: add point, click red point to build   Shift+LMB: delete volume" },
    .{ .id = .crowd, .label = "Create Crowds", .radio_id = 204, .hint = "Create/Move/Select via Tools panel" },
    .{ .id = .select, .label = "Select / Edit", .radio_id = 207, .hint = "LMB drag empty: box   drag selected: move   Ctrl+LMB: toggle   Ctrl+C/V: copy/paste   Del: delete" },
    .{ .id = .none, .label = "Disabled", .radio_id = 205, .hint = "RMB: rotate   WASD/QE: move   wheel: zoom   R: reset view" },
};

comptime {
    if (entries.len != @typeInfo(ToolId).@"enum".fields.len)
        @compileError("tool_registry.entries must have one entry per ToolId variant");
}

/// Control hint for the active tool. Every ToolId has an entry.
pub fn hintFor(id: ToolId) []const u8 {
    for (entries) |e| {
        if (e.id == id) return e.hint;
    }
    unreachable; // every ToolId has an entry (enforced by the test + comptime check below)
}

test "every ToolId has exactly one entry, ids unique, hints non-empty" {
    inline for (@typeInfo(ToolId).@"enum".fields) |f| {
        const id: ToolId = @enumFromInt(f.value);
        var count: usize = 0;
        for (entries) |e| {
            if (e.id == id) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(hintFor(id).len > 0);
    }
    for (entries, 0..) |a, i| {
        for (entries[i + 1 ..]) |b| {
            try std.testing.expect(a.radio_id != b.radio_id);
            try std.testing.expect(!std.mem.eql(u8, a.label, b.label));
        }
    }
}
