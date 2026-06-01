const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const qoi = okys.systems.qoi;

const marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

test "QOI decoder handles RGB RGBA index diff luma and run chunks" {
    const data = [_]u8{
        'q',  'o',  'i',  'f',
        0,    0,    0,    6,
        0,    0,    0,    1,
        4,    0,    0xfe, 10,
        20,   30,   0x79, 0xa2,
        0x79, 0xff, 1,    2,
        3,    4,    0x09, 0xc0,
    } ++ marker;

    var image = try qoi.decode(testing.allocator, &data);
    defer image.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 6), image.width);
    try testing.expectEqual(@as(u32, 1), image.height);
    try expectPixel(image.rgba, 0, .{ 10, 20, 30, 255 });
    try expectPixel(image.rgba, 1, .{ 11, 20, 29, 255 });
    try expectPixel(image.rgba, 2, .{ 12, 22, 32, 255 });
    try expectPixel(image.rgba, 3, .{ 1, 2, 3, 4 });
    try expectPixel(image.rgba, 4, .{ 10, 20, 30, 255 });
    try expectPixel(image.rgba, 5, .{ 10, 20, 30, 255 });
}

test "QOI RGB chunks emit opaque alpha" {
    const data = [_]u8{
        'q', 'o', 'i',  'f',
        0,   0,   0,    1,
        0,   0,   0,    1,
        3,   0,   0xfe, 8,
        9,   10,
    } ++ marker;

    var image = try qoi.decode(testing.allocator, &data);
    defer image.deinit(testing.allocator);
    try expectPixel(image.rgba, 0, .{ 8, 9, 10, 255 });
}

test "QOI decoder rejects malformed data" {
    const bad_magic = [_]u8{
        'b', 'a', 'd',  '!',
        0,   0,   0,    1,
        0,   0,   0,    1,
        4,   0,   0xc0,
    } ++ marker;
    try testing.expectError(error.UnsupportedFormat, qoi.decode(testing.allocator, &bad_magic));

    const truncated = [_]u8{
        'q', 'o', 'i',  'f',
        0,   0,   0,    1,
        0,   0,   0,    1,
        4,   0,   0xff, 1,
        2,
    } ++ marker;
    try testing.expectError(error.InvalidData, qoi.decode(testing.allocator, &truncated));

    const zero_width = [_]u8{
        'q', 'o', 'i',  'f',
        0,   0,   0,    0,
        0,   0,   0,    1,
        4,   0,   0xc0,
    } ++ marker;
    try testing.expectError(error.InvalidData, qoi.decode(testing.allocator, &zero_width));

    const too_large = [_]u8{
        'q',  'o',  'i',  'f',
        0x7f, 0xff, 0xff, 0xff,
        0x7f, 0xff, 0xff, 0xff,
        4,    0,    0xc0,
    } ++ marker;
    try testing.expectError(error.ImageTooLarge, qoi.decode(testing.allocator, &too_large));
}

fn expectPixel(rgba: []const u8, index: usize, expected: [4]u8) !void {
    const start = index * 4;
    try testing.expectEqualSlices(u8, &expected, rgba[start..][0..4]);
}
