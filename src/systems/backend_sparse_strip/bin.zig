//! Assign encoded segments to fixed-size tiles.

const std = @import("std");
const encode = @import("encode.zig");
const strip = @import("strip.zig");

pub fn build(
    gpa: std.mem.Allocator,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    tiles: *std.ArrayList(strip.TileRef),
) !void {
    tiles.clearRetainingCapacity();
    if (viewport_width <= 0 or viewport_height <= 0) return;

    const max_tile_x = @max(strip.tileCoord(viewport_width - 0.001), 0);
    const max_tile_y = @max(strip.tileCoord(viewport_height - 0.001), 0);

    for (calls, 0..) |call, call_index| {
        if (call.segments.count == 0) continue;
        const bounds = callBounds(call, segments);

        var x0 = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
        const x1 = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);
        var y0 = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
        const y1 = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);

        while (y0 <= y1) : (y0 += 1) {
            x0 = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
            while (x0 <= x1) : (x0 += 1) {
                const start: usize = @intCast(call.segments.start);
                const count: usize = @intCast(call.segments.count);
                for (0..count) |offset| {
                    try tiles.append(gpa, .{
                        .x = @intCast(x0),
                        .y = @intCast(y0),
                        .call_index = @intCast(call_index),
                        .segment_index = @intCast(start + offset),
                    });
                }
            }
        }
    }

    std.mem.sort(strip.TileRef, tiles.items, {}, lessThan);
}

fn lessThan(_: void, a: strip.TileRef, b: strip.TileRef) bool {
    if (a.y != b.y) return a.y < b.y;
    if (a.x != b.x) return a.x < b.x;
    if (a.call_index != b.call_index) return a.call_index < b.call_index;
    return a.segment_index < b.segment_index;
}

fn callBounds(call: encode.EncodedCall, segments: []const encode.Segment) [4]f32 {
    if (call.bounds[0] < call.bounds[2] and call.bounds[1] < call.bounds[3]) {
        return call.bounds;
    }

    var bounds = [4]f32{ 1e6, 1e6, -1e6, -1e6 };
    const start: usize = @intCast(call.segments.start);
    const count: usize = @intCast(call.segments.count);
    for (segments[start..][0..count]) |seg| {
        bounds[0] = @min(bounds[0], @min(seg.x0, seg.x1));
        bounds[1] = @min(bounds[1], @min(seg.y0, seg.y1));
        bounds[2] = @max(bounds[2], @max(seg.x0, seg.x1));
        bounds[3] = @max(bounds[3], @max(seg.y0, seg.y1));
    }
    return bounds;
}
