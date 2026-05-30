//! The C ABI surface — seam 1. The only module that exports public symbols.
//! Signatures must match include/okys.h exactly. POD in, POD out; the context
//! is opaque to C; errors come back as sentinels (null), never Zig errors.

const std = @import("std");
const Context = @import("state/context.zig").Context;
const color = @import("types/color.zig");
const Color = color.Color;

const frame = @import("ops/frame_ops.zig");
const paths = @import("ops/path_ops.zig");
const paint = @import("ops/paint_ops.zig");
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

export fn okyClosePath(ctx: ?*Context) void {
    if (ctx) |c| paths.closePath(c);
}

export fn okyRect(ctx: ?*Context, x: f32, y: f32, w: f32, h: f32) void {
    if (ctx) |c| paths.rect(c, x, y, w, h);
}

// --- render ----------------------------------------------------------------

export fn okyFill(ctx: ?*Context) void {
    _ = ctx;
    // TODO (Milestone 1): flatten + hand the polylines to the backend's fill.
}

export fn okyStroke(ctx: ?*Context) void {
    _ = ctx;
    // TODO (Milestone 1): flatten + hand the outline to the backend's stroke.
}
