//! Long-lived glyph atlas storage. This is intentionally just packing and CPU
//! RGBA bytes; ops/text_ops.zig owns backend texture uploads.

const std = @import("std");
const image = @import("../types/image.zig");
const text = @import("../types/text.zig");

const ImageId = image.ImageId;
const GlyphId = text.GlyphId;
const GlyphMetrics = text.GlyphMetrics;
const GlyphRecord = text.GlyphRecord;

pub const AddGlyphError = error{
    NotInitialized,
    InvalidGlyph,
    OutOfSpace,
    OutOfMemory,
};

pub const GlyphAtlas = struct {
    image_id: ImageId = .none,
    width: u32 = 0,
    height: u32 = 0,
    pixels: std.ArrayList(u8) = .empty,
    glyphs: std.ArrayList(GlyphRecord) = .empty,
    next_id: u32 = 1,
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    row_h: u32 = 0,

    const pad: u32 = 1;

    pub fn deinit(self: *GlyphAtlas, gpa: std.mem.Allocator) void {
        self.pixels.deinit(gpa);
        self.glyphs.deinit(gpa);
        self.* = .{};
    }

    pub fn initStorage(self: *GlyphAtlas, gpa: std.mem.Allocator, image_id: ImageId, width: u32, height: u32) !void {
        if (image_id == .none or width == 0 or height == 0) return error.InvalidGlyph;

        self.deinit(gpa);
        self.image_id = image_id;
        self.width = width;
        self.height = height;
        self.next_id = 1;
        try self.pixels.resize(gpa, byteLen(width, height));
        @memset(self.pixels.items, 0);
    }

    pub fn addGlyphAlpha(self: *GlyphAtlas, gpa: std.mem.Allocator, alpha: []const u8, width: u32, height: u32, metrics: GlyphMetrics) AddGlyphError!GlyphId {
        if (self.image_id == .none or self.width == 0 or self.height == 0) return error.NotInitialized;
        if (width == 0 or height == 0) return error.InvalidGlyph;
        if (alpha.len != @as(usize, width) * @as(usize, height)) return error.InvalidGlyph;

        const allocation = self.allocate(width, height) orelse return error.OutOfSpace;
        const id: GlyphId = @enumFromInt(self.next_id);
        self.next_id += 1;

        self.writeGlyph(alpha, width, height, allocation.x, allocation.y);
        try self.glyphs.append(gpa, .{
            .id = id,
            .atlas_x = allocation.x,
            .atlas_y = allocation.y,
            .width = width,
            .height = height,
            .draw_width = if (metrics.draw_width > 0) metrics.draw_width else @floatFromInt(width),
            .draw_height = if (metrics.draw_height > 0) metrics.draw_height else @floatFromInt(height),
            .offset_x = metrics.offset_x,
            .offset_y = metrics.offset_y,
            .advance_x = metrics.advance_x,
            .advance_y = metrics.advance_y,
        });
        return id;
    }

    pub fn get(self: *const GlyphAtlas, id: GlyphId) ?GlyphRecord {
        if (id == .none) return null;
        for (self.glyphs.items) |glyph| {
            if (glyph.id == id) return glyph;
        }
        return null;
    }

    const Allocation = struct {
        x: u32,
        y: u32,
    };

    fn allocate(self: *GlyphAtlas, width: u32, height: u32) ?Allocation {
        const padded_w = width + pad * 2;
        const padded_h = height + pad * 2;
        if (padded_w > self.width or padded_h > self.height) return null;

        if (self.cursor_x + padded_w > self.width) {
            self.cursor_x = 0;
            self.cursor_y += self.row_h;
            self.row_h = 0;
        }
        if (self.cursor_y + padded_h > self.height) return null;

        const allocation: Allocation = .{
            .x = self.cursor_x + pad,
            .y = self.cursor_y + pad,
        };
        self.cursor_x += padded_w;
        self.row_h = @max(self.row_h, padded_h);
        return allocation;
    }

    fn writeGlyph(self: *GlyphAtlas, alpha: []const u8, width: u32, height: u32, x: u32, y: u32) void {
        var row: u32 = 0;
        while (row < height) : (row += 1) {
            var col: u32 = 0;
            while (col < width) : (col += 1) {
                const src = @as(usize, row) * @as(usize, width) + col;
                const dst = (@as(usize, y + row) * @as(usize, self.width) + x + col) * 4;
                self.pixels.items[dst + 0] = 255;
                self.pixels.items[dst + 1] = 255;
                self.pixels.items[dst + 2] = 255;
                self.pixels.items[dst + 3] = alpha[src];
            }
        }
    }
};

fn byteLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * 4;
}
