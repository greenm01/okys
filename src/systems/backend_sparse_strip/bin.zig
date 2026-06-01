//! Assign encoded segments to fixed-size tiles.

const std = @import("std");
const encode = @import("encode.zig");
const strip = @import("strip.zig");

const max_bucket_sort_tiles: usize = 1_000_000;
const min_bucket_sort_tiles: usize = 65_536;

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
        const start: usize = @intCast(call.segments.start);
        const count: usize = @intCast(call.segments.count);
        for (segments[start..][0..count], 0..) |seg, offset| {
            try appendSegmentTiles(
                gpa,
                @intCast(call_index),
                @intCast(start + offset),
                seg,
                max_tile_x,
                max_tile_y,
                tiles,
            );
        }
    }

    try sortTiles(gpa, @intCast(max_tile_x + 1), @intCast(max_tile_y + 1), tiles);
}

fn appendSegmentTiles(
    gpa: std.mem.Allocator,
    call_index: u32,
    segment_index: u32,
    seg: encode.Segment,
    max_tile_x: i32,
    max_tile_y: i32,
    tiles: *std.ArrayList(strip.TileRef),
) !void {
    const min_y = @min(seg.y0, seg.y1);
    const max_y = @max(seg.y0, seg.y1);
    if (max_y <= min_y) {
        try appendHorizontalSegmentTiles(gpa, call_index, segment_index, seg, max_tile_x, max_tile_y, tiles);
        return;
    }

    var y_tile = std.math.clamp(strip.tileCoord(min_y), 0, max_tile_y);
    const y_end = std.math.clamp(strip.tileCoord(max_y - 0.001), 0, max_tile_y);
    const tile_size_f: f32 = @floatFromInt(strip.tile_size);

    while (y_tile <= y_end) : (y_tile += 1) {
        const row_top = @as(f32, @floatFromInt(y_tile)) * tile_size_f;
        const row_bottom = row_top + tile_size_f;
        const y0 = @max(min_y, row_top);
        const y1 = @min(max_y, row_bottom);
        if (y0 >= y1) continue;

        const x0 = xAt(seg, y0);
        const x1 = xAt(seg, y1);
        const left = @min(x0, x1);
        const right = @max(x0, x1);

        const x_start = std.math.clamp(tileCoordForStart(left, seg), 0, max_tile_x);
        const x_end = std.math.clamp(tileCoordForEnd(right, seg), 0, max_tile_x);
        if (x_start > x_end) continue;

        var x_tile = x_start;
        while (x_tile <= x_end) : (x_tile += 1) {
            try tiles.append(gpa, .{
                .x = @intCast(x_tile),
                .y = @intCast(y_tile),
                .call_index = call_index,
                .segment_index = segment_index,
                .flags = @intFromBool(seg.winding != 0),
            });
        }
    }
}

fn appendHorizontalSegmentTiles(
    gpa: std.mem.Allocator,
    call_index: u32,
    segment_index: u32,
    seg: encode.Segment,
    max_tile_x: i32,
    max_tile_y: i32,
    tiles: *std.ArrayList(strip.TileRef),
) !void {
    if (seg.x0 == seg.x1) return;

    const left = @min(seg.x0, seg.x1);
    const right = @max(seg.x0, seg.x1);
    const frame_width = @as(f32, @floatFromInt(max_tile_x + 1)) * @as(f32, @floatFromInt(strip.tile_size));
    const frame_height = @as(f32, @floatFromInt(max_tile_y + 1)) * @as(f32, @floatFromInt(strip.tile_size));
    if (right <= 0 or left >= frame_width or seg.y0 < 0 or seg.y0 >= frame_height) return;

    const x_start = std.math.clamp(strip.tileCoord(left), 0, max_tile_x);
    const x_end = std.math.clamp(strip.tileCoord(right - 0.001), 0, max_tile_x);
    if (x_start > x_end) return;

    const y_tile = std.math.clamp(strip.tileCoord(seg.y0 - 0.001), 0, max_tile_y);
    var x_tile = x_start;
    while (x_tile <= x_end) : (x_tile += 1) {
        try tiles.append(gpa, .{
            .x = @intCast(x_tile),
            .y = @intCast(y_tile),
            .call_index = call_index,
            .segment_index = segment_index,
            .flags = 0,
        });
    }
}

fn xAt(seg: encode.Segment, y: f32) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return seg.x0;
    const t = (y - seg.y0) / dy;
    return seg.x0 + t * (seg.x1 - seg.x0);
}

fn tileCoordForStart(x: f32, seg: encode.Segment) i32 {
    if (seg.x0 == seg.x1 and seg.winding < 0) return strip.tileCoord(x - 0.001);
    return strip.tileCoord(x);
}

fn tileCoordForEnd(x: f32, seg: encode.Segment) i32 {
    _ = seg;
    return strip.tileCoord(x - 0.001);
}

fn sortTiles(gpa: std.mem.Allocator, width_tiles: usize, height_tiles: usize, tiles: *std.ArrayList(strip.TileRef)) !void {
    if (!try bucketSortTiles(gpa, width_tiles, height_tiles, tiles)) {
        std.mem.sort(strip.TileRef, tiles.items, {}, lessThan);
    }
}

fn bucketSortTiles(gpa: std.mem.Allocator, width_tiles: usize, height_tiles: usize, tiles: *std.ArrayList(strip.TileRef)) !bool {
    if (tiles.items.len <= 1) return true;
    const tile_count = width_tiles * height_tiles;
    if (tile_count == 0 or tile_count > max_bucket_sort_tiles) return false;
    if (tile_count > @max(tiles.items.len * 4, min_bucket_sort_tiles)) return false;

    const buckets = try gpa.alloc(usize, tile_count);
    defer gpa.free(buckets);
    @memset(buckets, 0);

    for (tiles.items) |tile| {
        buckets[bucketIndex(width_tiles, tile)] += 1;
    }

    var running: usize = 0;
    for (buckets) |*bucket| {
        const count = bucket.*;
        bucket.* = running;
        running += count;
    }

    const sorted = try gpa.alloc(strip.TileRef, tiles.items.len);
    defer gpa.free(sorted);
    for (tiles.items) |tile| {
        const bucket = bucketIndex(width_tiles, tile);
        const out_index = buckets[bucket];
        sorted[out_index] = tile;
        buckets[bucket] = out_index + 1;
    }

    @memcpy(tiles.items, sorted);
    return true;
}

fn bucketIndex(width_tiles: usize, tile: strip.TileRef) usize {
    return @as(usize, tile.y) * width_tiles + tile.x;
}

fn lessThan(_: void, a: strip.TileRef, b: strip.TileRef) bool {
    if (a.y != b.y) return a.y < b.y;
    if (a.x != b.x) return a.x < b.x;
    if (a.call_index != b.call_index) return a.call_index < b.call_index;
    return a.segment_index < b.segment_index;
}

test "bucket tile sort matches comparison order for production append order" {
    const testing = std.testing;
    var tiles: std.ArrayList(strip.TileRef) = .empty;
    defer tiles.deinit(testing.allocator);

    const input = [_]strip.TileRef{
        .{ .x = 2, .y = 0, .call_index = 0, .segment_index = 0 },
        .{ .x = 0, .y = 0, .call_index = 0, .segment_index = 0 },
        .{ .x = 1, .y = 0, .call_index = 0, .segment_index = 1 },
        .{ .x = 0, .y = 0, .call_index = 0, .segment_index = 1 },
        .{ .x = 0, .y = 1, .call_index = 0, .segment_index = 2 },
        .{ .x = 0, .y = 0, .call_index = 1, .segment_index = 3 },
        .{ .x = 2, .y = 0, .call_index = 1, .segment_index = 3 },
    };
    try tiles.appendSlice(testing.allocator, &input);

    const expected = try testing.allocator.dupe(strip.TileRef, tiles.items);
    defer testing.allocator.free(expected);
    std.mem.sort(strip.TileRef, expected, {}, lessThan);

    try sortTiles(testing.allocator, 3, 2, &tiles);
    try testing.expectEqualSlices(strip.TileRef, expected, tiles.items);
}
