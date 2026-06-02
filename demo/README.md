# RecastDemo (zig 0.16 + DVUI)

Порт `recastnavigation/RecastDemo` на Zig 0.16 с GUI на DVUI (glfw + OpenGL 4.1 core).
3D-рендер — собственный модерн-GL (zgl), UI-панель dvui рисуется поверх (ontop).

## Запуск

```sh
# ВАЖНО: снять прокси-env, иначе zig-fetch падает (см. корневой CLAUDE.md)
zig build run-demo
```

Меши берутся из папки `test_data/` (`*.obj`). Выбор меша — в dropdown панели.

## Управление

| Действие | Управление |
|----------|-----------|
| Орбита камеры | ПКМ + перемещение мыши |
| Полёт камеры | W/A/S/D + Q/E (Shift — быстрее) |
| Зум | колесо мыши |
| Клик инструмента | ЛКМ (Shift+ЛКМ — альт. действие) |
| Закрыть | Esc / кнопка |

## Реализовано

**Сэмплы** (переключатель Solo / Tile / Temp Obstacles):
- **Solo Mesh** — полный Recast pipeline (rasterize → filter → compact → erode →
  convex volumes → regions → contours → polymesh → detail → dtNavMesh). 16 режимов
  отрисовки (voxels / compact / regions / distance / contours / polymesh / detail /
  navmesh / bvtree). Слайдеры параметров + Build.
- **Tile Mesh** — тайловая сборка (per-tile heightfield с border → addTile,
  tile/poly-биты). Build All Tiles.
- **Temp Obstacles** — dtTileCache: per-tile слои + MeshProcess + компрессор.
  ЛКМ ставит цилиндрическое препятствие (Shift+ЛКМ — убрать), navmesh
  пересчитывается через tilecache.update.

**Инструменты:**
- **NavMesh Tester** — поиск пути (Shift+ЛКМ старт, ЛКМ финиш): straight / follow / raycast,
  подсветка полигонов пути + waypoints.
- **Off-Mesh Connection** — 2 клика создают off-mesh связь (прыжок), navmesh пересобирается.
- **Convex Volume** — клики задают точки, Shift+ЛКМ строит выпуклый объём (зона области:
  grass/road/water/door), применяется к build (markConvexPolyArea).
- **Crowd** — ЛКМ добавляет агента, Shift+ЛКМ задаёт цель всем; симуляция detour_crowd,
  агенты рисуются цилиндрами с вектором скорости.

## Отложено (мелочи порта)

- **NavMesh Prune** — нет `findLocalNeighborhood` в движке.
- NavMeshTester: dist-to-wall, polys-in-circle/shape, local-neighborhood, sliced.
- Crowd: trails, perf-график (PlotWidget), отладочные оверлеи VO/corners.
- Tile Mesh: TileEdit/TileHighlight (клик по тайлу), порталы; ChunkyTriMesh-ускорение.
- `.gset` save/load, TestCase loader, checker-текстура пола, толстые линии (quad-рендер),
  worldspace-текст (imguiHelpers).

## Структура

```
demo/src/
  main.zig              — окно, GL, dvui, кадровый цикл, ввод, UI-панель
  mat.zig               — Mat4 + perspective/lookAt/unproject/project (замена glu)
  camera.zig            — камера (орбита/зум/полёт), ray-pick
  debug_draw_gl.zig     — DebugDrawGL (батчинг VBO + шейдер MVP), реализует duDebugDraw
  app_state.zig         — состояние приложения
  build_context.zig     — BuildContext (буфер лога для панели; recast.Context + sink)
  io_util.zig           — файловые утилиты (std.Io.Dir) + PerfTimer
  sample.zig            — интерфейсы Sample/Tool + enums + цвета областей
  input_geom.zig        — загрузка .obj, bounds, нормали, raycast, convex/offmesh
  sample_solo.zig       — Sample_SoloMesh (build pipeline + DrawMode + UI)
  tool_navmesh_tester.zig, tool_offmesh.zig, tool_convex.zig, tool_crowd.zig
```
