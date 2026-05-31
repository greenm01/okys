//! Front-end draw ops: finalize path geometry and hand immutable snapshots to
//! the active render backend.

const Context = @import("../state/context.zig").Context;
const frame_profile = @import("../state/frame_profile.zig");
const flatten = @import("../systems/flatten.zig");
const stroke_outline = @import("../systems/stroke.zig");

const OKY_ANTIALIAS: u32 = 1 << 0;

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
    const raw_width = stroke_outline.effectiveStrokeWidth(ctx);
    if (raw_width <= 0) return;

    var width = raw_width;
    var paint = ctx.state().stroke;
    const fringe = 1.0 / if (ctx.device_pixel_ratio > 0) ctx.device_pixel_ratio else 1.0;
    if ((ctx.flags & OKY_ANTIALIAS) != 0 and width < fringe) {
        const alpha = @min(@max(width / fringe, 0), 1);
        const alpha_scale = alpha * alpha;
        paint.inner_color.a *= alpha_scale;
        paint.outer_color.a *= alpha_scale;
        width = fringe;
    }

    const profile_enabled = ctx.frame_profile.enabled;
    const profile_start = if (profile_enabled) frame_profile.nowNs() else 0;
    stroke_outline.buildOutlineWithWidth(ctx, width);
    if (profile_enabled) {
        ctx.frame_profile.recordStrokeOutline(
            frame_profile.nowNs() - profile_start,
            ctx.cache.paths.items,
            ctx.cache.points.items.len,
            ctx.stroke_outline.paths.items.len,
            ctx.stroke_outline.points.items.len,
        );
    }
    if (ctx.stroke_outline.paths.items.len == 0 or ctx.stroke_outline.points.items.len == 0) return;

    const backend = ctx.backend orelse return;
    const state = ctx.state();
    const scissor = state.scissor;
    ctx.frame_profile.recordStrokeCall();

    backend.stroke(
        backend.ctx,
        &paint,
        &scissor,
        width,
        ctx.stroke_outline.paths.items,
        ctx.stroke_outline.points.items,
    );
}
