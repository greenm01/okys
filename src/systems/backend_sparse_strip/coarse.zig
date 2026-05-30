//! Convert binned tile references into sparse strip records.

const std = @import("std");
const strip = @import("strip.zig");

pub fn build(
    gpa: std.mem.Allocator,
    tiles: []const strip.TileRef,
    strips: *std.ArrayList(strip.Strip),
    strip_segment_indices: *std.ArrayList(u32),
) !void {
    strips.clearRetainingCapacity();
    strip_segment_indices.clearRetainingCapacity();

    var i: usize = 0;
    while (i < tiles.len) {
        const tile = tiles[i];
        const start = strip_segment_indices.items.len;
        while (i < tiles.len and tiles[i].x == tile.x and tiles[i].y == tile.y and tiles[i].call_index == tile.call_index) : (i += 1) {
            try strip_segment_indices.append(gpa, tiles[i].segment_index);
        }

        try strips.append(gpa, .{
            .x = strip.tileOrigin(tile.x),
            .y = strip.tileOrigin(tile.y),
            .call_index = tile.call_index,
            .segment_indices = .{
                .start = @intCast(start),
                .count = @intCast(strip_segment_indices.items.len - start),
            },
            .alpha = .{},
        });
    }
}
