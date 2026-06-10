# Creating NavMesh Guide

[Русская версия](../../ru/04-guides/creating-navmesh.md) | **English**

Practical guide to creating a Navigation Mesh.

---

## Overview

This guide walks you through the complete process of creating a NavMesh from a triangle mesh to a ready-to-use NavMesh for pathfinding.

**What you'll learn:**
- ✅ Prepare input mesh
- ✅ Configure settings
- ✅ Execute Recast pipeline
- ✅ Create Detour NavMesh
- ✅ Optimize parameters
- ✅ Debug issues

**Time:** 30-60 minutes

---

## Steps

1. **Prepare Input Mesh** - Load and validate triangle mesh
2. **Configure Parameters** - Set up Recast configuration
3. **Build Heightfield** - Voxelize input geometry
4. **Filter Heightfield** - Remove unwalkable areas
5. **Build Compact Heightfield** - Compress data
6. **Build Regions** - Partition into walkable regions
7. **Build Contours** - Extract region boundaries
8. **Build Polygon Mesh** - Create simplified mesh
9. **Build Detail Mesh** - Add height detail
10. **Create NavMesh** - Finalize runtime NavMesh

---

## See Also

- [Quick Start](../01-getting-started/quick-start.md) - Simple example
- [Pathfinding Guide](pathfinding.md) - Using the NavMesh
- [Architecture](../02-architecture/overview.md) - Understanding the pipeline

---

**Note:** For a detailed step-by-step guide with code examples, see the Russian version or refer to the Quick Start guide.
