//! Pure draw-plan expansion for the stencil-cover backend. It turns queued
//! backend calls into data the sokol replay layer can consume later.

const std = @import("std");
const color = @import("../../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const Transform = color.Transform;
const path = @import("../../types/path.zig");
const Winding = path.Winding;
const xforms = @import("../transform.zig");

pub const max_vertices: usize = 65535;
pub const max_indices: usize = (max_vertices - 2) * 3;

pub const CallType = enum {
    fill,
    fill_convex,
    stroke,
    stroke_convex,
    triangles,
};

pub const FillRule = enum {
    nonzero,
    even_odd,
};

pub const Primitive = enum {
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
    fringe_stencil_fill,
    cover_fill,
    convex_fill,
    fringe_fill,
    triangles,
};

pub const Range = struct {
    start: u32 = 0,
    count: u32 = 0,
};

pub const QueuedPath = struct {
    vertices: Range = .{},
    fringe: Range = .{},
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
    antialias: bool = false,
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
    edge_alpha_multiplier: f32 = 0,
};

pub const DrawOp = struct {
    kind: DrawOpKind,
    primitive: Primitive,
    vertices: Range,
    indices: Range = .{},
    uniform_index: u32,
    stencil_mode: StencilMode = .none,
    winding: Winding = .ccw,
};

pub fn build(
    gpa: std.mem.Allocator,
    calls: []const Call,
    queued_paths: []const QueuedPath,
    fill_rule: FillRule,
    uniforms: *std.ArrayList(PaintUniform),
    indices: *std.ArrayList(u16),
    draw_ops: *std.ArrayList(DrawOp),
) !void {
    uniforms.clearRetainingCapacity();
    indices.clearRetainingCapacity();
    draw_ops.clearRetainingCapacity();

    try uniforms.ensureUnusedCapacity(gpa, estimateUniforms(calls));
    try indices.ensureUnusedCapacity(gpa, estimateFanIndices(calls, queued_paths));
    try draw_ops.ensureUnusedCapacity(gpa, estimateDrawOps(calls, queued_paths));

    for (calls) |call| {
        switch (call.call_type) {
            .fill => try appendFill(call, queued_paths, fill_rule, uniforms, indices, draw_ops),
            .fill_convex => try appendConvexFill(call, queued_paths, uniforms, indices, draw_ops),
            .stroke => try appendStroke(call, queued_paths, uniforms, indices, draw_ops),
            .stroke_convex => try appendConvexFill(call, queued_paths, uniforms, indices, draw_ops),
            .triangles => appendTriangles(call, uniforms, draw_ops),
        }
    }
}

fn appendFill(
    call: Call,
    queued_paths: []const QueuedPath,
    fill_rule: FillRule,
    uniforms: *std.ArrayList(PaintUniform),
    indices: *std.ArrayList(u16),
    draw_ops: *std.ArrayList(DrawOp),
) !void {
    const uniform_index = appendUniform(call, uniforms);
    const stencil_mode: StencilMode = switch (fill_rule) {
        .nonzero => .nonzero,
        .even_odd => .even_odd,
    };

    for (pathsFor(call, queued_paths)) |p| {
        if (p.vertices.count < 3) continue;
        const fan_indices = try appendFanIndices(p.vertices, indices);
        draw_ops.appendAssumeCapacity(.{
            .kind = .stencil_fill,
            .primitive = .triangles,
            .vertices = p.vertices,
            .indices = fan_indices,
            .uniform_index = uniform_index,
            .stencil_mode = stencil_mode,
            .winding = p.winding,
        });
    }

    for (pathsFor(call, queued_paths)) |p| {
        if (p.fringe.count == 0) continue;
        draw_ops.appendAssumeCapacity(.{
            .kind = .fringe_stencil_fill,
            .primitive = .triangle_strip,
            .vertices = p.fringe,
            .uniform_index = uniform_index,
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
    indices: *std.ArrayList(u16),
    draw_ops: *std.ArrayList(DrawOp),
) !void {
    const uniform_index = appendUniform(call, uniforms);
    for (pathsFor(call, queued_paths)) |p| {
        if (p.vertices.count < 3) continue;
        const fan_indices = try appendFanIndices(p.vertices, indices);
        draw_ops.appendAssumeCapacity(.{
            .kind = .convex_fill,
            .primitive = .triangles,
            .vertices = p.vertices,
            .indices = fan_indices,
            .uniform_index = uniform_index,
            .winding = p.winding,
        });
        if (p.fringe.count > 0) {
            draw_ops.appendAssumeCapacity(.{
                .kind = .fringe_fill,
                .primitive = .triangle_strip,
                .vertices = p.fringe,
                .uniform_index = uniform_index,
                .winding = p.winding,
            });
        }
    }
}

fn appendStroke(
    call: Call,
    queued_paths: []const QueuedPath,
    uniforms: *std.ArrayList(PaintUniform),
    indices: *std.ArrayList(u16),
    draw_ops: *std.ArrayList(DrawOp),
) !void {
    const uniform_index = appendUniform(call, uniforms);

    for (pathsFor(call, queued_paths)) |p| {
        if (p.vertices.count < 3) continue;
        const fan_indices = try appendFanIndices(p.vertices, indices);
        draw_ops.appendAssumeCapacity(.{
            .kind = .stencil_fill,
            .primitive = .triangles,
            .vertices = p.vertices,
            .indices = fan_indices,
            .uniform_index = uniform_index,
            .stencil_mode = .nonzero,
            .winding = p.winding,
        });
    }

    for (pathsFor(call, queued_paths)) |p| {
        if (p.fringe.count == 0) continue;
        draw_ops.appendAssumeCapacity(.{
            .kind = .fringe_stencil_fill,
            .primitive = .triangle_strip,
            .vertices = p.fringe,
            .uniform_index = uniform_index,
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
    var uniform = packUniform(&call.paint, &call.scissor);
    uniform.edge_alpha_multiplier = if (call.antialias) 1 else 0;
    uniforms.appendAssumeCapacity(uniform);
    return index;
}

fn appendFanIndices(vertices: Range, indices: *std.ArrayList(u16)) !Range {
    if (vertices.count < 3) return .{};

    const vertex_start: usize = @intCast(vertices.start);
    const vertex_count: usize = @intCast(vertices.count);
    if (vertex_start + vertex_count > max_vertices) return error.FanIndexOverflow;

    const index_start = indices.items.len;
    for (0..vertex_count - 2) |i| {
        indices.appendAssumeCapacity(@intCast(vertex_start));
        indices.appendAssumeCapacity(@intCast(vertex_start + i + 1));
        indices.appendAssumeCapacity(@intCast(vertex_start + i + 2));
    }

    return .{
        .start = @intCast(index_start),
        .count = @intCast((vertex_count - 2) * 3),
    };
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

fn estimateDrawOps(calls: []const Call, queued_paths: []const QueuedPath) usize {
    var count: usize = 0;
    for (calls) |call| {
        switch (call.call_type) {
            .fill => {
                for (pathsFor(call, queued_paths)) |p| {
                    count += 1 + @as(usize, @intFromBool(p.fringe.count > 0));
                }
                count += @as(usize, @intFromBool(call.cover.count > 0));
            },
            .fill_convex => {
                for (pathsFor(call, queued_paths)) |p| {
                    count += 1 + @as(usize, @intFromBool(p.fringe.count > 0));
                }
            },
            .stroke => {
                for (pathsFor(call, queued_paths)) |p| {
                    count += 1 + @as(usize, @intFromBool(p.fringe.count > 0));
                }
                count += @as(usize, @intFromBool(call.cover.count > 0));
            },
            .stroke_convex => {
                for (pathsFor(call, queued_paths)) |p| {
                    count += 1 + @as(usize, @intFromBool(p.fringe.count > 0));
                }
            },
            .triangles => count += @as(usize, @intFromBool(call.vertices.count >= 3)),
        }
    }
    return count;
}

fn estimateUniforms(calls: []const Call) usize {
    var count: usize = 0;
    for (calls) |call| {
        switch (call.call_type) {
            .fill, .fill_convex, .stroke, .stroke_convex, .triangles => count += 1,
        }
    }
    return count;
}

fn estimateFanIndices(calls: []const Call, queued_paths: []const QueuedPath) usize {
    var count: usize = 0;
    for (calls) |call| {
        switch (call.call_type) {
            .fill, .fill_convex, .stroke, .stroke_convex => {
                for (pathsFor(call, queued_paths)) |p| {
                    count += fanIndexCount(p.vertices.count);
                }
            },
            .triangles => {},
        }
    }
    return count;
}

fn fanIndexCount(vertex_count: u32) usize {
    if (vertex_count < 3) return 0;
    return (@as(usize, vertex_count) - 2) * 3;
}
