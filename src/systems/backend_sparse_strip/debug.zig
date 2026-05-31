//! Sparse-strip diagnostic dumps. These helpers write human-readable packet
//! views to a caller-provided writer and do not own files or buffers.

const strip = @import("strip.zig");

pub fn writeTileSegments(writer: anytype, strips: []const strip.Strip, segment_indices: []const u32) !void {
    try writer.print("tile_x\ttile_y\tcall_index\tsegment_count\tsegment_indices\n", .{});
    for (strips) |s| {
        try writer.print("{}\t{}\t{}\t{}\t", .{ s.x, s.y, s.call_index, s.segment_indices.count });
        try writeRange(writer, segment_indices, s.segment_indices);
        try writer.print("\n", .{});
    }
}

pub fn writeStrips(writer: anytype, strips: []const strip.Strip) !void {
    try writer.print("strip_index\tx\ty\tcall_index\tsegment_start\tsegment_count\talpha_start\talpha_count\tflags\n", .{});
    for (strips, 0..) |s, i| {
        try writer.print(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
            .{
                i,
                s.x,
                s.y,
                s.call_index,
                s.segment_indices.start,
                s.segment_indices.count,
                s.alpha.start,
                s.alpha.count,
                s.flags,
            },
        );
    }
}

pub fn writeCoverage(writer: anytype, strips: []const strip.Strip, alphas: []const u8) !void {
    try writer.print("strip_index\tx\ty\tcall_index\trow\talphas\n", .{});
    for (strips, 0..) |s, i| {
        if (s.alpha.count != strip.tile_area) continue;
        const start: usize = @intCast(s.alpha.start);
        const end = start + strip.tile_area;
        if (end > alphas.len) continue;

        var row: u16 = 0;
        while (row < strip.tile_size) : (row += 1) {
            try writer.print("{}\t{}\t{}\t{}\t{}\t", .{ i, s.x, s.y, s.call_index, row });
            var col: u16 = 0;
            while (col < strip.tile_size) : (col += 1) {
                if (col > 0) try writer.print(",", .{});
                const index = start + @as(usize, row) * strip.tile_size + col;
                try writer.print("{}", .{alphas[index]});
            }
            try writer.print("\n", .{});
        }
    }
}

fn writeRange(writer: anytype, values: []const u32, range: strip.Range) !void {
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try writer.print(",", .{});
        const index = start + i;
        if (index < values.len) {
            try writer.print("{}", .{values[index]});
        } else {
            try writer.print("?", .{});
        }
    }
}
