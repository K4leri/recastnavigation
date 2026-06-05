//! UndoStack — fixed-depth undo/redo for scene edits (cluster F, feature F1 core).
//!
//! Two fixed-depth ring buffers hold `EditOp` copies:
//!   - the UNDO ring grows as edits are recorded; `undo()` pops the newest, reverts
//!     it against the geom, and pushes it onto the REDO ring.
//!   - `redo()` pops the newest redo entry, re-applies it, and pushes it back onto
//!     the undo ring.
//!   - `record()` (a fresh user edit) pushes onto undo and CLEARS the redo ring —
//!     the classic "new edit invalidates the redo branch" rule.
//!
//! When the undo ring overflows (more than `DEPTH` un-undone edits) the OLDEST
//! entry is evicted and its owned data freed (EditOp.deinit) — depth-bounded RAM.
//!
//! The stack owns the EditOp copies; `deinit` frees every live entry. EditOp is
//! currently POD (value copies, no heap), but deinit is called on every evicted /
//! cleared / dropped op so a future heap-owning variant stays leak-free.

const std = @import("std");
const ig = @import("../input_geom.zig");
const InputGeom = ig.InputGeom;
const EditOp = @import("edit_op.zig").EditOp;

pub const DEPTH = 128;

/// Fixed-capacity ring buffer of EditOp. Push appends to the tail; on overflow the
/// head (oldest) is evicted (caller frees it). Pop removes from the tail (newest).
const Ring = struct {
    buf: [DEPTH]EditOp = undefined,
    head: usize = 0, // index of oldest element
    len: usize = 0,

    fn isEmpty(self: *const Ring) bool {
        return self.len == 0;
    }

    fn idx(self: *const Ring, n: usize) usize {
        return (self.head + n) % DEPTH;
    }

    /// Push `op` onto the tail. Returns the evicted oldest op (already removed
    /// from the ring) if the ring was full, else null. Caller must deinit it.
    fn push(self: *Ring, op: EditOp) ?EditOp {
        if (self.len == DEPTH) {
            const evicted = self.buf[self.head];
            self.buf[self.head] = op;
            self.head = (self.head + 1) % DEPTH;
            return evicted;
        }
        self.buf[self.idx(self.len)] = op;
        self.len += 1;
        return null;
    }

    /// Remove and return the newest (tail) op, or null if empty.
    fn pop(self: *Ring) ?EditOp {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.buf[self.idx(self.len)];
    }

    /// Peek the newest (tail) op without removing it.
    fn peek(self: *const Ring) ?EditOp {
        if (self.len == 0) return null;
        return self.buf[self.idx(self.len - 1)];
    }
};

pub const UndoStack = struct {
    alloc: std.mem.Allocator,
    undo_ring: Ring = .{},
    redo_ring: Ring = .{},

    pub fn init(alloc: std.mem.Allocator) UndoStack {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *UndoStack) void {
        self.freeRing(&self.undo_ring);
        self.freeRing(&self.redo_ring);
    }

    fn freeRing(self: *UndoStack, ring: *Ring) void {
        _ = self;
        var i: usize = 0;
        while (i < ring.len) : (i += 1) {
            ring.buf[ring.idx(i)].deinit();
        }
        ring.len = 0;
        ring.head = 0;
    }

    /// Record a freshly-performed user edit. Pushes it onto the undo ring and
    /// clears the redo ring (a new edit invalidates the redo branch). The caller
    /// has ALREADY mutated the geom; this only captures the reversible record.
    pub fn record(self: *UndoStack, op: EditOp) void {
        self.freeRing(&self.redo_ring);
        if (self.undo_ring.push(op)) |evicted| {
            var e = evicted;
            e.deinit();
        }
    }

    /// Undo the newest edit: revert it against `geom`, move it to the redo ring.
    /// Returns true if something was undone (geom changed).
    pub fn undo(self: *UndoStack, geom: *InputGeom) bool {
        const op = self.undo_ring.pop() orelse return false;
        op.revert(geom);
        // Moving across rings; redo can't overflow past DEPTH here (it mirrors the
        // undo ring), but free any evicted entry defensively.
        if (self.redo_ring.push(op)) |evicted| {
            var e = evicted;
            e.deinit();
        }
        return true;
    }

    /// Redo the newest undone edit: re-apply it against `geom`, move it back to
    /// the undo ring. Returns true if something was redone (geom changed).
    pub fn redo(self: *UndoStack, geom: *InputGeom) bool {
        const op = self.redo_ring.pop() orelse return false;
        op.apply(geom);
        if (self.undo_ring.push(op)) |evicted| {
            var e = evicted;
            e.deinit();
        }
        return true;
    }

    pub fn canUndo(self: *const UndoStack) bool {
        return !self.undo_ring.isEmpty();
    }
    pub fn canRedo(self: *const UndoStack) bool {
        return !self.redo_ring.isEmpty();
    }

    /// Name of the op the next undo would revert (for tooltips), or null.
    pub fn nextUndoName(self: *const UndoStack) ?[]const u8 {
        return if (self.undo_ring.peek()) |op| op.name() else null;
    }
    /// Name of the op the next redo would re-apply (for tooltips), or null.
    pub fn nextRedoName(self: *const UndoStack) ?[]const u8 {
        return if (self.redo_ring.peek()) |op| op.name() else null;
    }
};

test "record/undo/redo round-trips a volume add" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    st.record(.{ .add_volume = geom.volumes.items[geom.volumes.items.len - 1] });

    try std.testing.expect(st.canUndo());
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 0), geom.volumes.items.len);

    try std.testing.expect(st.canRedo());
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    try std.testing.expectEqual(@as(u32, 1), geom.volumes.items[0].id);
}

test "delete-volume undo restores id/mode/band/verts" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const tri = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 3 };
    try geom.addConvexVolume(&tri, 3, -1.0, 5.0, 7);
    geom.volumes.items[0].mode = .prism;
    geom.volumes.items[0].band_below = 2.5;
    geom.volumes.items[0].band_above = 3.5;
    const captured = geom.volumes.items[0];

    st.record(.{ .delete_volume = .{ .index = 0, .vol = captured } });
    geom.deleteConvexVolume(0);
    try std.testing.expectEqual(@as(usize, 0), geom.volumes.items.len);

    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    const v = geom.volumes.items[0];
    try std.testing.expectEqual(captured.id, v.id);
    try std.testing.expectEqual(ig.VolumeMode.prism, v.mode);
    try std.testing.expectEqual(@as(f32, 2.5), v.band_below);
    try std.testing.expectEqual(@as(f32, 3.5), v.band_above);
    try std.testing.expectEqual(@as(u8, 7), v.area);
    try std.testing.expectEqual(@as(f32, 3), v.verts[8]);
}

test "off-mesh delete undo restores all 6 fields at index" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    try geom.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.6, 1, 9, 0x55);
    try geom.addOffMeshConnection(.{ 7, 8, 9 }, .{ 10, 11, 12 }, 0.9, 0, 3, 0x11);
    const cap = @import("edit_op.zig").OffMeshData.capture(&geom, 0);

    st.record(.{ .delete_offmesh = .{ .index = 0, .data = cap } });
    geom.deleteOffMeshConnection(0);
    try std.testing.expectEqual(@as(usize, 1), geom.offMeshCount());
    // remaining connection is the second one
    try std.testing.expectEqual(@as(f32, 0.9), geom.off_rad.items[0]);

    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 2), geom.offMeshCount());
    try std.testing.expectEqual(@as(f32, 1), geom.off_verts.items[0]);
    try std.testing.expectEqual(@as(f32, 6), geom.off_verts.items[5]);
    try std.testing.expectEqual(@as(f32, 0.6), geom.off_rad.items[0]);
    try std.testing.expectEqual(@as(u8, 1), geom.off_dir.items[0]);
    try std.testing.expectEqual(@as(u8, 9), geom.off_area.items[0]);
    try std.testing.expectEqual(@as(u16, 0x55), geom.off_flags.items[0]);
    try std.testing.expectEqual(@as(u32, 1000), geom.off_id.items[0]);
}

test "edit_volume is id-keyed: undo/redo hit the right volume after an index shift" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    // Add the volume we will edit (id 1), give it a distinctive mode/band.
    const tri = [_]f32{ 0, 0, 0, 2, 0, 0, 0, 0, 2 };
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 5); // id 1
    geom.volumes.items[0].mode = .prism;
    geom.volumes.items[0].band_below = 2.0;
    geom.volumes.items[0].band_above = 3.0;
    const target_id = geom.volumes.items[0].id;
    const before = geom.volumes.items[0];

    // Mutate it: translate verts by (+10,_,+20) and bump the band.
    var after = before;
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        after.verts[k * 3 + 0] += 10;
        after.verts[k * 3 + 2] += 20;
    }
    after.band_above = 9.0;
    geom.volumes.items[0] = after;
    st.record(.{ .edit_volume = .{ .id = target_id, .before = before, .after = after } });

    // SHIFT INDICES: insert a fresh volume at index 0 AFTER recording, BEFORE undo.
    // The edited volume is now at index 1 — index-keying would corrupt the wrong one.
    const tri2 = [_]f32{ 100, 0, 0, 101, 0, 0, 100, 0, 1 };
    try geom.addConvexVolume(&tri2, 3, 0.0, 1.0, 0); // id 2, appended at end...
    // ...move it to the front so the edited volume's INDEX changes.
    const shifter = geom.volumes.pop().?;
    try geom.volumes.insert(0, shifter);
    try std.testing.expectEqual(target_id, geom.volumes.items[1].id); // edited one moved to idx 1

    // Undo -> restores `before` EXACTLY on the id-keyed volume (now at idx 1).
    try std.testing.expect(st.undo(&geom));
    const u = geom.volumes.items[1];
    try std.testing.expectEqual(target_id, u.id);
    try std.testing.expectEqual(ig.VolumeMode.prism, u.mode);
    try std.testing.expectEqual(@as(f32, 2.0), u.band_below);
    try std.testing.expectEqual(@as(f32, 3.0), u.band_above);
    try std.testing.expectEqual(@as(f32, 0.0), u.verts[0]); // un-translated
    try std.testing.expectEqual(@as(f32, 2.0), u.verts[8]); // vert2.z == 2

    // Redo -> re-applies `after`.
    try std.testing.expect(st.redo(&geom));
    const r = geom.volumes.items[1];
    try std.testing.expectEqual(@as(f32, 10.0), r.verts[0]); // translated
    try std.testing.expectEqual(@as(f32, 22.0), r.verts[8]);
    try std.testing.expectEqual(@as(f32, 9.0), r.band_above);
}

test "edit_volume missing id is a no-op (no crash)" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0); // id 1
    var before = geom.volumes.items[0];
    before.id = 999; // an id that does NOT exist in geom
    const after = before;
    st.record(.{ .edit_volume = .{ .id = 999, .before = before, .after = after } });

    // Both undo and redo must be silent no-ops on the missing id.
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
}

test "edit_offmesh is id-keyed: undo/redo survive an index shift" {
    const OffMeshData = @import("edit_op.zig").OffMeshData;
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    // Add the connection we will edit (off_id 1000) at index 0.
    try geom.addOffMeshConnection(.{ 1, 2, 3 }, .{ 4, 5, 6 }, 0.5, 1, 7, 0x33); // off_id 1000
    const target_id = geom.off_id.items[0];
    const before = OffMeshData.capture(&geom, 0);

    // Mutate: translate both endpoints by (+10,_,+20), write it back in place.
    var after = before;
    after.verts[0] += 10;
    after.verts[2] += 20;
    after.verts[3] += 10;
    after.verts[5] += 20;
    writeBack(&geom, 0, after);
    st.record(.{ .edit_offmesh = .{ .id = target_id, .before = before, .after = after } });

    // SHIFT INDICES: insert a DIFFERENT connection at index 0 AFTER recording but
    // BEFORE undo. The edited connection (off_id 1000) is now at index 1 — an
    // index-keyed op would corrupt the wrong connection.
    try geom.insertOffMeshConnection(0, .{ 0, 0, 0, 1, 0, 1 }, 0.5, 1, 0, 0, 1001);
    try std.testing.expectEqual(target_id, geom.off_id.items[1]); // edited one moved to idx 1

    // Undo -> restores `before` on the id-keyed connection (wherever it now is).
    try std.testing.expect(st.undo(&geom));
    const i = offmeshIdx(&geom, target_id).?;
    try std.testing.expectEqual(@as(f32, 1.0), geom.off_verts.items[i * 6 + 0]);
    try std.testing.expectEqual(@as(f32, 6.0), geom.off_verts.items[i * 6 + 5]);

    // Redo -> re-applies `after`.
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(f32, 11.0), geom.off_verts.items[i * 6 + 0]);
    try std.testing.expectEqual(@as(f32, 26.0), geom.off_verts.items[i * 6 + 5]);
}

/// Test helper: overwrite the 6 mutable fields of off-mesh idx from an OffMeshData.
fn writeBack(geom: *InputGeom, idx: usize, d: @import("edit_op.zig").OffMeshData) void {
    @memcpy(geom.off_verts.items[idx * 6 ..][0..6], &d.verts);
    geom.off_rad.items[idx] = d.rad;
    geom.off_dir.items[idx] = d.dir;
    geom.off_area.items[idx] = d.area;
    geom.off_flags.items[idx] = d.flags;
}

/// Test helper: find off-mesh array index by off_id.
fn offmeshIdx(geom: *const InputGeom, id: u32) ?usize {
    for (geom.off_id.items, 0..) |oid, i| if (oid == id) return i;
    return null;
}

const area_types = @import("../area_types.zig");
const poly_flags = @import("../poly_flags.zig");

test "area_add undo removes the new type, redo re-creates it" {
    area_types.resetToBuiltins();
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const id = area_types.addType().?; // first free slot after 6 builtins == 6
    var t = area_types.get(id).?;
    t.setName("Lava");
    t.r = 9;
    t.g = 8;
    t.b = 7;
    t.cost = 4.5;
    t.flags = 0x0A;
    st.record(.{ .area_add = .{ .id = id, .type = t.* } });
    try std.testing.expect(area_types.get(id) != null);

    // Undo -> the type is gone.
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(?*area_types.AreaType, null), area_types.get(id));

    // Redo -> restored byte-for-byte.
    try std.testing.expect(st.redo(&geom));
    const r = area_types.get(id).?;
    try std.testing.expectEqualStrings("Lava", r.name());
    try std.testing.expectEqual(@as(u8, 9), r.r);
    try std.testing.expectEqual(@as(u8, 8), r.g);
    try std.testing.expectEqual(@as(u8, 7), r.b);
    try std.testing.expectEqual(@as(f32, 4.5), r.cost);
    try std.testing.expectEqual(@as(u16, 0x0A), r.flags);
    try std.testing.expect(!r.builtin);
    try std.testing.expect(r.used);
    area_types.resetToBuiltins();
}

test "area_edit undo restores before, redo applies after (name/color/cost/flags)" {
    area_types.resetToBuiltins();
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    // Edit the builtin Ground (slot 0): change name/color/cost/flags.
    const before = area_types.get(0).?.*;
    var after = before;
    after.setName("Stone");
    after.r = 1;
    after.g = 2;
    after.b = 3;
    after.cost = 9.0;
    after.flags = 0x0C;
    area_types.restoreType(0, after);
    st.record(.{ .area_edit = .{ .id = 0, .before = before, .after = after } });

    // Undo -> exactly the old Ground.
    try std.testing.expect(st.undo(&geom));
    const u = area_types.get(0).?;
    try std.testing.expectEqualStrings("Ground", u.name());
    try std.testing.expectEqual(before.cost, u.cost);
    try std.testing.expectEqual(before.flags, u.flags);
    try std.testing.expectEqual(before.r, u.r);
    try std.testing.expect(u.builtin);

    // Redo -> the edited values.
    try std.testing.expect(st.redo(&geom));
    const r = area_types.get(0).?;
    try std.testing.expectEqualStrings("Stone", r.name());
    try std.testing.expectEqual(@as(u8, 1), r.r);
    try std.testing.expectEqual(@as(u8, 2), r.g);
    try std.testing.expectEqual(@as(u8, 3), r.b);
    try std.testing.expectEqual(@as(f32, 9.0), r.cost);
    try std.testing.expectEqual(@as(u16, 0x0C), r.flags);
    area_types.resetToBuiltins();
}

test "area_remove undo restores the type, redo removes it again" {
    area_types.resetToBuiltins();
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const id = area_types.addType().?;
    var t = area_types.get(id).?;
    t.setName("Mud");
    t.r = 50;
    t.g = 100;
    t.b = 150;
    t.cost = 6.0;
    t.flags = 0x07;
    const captured = t.*;
    area_types.removeType(id);
    st.record(.{ .area_remove = .{ .id = id, .type = captured } });
    try std.testing.expectEqual(@as(?*area_types.AreaType, null), area_types.get(id));

    // Undo -> restored.
    try std.testing.expect(st.undo(&geom));
    const r = area_types.get(id).?;
    try std.testing.expectEqualStrings("Mud", r.name());
    try std.testing.expectEqual(@as(u8, 50), r.r);
    try std.testing.expectEqual(@as(u8, 100), r.g);
    try std.testing.expectEqual(@as(u8, 150), r.b);
    try std.testing.expectEqual(@as(f32, 6.0), r.cost);
    try std.testing.expectEqual(@as(u16, 0x07), r.flags);
    try std.testing.expect(!r.builtin);

    // Redo -> gone again.
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(?*area_types.AreaType, null), area_types.get(id));
    area_types.resetToBuiltins();
}

test "flag_add undo removes flag, redo re-creates it (name/builtin)" {
    poly_flags.resetToBuiltins();
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const bit = poly_flags.addFlag("ladder").?;
    const bit_index: usize = @ctz(bit);
    const captured = poly_flags.get(bit_index).?.*;
    st.record(.{ .flag_add = .{ .bit_index = bit_index, .flag = captured } });
    try std.testing.expect(poly_flags.get(bit_index) != null);

    // Undo -> flag gone.
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(?*poly_flags.Flag, null), poly_flags.get(bit_index));

    // Redo -> restored.
    try std.testing.expect(st.redo(&geom));
    const r = poly_flags.get(bit_index).?;
    try std.testing.expectEqualStrings("ladder", r.name());
    try std.testing.expect(!r.builtin);
    poly_flags.resetToBuiltins();
}

test "flag_remove undo restores flag, redo removes it again" {
    poly_flags.resetToBuiltins();
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const bit = poly_flags.addFlag("crouch").?;
    const bit_index: usize = @ctz(bit);
    const captured = poly_flags.get(bit_index).?.*;
    poly_flags.removeFlag(bit_index);
    st.record(.{ .flag_remove = .{ .bit_index = bit_index, .flag = captured } });
    try std.testing.expectEqual(@as(?*poly_flags.Flag, null), poly_flags.get(bit_index));

    // Undo -> restored.
    try std.testing.expect(st.undo(&geom));
    const r = poly_flags.get(bit_index).?;
    try std.testing.expectEqualStrings("crouch", r.name());
    try std.testing.expect(!r.builtin);

    // Redo -> gone again.
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(?*poly_flags.Flag, null), poly_flags.get(bit_index));
    poly_flags.resetToBuiltins();
}

test "composite group: undo reverts BOTH, redo re-adds BOTH, slice freed once" {
    const edit_op = @import("edit_op.zig");
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    // Perform two volume adds, then record them as ONE composite group.
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    const op0 = EditOp{ .add_volume = geom.volumes.items[geom.volumes.items.len - 1] };
    try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
    const op1 = EditOp{ .add_volume = geom.volumes.items[geom.volumes.items.len - 1] };
    try std.testing.expectEqual(@as(usize, 2), geom.volumes.items.len);

    // Caller owns the heap slice; record() transfers ownership to the stack,
    // which frees it exactly once (via deinit) on eviction / clear / st.deinit.
    const ops = try std.testing.allocator.alloc(EditOp, 2);
    ops[0] = op0;
    ops[1] = op1;
    st.record(edit_op.makeComposite(std.testing.allocator, ops));

    try std.testing.expect(st.canUndo());
    try std.testing.expectEqualStrings("Group Edit", st.nextUndoName().?);

    // Undo -> BOTH volumes removed (reverse-order revert).
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 0), geom.volumes.items.len);

    // Redo -> BOTH re-added (forward-order apply).
    try std.testing.expect(st.canRedo());
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(usize, 2), geom.volumes.items.len);
    // testing.allocator asserts no leak / no double-free on st.deinit() above.
}

test "composite revert is reverse-order: two index-deletes re-insert in order" {
    const edit_op = @import("edit_op.zig");
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const triA = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 }; // id 1
    const triB = [_]f32{ 5, 0, 0, 6, 0, 0, 5, 0, 1 }; // id 2
    const triC = [_]f32{ 9, 0, 0, 9, 0, 1, 8, 0, 0 }; // id 3
    try geom.addConvexVolume(&triA, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&triB, 3, 0.0, 1.0, 0);
    try geom.addConvexVolume(&triC, 3, 0.0, 1.0, 0);
    const id_a = geom.volumes.items[0].id;
    const id_b = geom.volumes.items[1].id;
    const id_c = geom.volumes.items[2].id;

    // Group deletes index 0 twice: removes A (list [B,C]), then removes B (list [C]).
    const op0 = EditOp{ .delete_volume = .{ .index = 0, .vol = geom.volumes.items[0] } };
    geom.deleteConvexVolume(0);
    const op1 = EditOp{ .delete_volume = .{ .index = 0, .vol = geom.volumes.items[0] } };
    geom.deleteConvexVolume(0);
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    try std.testing.expectEqual(id_c, geom.volumes.items[0].id);

    const ops = try std.testing.allocator.alloc(EditOp, 2);
    ops[0] = op0; // delete A
    ops[1] = op1; // delete B
    st.record(edit_op.makeComposite(std.testing.allocator, ops));

    // Reverse revert: ops[1] re-inserts B at 0 -> [B,C]; ops[0] re-inserts A at 0
    // -> [A,B,C]. FORWARD order would yield [B,A,C] (A inserted first, then B at 0
    // pushes A down) — so the id ordering below proves reverse iteration.
    try std.testing.expect(st.undo(&geom));
    try std.testing.expectEqual(@as(usize, 3), geom.volumes.items.len);
    try std.testing.expectEqual(id_a, geom.volumes.items[0].id);
    try std.testing.expectEqual(id_b, geom.volumes.items[1].id);
    try std.testing.expectEqual(id_c, geom.volumes.items[2].id);

    // Redo replays forward: both deletes again -> only C remains.
    try std.testing.expect(st.redo(&geom));
    try std.testing.expectEqual(@as(usize, 1), geom.volumes.items.len);
    try std.testing.expectEqual(id_c, geom.volumes.items[0].id);
}

test "ring eviction frees oldest, no leak" {
    var geom = InputGeom.init(std.testing.allocator);
    defer geom.deinit();
    var st = UndoStack.init(std.testing.allocator);
    defer st.deinit();

    const tri = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    // Record DEPTH+10 add ops; the ring must stay bounded at DEPTH.
    var i: usize = 0;
    while (i < DEPTH + 10) : (i += 1) {
        try geom.addConvexVolume(&tri, 3, 0.0, 1.0, 0);
        st.record(.{ .add_volume = geom.volumes.items[geom.volumes.items.len - 1] });
    }
    try std.testing.expectEqual(@as(usize, DEPTH), st.undo_ring.len);
    try std.testing.expect(st.canUndo());
}
