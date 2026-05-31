//! Font storage and Tatfi adapter. Public text APIs never expose Tatfi types;
//! this module owns font bytes and maps parser data into Okys metrics.

const std = @import("std");
const tatfi = @import("tatfi");

const max_font_bytes = 64 * 1024 * 1024;

pub const ScaledMetrics = struct {
    ascender: f32,
    descender: f32,
    line_height: f32,
};

pub const FontStore = struct {
    fonts: std.ArrayList(FontRecord) = .empty,
    next_id: i32 = 1,

    pub fn deinit(self: *FontStore, gpa: std.mem.Allocator) void {
        for (self.fonts.items) |*font| font.deinit(gpa);
        self.fonts.deinit(gpa);
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
        const font = self.record(id) orelse return null;
        var face = font.face() orelse return null;
        const glyph_id = face.glyph_index(codepoint) orelse return null;
        const advance = face.glyph_hor_advance(gpa, glyph_id) orelse return null;
        return @as(f32, @floatFromInt(advance)) * scaleFor(face, size);
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
