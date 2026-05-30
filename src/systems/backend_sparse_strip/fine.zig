//! Scalar fine stage for the first sparse-strip proof.

const std = @import("std");
const encode = @import("encode.zig");
const strip = @import("strip.zig");

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    strip_segment_indices: []const u32,
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
        const start = alphas.items.len;
        var local_y: u16 = 0;
        while (local_y < strip.tile_size) : (local_y += 1) {
            var local_x: u16 = 0;
            while (local_x < strip.tile_size) : (local_x += 1) {
                const alpha = pixelCoverage(
                    fill_rule,
                    s.x + local_x,
                    s.y + local_y,
                    s.segment_indices,
                    strip_segment_indices,
                    segments,
                );
                try alphas.append(gpa, alpha);
                if (s.call_index < calls.len) {
                    compositeSolid(
                        calls[s.call_index],
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

fn compositeSolid(
    call: encode.EncodedCall,
    coverage_alpha: u8,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) void {
    if (coverage_alpha == 0 or !isSolidPaint(call)) return;
    if (x >= width or y >= height) return;

    const coverage = u8ToNorm(coverage_alpha);
    const c = call.paint.inner_color;
    const src_a = c.a * coverage;
    const src_r = c.r * src_a;
    const src_g = c.g * src_a;
    const src_b = c.b * src_a;

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

fn isSolidPaint(call: encode.EncodedCall) bool {
    const paint = call.paint;
    return paint.image == 0 and
        paint.inner_color.r == paint.outer_color.r and
        paint.inner_color.g == paint.outer_color.g and
        paint.inner_color.b == paint.outer_color.b and
        paint.inner_color.a == paint.outer_color.a;
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
