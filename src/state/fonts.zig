//! Font storage and Tatfi adapter. Public text APIs never expose Tatfi types;
//! this module owns font bytes and maps parser data into Okys metrics.

const std = @import("std");
const tatfi = @import("tatfi");
const text = @import("../types/text.zig");

const max_font_bytes = 64 * 1024 * 1024;
const max_raster_pixels = 1024 * 1024;
const curve_steps = 14;
const sample_grid = 4;

pub const ScaledMetrics = struct {
    ascender: f32,
    descender: f32,
    line_height: f32,
};

pub const ResolvedGlyph = struct {
    font_id: i32,
    glyph_id: tatfi.GlyphId,
    advance_x: f32,
};

pub const RasterizedGlyph = struct {
    alpha: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    metrics: text.GlyphMetrics = .{},

    pub fn deinit(self: *RasterizedGlyph, gpa: std.mem.Allocator) void {
        gpa.free(self.alpha);
        self.* = .{};
    }
};

pub const CachedGlyph = struct {
    font_id: i32,
    codepoint: u21,
    size_bits: u32,
    dpr_bits: u32,
    glyph: text.GlyphId,
    advance_x: f32,
};

pub const FontStore = struct {
    fonts: std.ArrayList(FontRecord) = .empty,
    glyph_cache: std.ArrayList(CachedGlyph) = .empty,
    next_id: i32 = 1,

    pub fn deinit(self: *FontStore, gpa: std.mem.Allocator) void {
        for (self.fonts.items) |*font| font.deinit(gpa);
        self.fonts.deinit(gpa);
        self.glyph_cache.deinit(gpa);
        self.* = .{};
    }

    pub fn createFont(self: *FontStore, gpa: std.mem.Allocator, name: []const u8, filename: []const u8) !i32 {
        const data = try readFontFile(gpa, filename);
        errdefer gpa.free(data);
        return try self.createFontOwned(gpa, name, data);
    }

    pub fn createFontMem(self: *FontStore, gpa: std.mem.Allocator, name: []const u8, data: []const u8) !i32 {
        const owned = try gpa.dupe(u8, data);
        errdefer gpa.free(owned);
        return try self.createFontOwned(gpa, name, owned);
    }

    pub fn findFont(self: *const FontStore, name: []const u8) i32 {
        for (self.fonts.items) |font| {
            if (std.mem.eql(u8, font.name, name)) return font.id;
        }
        return 0;
    }

    pub fn hasFont(self: *const FontStore, id: i32) bool {
        return self.record(id) != null;
    }

    pub fn metrics(self: *const FontStore, gpa: std.mem.Allocator, id: i32, size: f32, line_height: f32) ?ScaledMetrics {
        _ = gpa;
        const font = self.record(id) orelse return null;
        const face = font.face() orelse return null;
        const scale = scaleFor(face, size);
        const ascender = @as(f32, @floatFromInt(face.ascender())) * scale;
        const descender = @as(f32, @floatFromInt(face.descender())) * scale;
        const line_gap = @as(f32, @floatFromInt(face.line_gap())) * scale;
        return .{
            .ascender = ascender,
            .descender = descender,
            .line_height = (ascender - descender + line_gap) * line_height,
        };
    }

    pub fn glyphAdvance(self: *const FontStore, gpa: std.mem.Allocator, id: i32, size: f32, codepoint: u21) ?f32 {
        return (self.resolveGlyph(gpa, id, size, codepoint) orelse return null).advance_x;
    }

    pub fn resolveGlyph(self: *const FontStore, gpa: std.mem.Allocator, id: i32, size: f32, codepoint: u21) ?ResolvedGlyph {
        const font = self.record(id) orelse return null;
        var face = font.face() orelse return null;
        const glyph_id = face.glyph_index(codepoint) orelse return null;
        const advance = face.glyph_hor_advance(gpa, glyph_id) orelse return null;
        return .{
            .font_id = font.id,
            .glyph_id = glyph_id,
            .advance_x = @as(f32, @floatFromInt(advance)) * scaleFor(face, size),
        };
    }

    pub fn rasterizeGlyph(self: *const FontStore, gpa: std.mem.Allocator, resolved: ResolvedGlyph, size: f32, dpr: f32) !RasterizedGlyph {
        const font = self.record(resolved.font_id) orelse return error.InvalidFont;
        var face = font.face() orelse return error.InvalidFont;
        const scale_px = scaleFor(face, size * dpr);
        if (scale_px <= 0) return error.InvalidFontSize;

        var outline: OutlineCollector = .{ .gpa = gpa };
        defer outline.deinit(gpa);
        const builder = outline.builder();
        const bbox = face.outline_glyph(gpa, resolved.glyph_id, builder) orelse {
            return .{ .metrics = .{ .advance_x = resolved.advance_x } };
        };
        if (outline.segments.items.len == 0 or bbox.x_max <= bbox.x_min or bbox.y_max <= bbox.y_min) {
            return .{ .metrics = .{ .advance_x = resolved.advance_x } };
        }

        const min_x = @floor(@as(f32, @floatFromInt(bbox.x_min)) * scale_px) - 1;
        const max_x = @ceil(@as(f32, @floatFromInt(bbox.x_max)) * scale_px) + 1;
        const min_y = @floor(-@as(f32, @floatFromInt(bbox.y_max)) * scale_px) - 1;
        const max_y = @ceil(-@as(f32, @floatFromInt(bbox.y_min)) * scale_px) + 1;
        const width_f = max_x - min_x;
        const height_f = max_y - min_y;
        if (width_f <= 0 or height_f <= 0) {
            return .{ .metrics = .{ .advance_x = resolved.advance_x } };
        }

        const width = std.math.cast(u32, @as(i64, @intFromFloat(width_f))) orelse return error.GlyphTooLarge;
        const height = std.math.cast(u32, @as(i64, @intFromFloat(height_f))) orelse return error.GlyphTooLarge;
        if (@as(usize, width) * @as(usize, height) > max_raster_pixels) return error.GlyphTooLarge;

        const alpha = try gpa.alloc(u8, @as(usize, width) * @as(usize, height));
        errdefer gpa.free(alpha);
        rasterizeSegments(outline.segments.items, alpha, width, height, min_x, min_y, scale_px);

        return .{
            .alpha = alpha,
            .width = width,
            .height = height,
            .metrics = .{
                .width = width,
                .height = height,
                .draw_width = @as(f32, @floatFromInt(width)) / dpr,
                .draw_height = @as(f32, @floatFromInt(height)) / dpr,
                .offset_x = min_x / dpr,
                .offset_y = min_y / dpr,
                .advance_x = resolved.advance_x,
            },
        };
    }

    pub fn cachedGlyph(self: *const FontStore, font_id: i32, codepoint: u21, size: f32, dpr: f32) ?CachedGlyph {
        const size_bits = floatBits(size);
        const dpr_bits = floatBits(dpr);
        for (self.glyph_cache.items) |cached| {
            if (cached.font_id == font_id and cached.codepoint == codepoint and cached.size_bits == size_bits and cached.dpr_bits == dpr_bits) {
                return cached;
            }
        }
        return null;
    }

    pub fn putCachedGlyph(self: *FontStore, gpa: std.mem.Allocator, font_id: i32, codepoint: u21, size: f32, dpr: f32, glyph: text.GlyphId, advance_x: f32) !void {
        try self.glyph_cache.append(gpa, .{
            .font_id = font_id,
            .codepoint = codepoint,
            .size_bits = floatBits(size),
            .dpr_bits = floatBits(dpr),
            .glyph = glyph,
            .advance_x = advance_x,
        });
    }

    pub fn clearGlyphCache(self: *FontStore) void {
        self.glyph_cache.clearRetainingCapacity();
    }

    fn createFontOwned(self: *FontStore, gpa: std.mem.Allocator, name: []const u8, data: []u8) !i32 {
        _ = try tatfi.Face.parse(data, 0);

        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);

        const id = self.next_id;
        self.next_id += 1;
        try self.fonts.append(gpa, .{
            .id = id,
            .name = owned_name,
            .data = data,
        });
        return id;
    }

    fn record(self: *const FontStore, id: i32) ?*const FontRecord {
        if (id <= 0) return null;
        for (self.fonts.items) |*font| {
            if (font.id == id) return font;
        }
        return null;
    }
};

const Point = struct {
    x: f32,
    y: f32,
};

const Segment = struct {
    a: Point,
    b: Point,
};

const OutlineCollector = struct {
    gpa: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    current: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    has_current: bool = false,

    fn deinit(self: *OutlineCollector, gpa: std.mem.Allocator) void {
        self.segments.deinit(gpa);
    }

    fn builder(self: *OutlineCollector) tatfi.OutlineBuilder {
        return .{
            .ptr = self,
            .vtable = .{
                .move_to = moveTo,
                .line_to = lineTo,
                .quad_to = quadTo,
                .curve_to = curveTo,
                .close = close,
            },
        };
    }

    fn addLine(self: *OutlineCollector, p: Point) void {
        if (self.has_current and (self.current.x != p.x or self.current.y != p.y)) {
            self.segments.append(self.gpa, .{ .a = self.current, .b = p }) catch {};
        }
        self.current = p;
        self.has_current = true;
    }

    fn moveTo(ptr: *anyopaque, x: f32, y: f32) void {
        const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
        const p: Point = .{ .x = x, .y = y };
        self.current = p;
        self.start = p;
        self.has_current = true;
    }

    fn lineTo(ptr: *anyopaque, x: f32, y: f32) void {
        const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
        self.addLine(.{ .x = x, .y = y });
    }

    fn quadTo(ptr: *anyopaque, x1: f32, y1: f32, x: f32, y: f32) void {
        const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
        if (!self.has_current) return;
        const p0 = self.current;
        const p1: Point = .{ .x = x1, .y = y1 };
        const p2: Point = .{ .x = x, .y = y };
        var i: usize = 1;
        while (i <= curve_steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(curve_steps));
            const mt = 1 - t;
            self.addLine(.{
                .x = mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
                .y = mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y,
            });
        }
    }

    fn curveTo(ptr: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) void {
        const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
        if (!self.has_current) return;
        const p0 = self.current;
        const p1: Point = .{ .x = x1, .y = y1 };
        const p2: Point = .{ .x = x2, .y = y2 };
        const p3: Point = .{ .x = x, .y = y };
        var i: usize = 1;
        while (i <= curve_steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(curve_steps));
            const mt = 1 - t;
            self.addLine(.{
                .x = mt * mt * mt * p0.x + 3 * mt * mt * t * p1.x + 3 * mt * t * t * p2.x + t * t * t * p3.x,
                .y = mt * mt * mt * p0.y + 3 * mt * mt * t * p1.y + 3 * mt * t * t * p2.y + t * t * t * p3.y,
            });
        }
    }

    fn close(ptr: *anyopaque) void {
        const self: *OutlineCollector = @ptrCast(@alignCast(ptr));
        if (self.has_current) self.addLine(self.start);
        self.has_current = false;
    }
};

fn rasterizeSegments(segments: []const Segment, alpha: []u8, width: u32, height: u32, min_x: f32, min_y: f32, scale_px: f32) void {
    const sample_count = sample_grid * sample_grid;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            var covered: u32 = 0;
            var sy: u32 = 0;
            while (sy < sample_grid) : (sy += 1) {
                var sx: u32 = 0;
                while (sx < sample_grid) : (sx += 1) {
                    const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / sample_grid;
                    const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / sample_grid;
                    if (inside(segments, px + min_x, py + min_y, scale_px)) covered += 1;
                }
            }
            const index = @as(usize, y) * @as(usize, width) + x;
            alpha[index] = @intCast((covered * 255 + sample_count / 2) / sample_count);
        }
    }
}

fn inside(segments: []const Segment, px: f32, py: f32, scale_px: f32) bool {
    var winding: i32 = 0;
    for (segments) |seg| {
        const x0 = seg.a.x * scale_px;
        const y0 = -seg.a.y * scale_px;
        const x1 = seg.b.x * scale_px;
        const y1 = -seg.b.y * scale_px;
        if ((y0 <= py and y1 > py) or (y1 <= py and y0 > py)) {
            const t = (py - y0) / (y1 - y0);
            const ix = x0 + t * (x1 - x0);
            if (ix > px) winding += if (y1 > y0) 1 else -1;
        }
    }
    return winding != 0;
}

fn floatBits(value: f32) u32 {
    return @bitCast(value);
}

const FontRecord = struct {
    id: i32,
    name: []u8,
    data: []u8,

    fn deinit(self: *FontRecord, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.data);
        self.* = undefined;
    }

    fn face(self: *const FontRecord) ?tatfi.Face {
        return tatfi.Face.parse(self.data, 0) catch null;
    }
};

fn readFontFile(gpa: std.mem.Allocator, filename: []const u8) ![]u8 {
    if (filename.len == 0) return error.InvalidFontPath;
    const filename_z = try gpa.dupeZ(u8, filename);
    defer gpa.free(filename_z);

    const file = std.c.fopen(filename_z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);

    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count == 0) break;
        if (bytes.items.len + read_count > max_font_bytes) return error.FileTooBig;
        try bytes.appendSlice(gpa, buf[0..read_count]);
        if (read_count < buf.len) break;
    }
    return try bytes.toOwnedSlice(gpa);
}

fn scaleFor(face: tatfi.Face, size: f32) f32 {
    const units = @as(f32, @floatFromInt(face.units_per_em()));
    if (units <= 0 or size <= 0) return 0;
    return size / units;
}
