//! Internal glyph-atlas text verbs. This first lane proves atlas storage and
//! textured quads without font loading, shaping, or public C ABI surface.

const Context = @import("../state/context.zig").Context;
const color = @import("../types/color.zig");
const image_ops = @import("image_ops.zig");
const paint_ops = @import("paint_ops.zig");
const text_types = @import("../types/text.zig");
const Vertex = @import("../types/path.zig").Vertex;
const xforms = @import("../systems/transform.zig");

const GlyphId = text_types.GlyphId;
const GlyphMetrics = text_types.GlyphMetrics;
const GlyphRecord = text_types.GlyphRecord;
const GlyphRunMetrics = text_types.GlyphRunMetrics;
pub const TextGlyphPosition = text_types.TextGlyphPosition;
pub const TextRow = text_types.TextRow;

pub const fallback_font_size: f32 = 16;
pub const fallback_advance: f32 = fallback_font_size * 0.5;
pub const fallback_ascender: f32 = fallback_font_size * 0.8;
pub const fallback_descender: f32 = -fallback_font_size * 0.2;
pub const fallback_line_height: f32 = fallback_font_size * 1.4;

pub fn initGlyphAtlas(ctx: *Context, width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    if (ctx.glyph_atlas.image_id != .none) {
        image_ops.deleteImage(ctx, ctx.glyph_atlas.image_id);
        ctx.glyph_atlas.deinit(ctx.gpa);
    }

    const image_id = image_ops.createImageRGBA(ctx, width, height, null);
    if (image_id == .none) return false;
    ctx.glyph_atlas.initStorage(ctx.gpa, image_id, width, height) catch {
        image_ops.deleteImage(ctx, image_id);
        ctx.glyph_atlas.deinit(ctx.gpa);
        return false;
    };
    return true;
}

pub fn addGlyphAlpha(ctx: *Context, alpha: []const u8, width: u32, height: u32, metrics: GlyphMetrics) GlyphId {
    const id = ctx.glyph_atlas.addGlyphAlpha(ctx.gpa, alpha, width, height, metrics) catch return .none;
    image_ops.updateImage(ctx, ctx.glyph_atlas.image_id, ctx.glyph_atlas.pixels.items);
    return id;
}

pub fn drawGlyph(ctx: *Context, id: GlyphId, x: f32, y: f32) void {
    drawGlyphTinted(ctx, id, x, y, color.rgbaf(1, 1, 1, 1));
}

pub fn drawGlyphTinted(ctx: *Context, id: GlyphId, x: f32, y: f32, tint: color.Color) void {
    const backend = ctx.backend orelse return;
    const atlas = &ctx.glyph_atlas;
    const glyph = atlas.get(id) orelse return;
    if (atlas.image_id == .none or atlas.width == 0 or atlas.height == 0) return;
    const paint = glyphPaint(ctx, glyph, x, y, tint);
    const verts = glyphVertices(ctx, glyph, paint);
    backend.triangles(backend.ctx, &paint, &ctx.state().scissor, &verts);
}

pub fn measureGlyphRun(ctx: *const Context, glyphs: []const GlyphId) GlyphRunMetrics {
    var result: GlyphRunMetrics = .{};
    for (glyphs) |id| {
        const glyph = ctx.glyph_atlas.get(id) orelse {
            result.missing_count += 1;
            continue;
        };
        result.advance_x += glyph.advance_x;
        result.advance_y += glyph.advance_y;
        result.emitted_count += 1;
    }
    return result;
}

pub fn drawGlyphRun(ctx: *Context, glyphs: []const GlyphId, x: f32, y: f32, tint: color.Color) GlyphRunMetrics {
    var result: GlyphRunMetrics = .{};
    var pen_x = x;
    var pen_y = y;
    for (glyphs) |id| {
        const glyph = ctx.glyph_atlas.get(id) orelse {
            result.missing_count += 1;
            continue;
        };
        drawGlyphTinted(ctx, id, pen_x, pen_y, tint);
        pen_x += glyph.advance_x;
        pen_y += glyph.advance_y;
        result.advance_x += glyph.advance_x;
        result.advance_y += glyph.advance_y;
        result.emitted_count += 1;
    }
    return result;
}

pub fn textWidth(bytes: []const u8) f32 {
    return @as(f32, @floatFromInt(countLineCodepoints(bytes))) * fallback_advance;
}

pub fn text(ctx: *Context, x: f32, y: f32, bytes: []const u8) f32 {
    _ = ctx;
    _ = y;
    return x + textWidth(bytes);
}

pub fn textBox(ctx: *Context, x: f32, y: f32, break_row_width: f32, bytes: []const u8) void {
    var rows: [4]TextRow = undefined;
    var offset: usize = 0;
    var line_y = y;
    while (offset < bytes.len) {
        const count = breakLines(bytes[offset..], break_row_width, &rows);
        if (count == 0) break;
        for (rows[0..@intCast(count)]) |row| {
            const start = offsetFromPtr(bytes, row.start) orelse offset;
            const end = offsetFromPtr(bytes, row.end) orelse start;
            _ = text(ctx, x, line_y, bytes[start..end]);
            line_y += fallback_line_height;
            offset = offsetFromPtr(bytes, row.next) orelse end;
        }
    }
}

pub fn textMetrics() struct { ascender: f32, descender: f32, line_height: f32 } {
    return .{
        .ascender = fallback_ascender,
        .descender = fallback_descender,
        .line_height = fallback_line_height,
    };
}

pub fn glyphPositions(x: f32, bytes: []const u8, positions: []TextGlyphPosition) c_int {
    var count: usize = 0;
    var i: usize = 0;
    var pen_x = x;
    while (i < bytes.len and count < positions.len) {
        const b = bytes[i];
        if (isLineBreak(b)) break;
        if (b == 0) break;

        positions[count] = .{
            .str = bytes.ptr + i,
            .x = pen_x,
            .minx = pen_x,
            .maxx = pen_x + fallback_advance,
        };
        count += 1;
        pen_x += fallback_advance;
        i += codepointByteLen(bytes[i..]);
    }
    return @intCast(count);
}

pub fn breakLines(bytes: []const u8, break_row_width: f32, rows: []TextRow) c_int {
    if (rows.len == 0 or bytes.len == 0) return 0;

    const max_glyphs = glyphLimitForWidth(break_row_width);
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < bytes.len and count < rows.len) {
        pos = skipLeadingSpaces(bytes, pos);
        if (pos >= bytes.len) break;

        const start = pos;
        var end = pos;
        var next = pos;
        var last_space_start: ?usize = null;
        var last_space_end: ?usize = null;
        var glyphs: usize = 0;

        while (next < bytes.len) {
            const b = bytes[next];
            if (b == 0) {
                end = trimTrailingSpaces(bytes, start, next);
                next = bytes.len;
                break;
            }
            if (b == '\n') {
                end = trimTrailingSpaces(bytes, start, next);
                next += 1;
                break;
            }
            if (b == '\r') {
                end = trimTrailingSpaces(bytes, start, next);
                next += 1;
                if (next < bytes.len and bytes[next] == '\n') next += 1;
                break;
            }

            const char_len = codepointByteLen(bytes[next..]);
            if (isBreakSpace(b)) {
                if (last_space_start == null or next > last_space_start.?) {
                    last_space_start = next;
                    last_space_end = next + char_len;
                }
            }

            if (glyphs >= max_glyphs) {
                if (last_space_start) |space_start| {
                    end = trimTrailingSpaces(bytes, start, space_start);
                    next = skipSpaces(bytes, last_space_end.?);
                } else {
                    end = next;
                }
                if (end == start) {
                    end = next + char_len;
                    next = end;
                }
                break;
            }

            next += char_len;
            end = next;
            glyphs += 1;
        }

        if (next >= bytes.len) {
            end = trimTrailingSpaces(bytes, start, end);
        }

        const width = textWidth(bytes[start..end]);
        rows[count] = .{
            .start = bytes.ptr + start,
            .end = bytes.ptr + end,
            .next = bytes.ptr + next,
            .width = width,
            .minx = 0,
            .maxx = width,
        };
        count += 1;
        pos = next;
    }

    return @intCast(count);
}

fn glyphPaint(ctx: *Context, glyph: GlyphRecord, x: f32, y: f32, tint: color.Color) color.Paint {
    const atlas = &ctx.glyph_atlas;
    const x0 = @as(f32, @floatFromInt(glyph.atlas_x));
    const y0 = @as(f32, @floatFromInt(glyph.atlas_y));

    var paint = paint_ops.imagePattern(
        ctx,
        x + glyph.offset_x - x0,
        y + glyph.offset_y - y0,
        @floatFromInt(atlas.width),
        @floatFromInt(atlas.height),
        0,
        @intCast(@intFromEnum(atlas.image_id)),
        1,
    );
    paint.inner_color = tint;
    paint.outer_color = tint;
    xforms.multiply(&paint.xform, &ctx.state().xform);
    return paint;
}

fn glyphVertices(ctx: *Context, glyph: GlyphRecord, paint: color.Paint) [6]Vertex {
    const atlas = &ctx.glyph_atlas;
    const x0 = @as(f32, @floatFromInt(glyph.atlas_x));
    const y0 = @as(f32, @floatFromInt(glyph.atlas_y));
    const x1 = x0 + @as(f32, @floatFromInt(glyph.width));
    const y1 = y0 + @as(f32, @floatFromInt(glyph.height));

    const p00 = xforms.point(&paint.xform, x0, y0);
    const p10 = xforms.point(&paint.xform, x1, y0);
    const p11 = xforms.point(&paint.xform, x1, y1);
    const p01 = xforms.point(&paint.xform, x0, y1);
    const inv_w = 1.0 / @as(f32, @floatFromInt(atlas.width));
    const inv_h = 1.0 / @as(f32, @floatFromInt(atlas.height));
    const tex_u0 = x0 * inv_w;
    const tex_v0 = y0 * inv_h;
    const tex_u1 = x1 * inv_w;
    const tex_v1 = y1 * inv_h;

    return .{
        .{ .x = p00[0], .y = p00[1], .u = tex_u0, .v = tex_v0 },
        .{ .x = p10[0], .y = p10[1], .u = tex_u1, .v = tex_v0 },
        .{ .x = p11[0], .y = p11[1], .u = tex_u1, .v = tex_v1 },
        .{ .x = p00[0], .y = p00[1], .u = tex_u0, .v = tex_v0 },
        .{ .x = p11[0], .y = p11[1], .u = tex_u1, .v = tex_v1 },
        .{ .x = p01[0], .y = p01[1], .u = tex_u0, .v = tex_v1 },
    };
}

fn countLineCodepoints(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0 or isLineBreak(b)) break;
        count += 1;
        i += codepointByteLen(bytes[i..]);
    }
    return count;
}

fn glyphLimitForWidth(width: f32) usize {
    if (width <= 0) return 1;
    const raw = @as(usize, @intFromFloat(@floor(width / fallback_advance)));
    return @max(raw, 1);
}

fn codepointByteLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const b0 = bytes[0];
    if (b0 < 0x80) return 1;
    if (b0 >= 0xC2 and b0 <= 0xDF and bytes.len >= 2 and isContinuation(bytes[1])) return 2;
    if (b0 >= 0xE0 and b0 <= 0xEF and bytes.len >= 3 and isContinuation(bytes[1]) and isContinuation(bytes[2])) return 3;
    if (b0 >= 0xF0 and b0 <= 0xF4 and bytes.len >= 4 and isContinuation(bytes[1]) and isContinuation(bytes[2]) and isContinuation(bytes[3])) return 4;
    return 1;
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn isLineBreak(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

fn isBreakSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn skipLeadingSpaces(bytes: []const u8, pos: usize) usize {
    return skipSpaces(bytes, pos);
}

fn skipSpaces(bytes: []const u8, start: usize) usize {
    var pos = start;
    while (pos < bytes.len and isBreakSpace(bytes[pos])) : (pos += 1) {}
    return pos;
}

fn trimTrailingSpaces(bytes: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and isBreakSpace(bytes[trimmed - 1])) : (trimmed -= 1) {}
    return trimmed;
}

fn offsetFromPtr(bytes: []const u8, maybe_ptr: ?[*]const u8) ?usize {
    const ptr = maybe_ptr orelse return null;
    const base = @intFromPtr(bytes.ptr);
    const addr = @intFromPtr(ptr);
    if (addr < base) return null;
    const offset = addr - base;
    if (offset > bytes.len) return null;
    return offset;
}
