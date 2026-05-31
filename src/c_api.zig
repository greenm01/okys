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
const image_ops = @import("ops/image_ops.zig");
const paths = @import("ops/path_ops.zig");
const paint = @import("ops/paint_ops.zig");
const render_ops = @import("ops/render_ops.zig");
const state_ops = @import("ops/state_ops.zig");
const text_ops = @import("ops/text_ops.zig");
const TextGlyphPosition = text_ops.TextGlyphPosition;
const TextRow = text_ops.TextRow;

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

export fn okyLineDash(ctx: ?*Context, pattern: ?[*]const f32, count: c_int) void {
    if (ctx == null) return;
    if (pattern == null or count <= 0) {
        state_ops.lineDash(ctx.?, &.{});
        return;
    }
    const len = @min(@as(usize, @intCast(count)), state_ops.max_line_dashes);
    state_ops.lineDash(ctx.?, pattern.?[0..len]);
}

export fn okyLineDashOffset(ctx: ?*Context, offset: f32) void {
    if (ctx) |c| state_ops.lineDashOffset(c, offset);
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

// --- images ---------------------------------------------------------------

export fn okyCreateImageRGBA(ctx: ?*Context, w: c_int, h: c_int, data: ?[*]const u8) c_int {
    if (ctx == null or w <= 0 or h <= 0) return 0;

    const width: u32 = @intCast(w);
    const height: u32 = @intCast(h);
    const len = rgbaLen(width, height);
    const bytes: ?[]const u8 = if (data) |ptr| ptr[0..len] else null;
    return @intCast(@intFromEnum(image_ops.createImageRGBA(ctx.?, width, height, bytes)));
}

export fn okyUpdateImage(ctx: ?*Context, image: c_int, data: ?[*]const u8) void {
    if (ctx == null or image <= 0 or data == null) return;

    const id = imageIdFromInt(image);
    const size = image_ops.imageSize(ctx.?, id) orelse return;
    const len = rgbaLen(size[0], size[1]);
    image_ops.updateImage(ctx.?, id, data.?[0..len]);
}

export fn okyImageSize(ctx: ?*Context, image: c_int, w: ?*c_int, h: ?*c_int) void {
    if (w) |out_w| out_w.* = 0;
    if (h) |out_h| out_h.* = 0;
    if (ctx == null or image <= 0) return;

    const size = image_ops.imageSize(ctx.?, imageIdFromInt(image)) orelse return;
    if (w) |out_w| out_w.* = @intCast(size[0]);
    if (h) |out_h| out_h.* = @intCast(size[1]);
}

export fn okyDeleteImage(ctx: ?*Context, image: c_int) void {
    if (ctx == null or image <= 0) return;
    image_ops.deleteImage(ctx.?, imageIdFromInt(image));
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

// --- text ------------------------------------------------------------------

export fn okyCreateFont(ctx: ?*Context, name: ?[*]const u8, filename: ?[*]const u8) c_int {
    if (ctx == null or name == null or filename == null) return 0;
    return text_ops.createFont(ctx.?, stringSlice(name, null), stringSlice(filename, null));
}

export fn okyCreateFontMem(ctx: ?*Context, name: ?[*]const u8, data: ?[*]u8, ndata: c_int, free_data: c_int) c_int {
    defer {
        if (free_data != 0) {
            if (data) |ptr| std.c.free(@ptrCast(ptr));
        }
    }
    if (ctx == null or name == null or data == null or ndata <= 0) return 0;
    return text_ops.createFontMem(ctx.?, stringSlice(name, null), data.?[0..@intCast(ndata)]);
}

export fn okyFindFont(ctx: ?*Context, name: ?[*]const u8) c_int {
    if (ctx == null or name == null) return 0;
    return text_ops.findFont(ctx.?, stringSlice(name, null));
}

export fn okyFontSize(ctx: ?*Context, size: f32) void {
    if (ctx) |c| text_ops.fontSize(c, size);
}

export fn okyFontFaceId(ctx: ?*Context, font: c_int) void {
    if (ctx) |c| text_ops.fontFaceId(c, font);
}

export fn okyFontFace(ctx: ?*Context, font: ?[*]const u8) void {
    if (ctx == null or font == null) return;
    text_ops.fontFace(ctx.?, stringSlice(font, null));
}

export fn okyTextAlign(ctx: ?*Context, alignment: c_int) void {
    if (ctx) |c| text_ops.textAlign(c, alignment);
}

export fn okyTextLetterSpacing(ctx: ?*Context, spacing: f32) void {
    if (ctx) |c| text_ops.textLetterSpacing(c, spacing);
}

export fn okyTextLineHeight(ctx: ?*Context, line_height: f32) void {
    if (ctx) |c| text_ops.textLineHeight(c, line_height);
}

export fn okyText(ctx: ?*Context, x: f32, y: f32, string: ?[*]const u8, end: ?[*]const u8) f32 {
    if (ctx == null) return x;
    const bytes = stringSlice(string, end);
    return text_ops.text(ctx.?, x, y, bytes);
}

export fn okyTextBox(ctx: ?*Context, x: f32, y: f32, break_row_width: f32, string: ?[*]const u8, end: ?[*]const u8) void {
    if (ctx == null) return;
    const bytes = stringSlice(string, end);
    text_ops.textBox(ctx.?, x, y, break_row_width, bytes);
}

export fn okyTextGlyphPositions(ctx: ?*Context, x: f32, y: f32, string: ?[*]const u8, end: ?[*]const u8, positions: ?[*]TextGlyphPosition, max_positions: c_int) c_int {
    _ = y;
    if (ctx == null or positions == null or max_positions <= 0) return 0;
    const bytes = stringSlice(string, end);
    const len: usize = @intCast(max_positions);
    return text_ops.glyphPositions(ctx.?, x, bytes, positions.?[0..len]);
}

export fn okyTextMetrics(ctx: ?*Context, ascender: ?*f32, descender: ?*f32, lineh: ?*f32) void {
    if (ctx == null) return;
    const metrics = text_ops.textMetrics(ctx.?);
    if (ascender) |out| out.* = metrics.ascender;
    if (descender) |out| out.* = metrics.descender;
    if (lineh) |out| out.* = metrics.line_height;
}

export fn okyTextBreakLines(ctx: ?*Context, string: ?[*]const u8, end: ?[*]const u8, break_row_width: f32, rows: ?[*]TextRow, max_rows: c_int) c_int {
    if (ctx == null or rows == null or max_rows <= 0) return 0;
    const bytes = stringSlice(string, end);
    const len: usize = @intCast(max_rows);
    return text_ops.breakLines(ctx.?, bytes, break_row_width, rows.?[0..len]);
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

fn imageIdFromInt(id: c_int) @import("types/image.zig").ImageId {
    return @enumFromInt(@as(u32, @intCast(id)));
}

fn rgbaLen(w: u32, h: u32) usize {
    return @as(usize, w) * @as(usize, h) * 4;
}

fn stringSlice(string: ?[*]const u8, end: ?[*]const u8) []const u8 {
    const ptr = string orelse return &.{};
    const start_addr = @intFromPtr(ptr);
    if (end) |end_ptr| {
        const end_addr = @intFromPtr(end_ptr);
        if (end_addr <= start_addr) return &.{};
        return ptr[0 .. end_addr - start_addr];
    }

    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}
