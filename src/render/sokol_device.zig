//! Shared sokol_gfx device layer. This is the only module that may import
//! sokol.gfx directly. Runtime device setup lands after the build wiring is
//! proven.

const sokol = @import("sokol");
const sg = sokol.gfx;
const smoke_shader = @import("okys_shader");

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

pub fn smokeTriangle() SmokeTriangle {
    return .{
        .vertices = .{
            .{ .x = 0.0, .y = 0.5, .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .{ .x = 0.5, .y = -0.5, .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 },
            .{ .x = -0.5, .y = -0.5, .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 },
        },
    };
}

comptime {
    _ = sg.Buffer;
    _ = sg.Pipeline;
    _ = sg.Pass;
    _ = sg.Bindings;
    _ = smoke_shader;
}
