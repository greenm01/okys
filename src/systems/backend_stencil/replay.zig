//! Converts stencil-cover draw-plan ops into device replay commands.

const std = @import("std");
const sokol_device = @import("../../render/sokol_device.zig");
const draw_plan = @import("draw_plan.zig");
const color = @import("../../types/color.zig");

pub fn build(
    gpa: std.mem.Allocator,
    draw_ops: []const draw_plan.DrawOp,
    uniforms: []const draw_plan.PaintUniform,
    path_draws: *std.ArrayList(sokol_device.PathDraw),
    stencil_draws: *std.ArrayList(sokol_device.StencilDraw),
    cover_draws: *std.ArrayList(sokol_device.CoverDraw),
    frag_params: *std.ArrayList(sokol_device.PathFsParams),
) !void {
    path_draws.clearRetainingCapacity();
    stencil_draws.clearRetainingCapacity();
    cover_draws.clearRetainingCapacity();
    frag_params.clearRetainingCapacity();

    try path_draws.ensureUnusedCapacity(gpa, countPathDraws(draw_ops));
    try stencil_draws.ensureUnusedCapacity(gpa, countStencilDraws(draw_ops));
    try cover_draws.ensureUnusedCapacity(gpa, countCoverDraws(draw_ops));
    try frag_params.ensureUnusedCapacity(gpa, uniforms.len);

    for (uniforms) |uniform| {
        frag_params.appendAssumeCapacity(packFragmentParams(uniform));
    }
    appendPathDraws(draw_ops, path_draws);
    appendStencilDraws(draw_ops, stencil_draws);
    appendCoverDraws(draw_ops, cover_draws);
}

pub fn buildStencilDraws(
    gpa: std.mem.Allocator,
    draw_ops: []const draw_plan.DrawOp,
    draws: *std.ArrayList(sokol_device.StencilDraw),
) !void {
    draws.clearRetainingCapacity();
    try draws.ensureUnusedCapacity(gpa, countStencilDraws(draw_ops));
    appendStencilDraws(draw_ops, draws);
}

fn appendPathDraws(
    draw_ops: []const draw_plan.DrawOp,
    draws: *std.ArrayList(sokol_device.PathDraw),
) void {
    for (draw_ops) |op| {
        switch (op.kind) {
            .stencil_fill => {
                if (op.indices.count == 0) continue;
                const kind = switch (op.stencil_mode) {
                    .nonzero => sokol_device.PathDrawKind.stencil_nonzero,
                    .even_odd => sokol_device.PathDrawKind.stencil_even_odd,
                    .none => continue,
                };
                draws.appendAssumeCapacity(.{
                    .kind = kind,
                    .base_element = op.indices.start,
                    .element_count = op.indices.count,
                    .uniform_index = op.uniform_index,
                });
            },
            .cover_fill => {
                if (op.vertices.count == 0) continue;
                draws.appendAssumeCapacity(.{
                    .kind = .cover,
                    .base_element = op.vertices.start,
                    .element_count = op.vertices.count,
                    .uniform_index = op.uniform_index,
                });
            },
            .convex_fill => {
                if (op.indices.count == 0) continue;
                draws.appendAssumeCapacity(.{
                    .kind = .convex,
                    .base_element = op.indices.start,
                    .element_count = op.indices.count,
                    .uniform_index = op.uniform_index,
                });
            },
            .triangles => {},
        }
    }
}

fn appendStencilDraws(
    draw_ops: []const draw_plan.DrawOp,
    draws: *std.ArrayList(sokol_device.StencilDraw),
) void {
    for (draw_ops) |op| {
        if (op.kind != .stencil_fill) continue;
        if (op.indices.count == 0) continue;

        const mode = switch (op.stencil_mode) {
            .nonzero => sokol_device.PathPipelineKind.stencil_nonzero,
            .even_odd => sokol_device.PathPipelineKind.stencil_even_odd,
            .none => continue,
        };

        draws.appendAssumeCapacity(.{
            .mode = mode,
            .base_element = op.indices.start,
            .element_count = op.indices.count,
        });
    }
}

fn appendCoverDraws(
    draw_ops: []const draw_plan.DrawOp,
    draws: *std.ArrayList(sokol_device.CoverDraw),
) void {
    for (draw_ops) |op| {
        if (op.kind != .cover_fill) continue;
        if (op.vertices.count == 0) continue;

        draws.appendAssumeCapacity(.{
            .base_element = op.vertices.start,
            .element_count = op.vertices.count,
            .uniform_index = op.uniform_index,
        });
    }
}

fn countPathDraws(draw_ops: []const draw_plan.DrawOp) usize {
    var count: usize = 0;
    for (draw_ops) |op| {
        switch (op.kind) {
            .stencil_fill, .convex_fill => count += @intFromBool(op.indices.count > 0),
            .cover_fill => count += @intFromBool(op.vertices.count > 0),
            .triangles => {},
        }
    }
    return count;
}

fn countStencilDraws(draw_ops: []const draw_plan.DrawOp) usize {
    var count: usize = 0;
    for (draw_ops) |op| {
        if (op.kind == .stencil_fill and op.indices.count > 0 and op.stencil_mode != .none) {
            count += 1;
        }
    }
    return count;
}

fn countCoverDraws(draw_ops: []const draw_plan.DrawOp) usize {
    var count: usize = 0;
    for (draw_ops) |op| {
        if (op.kind == .cover_fill and op.vertices.count > 0) {
            count += 1;
        }
    }
    return count;
}

fn packFragmentParams(uniform: draw_plan.PaintUniform) sokol_device.PathFsParams {
    const scissor_matrix = if (uniform.scissor_enabled)
        matrixColumns(uniform.scissor_xform)
    else
        [_][4]f32{ zeroColumn(), zeroColumn(), zeroColumn() };

    const paint_matrix = matrixColumns(uniform.paint_xform);
    return .{
        .paint_mat0 = paint_matrix[0],
        .paint_mat1 = paint_matrix[1],
        .paint_mat2 = paint_matrix[2],
        .scissor_mat0 = scissor_matrix[0],
        .scissor_mat1 = scissor_matrix[1],
        .scissor_mat2 = scissor_matrix[2],
        .inner_color = colorVec(uniform.inner_color),
        .outer_color = colorVec(uniform.outer_color),
        .scissor_extent_scale = .{
            uniform.scissor_extent[0],
            uniform.scissor_extent[1],
            uniform.scissor_scale[0],
            uniform.scissor_scale[1],
        },
        .extent_radius_feather = .{
            uniform.extent[0],
            uniform.extent[1],
            uniform.radius,
            uniform.feather,
        },
        .params = .{ 0, 0, 0, 0 },
    };
}

fn matrixColumns(t: color.Transform) [3][4]f32 {
    return .{
        .{ t[0], t[1], 0, 0 },
        .{ t[2], t[3], 0, 0 },
        .{ t[4], t[5], 1, 0 },
    };
}

fn zeroColumn() [4]f32 {
    return .{ 0, 0, 0, 0 };
}

fn colorVec(c: color.Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}
