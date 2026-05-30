//! Converts stencil-cover draw-plan ops into device replay commands.

const std = @import("std");
const sokol_device = @import("../../render/sokol_device.zig");
const draw_plan = @import("draw_plan.zig");

pub fn buildStencilDraws(
    gpa: std.mem.Allocator,
    draw_ops: []const draw_plan.DrawOp,
    draws: *std.ArrayList(sokol_device.StencilDraw),
) !void {
    draws.clearRetainingCapacity();
    try draws.ensureUnusedCapacity(gpa, countStencilDraws(draw_ops));

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

fn countStencilDraws(draw_ops: []const draw_plan.DrawOp) usize {
    var count: usize = 0;
    for (draw_ops) |op| {
        if (op.kind == .stencil_fill and op.indices.count > 0 and op.stencil_mode != .none) {
            count += 1;
        }
    }
    return count;
}
