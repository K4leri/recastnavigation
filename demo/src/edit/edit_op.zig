//! EditOp — a single reversible scene edit (cluster F, feature F1 core).
//!
//! Each variant captures ALL data needed to both redo (`apply`) and undo
//! (`revert`) the mutation against a live `*InputGeom`:
//!
//!   - add_volume     : the full ConvexVolume that was appended (id/mode/band/
//!                      verts) — redo re-appends a copy, undo removes the last.
//!   - delete_volume  : the full ConvexVolume that was removed PLUS its former
//!                      index — undo re-inserts the captured copy at that index,
//!                      restoring id/mode/band/verts byte-for-byte; redo deletes
//!                      it again.
//!   - add_offmesh    : the 6 off-mesh fields (verts[6]/rad/dir/area/flags/id) of
//!                      the connection that was appended — redo re-appends, undo
//!                      removes the last.
//!   - delete_offmesh : the 6 off-mesh fields PLUS the former index — undo
//!                      re-inserts at that index, redo deletes it again.
//!
//! Because `ConvexVolume` is a value type (its `verts` is a fixed [12*3]f32
//! array, not a slice) and the off-mesh capture is all scalars + a [6]f32, an
//! EditOp owns NO heap memory — copies are by value. `deinit` exists so the
//! UndoStack can call it uniformly and so a future variant that DOES own heap
//! data has a hook to free it.

const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;
const ConvexVolume = ig.ConvexVolume;

/// Reversible capture of one off-mesh connection (all 6 parallel-array fields).
pub const OffMeshData = struct {
    verts: [6]f32,
    rad: f32,
    dir: u8,
    area: u8,
    flags: u16,
    id: u32,

    /// Snapshot the connection currently stored at `idx` in `geom`.
    pub fn capture(geom: *const InputGeom, idx: usize) OffMeshData {
        return .{
            .verts = geom.off_verts.items[idx * 6 ..][0..6].*,
            .rad = geom.off_rad.items[idx],
            .dir = geom.off_dir.items[idx],
            .area = geom.off_area.items[idx],
            .flags = geom.off_flags.items[idx],
            .id = geom.off_id.items[idx],
        };
    }
};

pub const EditOp = union(enum) {
    add_volume: ConvexVolume,
    delete_volume: struct { index: usize, vol: ConvexVolume },
    add_offmesh: OffMeshData,
    delete_offmesh: struct { index: usize, data: OffMeshData },

    /// Redo the action (re-perform the original mutation).
    pub fn apply(self: EditOp, geom: *InputGeom) void {
        switch (self) {
            .add_volume => |vol| {
                // Re-append the exact captured volume (id/mode/band preserved).
                geom.insertConvexVolume(geom.volumes.items.len, vol) catch {};
            },
            .delete_volume => |d| {
                geom.deleteConvexVolume(d.index);
            },
            .add_offmesh => |d| {
                geom.insertOffMeshConnection(geom.offMeshCount(), d.verts, d.rad, d.dir, d.area, d.flags, d.id) catch {};
            },
            .delete_offmesh => |d| {
                geom.deleteOffMeshConnection(d.index);
            },
        }
    }

    /// Undo the action (reverse the original mutation).
    pub fn revert(self: EditOp, geom: *InputGeom) void {
        switch (self) {
            .add_volume => {
                // The add appended to the end — remove the last volume.
                if (geom.volumes.items.len > 0)
                    geom.deleteConvexVolume(geom.volumes.items.len - 1);
            },
            .delete_volume => |d| {
                geom.insertConvexVolume(d.index, d.vol) catch {};
            },
            .add_offmesh => {
                if (geom.offMeshCount() > 0)
                    geom.deleteOffMeshConnection(geom.offMeshCount() - 1);
            },
            .delete_offmesh => |d| {
                geom.insertOffMeshConnection(d.index, d.data.verts, d.data.rad, d.data.dir, d.data.area, d.data.flags, d.data.id) catch {};
            },
        }
    }

    /// Free any heap-owned data. Currently a no-op (all variants are POD value
    /// copies), kept so the UndoStack frees evicted ops uniformly.
    pub fn deinit(self: *EditOp) void {
        _ = self;
    }

    /// Short human label for the panel tooltip ("Undo: Add Volume").
    pub fn name(self: EditOp) []const u8 {
        return switch (self) {
            .add_volume => "Add Volume",
            .delete_volume => "Delete Volume",
            .add_offmesh => "Add Off-Mesh Link",
            .delete_offmesh => "Delete Off-Mesh Link",
        };
    }
};
