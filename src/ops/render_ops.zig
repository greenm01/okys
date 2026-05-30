//! Front-end draw ops: finalize path geometry and hand immutable snapshots to
//! the active render backend.

const Context = @import("../state/context.zig").Context;
const flatten = @import("../systems/flatten.zig");
const stroke_outline = @import("../systems/stroke.zig");

pub fn fill(ctx: *Context) void {
    flatten.flatten(ctx);
    if (ctx.cache.paths.items.len == 0 or ctx.cache.points.items.len == 0) return;

    const backend = ctx.backend orelse return;
    const state = ctx.state();
    const paint = state.fill;
    const scissor = state.scissor;
    const bounds = ctx.cache.bounds;

    backend.fill(
        backend.ctx,
        &paint,
        &scissor,
        bounds,
        ctx.cache.paths.items,
        ctx.cache.points.items,
    );
}

pub fn stroke(ctx: *Context) void {
    stroke_outline.buildOutline(ctx);
    if (ctx.stroke_outline.paths.items.len == 0 or ctx.stroke_outline.points.items.len == 0) return;

    const backend = ctx.backend orelse return;
    const state = ctx.state();
    const paint = state.stroke;
    const scissor = state.scissor;
    const width = state.stroke_width;

    backend.stroke(
        backend.ctx,
        &paint,
        &scissor,
        width,
        ctx.stroke_outline.paths.items,
        ctx.stroke_outline.points.items,
    );
}
