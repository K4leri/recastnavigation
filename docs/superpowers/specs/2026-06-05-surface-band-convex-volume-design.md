# Surface-band convex volume — design

> Дизайн-документ (НЕ реализация). Дата: 2026-06-05. Проект: `zig-recast`.
> Область: `demo/src/*` + (read-only) `src/recast/*` структуры. Faithful-ядро
> `rcMarkConvexPolyArea` НЕ изменяется.

## 1. Проблема и цель

Сейчас convex volume в демо — плоская **призма**: `markConvexPolyArea` красит воксели
поверхности внутри XZ-контура между едиными `hmin`/`hmax`. Помеченная область уже
повторяет рельеф (красятся поверхностные spans на их высотах), но единая высотная
полоса `min..max` имеет проблему: на **многоэтажной/перепадной** геометрии она
красит слишком широкий вертикальный диапазон и может **зацепить соседний этаж**, а
сам объём не «прилегает» к локальной поверхности.

**Цель:** объём помечает только navmesh у **локальной** поверхности (per-column),
прилегая к рельефу и не захватывая соседние этажи. Поведение, не визуализация
(конформная отрисовка — вне scope этой итерации).

## 2. Решения владельца (зафиксированы 2026-06-05)

- **Алгоритм:** per-column «ближайший spans к ожидаемой поверхности ± band».
  «Ожидаемая поверхность» = least-squares **плоскость** через вершины контура.
- **Режим по умолчанию для новых объёмов:** **surface** (prism доступен тогглом).
- Ядро `src/recast` не модифицируется; маркер — demo-уровень поверх `CompactHeightfield`.

## 3. Модель данных

`ConvexVolume` (`demo/src/input_geom.zig`) получает поля:

```zig
pub const VolumeMode = enum(u8) { prism = 0, surface = 1 };

pub const ConvexVolume = struct {
    verts: [MAX_CONVEXVOL_PTS * 3]f32 = undefined,
    nverts: i32 = 0,
    hmin: f32 = 0,            // грубый bbox по Y (для цикла маркера + .gset)
    hmax: f32 = 0,
    area: u8 = 0,
    id: u32 = 0,
    mode: VolumeMode = .surface,   // НОВОЕ: режим маркировки
    band_below: f32 = 1.0,         // НОВОЕ: толщина полосы вниз от поверхности
    band_above: f32 = 1.0,         // НОВОЕ: толщина полосы вверх
};
```

- Контур (`verts` с Y) уже хранит высоты кликнутых точек → плоскость считается на
  build из `verts`, **отдельно не хранится**.
- `hmin/hmax` остаются: для `prism` — как сейчас; для `surface` — грубый bbox
  `[min(plane)-band_below, max(plane)+band_above]` (нужен для bbox-цикла маркера и
  для записи в `.gset`).
- Поля имеют дефолты → существующие литералы `ConvexVolume{...}` не ломаются;
  старые/загруженные без mode → `.surface` по дефолту (или `.prism` для legacy —
  см. §7 персистентность: версия формата решает).

## 4. Маркировка (новый demo-модуль)

Новый файл `demo/src/convex_surface.zig`:

```zig
/// Пометить area на compact heightfield внутри XZ-контура, прилегая к локальной
/// поверхности (per-column nearest span к fit-плоскости ± band). Ядро не трогаем.
pub fn markConvexPolyAreaSurface(
    verts: []const f32, nverts: usize,
    band_below: f32, band_above: f32,
    area: u8, chf: *recast.CompactHeightfield,
) void
```

Алгоритм:
1. **Плоскость** least-squares через вершины контура `(xi, zi) -> yi`: решить 3×3
   нормальные уравнения для `(a,b,c)`, `expected_y(x,z) = a*x + b*z + c`.
   Вырождение (коллинеарность в XZ, `det≈0`) → `a=b=0, c=mean(yi)` (горизонталь).
2. **Bbox→диапазон ячеек** по XZ контура (как `markConvexPolyArea`: world→cell через
   `chf.bmin`/`chf.cs`), клампить к `[0, width)`×`[0, height)`.
3. Для каждой ячейки `(x,z)` в диапазоне:
   - центр ячейки в world `(wx, wz)`; **point-in-poly** `(wx,wz)` по контуру
     (повторяем `pointInPoly` локально — приватная в area.zig).
   - если снаружи — пропуск.
   - `expected = expected_y(wx, wz)`.
   - перебрать spans колонки `chf.cells[x+z*width]` (`index..index+count`):
     world-Y span = `chf.bmin[1] + span.y * chf.ch`; найти span `s*` с минимальным
     `|worldY - expected|`.
   - если `s*` есть и `|worldY(s*) - expected| <= snap_max` (где
     `snap_max = band_below + band_above`, см. §6) → пометить **все** spans колонки
     в `[worldY(s*) - band_below, worldY(s*) + band_above]`: `chf.areas[i] = area`.
   - иначе (нет поверхности рядом с ожидаемой — провал/дыра/другой этаж далеко) →
     колонку пропустить.

Якорение на ближайшем **реальном** span (а не на самой плоскости) — устойчивость к
квантованию вокселей и сдвигу поверхности на agent-radius.

Зависимости: читает pub-поля `CompactHeightfield` (`cells`/`spans`/`areas`/`bmin`/
`cs`/`ch`/`width`/`height` — `src/recast/heightfield.zig:201`). Запись — только в
`chf.areas` (как делает и faithful `markConvexPolyArea`).

## 5. Build-обвязка

В сэмплах (`sample_solo.zig:265-267`, аналогично `sample_tile`/`sample_temp_obstacles`)
цикл по `geom.volumes` ветвится по `vol.mode`:
```zig
for (geom.volumes.items) |*vol| {
    const nv: usize = @intCast(vol.nverts);
    switch (vol.mode) {
        .prism => rc.area.markConvexPolyArea(vol.verts[0..nv*3], nv, vol.hmin, vol.hmax, vol.area, &chf),
        .surface => convex_surface.markConvexPolyAreaSurface(vol.verts[0..nv*3], nv, vol.band_below, vol.band_above, vol.area, &chf),
    }
}
```
Оба режима сосуществуют. `markConvexPolyArea` faithful — без изменений.

## 6. UI (`tool_convex.zig`)

- **drawMenu:** переключатель **Mode: Prism / Surface** (radio/toggle, пишет в
  `self.new_mode: VolumeMode`, дефолт `.surface`). В surface-режиме слайдеры
  **Band Above** / **Band Below** (в prism — текущие Shape Ascent/Descent).
- **onClick build:** при создании объёма проставлять `vol.mode = self.new_mode`,
  `vol.band_below/above = self.band_below/above`. `hmin/hmax` для surface =
  `[min(vertY)-band_below-slack, max(vertY)+band_above+slack]` (грубый bbox; slack —
  небольшой запас, напр. 1.0, чтобы bbox-цикл маркера не отсекал крайние spans).
  `snap_max` маркера = `band_below + band_above`.
- Текущие `box_height`/`box_descent` остаются для prism-режима (переименование
  Shape Ascent/Descent из прошлой правки — сохраняется для prism).

## 7. Персистентность (`demo/src/persist/scene_io.zig`)

- `volumes.bin`: добавить в запись `mode:u8 + band_below:f32 + band_above:f32`.
  **Поднять версию формата** volumes (на чтении: старая версия → `mode=.prism`,
  bands=дефолт, чтобы старые контейнеры грузились как призмы — обратная
  совместимость). Per-record chunk-header уже несёт длину → читатель отличает версии.
- `.gset`: surface-объём пишет грубый `hmin/hmax` bbox (RecastDemo прочитает как
  призму — теряется конформность, но файл валиден). `mode`/band в `.gset` НЕ пишем
  (не ломаем faithful-формат) — они только в `volumes.bin`. При загрузке из `.gset`
  (без `volumes.bin`) объём = prism (как сейчас).

## 8. Визуализация

Вне scope (владелец выбрал «только маркировка»). Рендер-превью и committed-объёмы
остаются грубым bbox-боксом (`min..max`). Конформная отрисовка («драпировка») —
возможный отдельный инкремент позже; помечается как known-limitation: бокс surface-
объёма выглядит шире реальной помеченной полосы.

## 9. Edge cases

- `nverts < 3` → объём не строится (как сейчас, `nhull > 2` guard в tool_convex).
- Коллинеарные в XZ вершины → горизонтальная плоскость на mean(Y).
- Колонка без поверхности рядом с `expected` (дыра/другой этаж) → не помечается.
- Очень большой перепад при `prism` — прежнее поведение (пользователь сам выберет).
- `band_below + band_above == 0` → snap_max=0: помечается только точное совпадение —
  слайдеры clamp снизу (мин 0.1), чтобы полоса всегда была ненулевой.
- Многоэтажность: per-column nearest к плоскости выбирает правильный этаж.

## 10. Тестирование

- **Unit (demo-test):** `markConvexPolyAreaSurface` на синтетическом маленьком
  `CompactHeightfield`: (а) плоская поверхность — все spans в контуре помечены;
  (б) две поверхности на разной высоте (этажи) — помечается только ближняя к
  плоскости; (в) колонка-дыра пропущена; (г) band расширяет помеченную толщину.
  Сконструировать chf вручную (cells/spans/areas) — без полного build.
- **Plane-fit unit:** least-squares на наборе точек (плоскость/наклон/коллинеарность).
- **Round-trip (scene_io):** volume с mode/band сохраняется и грузится (новая версия
  volumes.bin); старый volumes.bin (без полей) грузится как prism.
- **Build smoke:** `zig build demo` exit 0; ручная проверка владельцем на dungeon.

## 11. Файлы

- Изменить: `demo/src/input_geom.zig` (поля ConvexVolume), `demo/src/tool_convex.zig`
  (UI + build объёма), `demo/src/sample_solo.zig` + `sample_tile.zig` +
  `sample_temp_obstacles.zig` (ветка маркировки), `demo/src/persist/scene_io.zig`
  (volumes.bin формат + версия).
- Создать: `demo/src/convex_surface.zig` (маркер + plane-fit + локальный pointInPoly).
- НЕ трогать: `src/recast/area.zig` (`markConvexPolyArea` faithful), прочее ядро.

## 12. Открытые вопросы

Нет блокеров. `snap_max = band_below + band_above` — разумный дефолт; при желании
можно вынести в отдельный слайдер «Max Snap» позже (YAGNI сейчас).
