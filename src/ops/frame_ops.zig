//! Frame lifecycle: the tick and the immutability fence.

const Context = @import("../state/context.zig").Context;
const State = @import("../state/draw_state.zig").State;

pub fn beginFrame(ctx: *Context, w: f32, h: f32, dpr: f32) void {
    const ratio = if (dpr > 0) dpr else 1;
    ctx.width = w;
    ctx.height = h;
    ctx.device_pixel_ratio = ratio;
    ctx.tess_tol = 0.25 / ratio;
    ctx.dist_tol = 0.01 / ratio;

    // Reset the state stack to a single default state.
    ctx.states.clearRetainingCapacity();
    ctx.states.append(ctx.gpa, State.default()) catch {};

    ctx.commands.clear();
    ctx.cache.clear();
    ctx.stroke_outline.clear();
    ctx.frame_arena.reset();

    if (ctx.backend) |b| b.viewport(b.ctx, w, h, ratio);
}

pub fn endFrame(ctx: *Context) void {
    if (ctx.backend) |b| b.flush(b.ctx);
    // TODO: the fill/stroke ops feed the backend; endFrame flushes it.
}

pub fn cancelFrame(ctx: *Context) void {
    ctx.commands.clear();
    ctx.cache.clear();
    ctx.stroke_outline.clear();
}
