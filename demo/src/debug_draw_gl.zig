//! DebugDrawGL — конкретная реализация интерфейса recast.debug.DebugDraw
//! поверх модерн-GL (zgl): батчинг вершин в VBO + мини-шейдер с MVP.
//! Аналог DebugDrawGL из RecastDemo/SampleInterfaces.cpp, но без legacy immediate mode.
//!
//! Вызовы duDebugDraw (begin/vertex/end) остаются 1в1 — меняется только бэкенд.

const std = @import("std");
const zgl = @import("zgl");
const recast = @import("recast-nav");

const DebugDraw = recast.debug.DebugDraw;
const DebugDrawPrimitives = recast.debug.DebugDrawPrimitives;

const vertex_shader_src =
    \\#version 330 core
    \\layout(location=0) in vec3 aPos;
    \\layout(location=1) in vec4 aCol;
    \\layout(location=2) in vec2 aUV;
    \\uniform mat4 uMVP;
    \\uniform int uClipSpace;
    \\out vec4 vCol;
    \\out vec2 vUV;
    \\out float vFogZ;
    \\void main() {
    \\    if (uClipSpace != 0) {
    \\        gl_Position = vec4(aPos, 1.0);  // aPos уже в NDC (толстые линии)
    \\        vFogZ = 1.0e9;
    \\    } else {
    \\        gl_Position = uMVP * vec4(aPos, 1.0);
    \\        vFogZ = gl_Position.w;
    \\    }
    \\    vCol = aCol;
    \\    vUV = aUV;
    \\}
;

const fragment_shader_src =
    \\#version 330 core
    \\in vec4 vCol;
    \\in vec2 vUV;
    \\in float vFogZ;
    \\uniform int uUseTex;
    \\uniform float uTexScale;
    \\uniform sampler2D uTex;
    \\uniform int uFogOn;
    \\uniform vec3 uFogColor;
    \\uniform float uFogStart;
    \\uniform float uFogEnd;
    \\out vec4 frag;
    \\void main() {
    \\    vec4 c = vCol;
    \\    if (uUseTex != 0) c *= texture(uTex, vUV * uTexScale);
    \\    if (uFogOn != 0) {
    \\        float f = clamp((uFogEnd - vFogZ) / (uFogEnd - uFogStart), 0.0, 1.0);
    \\        c.rgb = mix(uFogColor, c.rgb, f);
    \\    }
    \\    frag = c;
    \\}
;

const Vertex = extern struct {
    x: f32,
    y: f32,
    z: f32,
    col: u32,
    u: f32,
    v: f32,
};

pub const DebugDrawGL = struct {
    program: zgl.Program,
    vao: zgl.VertexArray,
    vbo: zgl.Buffer,
    tex: zgl.Texture,
    loc_mvp: ?u32,
    loc_use_tex: ?u32,
    loc_tex: ?u32,
    loc_tex_scale: ?u32,
    loc_fog_on: ?u32 = null,
    loc_fog_color: ?u32 = null,
    loc_fog_start: ?u32 = null,
    loc_fog_end: ?u32 = null,
    loc_clip_space: ?u32 = null,
    tex_scale: f32 = 1.0,
    // Туман как в RecastDemo (LINEAR, цвет 0.32,0.31,0.30). Включается только
    // вокруг input-mesh (Sample::render glEnable/glDisable GL_FOG).
    fog_on: bool = false,
    fog_start: f32 = 0,
    fog_end: f32 = 1e9,
    fog_color: [3]f32 = .{ 0.32, 0.31, 0.30 },

    verts: std.array_list.Managed(Vertex),
    // Переиспользуемый буфер для разворота quads/толстых линий — без аллокации каждый кадр
    // (иначе воксели с сотнями тысяч боксов жёстко лагают).
    scratch: std.array_list.Managed(Vertex),
    cur_prim: DebugDrawPrimitives = .tris,
    cur_size: f32 = 1.0,
    use_texture: bool = false,
    mvp: [16]f32 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 },
    // Размер фреймбуфера в пикселях — для quad-рендера толстых линий (GL core клампит lineWidth до 1).
    fb_w: f32 = 1280,
    fb_h: f32 = 720,
    /// Профилировочные счётчики (сбрасываются раз в кадр в main).
    draw_calls: u32 = 0,
    verts_uploaded: u32 = 0,
    /// Режим отсечения граней меша: 0=off, 1=back, 2=front (переключается клавишей C).
    cull_mode: u8 = 1,
    /// Вариант рендера вокселей (клавиша V). Применяется+восстанавливается вокруг
    /// отрисовки вокселей -> не протекает в другие режимы.
    voxel_variant: u8 = 0,
    /// Переопределение areaToCol (SampleDebugDraw задаёт цвета SAMPLE_POLYAREA_*).
    area_to_col: ?*const fn (area: u32) u32 = null,

    pub fn init(allocator: std.mem.Allocator) !DebugDrawGL {
        const program = try buildProgram(allocator);

        const vao = zgl.createVertexArray();
        const vbo = zgl.createBuffer();

        zgl.bindVertexArray(vao);
        zgl.bindBuffer(vbo, .array_buffer);

        const stride = @sizeOf(Vertex);
        zgl.enableVertexAttribArray(0);
        zgl.vertexAttribPointer(0, 3, .float, false, stride, @offsetOf(Vertex, "x"));
        zgl.enableVertexAttribArray(1);
        zgl.vertexAttribPointer(1, 4, .unsigned_byte, true, stride, @offsetOf(Vertex, "col"));
        zgl.enableVertexAttribArray(2);
        zgl.vertexAttribPointer(2, 2, .float, false, stride, @offsetOf(Vertex, "u"));

        zgl.bindVertexArray(.invalid);

        const tex = buildCheckerTexture();

        return .{
            .program = program,
            .vao = vao,
            .vbo = vbo,
            .tex = tex,
            .loc_mvp = zgl.getUniformLocation(program, "uMVP"),
            .loc_use_tex = zgl.getUniformLocation(program, "uUseTex"),
            .loc_tex = zgl.getUniformLocation(program, "uTex"),
            .loc_tex_scale = zgl.getUniformLocation(program, "uTexScale"),
            .loc_fog_on = zgl.getUniformLocation(program, "uFogOn"),
            .loc_fog_color = zgl.getUniformLocation(program, "uFogColor"),
            .loc_fog_start = zgl.getUniformLocation(program, "uFogStart"),
            .loc_fog_end = zgl.getUniformLocation(program, "uFogEnd"),
            .loc_clip_space = zgl.getUniformLocation(program, "uClipSpace"),
            .verts = std.array_list.Managed(Vertex).init(allocator),
            .scratch = std.array_list.Managed(Vertex).init(allocator),
        };
    }

    pub fn deinit(self: *DebugDrawGL) void {
        self.scratch.deinit();
        self.verts.deinit();
        self.tex.delete();
        self.vbo.delete();
        self.vao.delete();
        self.program.delete();
    }

    /// Текущий масштаб текстуры (uv * scale). RecastDemo: 1/(cellSize*10).
    pub fn setTexScale(self: *DebugDrawGL, scale: f32) void {
        self.tex_scale = scale;
    }

    /// Устанавливает текущую model-view-projection матрицу (column-major [16]).
    pub fn setMvp(self: *DebugDrawGL, m: [16]f32) void {
        self.mvp = m;
    }

    /// Размер фреймбуфера (пиксели) — для пересчёта пиксельной толщины линий в NDC.
    pub fn setViewport(self: *DebugDrawGL, w: i32, h: i32) void {
        self.fb_w = @floatFromInt(@max(1, w));
        self.fb_h = @floatFromInt(@max(1, h));
    }

    /// Параметры тумана (мировые eye-distance). RecastDemo: start=camr*0.1, end=camr*1.25.
    pub fn setFogRange(self: *DebugDrawGL, start: f32, end: f32) void {
        self.fog_start = start;
        self.fog_end = end;
    }

    /// Вкл/выкл туман (как glEnable/glDisable(GL_FOG) вокруг конкретных draw'ов).
    pub fn enableFog(self: *DebugDrawGL, on: bool) void {
        self.fog_on = on;
    }

    /// Возвращает интерфейс DebugDraw (vtable) для передачи в recast.debug.*.
    pub fn debugDraw(self: *DebugDrawGL) DebugDraw {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- реализация vtable ---
    const vtable = DebugDraw.VTable{
        .depthMask = vtDepthMask,
        .texture = vtTexture,
        .begin = vtBegin,
        .vertex = vtVertex,
        .vertexXYZ = vtVertexXYZ,
        .end = vtEnd,
        .areaToCol = vtAreaToCol,
    };

    fn vtDepthMask(_: *anyopaque, state: bool) void {
        zgl.depthMask(state);
    }

    fn vtTexture(ptr: *anyopaque, state: bool) void {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        // TODO(#11): checker-текстура пола. Пока рендерим без текстуры.
        self.use_texture = state;
    }

    fn vtBegin(ptr: *anyopaque, prim: DebugDrawPrimitives, size: f32) void {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        self.cur_prim = prim;
        self.cur_size = size;
        self.verts.clearRetainingCapacity();
        switch (prim) {
            .points => zgl.pointSize(size),
            // core profile поддерживает только line width 1.0 (>1 -> GL_INVALID_VALUE).
            // TODO: толстые линии через quad-рендер.
            .lines => zgl.lineWidth(@min(size, 1.0)),
            else => {},
        }
    }

    fn vtVertex(ptr: *anyopaque, pos: *const [3]f32, color: u32) void {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        self.push(pos[0], pos[1], pos[2], color);
    }

    fn vtVertexXYZ(ptr: *anyopaque, x: f32, y: f32, z: f32, color: u32) void {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        self.push(x, y, z, color);
    }

    fn push(self: *DebugDrawGL, x: f32, y: f32, z: f32, color: u32) void {
        // uv от мировых x,z — для checker (когда будет включён).
        self.verts.append(.{ .x = x, .y = y, .z = z, .col = color, .u = x, .v = z }) catch {};
    }

    /// Вершина с явными uv (triplanar-маппинг checker'а из duDebugDrawTriMesh:
    /// uv = две оси, перпендикулярные доминантной оси нормали — иначе на стенах
    /// текстура смазана вертикально и горизонтальных линий сетки нет).
    pub fn vertexUV(self: *DebugDrawGL, x: f32, y: f32, z: f32, color: u32, u: f32, v: f32) void {
        self.verts.append(.{ .x = x, .y = y, .z = z, .col = color, .u = u, .v = v }) catch {};
    }

    fn vtEnd(ptr: *anyopaque) void {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        defer {
            switch (self.cur_prim) {
                .points => zgl.pointSize(1.0),
                .lines => zgl.lineWidth(1.0),
                else => {},
            }
        }
        if (self.verts.items.len == 0) return;

        // GL core не знает QUADS — разворачиваем в треугольники (через scratch без аллокации).
        var upload = self.verts.items;
        var clip_space = false;

        const mode: zgl.PrimitiveType = switch (self.cur_prim) {
            .points => .points,
            // Толстые линии (size>1): GL core клампит lineWidth до 1px, поэтому
            // разворачиваем каждый сегмент в экранно-ориентированный quad (в NDC).
            .lines => if (self.cur_size > 1.1) blk: {
                self.scratch.clearRetainingCapacity();
                self.expandThickLines(&self.scratch);
                upload = self.scratch.items;
                clip_space = true;
                break :blk .triangles;
            } else .lines,
            .tris => .triangles,
            .quads => blk: {
                self.scratch.clearRetainingCapacity();
                // защита от десинхронизации группировки по 4 (если вершина потерялась)
                const quad_count = self.verts.items.len / 4;
                self.scratch.ensureTotalCapacity(quad_count * 6) catch {};
                var i: usize = 0;
                while (i < quad_count * 4) : (i += 4) {
                    const q = self.verts.items[i .. i + 4];
                    self.scratch.appendSliceAssumeCapacity(&.{ q[0], q[1], q[2], q[0], q[2], q[3] });
                }
                upload = self.scratch.items;
                break :blk .triangles;
            },
        };

        zgl.bindBuffer(self.vbo, .array_buffer);
        zgl.bufferData(.array_buffer, Vertex, upload, .dynamic_draw);

        zgl.useProgram(self.program);
        const mtx: [4][4]f32 = @bitCast(self.mvp);
        zgl.uniformMatrix4fv(self.loc_mvp, false, &.{mtx});
        if (self.use_texture) {
            zgl.activeTexture(.texture_0);
            zgl.bindTexture(self.tex, .@"2d");
            zgl.programUniform1i(self.program, self.loc_tex, 0);
            zgl.programUniform1i(self.program, self.loc_use_tex, 1);
            zgl.programUniform1f(self.program, self.loc_tex_scale, self.tex_scale);
        } else {
            zgl.programUniform1i(self.program, self.loc_use_tex, 0);
        }
        if (self.fog_on) {
            zgl.programUniform1i(self.program, self.loc_fog_on, 1);
            zgl.programUniform3f(self.program, self.loc_fog_color, self.fog_color[0], self.fog_color[1], self.fog_color[2]);
            zgl.programUniform1f(self.program, self.loc_fog_start, self.fog_start);
            zgl.programUniform1f(self.program, self.loc_fog_end, self.fog_end);
        } else {
            zgl.programUniform1i(self.program, self.loc_fog_on, 0);
        }
        zgl.programUniform1i(self.program, self.loc_clip_space, if (clip_space) 1 else 0);

        zgl.bindVertexArray(self.vao);
        zgl.drawArrays(mode, 0, upload.len);
        zgl.bindVertexArray(.invalid);

        self.draw_calls += 1;
        self.verts_uploaded += @intCast(upload.len);
    }

    /// Разворачивает пары вершин (.lines) в экранно-ориентированные quad'ы толщины
    /// cur_size пикселей. Выходные позиции — в NDC (шейдер с uClipSpace=1 не трогает MVP).
    fn expandThickLines(self: *DebugDrawGL, out: *std.array_list.Managed(Vertex)) void {
        const m = self.mvp;
        const half_px = self.cur_size * 0.5;
        const src = self.verts.items;
        var i: usize = 0;
        while (i + 2 <= src.len) : (i += 2) {
            const a = src[i];
            const b = src[i + 1];
            // проекция в clip -> NDC
            const aw = m[3] * a.x + m[7] * a.y + m[11] * a.z + m[15];
            const bw = m[3] * b.x + m[7] * b.y + m[11] * b.z + m[15];
            if (aw <= 0.0001 or bw <= 0.0001) continue; // за камерой — пропуск
            const ax = (m[0] * a.x + m[4] * a.y + m[8] * a.z + m[12]) / aw;
            const ay = (m[1] * a.x + m[5] * a.y + m[9] * a.z + m[13]) / aw;
            const az = (m[2] * a.x + m[6] * a.y + m[10] * a.z + m[14]) / aw;
            const bx = (m[0] * b.x + m[4] * b.y + m[8] * b.z + m[12]) / bw;
            const by = (m[1] * b.x + m[5] * b.y + m[9] * b.z + m[13]) / bw;
            const bz = (m[2] * b.x + m[6] * b.y + m[10] * b.z + m[14]) / bw;
            // направление в пикселях
            var dx = (bx - ax) * self.fb_w * 0.5;
            var dy = (by - ay) * self.fb_h * 0.5;
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 1e-5) continue;
            dx /= len;
            dy /= len;
            // перпендикуляр в пикселях -> смещение в NDC
            const ox = -dy * half_px * 2.0 / self.fb_w;
            const oy = dx * half_px * 2.0 / self.fb_h;
            const v = struct {
                fn mk(x: f32, y: f32, z: f32, c: u32) Vertex {
                    return .{ .x = x, .y = y, .z = z, .col = c, .u = 0, .v = 0 };
                }
            }.mk;
            const a0 = v(ax + ox, ay + oy, az, a.col);
            const a1 = v(ax - ox, ay - oy, az, a.col);
            const b0 = v(bx + ox, by + oy, bz, b.col);
            const b1 = v(bx - ox, by - oy, bz, b.col);
            out.append(a0) catch {};
            out.append(a1) catch {};
            out.append(b1) catch {};
            out.append(a0) catch {};
            out.append(b1) catch {};
            out.append(b0) catch {};
        }
    }

    fn vtAreaToCol(ptr: *anyopaque, area: u32) u32 {
        const self: *DebugDrawGL = @ptrCast(@alignCast(ptr));
        if (self.area_to_col) |f| return f(area);
        // Поведение базового duDebugDraw::areaToCol.
        if (area == 0) return recast.debug.rgba(0, 192, 255, 255);
        return recast.debug.intToCol(@intCast(area), 255);
    }
};

/// Checker/grid-текстура пола как в RecastDemo (GLCheckerTexture): 64x64, линия
/// сетки (col0) на x==0||y==0, иначе заливка (col1). Мип-уровни строятся вручную,
/// чтобы линии сетки оставались видимыми на расстоянии. REPEAT-обёртка.
fn buildCheckerTexture() zgl.Texture {
    const col0 = recast.debug.rgba(215, 215, 215, 255);
    const col1 = recast.debug.rgba(255, 255, 255, 255);
    const tex = zgl.createTexture(.@"2d");
    zgl.bindTexture(tex, .@"2d");

    var data: [64 * 64]u32 = undefined;
    var size: usize = 64;
    var level: usize = 0;
    while (size > 0) : ({
        size /= 2;
        level += 1;
    }) {
        for (0..size) |y| {
            for (0..size) |x| {
                data[x + y * size] = if (x == 0 or y == 0) col0 else col1;
            }
        }
        zgl.textureImage2D(.@"2d", level, .rgba8, size, size, .rgba, .unsigned_byte, @ptrCast(&data));
    }
    zgl.textureParameter(tex, .min_filter, .linear_mipmap_nearest);
    zgl.textureParameter(tex, .mag_filter, .linear);
    zgl.textureParameter(tex, .wrap_s, .repeat);
    zgl.textureParameter(tex, .wrap_t, .repeat);
    zgl.bindTexture(.invalid, .@"2d");
    return tex;
}

fn buildProgram(allocator: std.mem.Allocator) !zgl.Program {
    const vs = zgl.createShader(.vertex);
    defer zgl.deleteShader(vs);
    zgl.shaderSource(vs, 1, &.{vertex_shader_src});
    zgl.compileShader(vs);
    if (zgl.getShader(vs, .compile_status) == 0) {
        const log = try zgl.getShaderInfoLog(vs, allocator);
        defer allocator.free(log);
        std.log.err("vertex shader: {s}", .{log});
        return error.ShaderCompileFailed;
    }

    const fs = zgl.createShader(.fragment);
    defer zgl.deleteShader(fs);
    zgl.shaderSource(fs, 1, &.{fragment_shader_src});
    zgl.compileShader(fs);
    if (zgl.getShader(fs, .compile_status) == 0) {
        const log = try zgl.getShaderInfoLog(fs, allocator);
        defer allocator.free(log);
        std.log.err("fragment shader: {s}", .{log});
        return error.ShaderCompileFailed;
    }

    const program = zgl.createProgram();
    zgl.attachShader(program, vs);
    zgl.attachShader(program, fs);
    zgl.linkProgram(program);
    if (zgl.getProgram(program, .link_status) == 0) {
        const log = try zgl.getProgramInfoLog(program, allocator);
        defer allocator.free(log);
        std.log.err("program link: {s}", .{log});
        return error.ProgramLinkFailed;
    }
    return program;
}
