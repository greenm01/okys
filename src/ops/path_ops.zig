//! Path-building verbs. Each appends to the command stream; flattening happens
//! later, in systems/flatten.zig. Coordinates are transformed on append.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const Winding = @import("../types/path.zig").Winding;
const xforms = @import("../systems/transform.zig");

const kappa90: f32 = 0.5522847493;
const dist_tol: f32 = 0.01;

pub fn beginPath(ctx: *Context) void {
    ctx.commands.clear();
    ctx.cache.clear();
}

pub fn moveTo(ctx: *Context, x: f32, y: f32) void {
    const p = xforms.point(&ctx.state().xform, x, y);
    ctx.commands.tag(ctx.gpa, .move_to);
    ctx.commands.float(ctx.gpa, p[0]);
    ctx.commands.float(ctx.gpa, p[1]);
    ctx.command_x = x;
    ctx.command_y = y;
    ctx.cache.clear();
}

pub fn lineTo(ctx: *Context, x: f32, y: f32) void {
    const p = xforms.point(&ctx.state().xform, x, y);
    ctx.commands.tag(ctx.gpa, .line_to);
    ctx.commands.float(ctx.gpa, p[0]);
    ctx.commands.float(ctx.gpa, p[1]);
    ctx.command_x = x;
    ctx.command_y = y;
    ctx.cache.clear();
}

pub fn bezierTo(ctx: *Context, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
    const c1 = xforms.point(&ctx.state().xform, c1x, c1y);
    const c2 = xforms.point(&ctx.state().xform, c2x, c2y);
    const p = xforms.point(&ctx.state().xform, x, y);
    ctx.commands.tag(ctx.gpa, .bezier_to);
    ctx.commands.float(ctx.gpa, c1[0]);
    ctx.commands.float(ctx.gpa, c1[1]);
    ctx.commands.float(ctx.gpa, c2[0]);
    ctx.commands.float(ctx.gpa, c2[1]);
    ctx.commands.float(ctx.gpa, p[0]);
    ctx.commands.float(ctx.gpa, p[1]);
    ctx.command_x = x;
    ctx.command_y = y;
    ctx.cache.clear();
}

pub fn quadTo(ctx: *Context, cx: f32, cy: f32, x: f32, y: f32) void {
    const x0 = ctx.command_x;
    const y0 = ctx.command_y;
    bezierTo(
        ctx,
        x0 + 2.0 / 3.0 * (cx - x0),
        y0 + 2.0 / 3.0 * (cy - y0),
        x + 2.0 / 3.0 * (cx - x),
        y + 2.0 / 3.0 * (cy - y),
        x,
        y,
    );
}

pub fn arcTo(ctx: *Context, x1: f32, y1: f32, x2: f32, y2: f32, radius: f32) void {
    const x0 = ctx.command_x;
    const y0 = ctx.command_y;
    if (ctx.commands.data.items.len == 0) return;

    if (ptEquals(x0, y0, x1, y1) or
        ptEquals(x1, y1, x2, y2) or
        distPtSeg(x1, y1, x0, y0, x2, y2) < dist_tol * dist_tol or
        radius < dist_tol)
    {
        lineTo(ctx, x1, y1);
        return;
    }

    var dx0 = x0 - x1;
    var dy0 = y0 - y1;
    var dx1 = x2 - x1;
    var dy1 = y2 - y1;
    _ = normalize(&dx0, &dy0);
    _ = normalize(&dx1, &dy1);
    const dot = std.math.clamp(dx0 * dx1 + dy0 * dy1, -1.0, 1.0);
    const a = std.math.acos(dot);
    const d = radius / @tan(a / 2.0);
    if (d > 10000.0) {
        lineTo(ctx, x1, y1);
        return;
    }

    if (cross(dx0, dy0, dx1, dy1) > 0.0) {
        arc(
            ctx,
            x1 + dx0 * d + dy0 * radius,
            y1 + dy0 * d - dx0 * radius,
            radius,
            std.math.atan2(dx0, -dy0),
            std.math.atan2(-dx1, dy1),
            .cw,
        );
    } else {
        arc(
            ctx,
            x1 + dx0 * d - dy0 * radius,
            y1 + dy0 * d + dx0 * radius,
            radius,
            std.math.atan2(-dx0, dy0),
            std.math.atan2(dx1, -dy1),
            .ccw,
        );
    }
}

pub fn closePath(ctx: *Context) void {
    ctx.commands.tag(ctx.gpa, .close);
    ctx.cache.clear();
}

pub fn pathWinding(ctx: *Context, dir: Winding) void {
    ctx.commands.tag(ctx.gpa, .winding);
    ctx.commands.float(ctx.gpa, @floatFromInt(@intFromEnum(dir)));
    ctx.cache.clear();
}

pub fn arc(ctx: *Context, cx: f32, cy: f32, r: f32, a0: f32, a1: f32, dir: Winding) void {
    const started = ctx.commands.data.items.len > 0;

    var da = a1 - a0;
    if (dir == .cw) {
        if (@abs(da) >= std.math.pi * 2.0) {
            da = std.math.pi * 2.0;
        } else {
            while (da < 0.0) da += std.math.pi * 2.0;
        }
    } else {
        if (@abs(da) >= std.math.pi * 2.0) {
            da = -std.math.pi * 2.0;
        } else {
            while (da > 0.0) da -= std.math.pi * 2.0;
        }
    }

    const ndivs_float = std.math.clamp(@round(@abs(da) / (std.math.pi * 0.5)), 1, 5);
    const ndivs: u32 = @intFromFloat(ndivs_float);
    const hda = (da / @as(f32, @floatFromInt(ndivs))) / 2.0;
    var kappa = @abs(4.0 / 3.0 * (1.0 - @cos(hda)) / @sin(hda));
    if (dir == .ccw) kappa = -kappa;

    var px: f32 = 0;
    var py: f32 = 0;
    var ptanx: f32 = 0;
    var ptany: f32 = 0;
    var i: u32 = 0;
    while (i <= ndivs) : (i += 1) {
        const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ndivs));
        const a = a0 + da * u;
        const dx = @cos(a);
        const dy = @sin(a);
        const x = cx + dx * r;
        const y = cy + dy * r;
        const tanx = -dy * r * kappa;
        const tany = dx * r * kappa;

        if (i == 0) {
            if (started) {
                lineTo(ctx, x, y);
            } else {
                moveTo(ctx, x, y);
            }
        } else {
            bezierTo(ctx, px + ptanx, py + ptany, x - tanx, y - tany, x, y);
        }
        px = x;
        py = y;
        ptanx = tanx;
        ptany = tany;
    }
}

pub fn rect(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
    moveTo(ctx, x, y);
    lineTo(ctx, x, y + h);
    lineTo(ctx, x + w, y + h);
    lineTo(ctx, x + w, y);
    closePath(ctx);
}

pub fn roundedRect(ctx: *Context, x: f32, y: f32, w: f32, h: f32, r: f32) void {
    roundedRectVarying(ctx, x, y, w, h, r, r, r, r);
}

pub fn roundedRectVarying(ctx: *Context, x: f32, y: f32, w: f32, h: f32, rtl: f32, rtr: f32, rbr: f32, rbl: f32) void {
    if (rtl < 0.1 and rtr < 0.1 and rbr < 0.1 and rbl < 0.1) {
        rect(ctx, x, y, w, h);
        return;
    }

    const halfw = @abs(w) * 0.5;
    const halfh = @abs(h) * 0.5;
    const rxbl = @min(rbl, halfw) * sign(w);
    const rybl = @min(rbl, halfh) * sign(h);
    const rxbr = @min(rbr, halfw) * sign(w);
    const rybr = @min(rbr, halfh) * sign(h);
    const rxtr = @min(rtr, halfw) * sign(w);
    const rytr = @min(rtr, halfh) * sign(h);
    const rxtl = @min(rtl, halfw) * sign(w);
    const rytl = @min(rtl, halfh) * sign(h);

    moveTo(ctx, x, y + rytl);
    lineTo(ctx, x, y + h - rybl);
    bezierTo(ctx, x, y + h - rybl * (1 - kappa90), x + rxbl * (1 - kappa90), y + h, x + rxbl, y + h);
    lineTo(ctx, x + w - rxbr, y + h);
    bezierTo(ctx, x + w - rxbr * (1 - kappa90), y + h, x + w, y + h - rybr * (1 - kappa90), x + w, y + h - rybr);
    lineTo(ctx, x + w, y + rytr);
    bezierTo(ctx, x + w, y + rytr * (1 - kappa90), x + w - rxtr * (1 - kappa90), y, x + w - rxtr, y);
    lineTo(ctx, x + rxtl, y);
    bezierTo(ctx, x + rxtl * (1 - kappa90), y, x, y + rytl * (1 - kappa90), x, y + rytl);
    closePath(ctx);
}

pub fn ellipse(ctx: *Context, cx: f32, cy: f32, rx: f32, ry: f32) void {
    moveTo(ctx, cx - rx, cy);
    bezierTo(ctx, cx - rx, cy + ry * kappa90, cx - rx * kappa90, cy + ry, cx, cy + ry);
    bezierTo(ctx, cx + rx * kappa90, cy + ry, cx + rx, cy + ry * kappa90, cx + rx, cy);
    bezierTo(ctx, cx + rx, cy - ry * kappa90, cx + rx * kappa90, cy - ry, cx, cy - ry);
    bezierTo(ctx, cx - rx * kappa90, cy - ry, cx - rx, cy - ry * kappa90, cx - rx, cy);
    closePath(ctx);
}

pub fn circle(ctx: *Context, cx: f32, cy: f32, r: f32) void {
    ellipse(ctx, cx, cy, r, r);
}

fn ptEquals(x1: f32, y1: f32, x2: f32, y2: f32) bool {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return dx * dx + dy * dy < dist_tol * dist_tol;
}

fn distPtSeg(x: f32, y: f32, px: f32, py: f32, qx: f32, qy: f32) f32 {
    const pqx = qx - px;
    const pqy = qy - py;
    var d = pqx * pqx + pqy * pqy;
    var t = pqx * (x - px) + pqy * (y - py);
    if (d > 0) t /= d;
    if (t < 0) {
        d = (x - px) * (x - px) + (y - py) * (y - py);
    } else if (t > 1) {
        d = (x - qx) * (x - qx) + (y - qy) * (y - qy);
    } else {
        const ix = px + t * pqx;
        const iy = py + t * pqy;
        d = (x - ix) * (x - ix) + (y - iy) * (y - iy);
    }
    return d;
}

fn normalize(x: *f32, y: *f32) f32 {
    const d = @sqrt(x.* * x.* + y.* * y.*);
    if (d > 1e-6) {
        const id = 1.0 / d;
        x.* *= id;
        y.* *= id;
    }
    return d;
}

fn cross(dx0: f32, dy0: f32, dx1: f32, dy1: f32) f32 {
    return dx1 * dy0 - dx0 * dy1;
}

fn sign(v: f32) f32 {
    return if (v >= 0) 1 else -1;
}
