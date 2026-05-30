//! Shared sokol_gfx device layer. This is the only module that may import
//! sokol.gfx directly.

const sokol = @import("sokol");
const sg = sokol.gfx;
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

    pub fn initOwned(desc: Desc) Device {
        sg.setup(desc);
        return .{ .owns_setup = true };
    }

    pub fn attach() Device {
        return .{};
    }

    pub fn deinit(self: *Device) void {
        self.destroySmokeResources();
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

    fn applyViewport(self: *const Device) void {
        if (self.width <= 0 or self.height <= 0) {
            return;
        }
        sg.applyViewport(0, 0, self.width, self.height, true);
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

fn pixelExtent(points: f32, dpr: f32) i32 {
    if (points <= 0.0) {
        return 0;
    }
    return @intFromFloat(@ceil(points * dpr));
}
