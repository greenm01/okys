//! Paint verbs and constructors. Paints are flat POD; shaders resolve them.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const color = @import("../types/color.zig");
const Color = color.Color;
const Paint = color.Paint;
const xforms = @import("../systems/transform.zig");

pub fn fillColor(ctx: *Context, c: Color) void {
    ctx.state().fill = color.solid(c);
}

pub fn strokeColor(ctx: *Context, c: Color) void {
    ctx.state().stroke = color.solid(c);
}

pub fn fillPaint(ctx: *Context, p: Paint) void {
    ctx.state().fill = p;
    xforms.multiply(&ctx.state().fill.xform, &ctx.state().xform);
}

pub fn strokePaint(ctx: *Context, p: Paint) void {
    ctx.state().stroke = p;
    xforms.multiply(&ctx.state().stroke.xform, &ctx.state().xform);
}

pub fn linearGradient(ctx: *Context, sx: f32, sy: f32, ex: f32, ey: f32, inner: Color, outer: Color) Paint {
    _ = ctx;
    const large = 1e5;
    var dx = ex - sx;
    var dy = ey - sy;
    const d = @sqrt(dx * dx + dy * dy);
    if (d > 0.0001) {
        dx /= d;
        dy /= d;
    } else {
        dx = 0;
        dy = 1;
    }

    return .{
        .xform = .{ dy, -dx, dx, dy, sx - dx * large, sy - dy * large },
        .extent = .{ large, large + d * 0.5 },
        .radius = 0,
        .feather = @max(@as(f32, 1), d),
        .inner_color = inner,
        .outer_color = outer,
        .image = 0,
    };
}

pub fn radialGradient(ctx: *Context, cx: f32, cy: f32, inner_radius: f32, outer_radius: f32, inner: Color, outer: Color) Paint {
    _ = ctx;
    const r = (inner_radius + outer_radius) * 0.5;
    const f = outer_radius - inner_radius;
    return .{
        .xform = .{ 1, 0, 0, 1, cx, cy },
        .extent = .{ r, r },
        .radius = r,
        .feather = @max(@as(f32, 1), f),
        .inner_color = inner,
        .outer_color = outer,
        .image = 0,
    };
}

pub fn boxGradient(ctx: *Context, x: f32, y: f32, w: f32, h: f32, radius: f32, feather: f32, inner: Color, outer: Color) Paint {
    _ = ctx;
    return .{
        .xform = .{ 1, 0, 0, 1, x + w * 0.5, y + h * 0.5 },
        .extent = .{ w * 0.5, h * 0.5 },
        .radius = radius,
        .feather = @max(@as(f32, 1), feather),
        .inner_color = inner,
        .outer_color = outer,
        .image = 0,
    };
}

pub fn imagePattern(ctx: *Context, ox: f32, oy: f32, ex: f32, ey: f32, angle: f32, image: i32, alpha: f32) Paint {
    _ = ctx;
    var xform = xforms.rotate(angle);
    xform[4] = ox;
    xform[5] = oy;
    const c = color.rgbaf(1, 1, 1, std.math.clamp(alpha, 0.0, 1.0));
    return .{
        .xform = xform,
        .extent = .{ ex, ey },
        .radius = 0,
        .feather = 0,
        .inner_color = c,
        .outer_color = c,
        .image = image,
    };
}
