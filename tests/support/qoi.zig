//! Test-support QOI decoder. Codecs intentionally stay out of the okys core;
//! this keeps deterministic image fixtures available without adding a public
//! loader surface.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
        self.* = .{ .width = 0, .height = 0, .rgba = &.{} };
    }
};

const Pixel = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
};

const magic = "qoif";
const header_len = 14;
const end_marker = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
const max_pixels: usize = 16 * 1024 * 1024;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < header_len + end_marker.len) return error.InvalidData;
    if (!std.mem.eql(u8, data[0..4], magic)) return error.UnsupportedFormat;
    if (!std.mem.eql(u8, data[data.len - end_marker.len ..], &end_marker)) return error.InvalidData;

    const width = readBe32(data[4..8]);
    const height = readBe32(data[8..12]);
    const channels = data[12];
    if (width == 0 or height == 0) return error.InvalidData;
    if (channels != 3 and channels != 4) return error.InvalidData;

    const pixel_count = std.math.mul(usize, width, height) catch return error.ImageTooLarge;
    if (pixel_count > max_pixels) return error.ImageTooLarge;
    const rgba_len = std.math.mul(usize, pixel_count, 4) catch return error.ImageTooLarge;
    const rgba = try gpa.alloc(u8, rgba_len);
    errdefer gpa.free(rgba);

    var index = [_]Pixel{.{}} ** 64;
    var px: Pixel = .{};
    var in: usize = header_len;
    const chunks_end = data.len - end_marker.len;
    var out_pixel: usize = 0;

    while (out_pixel < pixel_count) {
        if (in >= chunks_end) return error.InvalidData;
        const b1 = data[in];
        in += 1;

        if (b1 == 0xfe) {
            if (chunks_end - in < 3) return error.InvalidData;
            px.r = data[in + 0];
            px.g = data[in + 1];
            px.b = data[in + 2];
            in += 3;
            writePixel(rgba, out_pixel, px);
            index[pixelHash(px)] = px;
            out_pixel += 1;
            continue;
        }

        if (b1 == 0xff) {
            if (chunks_end - in < 4) return error.InvalidData;
            px.r = data[in + 0];
            px.g = data[in + 1];
            px.b = data[in + 2];
            px.a = data[in + 3];
            in += 4;
            writePixel(rgba, out_pixel, px);
            index[pixelHash(px)] = px;
            out_pixel += 1;
            continue;
        }

        switch (b1 & 0xc0) {
            0x00 => {
                px = index[b1 & 0x3f];
                writePixel(rgba, out_pixel, px);
                out_pixel += 1;
            },
            0x40 => {
                px.r = addWrapping(px.r, @as(i16, @intCast((b1 >> 4) & 0x03)) - 2);
                px.g = addWrapping(px.g, @as(i16, @intCast((b1 >> 2) & 0x03)) - 2);
                px.b = addWrapping(px.b, @as(i16, @intCast(b1 & 0x03)) - 2);
                writePixel(rgba, out_pixel, px);
                index[pixelHash(px)] = px;
                out_pixel += 1;
            },
            0x80 => {
                if (in >= chunks_end) return error.InvalidData;
                const b2 = data[in];
                in += 1;
                const dg = @as(i16, @intCast(b1 & 0x3f)) - 32;
                const dr_dg = @as(i16, @intCast((b2 >> 4) & 0x0f)) - 8;
                const db_dg = @as(i16, @intCast(b2 & 0x0f)) - 8;
                px.r = addWrapping(px.r, dg + dr_dg);
                px.g = addWrapping(px.g, dg);
                px.b = addWrapping(px.b, dg + db_dg);
                writePixel(rgba, out_pixel, px);
                index[pixelHash(px)] = px;
                out_pixel += 1;
            },
            0xc0 => {
                const run = @as(usize, b1 & 0x3f) + 1;
                if (run > pixel_count - out_pixel) return error.InvalidData;
                var n: usize = 0;
                while (n < run) : (n += 1) {
                    writePixel(rgba, out_pixel, px);
                    out_pixel += 1;
                }
            },
            else => unreachable,
        }
    }

    if (in != chunks_end) return error.InvalidData;
    return .{ .width = width, .height = height, .rgba = rgba };
}

fn readBe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn writePixel(rgba: []u8, pixel_index: usize, px: Pixel) void {
    const out = pixel_index * 4;
    rgba[out + 0] = px.r;
    rgba[out + 1] = px.g;
    rgba[out + 2] = px.b;
    rgba[out + 3] = px.a;
}

fn addWrapping(value: u8, delta: i16) u8 {
    return @intCast(@mod(@as(i16, value) + delta, 256));
}

fn pixelHash(px: Pixel) usize {
    return (@as(usize, px.r) * 3 +
        @as(usize, px.g) * 5 +
        @as(usize, px.b) * 7 +
        @as(usize, px.a) * 11) % 64;
}
