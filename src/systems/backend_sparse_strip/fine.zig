//! Scalar fine stage for the first sparse-strip proof.

const std = @import("std");
const color = @import("../../types/color.zig");
const image = @import("../../types/image.zig");
const encode = @import("encode.zig");
const strip = @import("strip.zig");
const xforms = @import("../transform.zig");

pub const Texture = struct {
    id: image.ImageId,
    width: u32,
    height: u32,
    format: image.TexFormat,
    pixels: []const u8,
};

const ColorF = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    strip_segment_indices: []const u32,
    textures: []const Texture,
    strips: *std.ArrayList(strip.Strip),
    alphas: *std.ArrayList(u8),
    surface: *std.ArrayList(u8),
) !void {
    alphas.clearRetainingCapacity();
    const width = pixelExtent(viewport_width);
    const height = pixelExtent(viewport_height);
    try surface.resize(gpa, @as(usize, width) * @as(usize, height) * 4);
    @memset(surface.items, 0);

    for (strips.items) |*s| {
        const call = if (s.call_index < calls.len) calls[s.call_index] else null;
        const call_fill_rule = if (call) |c| fillRuleForCall(fill_rule, c.kind) else fill_rule;
        const start = alphas.items.len;
        var local_y: u16 = 0;
        while (local_y < strip.tile_size) : (local_y += 1) {
            var local_x: u16 = 0;
            while (local_x < strip.tile_size) : (local_x += 1) {
                const alpha = pixelCoverage(
                    call_fill_rule,
                    s.x + local_x,
                    s.y + local_y,
                    s.segment_indices,
                    strip_segment_indices,
                    segments,
                );
                try alphas.append(gpa, alpha);
                if (call) |c| {
                    compositePaint(
                        c,
                        textures,
                        alpha,
                        s.x + local_x,
                        s.y + local_y,
                        width,
                        height,
                        surface.items,
                    );
                }
            }
        }
        s.alpha = .{ .start = @intCast(start), .count = strip.tile_area };
    }
}

pub fn coverageAt(
    fill_rule: strip.FillRule,
    px: f32,
    py: f32,
    segment_indices: []const u32,
    segments: []const encode.Segment,
) u8 {
    var winding: i32 = 0;
    for (segment_indices) |segment_index| {
        winding += crossingWinding(px, py, segments[segment_index]);
    }
    return if (filled(fill_rule, winding)) 255 else 0;
}

pub fn pixelCoverage(
    fill_rule: strip.FillRule,
    x: u16,
    y: u16,
    range: strip.Range,
    strip_segment_indices: []const u32,
    segments: []const encode.Segment,
) u8 {
    var area: f32 = 0;
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (strip_segment_indices[start..][0..count]) |segment_index| {
        area += segmentArea(px, py, segments[segment_index]);
    }
    return areaToAlpha(fill_rule, area);
}

fn windingAt(
    px: f32,
    py: f32,
    range: strip.Range,
    strip_segment_indices: []const u32,
    segments: []const encode.Segment,
) i32 {
    var winding: i32 = 0;
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (strip_segment_indices[start..][0..count]) |segment_index| {
        winding += crossingWinding(px, py, segments[segment_index]);
    }
    return winding;
}

fn crossingWinding(px: f32, py: f32, seg: encode.Segment) i32 {
    if (seg.y0 <= py and seg.y1 > py) {
        const x = intersectX(py, seg);
        if (x > px) return 1;
    } else if (seg.y1 <= py and seg.y0 > py) {
        const x = intersectX(py, seg);
        if (x > px) return -1;
    }
    return 0;
}

fn intersectX(py: f32, seg: encode.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return seg.x0;
    const t = (py - seg.y0) / dy;
    return seg.x0 + t * (seg.x1 - seg.x0);
}

fn filled(fill_rule: strip.FillRule, winding: i32) bool {
    return switch (fill_rule) {
        .nonzero => winding != 0,
        .even_odd => @mod(winding, 2) != 0,
    };
}

fn fillRuleForCall(default_rule: strip.FillRule, kind: strip.CallKind) strip.FillRule {
    return switch (kind) {
        .fill => default_rule,
        .stroke, .triangles => .nonzero,
    };
}

fn segmentArea(px: f32, py: f32, seg: encode.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return 0;

    const y0 = @max(@min(seg.y0, seg.y1), py);
    const y1 = @min(@max(seg.y0, seg.y1), py + 1);
    if (y0 >= y1) return 0;

    const slope = (seg.x1 - seg.x0) / dy;
    const intercept = seg.x0 - slope * seg.y0 - px;
    const sign: f32 = if (dy > 0) 1 else -1;
    return sign * integrateClampedLinear(slope, intercept, y0, y1);
}

fn integrateClampedLinear(slope: f32, intercept: f32, y0: f32, y1: f32) f32 {
    if (slope == 0) return (y1 - y0) * std.math.clamp(intercept, 0, 1);

    var stops = [_]f32{ y0, y1, 0, 0 };
    var count: usize = 2;
    addStop(&stops, &count, (0 - intercept) / slope, y0, y1);
    addStop(&stops, &count, (1 - intercept) / slope, y0, y1);
    std.mem.sort(f32, stops[0..count], {}, lessThanF32);

    var area: f32 = 0;
    var i: usize = 0;
    while (i + 1 < count) : (i += 1) {
        const a = stops[i];
        const b = stops[i + 1];
        if (a == b) continue;

        const mid = (a + b) * 0.5;
        const mid_value = slope * mid + intercept;
        if (mid_value <= 0) continue;
        if (mid_value >= 1) {
            area += b - a;
            continue;
        }

        const av = slope * a + intercept;
        const bv = slope * b + intercept;
        area += (av + bv) * 0.5 * (b - a);
    }

    return std.math.clamp(area, 0, y1 - y0);
}

fn addStop(stops: *[4]f32, count: *usize, value: f32, min: f32, max: f32) void {
    if (value <= min or value >= max) return;
    stops[count.*] = value;
    count.* += 1;
}

fn lessThanF32(_: void, a: f32, b: f32) bool {
    return a < b;
}

fn areaToAlpha(fill_rule: strip.FillRule, area: f32) u8 {
    const coverage = switch (fill_rule) {
        .nonzero => @min(@abs(area), 1),
        .even_odd => blk: {
            const folded = area - 2 * @floor(area * 0.5 + 0.5);
            break :blk @min(@abs(folded), 1);
        },
    };
    return normToU8(coverage);
}

fn compositePaint(
    call: encode.EncodedCall,
    textures: []const Texture,
    coverage_alpha: u8,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) void {
    if (coverage_alpha == 0) return;
    if (x >= width or y >= height) return;

    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const mask = u8ToNorm(coverage_alpha) * scissorMask(&call.scissor, px, py);
    if (mask <= 0) return;

    const c = resolvePaint(call, textures, px, py);
    const src_a = c.a * mask;
    const src_r = c.r * mask;
    const src_g = c.g * mask;
    const src_b = c.b * mask;

    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    const dst_r = u8ToNorm(surface[index + 0]);
    const dst_g = u8ToNorm(surface[index + 1]);
    const dst_b = u8ToNorm(surface[index + 2]);
    const dst_a = u8ToNorm(surface[index + 3]);
    const inv_a = 1 - src_a;

    surface[index + 0] = normToU8(src_r + dst_r * inv_a);
    surface[index + 1] = normToU8(src_g + dst_g * inv_a);
    surface[index + 2] = normToU8(src_b + dst_b * inv_a);
    surface[index + 3] = normToU8(src_a + dst_a * inv_a);
}

fn resolvePaint(call: encode.EncodedCall, textures: []const Texture, px: f32, py: f32) ColorF {
    const paint = call.paint;
    if (paint.image > 0) {
        if (findTexture(textures, @enumFromInt(@as(u32, @intCast(paint.image))))) |texture| {
            return sampleImagePattern(&paint, texture, px, py);
        }
        return .{};
    }

    const inv = xforms.inverse(&paint.xform) orelse xforms.identity();
    const pt = xforms.point(&inv, px, py);
    const feather = @max(paint.feather, 0.0001);
    const d = std.math.clamp((sdroundrect(pt, paint.extent, paint.radius) + feather * 0.5) / feather, 0, 1);
    return mixPremul(paint.inner_color, paint.outer_color, d);
}

fn sampleImagePattern(paint: *const color.Paint, texture: *const Texture, px: f32, py: f32) ColorF {
    if (texture.format != .rgba8 or texture.width == 0 or texture.height == 0 or texture.pixels.len < @as(usize, texture.width) * @as(usize, texture.height) * 4) {
        return .{};
    }

    const inv = xforms.inverse(&paint.xform) orelse xforms.identity();
    const pt = xforms.point(&inv, px, py);
    const sample = sampleWrappedLinear(texture, pt[0], pt[1], paint.extent);
    const alpha = sample.a * paint.inner_color.a;
    return .{
        .r = sample.r * alpha,
        .g = sample.g * alpha,
        .b = sample.b * alpha,
        .a = alpha,
    };
}

fn sampleWrappedLinear(texture: *const Texture, x: f32, y: f32, extent: [2]f32) ColorF {
    const tx = wrappedTexelCoord(x, extent[0], texture.width);
    const ty = wrappedTexelCoord(y, extent[1], texture.height);
    const c00 = texel(texture, tx.i0, ty.i0);
    const c10 = texel(texture, tx.i1, ty.i0);
    const c01 = texel(texture, tx.i0, ty.i1);
    const c11 = texel(texture, tx.i1, ty.i1);
    return mixColor(mixColor(c00, c10, tx.t), mixColor(c01, c11, tx.t), ty.t);
}

fn scissorMask(scissor: *const color.Scissor, px: f32, py: f32) f32 {
    if (scissor.extent[0] < 0 or scissor.extent[1] < 0) return 1;

    const inv = xforms.inverse(&scissor.xform) orelse return 0;
    const pt = xforms.point(&inv, px, py);
    var sx = @abs(pt[0]) - scissor.extent[0];
    var sy = @abs(pt[1]) - scissor.extent[1];
    const scale_x = @sqrt(scissor.xform[0] * scissor.xform[0] + scissor.xform[2] * scissor.xform[2]);
    const scale_y = @sqrt(scissor.xform[1] * scissor.xform[1] + scissor.xform[3] * scissor.xform[3]);
    sx = 0.5 - sx * scale_x;
    sy = 0.5 - sy * scale_y;
    return std.math.clamp(sx, 0, 1) * std.math.clamp(sy, 0, 1);
}

fn findTexture(textures: []const Texture, id: image.ImageId) ?*const Texture {
    for (textures) |*texture| {
        if (texture.id == id) return texture;
    }
    return null;
}

const WrappedTexelCoord = struct {
    i0: u32,
    i1: u32,
    t: f32,
};

fn wrappedTexelCoord(value: f32, extent: f32, size: u32) WrappedTexelCoord {
    if (size == 0) return .{ .i0 = 0, .i1 = 0, .t = 0 };
    const local_extent = if (@abs(extent) > 0.0001) @abs(extent) else @as(f32, @floatFromInt(size));
    const scaled = value / local_extent * @as(f32, @floatFromInt(size)) - 0.5;
    const base = @floor(scaled);
    const base_index: i32 = @intFromFloat(base);
    return .{
        .i0 = wrapIndex(base_index, size),
        .i1 = wrapIndex(base_index + 1, size),
        .t = scaled - base,
    };
}

fn wrapIndex(index: i32, size: u32) u32 {
    const size_i32: i32 = @intCast(size);
    return @intCast(@mod(index, size_i32));
}

fn texel(texture: *const Texture, x: u32, y: u32) ColorF {
    const index = (@as(usize, y) * @as(usize, texture.width) + x) * 4;
    return .{
        .r = u8ToNorm(texture.pixels[index + 0]),
        .g = u8ToNorm(texture.pixels[index + 1]),
        .b = u8ToNorm(texture.pixels[index + 2]),
        .a = u8ToNorm(texture.pixels[index + 3]),
    };
}

fn mixColor(a: ColorF, b: ColorF, t: f32) ColorF {
    const inv = 1 - t;
    return .{
        .r = a.r * inv + b.r * t,
        .g = a.g * inv + b.g * t,
        .b = a.b * inv + b.b * t,
        .a = a.a * inv + b.a * t,
    };
}

fn sdroundrect(pt: [2]f32, ext: [2]f32, rad: f32) f32 {
    const ext2 = [2]f32{ ext[0] - rad, ext[1] - rad };
    const dx = @abs(pt[0]) - ext2[0];
    const dy = @abs(pt[1]) - ext2[1];
    return @min(@max(dx, dy), 0) + @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0)) - rad;
}

fn mixPremul(inner: color.Color, outer: color.Color, t: f32) ColorF {
    const inv = 1 - t;
    return .{
        .r = inner.r * inner.a * inv + outer.r * outer.a * t,
        .g = inner.g * inner.a * inv + outer.g * outer.a * t,
        .b = inner.b * inner.a * inv + outer.b * outer.a * t,
        .a = inner.a * inv + outer.a * t,
    };
}

fn pixelExtent(value: f32) u32 {
    if (value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn u8ToNorm(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn normToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    return @intFromFloat(@floor(clamped * 255 + 0.5));
}
