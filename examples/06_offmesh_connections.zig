const std = @import("std");
const recast = @import("recast-nav");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🌉 Off-Mesh Connections Example\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    // Create a build context
    var ctx = recast.Context.init(allocator);

    std.debug.print("📖 What are Off-Mesh Connections?\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("Off-mesh connections are special navigation links that connect\n", .{});
    std.debug.print("disconnected parts of the navmesh. They represent:\n", .{});
    std.debug.print("  • Jumps between platforms\n", .{});
    std.debug.print("  • Ladders\n", .{});
    std.debug.print("  • Teleports\n", .{});
    std.debug.print("  • Ziplines\n", .{});
    std.debug.print("  • Doors or gates\n", .{});
    std.debug.print("  • Any custom traversal mechanism\n\n", .{});

    // ========================================================================
    // Example 1: Two platforms with a jump connection
    // ========================================================================
    std.debug.print("🎯 Example 1: Jump Between Platforms\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    // Define two platforms
    const platform1_verts = [_]f32{
        // Platform 1: Ground level (0-10 on X, 0-10 on Z)
        0.0, 0.0, 0.0,
        10.0, 0.0, 0.0,
        10.0, 0.0, 10.0,
        0.0, 0.0, 10.0,
    };

    const platform2_verts = [_]f32{
        // Platform 2: Higher level (15-25 on X, 0-10 on Z, Y=3)
        15.0, 3.0, 0.0,
        25.0, 3.0, 0.0,
        25.0, 3.0, 10.0,
        15.0, 3.0, 10.0,
    };

    std.debug.print("Platform 1: Ground level (Y = 0.0)\n", .{});
    std.debug.print("Platform 2: Elevated (Y = 3.0)\n", .{});
    std.debug.print("Gap: ~5 units horizontally, 3 units vertically\n\n", .{});

    // Define off-mesh connection (jump from platform 1 to platform 2)
    const offmesh_con_verts = [_]f32{
        9.0,  0.0, 5.0, // Start: edge of platform 1
        16.0, 3.0, 5.0, // End: edge of platform 2
    };

    const offmesh_con_rad = [_]f32{0.6}; // Connection radius
    const offmesh_con_dir = [_]u8{1}; // 1 = bidirectional, 0 = one-way
    const offmesh_con_areas = [_]u8{recast.POLYAREA_JUMP}; // Mark as jump area
    const offmesh_con_flags = [_]u16{recast.POLYFLAGS_JUMP}; // Jump flag
    const offmesh_con_count: i32 = 1;

    std.debug.print("Off-Mesh Connection:\n", .{});
    std.debug.print("  Start: ({d:.1}, {d:.1}, {d:.1})\n", .{
        offmesh_con_verts[0],
        offmesh_con_verts[1],
        offmesh_con_verts[2],
    });
    std.debug.print("  End:   ({d:.1}, {d:.1}, {d:.1})\n", .{
        offmesh_con_verts[3],
        offmesh_con_verts[4],
        offmesh_con_verts[5],
    });
    std.debug.print("  Radius: {d:.2}\n", .{offmesh_con_rad[0]});
    std.debug.print("  Bidirectional: {s}\n", .{if (offmesh_con_dir[0] == 1) "Yes" else "No"});
    std.debug.print("  Area Type: JUMP\n\n", .{});

    // ========================================================================
    // Creating NavMesh with off-mesh connections
    // ========================================================================
    std.debug.print("⚙️  Creating NavMesh Data with Off-Mesh Connections\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    // Note: In a real scenario, you would:
    // 1. Build polygon mesh from both platforms
    // 2. Create NavMeshCreateParams
    // 3. Set offmesh connection data:

    std.debug.print("NavMeshCreateParams setup:\n", .{});
    std.debug.print("  create_params.offmesh_con_verts = &offmesh_con_verts\n", .{});
    std.debug.print("  create_params.offmesh_con_rad = &offmesh_con_rad\n", .{});
    std.debug.print("  create_params.offmesh_con_dir = &offmesh_con_dir\n", .{});
    std.debug.print("  create_params.offmesh_con_areas = &offmesh_con_areas\n", .{});
    std.debug.print("  create_params.offmesh_con_flags = &offmesh_con_flags\n", .{});
    std.debug.print("  create_params.offmesh_con_count = {d}\n\n", .{offmesh_con_count});

    // ========================================================================
    // Example 2: Ladder connection (bidirectional vertical link)
    // ========================================================================
    std.debug.print("🎯 Example 2: Ladder Connection\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    const ladder_start = [3]f32{ 5.0, 0.0, 5.0 }; // Bottom of ladder
    const ladder_end = [3]f32{ 5.0, 5.0, 5.0 }; // Top of ladder

    std.debug.print("Ladder connection (bidirectional vertical link):\n", .{});
    std.debug.print("  Bottom: ({d:.1}, {d:.1}, {d:.1})\n", .{ ladder_start[0], ladder_start[1], ladder_start[2] });
    std.debug.print("  Top:    ({d:.1}, {d:.1}, {d:.1})\n", .{ ladder_end[0], ladder_end[1], ladder_end[2] });
    std.debug.print("  Height: {d:.1} units\n", .{ladder_end[1] - ladder_start[1]});
    std.debug.print("  Type: Bidirectional (climb up/down)\n\n", .{});

    // ========================================================================
    // Example 3: One-way jump (drop down)
    // ========================================================================
    std.debug.print("🎯 Example 3: One-Way Drop\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});

    const drop_start = [3]f32{ 10.0, 5.0, 10.0 }; // High platform
    const drop_end = [3]f32{ 10.0, 0.0, 15.0 }; // Low platform

    std.debug.print("One-way drop connection:\n", .{});
    std.debug.print("  Start: ({d:.1}, {d:.1}, {d:.1}) [High]\n", .{ drop_start[0], drop_start[1], drop_start[2] });
    std.debug.print("  End:   ({d:.1}, {d:.1}, {d:.1}) [Low]\n", .{ drop_end[0], drop_end[1], drop_end[2] });
    std.debug.print("  Direction: One-way only (can drop, can't climb)\n\n", .{});

    // ========================================================================
    // Off-mesh connection parameters
    // ========================================================================
    std.debug.print("📋 Off-Mesh Connection Parameters\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("1. Vertices (start/end positions):\n", .{});
    std.debug.print("   • Array of f32 pairs: [start_x, start_y, start_z, end_x, end_y, end_z]\n", .{});
    std.debug.print("   • Each connection uses 6 floats (2 positions)\n\n", .{});

    std.debug.print("2. Radius:\n", .{});
    std.debug.print("   • Agent must be within radius to use connection\n", .{});
    std.debug.print("   • Typically matches walkable_radius (0.6 units)\n\n", .{});

    std.debug.print("3. Direction:\n", .{});
    std.debug.print("   • 0 = One-way (start -> end only)\n", .{});
    std.debug.print("   • 1 = Bidirectional (start <-> end)\n\n", .{});

    std.debug.print("4. Area Type:\n", .{});
    std.debug.print("   • POLYAREA_GROUND (0) = Normal walkable\n", .{});
    std.debug.print("   • POLYAREA_JUMP (custom) = Jump connection\n", .{});
    std.debug.print("   • POLYAREA_DOOR (custom) = Door/gate\n", .{});
    std.debug.print("   • Custom areas for cost adjustment\n\n", .{});

    std.debug.print("5. Flags:\n", .{});
    std.debug.print("   • POLYFLAGS_WALK = Normal walking\n", .{});
    std.debug.print("   • POLYFLAGS_JUMP = Jumping required\n", .{});
    std.debug.print("   • POLYFLAGS_DOOR = Door interaction\n", .{});
    std.debug.print("   • Custom flags for filtering\n\n", .{});

    // ========================================================================
    // Usage in pathfinding
    // ========================================================================
    std.debug.print("🔍 Off-Mesh Connections in Pathfinding\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("When findPath() encounters an off-mesh connection:\n\n", .{});

    std.debug.print("1. Filter Check:\n", .{});
    std.debug.print("   • QueryFilter checks if polygon flags are allowed\n", .{});
    std.debug.print("   • Can exclude JUMP connections if agent can't jump\n\n", .{});

    std.debug.print("2. Cost Calculation:\n", .{});
    std.debug.print("   • QueryFilter.getCost() adjusts traversal cost\n", .{});
    std.debug.print("   • Example: jump costs more than walking\n\n", .{});

    std.debug.print("3. Path Output:\n", .{});
    std.debug.print("   • Off-mesh polygons appear in path\n", .{});
    std.debug.print("   • Application detects off-mesh polygon\n", .{});
    std.debug.print("   • Triggers special animation (jump, climb, etc.)\n\n", .{});

    // ========================================================================
    // Best practices
    // ========================================================================
    std.debug.print("💡 Best Practices\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("✅ DO:\n", .{});
    std.debug.print("  • Use bidirectional for ladders and symmetric connections\n", .{});
    std.debug.print("  • Use one-way for drops and asymmetric traversal\n", .{});
    std.debug.print("  • Set appropriate radius (match agent radius)\n", .{});
    std.debug.print("  • Use custom area types for cost adjustment\n", .{});
    std.debug.print("  • Place endpoints slightly inside walkable areas\n", .{});
    std.debug.print("  • Test connections with actual pathfinding\n\n", .{});

    std.debug.print("❌ DON'T:\n", .{});
    std.debug.print("  • Make connections too long (max ~10 units recommended)\n", .{});
    std.debug.print("  • Overlap multiple connections at same location\n", .{});
    std.debug.print("  • Place endpoints outside navmesh polygons\n", .{});
    std.debug.print("  • Use for normal walkable connections (use mesh instead)\n", .{});
    std.debug.print("  • Forget to set appropriate flags for filtering\n\n", .{});

    // ========================================================================
    // Example filter for off-mesh connections
    // ========================================================================
    std.debug.print("🎮 Example: Filter Configuration\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("// Allow agent that can jump and open doors:\n", .{});
    std.debug.print("var filter = QueryFilter.init();\n", .{});
    std.debug.print("filter.setIncludeFlags(POLYFLAGS_WALK | POLYFLAGS_JUMP | POLYFLAGS_DOOR);\n", .{});
    std.debug.print("filter.setExcludeFlags(0);\n\n", .{});

    std.debug.print("// Adjust costs for different area types:\n", .{});
    std.debug.print("filter.setAreaCost(POLYAREA_GROUND, 1.0);  // Normal cost\n", .{});
    std.debug.print("filter.setAreaCost(POLYAREA_JUMP, 2.5);    // Jumps are expensive\n", .{});
    std.debug.print("filter.setAreaCost(POLYAREA_DOOR, 1.5);    // Doors slightly costly\n\n", .{});

    std.debug.print("// Agent without jump ability:\n", .{});
    std.debug.print("var no_jump_filter = QueryFilter.init();\n", .{});
    std.debug.print("no_jump_filter.setIncludeFlags(POLYFLAGS_WALK);  // Walk only\n", .{});
    std.debug.print("no_jump_filter.setExcludeFlags(POLYFLAGS_JUMP);  // No jumps!\n\n", .{});

    // ========================================================================
    // Common use cases
    // ========================================================================
    std.debug.print("📚 Common Use Cases\n", .{});
    std.debug.print("-" ** 70 ++ "\n\n", .{});

    std.debug.print("1. 🪜 Ladders:\n", .{});
    std.debug.print("   • Bidirectional vertical connections\n", .{});
    std.debug.print("   • Area: POLYAREA_LADDER\n", .{});
    std.debug.print("   • Slower movement speed\n\n", .{});

    std.debug.print("2. 🎯 Jumps:\n", .{});
    std.debug.print("   • One-way or bidirectional\n", .{});
    std.debug.print("   • Area: POLYAREA_JUMP\n", .{});
    std.debug.print("   • Higher cost (avoid if possible)\n\n", .{});

    std.debug.print("3. 🚪 Doors:\n", .{});
    std.debug.print("   • Bidirectional\n", .{});
    std.debug.print("   • Can enable/disable at runtime\n", .{});
    std.debug.print("   • Area: POLYAREA_DOOR\n\n", .{});

    std.debug.print("4. ✈️  Teleports:\n", .{});
    std.debug.print("   • Typically one-way\n", .{});
    std.debug.print("   • Can be very long distance\n", .{});
    std.debug.print("   • Area: POLYAREA_TELEPORT\n\n", .{});

    std.debug.print("5. 📦 Moving Platforms:\n", .{});
    std.debug.print("   • Dynamic connections\n", .{});
    std.debug.print("   • Enable/disable based on platform position\n", .{});
    std.debug.print("   • Requires runtime updates\n\n", .{});

    // ========================================================================
    // Dynamic connections (runtime)
    // ========================================================================
    std.debug.print("⚡ Dynamic Off-Mesh Connections\n", .{});
    std.debug.print("-" ** 70 ++ "\n", .{});
    std.debug.print("Off-mesh connections can be enabled/disabled at runtime:\n\n", .{});

    std.debug.print("// During NavMesh creation:\n", .{});
    std.debug.print("create_params.offmesh_con_user_id = &user_ids; // Assign IDs\n\n", .{});

    std.debug.print("// At runtime (modify polygon flags):\n", .{});
    std.debug.print("const door_poly_ref = ...;  // Get door polygon reference\n", .{});
    std.debug.print("navmesh.setPolyFlags(door_poly_ref, 0);  // Disable (closed door)\n", .{});
    std.debug.print("navmesh.setPolyFlags(door_poly_ref, POLYFLAGS_DOOR);  // Enable (open)\n\n", .{});

    std.debug.print("This allows:\n", .{});
    std.debug.print("  • Opening/closing doors\n", .{});
    std.debug.print("  • Activating/deactivating teleports\n", .{});
    std.debug.print("  • Dynamic obstacle avoidance\n", .{});
    std.debug.print("  • State-dependent navigation\n\n", .{});

    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("✨ Off-Mesh Connections example completed!\n", .{});
    std.debug.print("\n📖 Key Takeaways:\n", .{});
    std.debug.print("   ✅ Off-mesh connections link disconnected navmesh areas\n", .{});
    std.debug.print("   ✅ Support bidirectional and one-way traversal\n", .{});
    std.debug.print("   ✅ Can be filtered and cost-adjusted\n", .{});
    std.debug.print("   ✅ Enable special gameplay mechanics (jumps, ladders, etc.)\n", .{});
    std.debug.print("   ✅ Can be enabled/disabled at runtime\n", .{});
    std.debug.print("\n🔗 See also:\n", .{});
    std.debug.print("   • 03_full_pathfinding.zig for complete NavMesh building\n", .{});
    std.debug.print("   • dynamic_obstacles.zig for runtime NavMesh updates\n", .{});
}
