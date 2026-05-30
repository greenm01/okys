//! Pure draw-plan expansion for the stencil-cover backend. It turns queued
//! backend calls into data the sokol replay layer can consume later.

const std = @import("std");
const color = @import("../../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const Transform = color.Transform;
const path = @import("../../types/path.zig");
const Vertex = path.Vertex;
const Winding = path.Winding;
const xforms = @import("../transform.zig");

pub const CallType = enum {
    fill,
    fill_convex,
    stroke,
    triangles,
};

pub const FillRule = enum {
    nonzero,
    even_odd,
};

pub const Primitive = enum {
    triangle_fan,
    triangle_strip,
    triangles,
};

pub const StencilMode = enum {
    none,
    nonzero,
    even_odd,
};

pub const DrawOpKind = enum {
    stencil_fill,
    cover_fill,
    convex_fill,
    triangles,
};

pub const Range = struct {
    start: u32 = 0,
    count: u32 = 0,
};

pub const QueuedPath = struct {
    vertices: Range = .{},
    winding: Winding = .ccw,
    closed: bool = false,
    convex: bool = false,
};

pub const Call = struct {
    call_type: CallType,
    paint: Paint,
    scissor: Scissor,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    width: f32 = 0,
    paths: Range = .{},
    vertices: Range = .{},
    cover: Range = .{},
};

pub const PaintUniform = struct {
    paint_xform: Transform = identity(),
    scissor_xform: Transform = .{ 0, 0, 0, 0, 0, 0 },
    scissor_extent: [2]f32 = .{ 1, 1 },
    scissor_scale: [2]f32 = .{ 1, 1 },
    extent: [2]f32 = .{ 0, 0 },
    radius: f32 = 0,
    feather: f32 = 1,
    inner_color: color.Color = .{},
    outer_color: color.Color = .{},
    image: i32 = 0,
    scissor_enabled: bool = false,
};

pub const DrawOp = struct {
    kind: DrawOpKind,
    primitive: Primitive,
    vertices: Range,
    uniform_index: u32,
    stencil_mode: StencilMode = .none,
    winding: Winding = .ccw,
};

pub fn build(
    gpa: std.mem.Allocator,
    calls: []const Call,
    queued_paths: []const QueuedPath,
    vertices: []const Vertex,
    fill_rule: FillRule,
    uniforms: *std.ArrayList(PaintUniform),
    draw_ops: *std.ArrayList(DrawOp),
) !void {
    _ = vertices;

    uniforms.clearRetainingCapacity();
    draw_ops.clearRetainingCapacity();

    try uniforms.ensureUnusedCapacity(gpa, calls.len);
    try draw_ops.ensureUnusedCapacity(gpa, estimateDrawOps(calls));

    for (calls) |call| {
        switch (call.call_type) {
            .fill => appendFill(call, queued_paths, fill_rule, uniforms, draw_ops),
            .fill_convex => appendConvexFill(call, queued_paths, uniforms, draw_ops),
            .triangles => appendTriangles(call, uniforms, draw_ops),
            .stroke => {},
        }
    }
}

fn appendFill(
    call: Call,
    queued_paths: []const QueuedPath,
    fill_rule: FillRule,
    uniforms: *std.ArrayList(PaintUniform),
    draw_ops: *std.ArrayList(DrawOp),
) void {
    const uniform_index = appendUniform(call, uniforms);
    const stencil_mode: StencilMode = switch (fill_rule) {
        .nonzero => .nonzero,
        .even_odd => .even_odd,
    };

    for (pathsFor(call, queued_paths)) |p| {
        if (p.vertices.count < 3) continue;
        draw_ops.appendAssumeCapacity(.{
            .kind = .stencil_fill,
            .primitive = .triangle_fan,
            .vertices = p.vertices,
            .uniform_index = uniform_index,
            .stencil_mode = stencil_mode,
            .winding = p.winding,
        });
    }

    if (call.cover.count > 0) {
        draw_ops.appendAssumeCapacity(.{
            .kind = .cover_fill,
            .primitive = .triangle_strip,
            .vertices = call.cover,
            .uniform_index = uniform_index,
        });
    }
}

fn appendConvexFill(
    call: Call,
    queued_paths: []const QueuedPath,
    uniforms: *std.ArrayList(PaintUniform),
    draw_ops: *std.ArrayList(DrawOp),
) void {
    const uniform_index = appendUniform(call, uniforms);
    for (pathsFor(call, queued_paths)) |p| {
        if (p.vertices.count < 3) continue;
        draw_ops.appendAssumeCapacity(.{
            .kind = .convex_fill,
            .primitive = .triangle_fan,
            .vertices = p.vertices,
            .uniform_index = uniform_index,
            .winding = p.winding,
        });
    }
}

fn appendTriangles(
    call: Call,
    uniforms: *std.ArrayList(PaintUniform),
    draw_ops: *std.ArrayList(DrawOp),
) void {
    if (call.vertices.count < 3) return;

    const uniform_index = appendUniform(call, uniforms);
    draw_ops.appendAssumeCapacity(.{
        .kind = .triangles,
        .primitive = .triangles,
        .vertices = call.vertices,
        .uniform_index = uniform_index,
    });
}

fn appendUniform(call: Call, uniforms: *std.ArrayList(PaintUniform)) u32 {
    const index: u32 = @intCast(uniforms.items.len);
    uniforms.appendAssumeCapacity(packUniform(&call.paint, &call.scissor));
    return index;
}

fn packUniform(paint: *const Paint, scissor: *const Scissor) PaintUniform {
    var uniform: PaintUniform = .{
        .paint_xform = inverseOrIdentity(&paint.xform),
        .extent = paint.extent,
        .radius = paint.radius,
        .feather = paint.feather,
        .inner_color = premul(paint.inner_color),
        .outer_color = premul(paint.outer_color),
        .image = paint.image,
    };

    if (scissor.extent[0] >= 0 and scissor.extent[1] >= 0) {
        uniform.scissor_enabled = true;
        uniform.scissor_xform = xforms.inverse(&scissor.xform) orelse .{ 0, 0, 0, 0, 0, 0 };
        uniform.scissor_extent = scissor.extent;
        uniform.scissor_scale = .{
            @sqrt(scissor.xform[0] * scissor.xform[0] + scissor.xform[2] * scissor.xform[2]),
            @sqrt(scissor.xform[1] * scissor.xform[1] + scissor.xform[3] * scissor.xform[3]),
        };
    }

    return uniform;
}

fn premul(c: color.Color) color.Color {
    return .{
        .r = c.r * c.a,
        .g = c.g * c.a,
        .b = c.b * c.a,
        .a = c.a,
    };
}

fn inverseOrIdentity(t: *const Transform) Transform {
    return xforms.inverse(t) orelse identity();
}

fn identity() Transform {
    return .{ 1, 0, 0, 1, 0, 0 };
}

fn pathsFor(call: Call, queued_paths: []const QueuedPath) []const QueuedPath {
    const start: usize = @intCast(call.paths.start);
    const count: usize = @intCast(call.paths.count);
    return queued_paths[start..][0..count];
}

fn estimateDrawOps(calls: []const Call) usize {
    var count: usize = 0;
    for (calls) |call| {
        switch (call.call_type) {
            .fill => count += @as(usize, call.paths.count) + @as(usize, @intFromBool(call.cover.count > 0)),
            .fill_convex => count += @as(usize, call.paths.count),
            .triangles => count += @as(usize, @intFromBool(call.vertices.count >= 3)),
            .stroke => {},
        }
    }
    return count;
}
