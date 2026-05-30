//! Scalar fine stage for the first sparse-strip proof.

const std = @import("std");
const encode = @import("encode.zig");
const strip = @import("strip.zig");

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    segments: []const encode.Segment,
    strip_segment_indices: []const u32,
    strips: *std.ArrayList(strip.Strip),
    alphas: *std.ArrayList(u8),
) !void {
    alphas.clearRetainingCapacity();
    for (strips.items) |*s| {
        const start = alphas.items.len;
        var local_y: u16 = 0;
        while (local_y < strip.tile_size) : (local_y += 1) {
            var local_x: u16 = 0;
            while (local_x < strip.tile_size) : (local_x += 1) {
                try alphas.append(gpa, pixelCoverage(
                    fill_rule,
                    s.x + local_x,
                    s.y + local_y,
                    s.segment_indices,
                    strip_segment_indices,
                    segments,
                ));
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
    const offsets = [_]f32{ 0.25, 0.75 };
    var covered: u8 = 0;
    for (offsets) |oy| {
        for (offsets) |ox| {
            const winding = windingAt(
                @as(f32, @floatFromInt(x)) + ox,
                @as(f32, @floatFromInt(y)) + oy,
                range,
                strip_segment_indices,
                segments,
            );
            covered += @intFromBool(filled(fill_rule, winding));
        }
    }
    return switch (covered) {
        0 => 0,
        1 => 64,
        2 => 128,
        3 => 192,
        else => 255,
    };
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
