//! The C ABI surface. The only module that exports public symbols. Signatures
//! must match include/okys.h exactly. POD in, POD out; the context is opaque to
//! C; errors come back as sentinels (null), never Zig errors.

const std = @import("std");
const Context = @import("state/context.zig").Context;
const color = @import("types/color.zig");
const Color = color.Color;
const Paint = color.Paint;
const Transform = color.Transform;
const draw_state = @import("state/draw_state.zig");
const LineCap = draw_state.LineCap;
const LineJoin = draw_state.LineJoin;
const Winding = @import("types/path.zig").Winding;

const frame = @import("ops/frame_ops.zig");
const paths = @import("ops/path_ops.zig");
const paint = @import("ops/paint_ops.zig");
const render_ops = @import("ops/render_ops.zig");
const state_ops = @import("ops/state_ops.zig");

const version_string = "0.0.0";
const abi_version: u32 = 0;

// --- version / abi ---------------------------------------------------------

export fn okyAbiVersion() u32 {
    return abi_version;
}

export fn okyVersionString() [*:0]const u8 {
    return version_string;
}

// --- lifecycle -------------------------------------------------------------

export fn okyCreate(flags: c_int) ?*Context {
    return Context.create(std.heap.c_allocator, @intCast(flags)) catch null;
}

export fn okyDelete(ctx: ?*Context) void {
    if (ctx) |c| c.destroy();
}

// --- frame -----------------------------------------------------------------

export fn okyBeginFrame(ctx: ?*Context, w: f32, h: f32, dpr: f32) void {
    if (ctx) |c| frame.beginFrame(c, w, h, dpr);
}

export fn okyEndFrame(ctx: ?*Context) void {
    if (ctx) |c| frame.endFrame(c);
}

export fn okyCancelFrame(ctx: ?*Context) void {
    if (ctx) |c| frame.cancelFrame(c);
}

// --- state stack -----------------------------------------------------------

export fn okySave(ctx: ?*Context) void {
    if (ctx) |c| state_ops.save(c);
}

export fn okyRestore(ctx: ?*Context) void {
    if (ctx) |c| state_ops.restore(c);
}

export fn okyReset(ctx: ?*Context) void {
    if (ctx) |c| state_ops.reset(c);
}

// --- style ----------------------------------------------------------------

export fn okyStrokeWidth(ctx: ?*Context, width: f32) void {
    if (ctx) |c| state_ops.strokeWidth(c, width);
}

export fn okyMiterLimit(ctx: ?*Context, limit: f32) void {
    if (ctx) |c| state_ops.miterLimit(c, limit);
}

export fn okyLineCap(ctx: ?*Context, cap: c_int) void {
    if (ctx) |c| state_ops.lineCap(c, lineCapFromInt(cap));
}

export fn okyLineJoin(ctx: ?*Context, join: c_int) void {
    if (ctx) |c| state_ops.lineJoin(c, lineJoinFromInt(join));
}

export fn okyGlobalAlpha(ctx: ?*Context, alpha: f32) void {
    if (ctx) |c| state_ops.globalAlpha(c, alpha);
}

// --- transforms -----------------------------------------------------------

export fn okyResetTransform(ctx: ?*Context) void {
    if (ctx) |c| state_ops.resetTransform(c);
}

export fn okyTransform(ctx: ?*Context, a: f32, b: f32, c_: f32, d: f32, e: f32, f: f32) void {
    if (ctx) |c| state_ops.transform(c, a, b, c_, d, e, f);
}

export fn okyTranslate(ctx: ?*Context, x: f32, y: f32) void {
    if (ctx) |c| state_ops.translate(c, x, y);
}

export fn okyRotate(ctx: ?*Context, angle: f32) void {
    if (ctx) |c| state_ops.rotate(c, angle);
}

export fn okyScale(ctx: ?*Context, x: f32, y: f32) void {
    if (ctx) |c| state_ops.scale(c, x, y);
}

export fn okySkewX(ctx: ?*Context, angle: f32) void {
    if (ctx) |c| state_ops.skewX(c, angle);
}

export fn okySkewY(ctx: ?*Context, angle: f32) void {
    if (ctx) |c| state_ops.skewY(c, angle);
}

export fn okyCurrentTransform(ctx: ?*Context, dst: ?[*]f32) void {
    if (ctx == null or dst == null) return;
    const t: Transform = state_ops.currentTransform(ctx.?);
    for (t, 0..) |v, i| dst.?[i] = v;
}

// --- color helpers (pure) --------------------------------------------------

export fn okyRGBA(r: u8, g: u8, b: u8, a: u8) Color {
    return color.rgba(r, g, b, a);
}

export fn okyRGBAf(r: f32, g: f32, b: f32, a: f32) Color {
    return color.rgbaf(r, g, b, a);
}

// --- paints ----------------------------------------------------------------

export fn okyFillColor(ctx: ?*Context, col: Color) void {
    if (ctx) |c| paint.fillColor(c, col);
}

export fn okyStrokeColor(ctx: ?*Context, col: Color) void {
    if (ctx) |c| paint.strokeColor(c, col);
}

export fn okyFillPaint(ctx: ?*Context, p: Paint) void {
    if (ctx) |c| paint.fillPaint(c, p);
}

export fn okyStrokePaint(ctx: ?*Context, p: Paint) void {
    if (ctx) |c| paint.strokePaint(c, p);
}

export fn okyLinearGradient(ctx: ?*Context, sx: f32, sy: f32, ex: f32, ey: f32, inner: Color, outer: Color) Paint {
    if (ctx) |c| return paint.linearGradient(c, sx, sy, ex, ey, inner, outer);
    return std.mem.zeroes(Paint);
}

export fn okyRadialGradient(ctx: ?*Context, cx: f32, cy: f32, inner_radius: f32, outer_radius: f32, inner: Color, outer: Color) Paint {
    if (ctx) |c| return paint.radialGradient(c, cx, cy, inner_radius, outer_radius, inner, outer);
    return std.mem.zeroes(Paint);
}

export fn okyBoxGradient(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32, radius: f32, feather: f32, inner: Color, outer: Color) Paint {
    if (ctx) |c| return paint.boxGradient(c, x, y, w, h, radius, feather, inner, outer);
    return std.mem.zeroes(Paint);
}

export fn okyImagePattern(ctx: ?*Context, ox: f32, oy: f32, ex: f32, ey: f32, angle: f32, image: c_int, alpha: f32) Paint {
    if (ctx) |c| return paint.imagePattern(c, ox, oy, ex, ey, angle, @intCast(image), alpha);
    return std.mem.zeroes(Paint);
}

// --- scissor ---------------------------------------------------------------

export fn okyScissor(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32) void {
    if (ctx) |c| state_ops.scissor(c, x, y, w, h);
}

export fn okyIntersectScissor(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32) void {
    if (ctx) |c| state_ops.intersectScissor(c, x, y, w, h);
}

export fn okyResetScissor(ctx: ?*Context) void {
    if (ctx) |c| state_ops.resetScissor(c);
}

// --- path building ---------------------------------------------------------

export fn okyBeginPath(ctx: ?*Context) void {
    if (ctx) |c| paths.beginPath(c);
}

export fn okyMoveTo(ctx: ?*Context, x: f32, y: f32) void {
    if (ctx) |c| paths.moveTo(c, x, y);
}

export fn okyLineTo(ctx: ?*Context, x: f32, y: f32) void {
    if (ctx) |c| paths.lineTo(c, x, y);
}

export fn okyBezierTo(ctx: ?*Context, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
    if (ctx) |c| paths.bezierTo(c, c1x, c1y, c2x, c2y, x, y);
}

export fn okyQuadTo(ctx: ?*Context, cx: f32, cy: f32, x: f32, y: f32) void {
    if (ctx) |c| paths.quadTo(c, cx, cy, x, y);
}

export fn okyArcTo(ctx: ?*Context, x1: f32, y1: f32, x2: f32, y2: f32, radius: f32) void {
    if (ctx) |c| paths.arcTo(c, x1, y1, x2, y2, radius);
}

export fn okyClosePath(ctx: ?*Context) void {
    if (ctx) |c| paths.closePath(c);
}

export fn okyPathWinding(ctx: ?*Context, dir: c_int) void {
    if (ctx) |c| paths.pathWinding(c, windingFromInt(dir));
}

export fn okyArc(ctx: ?*Context, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, dir: c_int) void {
    if (ctx) |c| paths.arc(c, cx, cy, r, a0, a1, windingFromInt(dir));
}

export fn okyRect(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32) void {
    if (ctx) |c| paths.rect(c, x, y, w, h);
}

export fn okyRoundedRect(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32, radius: f32) void {
    if (ctx) |c| paths.roundedRect(c, x, y, w, h, radius);
}

export fn okyRoundedRectVarying(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32, rtl: f32, rtr: f32, rbr: f32, rbl: f32) void {
    if (ctx) |c| paths.roundedRectVarying(c, x, y, w, h, rtl, rtr, rbr, rbl);
}

export fn okyEllipse(ctx: ?*Context, cx: f32, cy: f32, rx: f32, ry: f32) void {
    if (ctx) |c| paths.ellipse(c, cx, cy, rx, ry);
}

export fn okyCircle(ctx: ?*Context, cx: f32, cy: f32, r: f32) void {
    if (ctx) |c| paths.circle(c, cx, cy, r);
}

// --- render ----------------------------------------------------------------

export fn okyFill(ctx: ?*Context) void {
    if (ctx) |c| render_ops.fill(c);
}

export fn okyStroke(ctx: ?*Context) void {
    if (ctx) |c| render_ops.stroke(c);
}

fn lineCapFromInt(cap: c_int) LineCap {
    return switch (cap) {
        1 => .round,
        2 => .square,
        else => .butt,
    };
}

fn lineJoinFromInt(join: c_int) LineJoin {
    return switch (join) {
        1 => .round,
        2 => .bevel,
        else => .miter,
    };
}

fn windingFromInt(dir: c_int) Winding {
    return switch (dir) {
        2 => .cw,
        else => .ccw,
    };
}
