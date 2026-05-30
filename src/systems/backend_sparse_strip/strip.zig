//! Sparse-strip records and constants shared by the CPU proof stages.

const std = @import("std");

pub const tile_size: u16 = 16;
pub const tile_area: u32 = tile_size * tile_size;

pub const FillRule = enum(u8) {
    nonzero,
    even_odd,
};

pub const CallKind = enum(u8) {
    fill,
    stroke,
    triangles,
};

pub const Range = extern struct {
    start: u32 = 0,
    count: u32 = 0,
};

pub const Strip = extern struct {
    x: u16 = 0,
    y: u16 = 0,
    call_index: u32 = 0,
    segment_indices: Range = .{},
    alpha: Range = .{},
};

pub const TileRef = extern struct {
    x: u16 = 0,
    y: u16 = 0,
    call_index: u32 = 0,
    segment_index: u32 = 0,
};

pub fn tileCoord(v: f32) i32 {
    return @intFromFloat(@floor(v / @as(f32, @floatFromInt(tile_size))));
}

pub fn tileOrigin(coord: u16) u16 {
    return coord * tile_size;
}

comptime {
    std.debug.assert(@sizeOf(Range) == 8);
    std.debug.assert(@offsetOf(Range, "start") == 0);
    std.debug.assert(@offsetOf(Range, "count") == 4);
    std.debug.assert(@sizeOf(TileRef) == 12);
    std.debug.assert(@offsetOf(TileRef, "x") == 0);
    std.debug.assert(@offsetOf(TileRef, "y") == 2);
    std.debug.assert(@offsetOf(TileRef, "call_index") == 4);
    std.debug.assert(@offsetOf(TileRef, "segment_index") == 8);
    std.debug.assert(@sizeOf(Strip) == 24);
    std.debug.assert(@offsetOf(Strip, "x") == 0);
    std.debug.assert(@offsetOf(Strip, "y") == 2);
    std.debug.assert(@offsetOf(Strip, "call_index") == 4);
    std.debug.assert(@offsetOf(Strip, "segment_indices") == 8);
    std.debug.assert(@offsetOf(Strip, "alpha") == 16);
}
