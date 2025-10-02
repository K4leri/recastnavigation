# Comprehensive Testing Plan: Full API Coverage

## Goal
Test **EVERY PUBLIC METHOD** in Recast/Detour/DetourCrowd/DetourTileCache with real data (nav_test.obj) and compare C++ vs Zig results.

## Phase 1: Recast Full Pipeline Test

### Core Pipeline (Already Tested ✅)
- [x] rcCalcBounds
- [x] rcCalcGridSize
- [x] rcCreateHeightfield
- [x] rcMarkWalkableTriangles
- [x] rcRasterizeTriangles
- [x] rcFilterLowHangingWalkableObstacles
- [x] rcFilterLedgeSpans
- [x] rcFilterWalkableLowHeightSpans
- [x] rcBuildCompactHeightfield
- [x] rcErodeWalkableArea
- [x] rcBuildDistanceField
- [x] rcBuildRegions
- [x] rcBuildContours
- [x] rcBuildPolyMesh
- [x] rcBuildPolyMeshDetail

### Additional Recast Methods (NOT TESTED)
- [ ] rcMedianFilterWalkableArea
- [ ] rcMarkBoxArea
- [ ] rcMarkConvexPolyArea
- [ ] rcOffsetPoly
- [ ] rcMarkCylinderArea
- [ ] rcBuildLayerRegions
- [ ] rcBuildRegionsMonotone
- [ ] rcBuildHeightfieldLayers
- [ ] rcMergePolyMeshes
- [ ] rcCopyPolyMesh
- [ ] rcMergePolyMeshDetails

## Phase 2: Detour NavMesh Operations

### NavMesh Creation and Query (NEED TESTING)
- [ ] dtAllocNavMesh / dtFreeNavMesh
- [ ] dtNavMesh::init
- [ ] dtNavMesh::addTile
- [ ] dtNavMesh::removeTile
- [ ] dtNavMesh::getTileAt
- [ ] dtNavMesh::getTileRefAt
- [ ] dtNavMesh::getTileByRef
- [ ] dtNavMesh::queryPolygons
- [ ] dtNavMesh::findNearestPoly
- [ ] dtNavMesh::getPolyWallSegments
- [ ] dtNavMesh::getAttachedNavMeshes (off-mesh connections)

### NavMesh Query (NEED TESTING)
- [ ] dtNavMeshQuery::init
- [ ] dtNavMeshQuery::findPath
- [ ] dtNavMeshQuery::findStraightPath
- [ ] dtNavMeshQuery::findPolysAroundCircle
- [ ] dtNavMeshQuery::findPolysAroundShape
- [ ] dtNavMeshQuery::findLocalNeighbourhood
- [ ] dtNavMeshQuery::moveAlongSurface
- [ ] dtNavMeshQuery::raycast
- [ ] dtNavMeshQuery::findDistanceToWall
- [ ] dtNavMeshQuery::getPolyHeight
- [ ] dtNavMeshQuery::isValidPolyRef
- [ ] dtNavMeshQuery::isInClosedList
- [ ] dtNavMeshQuery::getNodePool

## Phase 3: DetourCrowd Operations

### Crowd Management (NEED TESTING)
- [ ] dtCrowd::init
- [ ] dtCrowd::addAgent
- [ ] dtCrowd::removeAgent
- [ ] dtCrowd::update
- [ ] dtCrowd::getAgent
- [ ] dtCrowd::getEditableAgent
- [ ] dtCrowd::getActiveAgents
- [ ] dtCrowd::requestMoveTarget
- [ ] dtCrowd::requestMoveVelocity
- [ ] dtCrowd::resetMoveTarget
- [ ] dtCrowd::getAgentPosition
- [ ] dtCrowd::getQueryExtents
- [ ] dtCrowd::getFilter
- [ ] dtCrowd::getObstacleAvoidanceParams
- [ ] dtCrowd::setObstacleAvoidanceParams

### Path Corridor (Partially Tested)
- [x] dtPathCorridor::mergeCorridorStartMoved (basic tests)
- [ ] dtPathCorridor::init
- [ ] dtPathCorridor::reset
- [ ] dtPathCorridor::findCorners
- [ ] dtPathCorridor::optimizePathVisibility
- [ ] dtPathCorridor::optimizePathTopology
- [ ] dtPathCorridor::moveOverOffmeshConnection
- [ ] dtPathCorridor::fixPathStart
- [ ] dtPathCorridor::trimInvalidPath
- [ ] dtPathCorridor::isValid

### Local Boundary (NEED TESTING)
- [ ] dtLocalBoundary::reset
- [ ] dtLocalBoundary::update
- [ ] dtLocalBoundary::isValid
- [ ] dtLocalBoundary::getCenter
- [ ] dtLocalBoundary::getSegmentCount
- [ ] dtLocalBoundary::getSegment

### Obstacle Avoidance (NEED TESTING)
- [ ] dtObstacleAvoidanceQuery::reset
- [ ] dtObstacleAvoidanceQuery::addCircle
- [ ] dtObstacleAvoidanceQuery::addSegment
- [ ] dtObstacleAvoidanceQuery::prepare
- [ ] dtObstacleAvoidanceQuery::sampleVelocityGrid
- [ ] dtObstacleAvoidanceQuery::sampleVelocityAdaptive
- [ ] dtObstacleAvoidanceQuery::getObstacleCircleCount
- [ ] dtObstacleAvoidanceQuery::getObstacleSegmentCount

## Phase 4: DetourTileCache Operations

### TileCache Management (PARTIALLY TESTED)
- [x] dtTileCache::init (basic integration test)
- [ ] dtTileCache::addTile
- [ ] dtTileCache::removeTile
- [ ] dtTileCache::getTileAt
- [ ] dtTileCache::getTileByRef
- [ ] dtTileCache::getTileRef
- [ ] dtTileCache::getTileCount
- [ ] dtTileCache::update
- [ ] dtTileCache::buildNavMeshTilesAt
- [ ] dtTileCache::addObstacle (cylinder)
- [ ] dtTileCache::addBoxObstacle
- [ ] dtTileCache::removeObstacle
- [ ] dtTileCache::queryTiles
- [ ] dtTileCache::getObstacleByRef
- [ ] dtTileCache::getObstacleRef
- [ ] dtTileCache::getObstacleCount

### Compression/Decompression (NEED TESTING)
- [ ] dtTileCacheCompressor::compress
- [ ] dtTileCacheCompressor::decompress

## Testing Strategy

### For Each Method:
1. Create C++ test that:
   - Uses nav_test.obj
   - Calls the method
   - Logs ALL parameters and results

2. Create identical Zig test that:
   - Uses nav_test.obj
   - Calls the method
   - Logs ALL parameters and results

3. Compare:
   - Input parameters (should be identical)
   - Output values (should match within tolerance)
   - Side effects (mesh changes, etc.)

### Success Criteria:
- **Exact match** for deterministic operations
- **< 0.1% difference** for floating-point operations
- **< 5% difference** for complex algorithms (with investigation)

## Implementation Plan

### Step 1: Create Comprehensive C++ Test
- Single executable that tests ALL methods
- Outputs detailed JSON/CSV with all results
- Uses nav_test.obj throughout

### Step 2: Create Comprehensive Zig Test
- Mirror of C++ test
- Identical inputs
- Identical output format

### Step 3: Automated Comparison
- Script to compare outputs
- Highlight any differences
- Generate detailed report

### Step 4: Fix Any Issues
- Investigate differences
- Fix bugs in Zig implementation
- Re-test until 100% match

## Current Status

**Phase 1 (Recast Core)**: ✅ 15/27 methods tested (55%)
**Phase 2 (Detour)**: ❌ 0/25 methods tested (0%)
**Phase 3 (DetourCrowd)**: ❌ 1/30 methods tested (3%)
**Phase 4 (DetourTileCache)**: ❌ 1/15 methods tested (7%)

**OVERALL**: ✅ 17/97 methods tested (**17.5%**)

## Next Actions

1. Create comprehensive C++ test file
2. Create comprehensive Zig test file
3. Run both and compare
4. Fix any discrepancies
5. Repeat until 100% pass
