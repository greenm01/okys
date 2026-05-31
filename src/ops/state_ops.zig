//! State verbs. save/restore push and pop; style, transform, and scissor mutate
//! the live top-of-stack state.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const draw_state = @import("../state/draw_state.zig");
const State = draw_state.State;
const LineCap = draw_state.LineCap;
const LineJoin = draw_state.LineJoin;
pub const max_line_dashes = draw_state.max_line_dashes;
const xforms = @import("../systems/transform.zig");
const Transform = @import("../types/color.zig").Transform;

pub fn save(ctx: *Context) void {
    const top = ctx.state().*;
    ctx.states.append(ctx.gpa, top) catch {};
}

pub fn restore(ctx: *Context) void {
    // Always keep one state on the stack.
    if (ctx.states.items.len <= 1) {
        ctx.recordDiagnostic(.unbalanced_restore);
        return;
    }
    _ = ctx.states.pop();
}

pub fn reset(ctx: *Context) void {
    ctx.state().* = State.default();
}

pub fn strokeWidth(ctx: *Context, width: f32) void {
    ctx.state().stroke_width = width;
}

pub fn miterLimit(ctx: *Context, limit: f32) void {
    ctx.state().miter_limit = limit;
}

pub fn lineCap(ctx: *Context, cap: LineCap) void {
    ctx.state().line_cap = cap;
}

pub fn lineJoin(ctx: *Context, join: LineJoin) void {
    ctx.state().line_join = join;
}

pub fn lineDash(ctx: *Context, pattern: []const f32) void {
    const state = ctx.state();
    state.line_dash = @splat(0);
    state.line_dash_count = 0;

    if (pattern.len == 0) return;

    const count = @min(pattern.len, max_line_dashes);
    for (pattern[0..count], 0..) |value, i| {
        if (!std.math.isFinite(value) or value <= 0) {
            state.line_dash = @splat(0);
            state.line_dash_count = 0;
            return;
        }
        state.line_dash[i] = value;
    }
    state.line_dash_count = @intCast(count);
}

pub fn lineDashOffset(ctx: *Context, offset: f32) void {
    ctx.state().line_dash_offset = if (std.math.isFinite(offset)) offset else 0;
}

pub fn globalAlpha(ctx: *Context, alpha: f32) void {
    ctx.state().alpha = std.math.clamp(alpha, 0.0, 1.0);
}

pub fn resetTransform(ctx: *Context) void {
    ctx.state().xform = xforms.identity();
}

pub fn transform(ctx: *Context, a: f32, b: f32, c: f32, d: f32, e: f32, f: f32) void {
    const t: Transform = .{ a, b, c, d, e, f };
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn translate(ctx: *Context, x: f32, y: f32) void {
    const t = xforms.translate(x, y);
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn rotate(ctx: *Context, angle: f32) void {
    const t = xforms.rotate(angle);
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn scale(ctx: *Context, x: f32, y: f32) void {
    const t = xforms.scale(x, y);
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn skewX(ctx: *Context, angle: f32) void {
    const t = xforms.skewX(angle);
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn skewY(ctx: *Context, angle: f32) void {
    const t = xforms.skewY(angle);
    xforms.premultiply(&ctx.state().xform, &t);
}

pub fn currentTransform(ctx: *Context) Transform {
    return ctx.state().xform;
}

pub fn scissor(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
    var scissor_xform = xforms.identity();
    scissor_xform[4] = x + w * 0.5;
    scissor_xform[5] = y + h * 0.5;
    xforms.multiply(&scissor_xform, &ctx.state().xform);

    ctx.state().scissor = .{
        .xform = scissor_xform,
        .extent = .{ w * 0.5, h * 0.5 },
    };
}

pub fn intersectScissor(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
    const state = ctx.state();
    if (state.scissor.extent[0] < 0) {
        scissor(ctx, x, y, w, h);
        return;
    }

    const invxform = xforms.inverse(&state.xform) orelse xforms.identity();
    var pxform = state.scissor.xform;
    xforms.multiply(&pxform, &invxform);

    const ex = state.scissor.extent[0];
    const ey = state.scissor.extent[1];
    const tex = ex * @abs(pxform[0]) + ey * @abs(pxform[2]);
    const tey = ex * @abs(pxform[1]) + ey * @abs(pxform[3]);

    const ax = pxform[4] - tex;
    const ay = pxform[5] - tey;
    const aw = tex * 2;
    const ah = tey * 2;

    const minx = @max(ax, x);
    const miny = @max(ay, y);
    const maxx = @min(ax + aw, x + w);
    const maxy = @min(ay + ah, y + h);

    scissor(ctx, minx, miny, @max(0, maxx - minx), @max(0, maxy - miny));
}

pub fn resetScissor(ctx: *Context) void {
    ctx.state().scissor = .{
        .xform = .{ 0, 0, 0, 0, 0, 0 },
        .extent = .{ -1, -1 },
    };
}
