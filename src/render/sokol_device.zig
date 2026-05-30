//! Shared sokol_gfx device layer. This is the only module that may import
//! sokol.gfx directly.

const sokol = @import("sokol");
const sg = sokol.gfx;
const path = @import("../types/path.zig");
const path_shader = @import("okys_path_shader");
const smoke_shader = @import("okys_shader");

pub const Desc = sg.Desc;
pub const Buffer = sg.Buffer;
pub const Shader = sg.Shader;
pub const Pipeline = sg.Pipeline;
pub const Pass = sg.Pass;
pub const Bindings = sg.Bindings;
pub const Color = sg.Color;
pub const PassAction = sg.PassAction;
pub const BufferDesc = sg.BufferDesc;
pub const PipelineDesc = sg.PipelineDesc;

pub const smoke_position_attr = smoke_shader.ATTR_smoke_position;
pub const smoke_color_attr = smoke_shader.ATTR_smoke_color0;

pub const path_position_attr = path_shader.ATTR_path_stencil_position;
pub const path_uv_attr = path_shader.ATTR_path_stencil_uv;
pub const path_cover_position_attr = path_shader.ATTR_path_cover_position;
pub const path_cover_uv_attr = path_shader.ATTR_path_cover_uv;
pub const path_vs_params_slot = path_shader.UB_vs_params;
pub const path_fs_params_slot = path_shader.UB_fs_params;
pub const PathVsParams = path_shader.VsParams;
pub const PathFsParams = path_shader.FsParams;

pub const PathPipelineKind = enum {
    stencil_nonzero,
    stencil_even_odd,
    cover,
    convex,
    triangles,
};

pub const StencilDraw = struct {
    mode: PathPipelineKind,
    base_element: u32,
    element_count: u32,
};

pub const CoverDraw = struct {
    base_element: u32,
    element_count: u32,
    uniform_index: u32,
};

pub const SmokeVertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const SmokeTriangle = struct {
    vertices: [3]SmokeVertex,
};

pub const Device = struct {
    owns_setup: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    dpr: f32 = 1.0,
    smoke_shader: Shader = .{},
    smoke_pipeline: Pipeline = .{},
    smoke_vertices: Buffer = .{},
    smoke_bindings: Bindings = .{},
    path_stencil_shader: Shader = .{},
    path_cover_shader: Shader = .{},
    path_stencil_nonzero_pipeline: Pipeline = .{},
    path_stencil_even_odd_pipeline: Pipeline = .{},
    path_cover_pipeline: Pipeline = .{},
    path_vertex_buffer: Buffer = .{},
    path_index_buffer: Buffer = .{},
    path_vertex_capacity: usize = 0,
    path_index_capacity: usize = 0,

    pub fn initOwned(desc: Desc) Device {
        sg.setup(desc);
        return .{ .owns_setup = true };
    }

    pub fn attach() Device {
        return .{};
    }

    pub fn deinit(self: *Device) void {
        self.destroySmokeResources();
        self.destroyPathResources();
        if (self.owns_setup) {
            sg.shutdown();
            self.owns_setup = false;
        }
    }

    pub fn resize(self: *Device, width: f32, height: f32, dpr: f32) void {
        self.dpr = if (dpr > 0.0) dpr else 1.0;
        self.width = pixelExtent(width, self.dpr);
        self.height = pixelExtent(height, self.dpr);
    }

    pub fn createSmokeResources(self: *Device) void {
        self.destroySmokeResources();

        const triangle = smokeTriangle();
        self.smoke_shader = sg.makeShader(smoke_shader.smokeShaderDesc(sg.queryBackend()));
        self.smoke_vertices = sg.makeBuffer(smokeVertexBufferDesc(&triangle));
        self.smoke_pipeline = sg.makePipeline(smokePipelineDesc(self.smoke_shader));
        self.smoke_bindings = smokeBindings(self.smoke_vertices);
    }

    pub fn destroySmokeResources(self: *Device) void {
        if (self.smoke_pipeline.id != 0) {
            sg.destroyPipeline(self.smoke_pipeline);
            self.smoke_pipeline = .{};
        }
        if (self.smoke_shader.id != 0) {
            sg.destroyShader(self.smoke_shader);
            self.smoke_shader = .{};
        }
        if (self.smoke_vertices.id != 0) {
            sg.destroyBuffer(self.smoke_vertices);
            self.smoke_vertices = .{};
        }
        self.smoke_bindings = .{};
    }

    pub fn createPathResources(self: *Device, vertex_capacity: usize, index_capacity: usize) void {
        self.destroyPathResources();
        const vertex_count = @max(vertex_capacity, 1);
        const index_count = @max(index_capacity, 1);
        self.path_stencil_shader = sg.makeShader(path_shader.pathStencilShaderDesc(sg.queryBackend()));
        self.path_cover_shader = sg.makeShader(path_shader.pathCoverShaderDesc(sg.queryBackend()));
        self.path_stencil_nonzero_pipeline = sg.makePipeline(pathPipelineDesc(self.path_stencil_shader, .stencil_nonzero));
        self.path_stencil_even_odd_pipeline = sg.makePipeline(pathPipelineDesc(self.path_stencil_shader, .stencil_even_odd));
        self.path_cover_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .cover));
        self.path_vertex_buffer = sg.makeBuffer(pathVertexBufferDesc(vertex_count));
        self.path_index_buffer = sg.makeBuffer(pathIndexBufferDesc(index_count));
        self.path_vertex_capacity = vertex_count;
        self.path_index_capacity = index_count;
    }

    pub fn destroyPathResources(self: *Device) void {
        if (self.path_cover_pipeline.id != 0) {
            sg.destroyPipeline(self.path_cover_pipeline);
            self.path_cover_pipeline = .{};
        }
        if (self.path_stencil_even_odd_pipeline.id != 0) {
            sg.destroyPipeline(self.path_stencil_even_odd_pipeline);
            self.path_stencil_even_odd_pipeline = .{};
        }
        if (self.path_stencil_nonzero_pipeline.id != 0) {
            sg.destroyPipeline(self.path_stencil_nonzero_pipeline);
            self.path_stencil_nonzero_pipeline = .{};
        }
        if (self.path_cover_shader.id != 0) {
            sg.destroyShader(self.path_cover_shader);
            self.path_cover_shader = .{};
        }
        if (self.path_stencil_shader.id != 0) {
            sg.destroyShader(self.path_stencil_shader);
            self.path_stencil_shader = .{};
        }
        if (self.path_vertex_buffer.id != 0) {
            sg.destroyBuffer(self.path_vertex_buffer);
            self.path_vertex_buffer = .{};
        }
        if (self.path_index_buffer.id != 0) {
            sg.destroyBuffer(self.path_index_buffer);
            self.path_index_buffer = .{};
        }
        self.path_vertex_capacity = 0;
        self.path_index_capacity = 0;
    }

    pub fn beginPass(self: *const Device, pass: Pass) void {
        sg.beginPass(pass);
        self.applyViewport();
    }

    pub fn endPass() void {
        sg.endPass();
    }

    pub fn commit() void {
        sg.commit();
    }

    pub fn drawSmokeTriangle(self: *Device, pass: Pass) void {
        if (self.smoke_pipeline.id == 0 or self.smoke_vertices.id == 0) {
            self.createSmokeResources();
        }

        self.beginPass(pass);
        sg.applyPipeline(self.smoke_pipeline);
        sg.applyBindings(self.smoke_bindings);
        sg.draw(0, 3, 1);
        sg.endPass();
        sg.commit();
    }

    pub fn drawStencilPass(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        draws: []const StencilDraw,
        view_width: f32,
        view_height: f32,
    ) void {
        self.drawStencilCoverPass(pass, vertices, indices, draws, &.{}, &.{}, view_width, view_height);
    }

    pub fn drawStencilCoverPass(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        stencil_draws: []const StencilDraw,
        cover_draws: []const CoverDraw,
        frag_params: []const PathFsParams,
        view_width: f32,
        view_height: f32,
    ) void {
        if (vertices.len == 0 or (stencil_draws.len == 0 and cover_draws.len == 0)) return;
        if (stencil_draws.len > 0 and indices.len == 0) return;
        self.ensurePathResources(vertices.len, indices.len);

        sg.updateBuffer(self.path_vertex_buffer, rangeFromSlice(path.Vertex, vertices));
        if (indices.len > 0) {
            sg.updateBuffer(self.path_index_buffer, rangeFromSlice(u16, indices));
        }

        self.beginPass(pass);
        const params = pathVsParams(view_width, view_height);
        const indexed_bindings = pathIndexedBindings(self.path_vertex_buffer, self.path_index_buffer, 0, 0);
        const vertex_bindings = pathVertexBindings(self.path_vertex_buffer, 0);

        for (stencil_draws) |draw| {
            if (draw.element_count == 0) continue;
            const pipeline = self.stencilPipeline(draw.mode);
            if (pipeline.id == 0) continue;
            sg.applyPipeline(pipeline);
            sg.applyBindings(indexed_bindings);
            sg.applyUniforms(path_vs_params_slot, rangeFromValue(PathVsParams, &params));
            sg.draw(draw.base_element, draw.element_count, 1);
        }

        if (self.path_cover_pipeline.id != 0) {
            for (cover_draws) |draw| {
                if (draw.element_count == 0) continue;
                const uniform_index: usize = @intCast(draw.uniform_index);
                if (uniform_index >= frag_params.len) continue;
                sg.applyPipeline(self.path_cover_pipeline);
                sg.applyBindings(vertex_bindings);
                sg.applyUniforms(path_vs_params_slot, rangeFromValue(PathVsParams, &params));
                sg.applyUniforms(path_fs_params_slot, rangeFromValue(PathFsParams, &frag_params[uniform_index]));
                sg.draw(draw.base_element, draw.element_count, 1);
            }
        }

        sg.endPass();
    }

    fn applyViewport(self: *const Device) void {
        if (self.width <= 0 or self.height <= 0) {
            return;
        }
        sg.applyViewport(0, 0, self.width, self.height, true);
    }

    fn ensurePathResources(self: *Device, vertex_capacity: usize, index_capacity: usize) void {
        const index_count = @max(index_capacity, 1);
        const missing = self.path_stencil_shader.id == 0 or
            self.path_cover_shader.id == 0 or
            self.path_stencil_nonzero_pipeline.id == 0 or
            self.path_stencil_even_odd_pipeline.id == 0 or
            self.path_cover_pipeline.id == 0 or
            self.path_vertex_buffer.id == 0 or
            self.path_index_buffer.id == 0;
        if (!missing and self.path_vertex_capacity >= vertex_capacity and self.path_index_capacity >= index_count) {
            return;
        }
        self.createPathResources(vertex_capacity, index_count);
    }

    fn stencilPipeline(self: *const Device, mode: PathPipelineKind) Pipeline {
        return switch (mode) {
            .stencil_nonzero => self.path_stencil_nonzero_pipeline,
            .stencil_even_odd => self.path_stencil_even_odd_pipeline,
            .cover, .convex, .triangles => .{},
        };
    }
};

pub fn smokeTriangle() SmokeTriangle {
    return .{
        .vertices = .{
            .{ .x = 0.0, .y = 0.5, .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .{ .x = 0.5, .y = -0.5, .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 },
            .{ .x = -0.5, .y = -0.5, .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 },
        },
    };
}

pub fn clearPassAction(clear_color: Color) PassAction {
    var action: PassAction = .{};
    action.colors[0].load_action = .CLEAR;
    action.colors[0].store_action = .STORE;
    action.colors[0].clear_value = clear_color;
    return action;
}

pub fn stencilCoverPassAction(clear_color: Color) PassAction {
    var action = clearPassAction(clear_color);
    action.stencil.load_action = .CLEAR;
    action.stencil.store_action = .STORE;
    action.stencil.clear_value = 0;
    return action;
}

pub fn passWithAction(action: PassAction) Pass {
    return .{ .action = action, .label = "okys_pass" };
}

pub fn smokeVertexBufferDesc(triangle: *const SmokeTriangle) BufferDesc {
    return .{
        .usage = .{ .vertex_buffer = true, .immutable = true },
        .data = .{
            .ptr = @ptrCast(&triangle.vertices),
            .size = @sizeOf(@TypeOf(triangle.vertices)),
        },
        .label = "okys_smoke_vertices",
    };
}

pub fn smokePipelineDesc(shader: Shader) PipelineDesc {
    var desc: PipelineDesc = .{};
    desc.shader = shader;
    desc.layout.buffers[0].stride = @sizeOf(SmokeVertex);
    desc.layout.attrs[smoke_position_attr].offset = @offsetOf(SmokeVertex, "x");
    desc.layout.attrs[smoke_position_attr].format = .FLOAT2;
    desc.layout.attrs[smoke_color_attr].offset = @offsetOf(SmokeVertex, "r");
    desc.layout.attrs[smoke_color_attr].format = .FLOAT4;
    desc.primitive_type = .TRIANGLES;
    desc.label = "okys_smoke_pipeline";
    return desc;
}

pub fn smokeBindings(vertex_buffer: Buffer) Bindings {
    var bindings: Bindings = .{};
    bindings.vertex_buffers[0] = vertex_buffer;
    return bindings;
}

pub fn pathVertexBufferDesc(vertex_capacity: usize) BufferDesc {
    return .{
        .size = vertex_capacity * @sizeOf(path.Vertex),
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "okys_path_vertices",
    };
}

pub fn pathIndexBufferDesc(index_capacity: usize) BufferDesc {
    return .{
        .size = index_capacity * @sizeOf(u16),
        .usage = .{ .index_buffer = true, .stream_update = true },
        .label = "okys_path_indices",
    };
}

pub fn pathVertexBindings(vertex_buffer: Buffer, vertex_offset_bytes: i32) Bindings {
    var bindings: Bindings = .{};
    bindings.vertex_buffers[0] = vertex_buffer;
    bindings.vertex_buffer_offsets[0] = vertex_offset_bytes;
    return bindings;
}

pub fn pathIndexedBindings(vertex_buffer: Buffer, index_buffer: Buffer, vertex_offset_bytes: i32, index_offset_bytes: i32) Bindings {
    var bindings = pathVertexBindings(vertex_buffer, vertex_offset_bytes);
    bindings.index_buffer = index_buffer;
    bindings.index_buffer_offset = index_offset_bytes;
    return bindings;
}

pub fn pathVsParams(view_width: f32, view_height: f32) PathVsParams {
    return .{
        .view_size = .{
            if (view_width > 0) view_width else 1,
            if (view_height > 0) view_height else 1,
        },
    };
}

pub fn pathPipelineDesc(shader: Shader, kind: PathPipelineKind) PipelineDesc {
    var desc: PipelineDesc = .{};
    desc.shader = shader;
    desc.layout.buffers[0].stride = @sizeOf(path.Vertex);
    desc.layout.attrs[path_position_attr].offset = @offsetOf(path.Vertex, "x");
    desc.layout.attrs[path_position_attr].format = .FLOAT2;
    desc.layout.attrs[path_uv_attr].offset = @offsetOf(path.Vertex, "u");
    desc.layout.attrs[path_uv_attr].format = .FLOAT2;
    desc.face_winding = .CCW;

    switch (kind) {
        .stencil_nonzero => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].write_mask = .NONE;
            desc.stencil = stencilState(.ALWAYS, .INCR_WRAP, .DECR_WRAP);
            desc.label = "okys_path_stencil_nonzero_pipeline";
        },
        .stencil_even_odd => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].write_mask = .NONE;
            desc.stencil = stencilState(.ALWAYS, .INVERT, .INVERT);
            desc.label = "okys_path_stencil_even_odd_pipeline";
        },
        .cover => {
            desc.primitive_type = .TRIANGLE_STRIP;
            desc.stencil = stencilState(.NOT_EQUAL, .ZERO, .ZERO);
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_cover_pipeline";
        },
        .convex => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_convex_pipeline";
        },
        .triangles => {
            desc.primitive_type = .TRIANGLES;
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_triangles_pipeline";
        },
    }

    return desc;
}

fn pixelExtent(points: f32, dpr: f32) i32 {
    if (points <= 0.0) {
        return 0;
    }
    return @intFromFloat(@ceil(points * dpr));
}

fn alphaBlend() sg.BlendState {
    return .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };
}

fn stencilState(compare: sg.CompareFunc, front_pass: sg.StencilOp, back_pass: sg.StencilOp) sg.StencilState {
    return .{
        .enabled = true,
        .front = .{
            .compare = compare,
            .fail_op = .KEEP,
            .depth_fail_op = .KEEP,
            .pass_op = front_pass,
        },
        .back = .{
            .compare = compare,
            .fail_op = .KEEP,
            .depth_fail_op = .KEEP,
            .pass_op = back_pass,
        },
        .read_mask = 0xff,
        .write_mask = 0xff,
        .ref = 0,
    };
}

fn rangeFromSlice(comptime T: type, values: []const T) sg.Range {
    return .{
        .ptr = values.ptr,
        .size = values.len * @sizeOf(T),
    };
}

fn rangeFromValue(comptime T: type, value: *const T) sg.Range {
    return .{
        .ptr = value,
        .size = @sizeOf(T),
    };
}
