//! Internal glyph-atlas text verbs. This first lane proves atlas storage and
//! textured quads without font loading, shaping, or public C ABI surface.

const Context = @import("../state/context.zig").Context;
const color = @import("../types/color.zig");
const image_ops = @import("image_ops.zig");
const paint_ops = @import("paint_ops.zig");
const text_types = @import("../types/text.zig");
const draw_state = @import("../state/draw_state.zig");
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
const default_atlas_size: u32 = 2048;

pub fn createFont(ctx: *Context, name: []const u8, filename: []const u8) c_int {
    if (name.len == 0 or filename.len == 0) return 0;
    return @intCast(ctx.fonts.createFont(ctx.gpa, name, filename) catch return 0);
}

pub fn createFontMem(ctx: *Context, name: []const u8, data: []const u8) c_int {
    if (name.len == 0 or data.len == 0) return 0;
    return @intCast(ctx.fonts.createFontMem(ctx.gpa, name, data) catch return 0);
}

pub fn findFont(ctx: *const Context, name: []const u8) c_int {
    if (name.len == 0) return 0;
    return @intCast(ctx.fonts.findFont(name));
}

pub fn fontSize(ctx: *Context, size: f32) void {
    if (size > 0) ctx.state().font_size = size;
}

pub fn fontFaceId(ctx: *Context, id: c_int) void {
    ctx.state().font_id = if (ctx.fonts.hasFont(id)) id else 0;
}

pub fn fontFace(ctx: *Context, name: []const u8) void {
    fontFaceId(ctx, findFont(ctx, name));
}

pub fn textAlign(ctx: *Context, alignment: c_int) void {
    if (alignment >= 0) ctx.state().text_align = @intCast(alignment);
}

pub fn textLetterSpacing(ctx: *Context, spacing: f32) void {
    ctx.state().text_letter_spacing = spacing;
}

pub fn textLineHeight(ctx: *Context, line_height: f32) void {
    if (line_height > 0) ctx.state().text_line_height = line_height;
}

pub fn initGlyphAtlas(ctx: *Context, width: u32, height: u32) bool {
    if (width == 0 or height == 0) return false;
    if (ctx.glyph_atlas.image_id != .none) {
        image_ops.deleteImage(ctx, ctx.glyph_atlas.image_id);
        ctx.glyph_atlas.deinit(ctx.gpa);
    }
    ctx.fonts.clearGlyphCache();

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
    uploadGlyphAlpha(ctx, id, alpha, width, height);
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
    const state = ctx.state();
    if (state.font_id <= 0) return x + textWidthFor(ctx, bytes);

    var i: usize = 0;
    var pen_x = alignedX(ctx, x, bytes);
    const baseline_y = alignedBaselineY(ctx, y);
    const tint = state.fill.inner_color;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0 or isLineBreak(b)) break;
        const char_len = codepointByteLen(bytes[i..]);
        const codepoint = decodeCodepoint(bytes[i .. i + char_len]);
        const glyph = cachedGlyphForCodepoint(ctx, codepoint);
        if (glyph.glyph != .none) drawGlyphTinted(ctx, glyph.glyph, pen_x, baseline_y, tint);
        pen_x += glyph.advance_x;
        i += char_len;
        if (i < bytes.len and bytes[i] != 0 and !isLineBreak(bytes[i])) pen_x += letterSpacing(ctx);
    }
    return pen_x;
}

pub fn textBox(ctx: *Context, x: f32, y: f32, break_row_width: f32, bytes: []const u8) void {
    var rows: [4]TextRow = undefined;
    var offset: usize = 0;
    var line_y = y;
    while (offset < bytes.len) {
        const count = breakLines(ctx, bytes[offset..], break_row_width, &rows);
        if (count == 0) break;
        for (rows[0..@intCast(count)]) |row| {
            const start = offsetFromPtr(bytes, row.start) orelse offset;
            const end = offsetFromPtr(bytes, row.end) orelse start;
            _ = text(ctx, x, line_y, bytes[start..end]);
            line_y += textMetrics(ctx).line_height;
            offset = offsetFromPtr(bytes, row.next) orelse end;
        }
    }
}

pub fn textMetrics(ctx: ?*const Context) struct { ascender: f32, descender: f32, line_height: f32 } {
    if (ctx) |c| {
        const state = c.states.items[c.states.items.len - 1];
        if (c.fonts.metrics(c.gpa, state.font_id, state.font_size, state.text_line_height)) |metrics| {
            return .{
                .ascender = metrics.ascender,
                .descender = metrics.descender,
                .line_height = metrics.line_height,
            };
        }
        const scale = state.font_size / fallback_font_size;
        return .{
            .ascender = fallback_ascender * scale,
            .descender = fallback_descender * scale,
            .line_height = fallback_line_height * scale * state.text_line_height,
        };
    }
    return .{
        .ascender = fallback_ascender,
        .descender = fallback_descender,
        .line_height = fallback_line_height,
    };
}

pub fn glyphPositions(ctx: ?*const Context, x: f32, bytes: []const u8, positions: []TextGlyphPosition) c_int {
    var count: usize = 0;
    var i: usize = 0;
    var pen_x = alignedX(ctx, x, bytes);
    while (i < bytes.len and count < positions.len) {
        const b = bytes[i];
        if (isLineBreak(b)) break;
        if (b == 0) break;
        const char_len = codepointByteLen(bytes[i..]);
        const codepoint = decodeCodepoint(bytes[i .. i + char_len]);
        const advance = glyphAdvance(ctx, codepoint);

        positions[count] = .{
            .str = bytes.ptr + i,
            .x = pen_x,
            .minx = pen_x,
            .maxx = pen_x + advance,
        };
        count += 1;
        pen_x += advance + letterSpacing(ctx);
        i += char_len;
    }
    return @intCast(count);
}

pub fn breakLines(ctx: ?*const Context, bytes: []const u8, break_row_width: f32, rows: []TextRow) c_int {
    if (rows.len == 0 or bytes.len == 0) return 0;

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
        var row_width: f32 = 0;
        var end_width: f32 = 0;
        var last_space_width: f32 = 0;

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
            const codepoint = decodeCodepoint(bytes[next .. next + char_len]);
            const advance = glyphAdvance(ctx, codepoint);
            if (isBreakSpace(b)) {
                if (last_space_start == null or next > last_space_start.?) {
                    last_space_start = next;
                    last_space_end = next + char_len;
                    last_space_width = row_width;
                }
            }

            if (row_width > 0 and row_width + advance > break_row_width and break_row_width > 0) {
                if (last_space_start) |space_start| {
                    end = trimTrailingSpaces(bytes, start, space_start);
                    next = skipSpaces(bytes, last_space_end.?);
                    end_width = last_space_width;
                } else {
                    end = next;
                }
                if (end == start) {
                    end = next + char_len;
                    next = end;
                    end_width = advance;
                }
                break;
            }

            next += char_len;
            end = next;
            row_width += advance + letterSpacing(ctx);
            end_width = row_width;
        }

        if (next >= bytes.len) {
            end = trimTrailingSpaces(bytes, start, end);
        }

        const width = if (end_width > 0) textWidthFor(ctx, bytes[start..end]) else end_width;
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

fn textWidthFor(ctx: ?*const Context, bytes: []const u8) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    var emitted: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0 or isLineBreak(b)) break;
        const char_len = codepointByteLen(bytes[i..]);
        width += glyphAdvance(ctx, decodeCodepoint(bytes[i .. i + char_len]));
        emitted += 1;
        i += char_len;
    }
    if (emitted > 1) width += @as(f32, @floatFromInt(emitted - 1)) * letterSpacing(ctx);
    return width;
}

fn glyphAdvance(ctx: ?*const Context, codepoint: u21) f32 {
    if (ctx) |c| {
        const state = c.states.items[c.states.items.len - 1];
        if (c.fonts.glyphAdvance(c.gpa, state.font_id, state.font_size, codepoint)) |advance| {
            return advance;
        }
        return fallback_advance * (state.font_size / fallback_font_size);
    }
    return fallback_advance;
}

fn letterSpacing(ctx: ?*const Context) f32 {
    if (ctx) |c| return c.states.items[c.states.items.len - 1].text_letter_spacing;
    return 0;
}

fn alignedX(ctx: ?*const Context, x: f32, bytes: []const u8) f32 {
    const c = ctx orelse return x;
    const alignment = c.states.items[c.states.items.len - 1].text_align;
    const width = textWidthFor(ctx, bytes);
    if (alignment & draw_state.text_align.right != 0) return x - width;
    if (alignment & draw_state.text_align.center != 0) return x - width * 0.5;
    return x;
}

fn alignedBaselineY(ctx: *const Context, y: f32) f32 {
    const alignment = ctx.states.items[ctx.states.items.len - 1].text_align;
    const metrics = textMetrics(ctx);
    if (alignment & draw_state.text_align.top != 0) return y + metrics.ascender;
    if (alignment & draw_state.text_align.middle != 0) return y + (metrics.ascender + metrics.descender) * 0.5;
    if (alignment & draw_state.text_align.bottom != 0) return y + metrics.descender;
    return y;
}

const CachedTextGlyph = struct {
    glyph: GlyphId = .none,
    advance_x: f32 = 0,
};

fn cachedGlyphForCodepoint(ctx: *Context, codepoint: u21) CachedTextGlyph {
    const state = ctx.state();
    const font_id = state.font_id;
    const size = state.font_size;
    const dpr = if (ctx.device_pixel_ratio > 0) ctx.device_pixel_ratio else 1;
    if (ctx.fonts.cachedGlyph(font_id, codepoint, size, dpr)) |cached| {
        return .{ .glyph = cached.glyph, .advance_x = cached.advance_x };
    }

    const resolved = ctx.fonts.resolveGlyph(ctx.gpa, font_id, size, codepoint) orelse {
        return .{ .advance_x = glyphAdvance(ctx, codepoint) };
    };
    const glyph_id = rasterizeAndCacheGlyph(ctx, codepoint, resolved, size, dpr);
    return .{ .glyph = glyph_id, .advance_x = resolved.advance_x };
}

fn rasterizeAndCacheGlyph(ctx: *Context, codepoint: u21, resolved: @import("../state/fonts.zig").ResolvedGlyph, size: f32, dpr: f32) GlyphId {
    if (ctx.glyph_atlas.image_id == .none and !initGlyphAtlas(ctx, default_atlas_size, default_atlas_size)) return .none;

    var raster = ctx.fonts.rasterizeGlyph(ctx.gpa, resolved, size, dpr) catch return .none;
    defer raster.deinit(ctx.gpa);
    if (raster.width == 0 or raster.height == 0 or raster.alpha.len == 0) {
        ctx.fonts.putCachedGlyph(ctx.gpa, resolved.font_id, codepoint, size, dpr, .none, raster.metrics.advance_x) catch {};
        return .none;
    }

    const glyph_id = ctx.glyph_atlas.addGlyphAlpha(ctx.gpa, raster.alpha, raster.width, raster.height, raster.metrics) catch return .none;
    uploadGlyphAlpha(ctx, glyph_id, raster.alpha, raster.width, raster.height);
    ctx.fonts.putCachedGlyph(ctx.gpa, resolved.font_id, codepoint, size, dpr, glyph_id, raster.metrics.advance_x) catch {};
    return glyph_id;
}

fn uploadGlyphAlpha(ctx: *Context, id: GlyphId, alpha: []const u8, width: u32, height: u32) void {
    if (ctx.glyph_atlas.image_id == .none) return;
    const glyph = ctx.glyph_atlas.get(id) orelse return;
    const upload_len = @as(usize, width) * @as(usize, height) * 4;
    if (upload_len == 0 or alpha.len != @as(usize, width) * @as(usize, height)) return;

    const upload = ctx.gpa.alloc(u8, upload_len) catch return;
    defer ctx.gpa.free(upload);
    packAlphaRgba(upload, alpha, width, height);
    image_ops.updateImageRect(ctx, ctx.glyph_atlas.image_id, glyph.atlas_x, glyph.atlas_y, width, height, upload);
}

fn packAlphaRgba(dst: []u8, alpha: []const u8, width: u32, height: u32) void {
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const src = @as(usize, row) * @as(usize, width) + col;
            const dst_index = src * 4;
            dst[dst_index + 0] = 255;
            dst[dst_index + 1] = 255;
            dst[dst_index + 2] = 255;
            dst[dst_index + 3] = alpha[src];
        }
    }
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
    const draw_w = if (glyph.draw_width > 0) glyph.draw_width else @as(f32, @floatFromInt(glyph.width));
    const draw_h = if (glyph.draw_height > 0) glyph.draw_height else @as(f32, @floatFromInt(glyph.height));
    const x1 = x0 + @as(f32, @floatFromInt(glyph.width));
    const y1 = y0 + @as(f32, @floatFromInt(glyph.height));

    const p00 = xforms.point(&paint.xform, x0, y0);
    const p10 = xforms.point(&paint.xform, x0 + draw_w, y0);
    const p11 = xforms.point(&paint.xform, x0 + draw_w, y0 + draw_h);
    const p01 = xforms.point(&paint.xform, x0, y0 + draw_h);
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

fn codepointByteLen(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    const b0 = bytes[0];
    if (b0 < 0x80) return 1;
    if (b0 >= 0xC2 and b0 <= 0xDF and bytes.len >= 2 and isContinuation(bytes[1])) return 2;
    if (b0 >= 0xE0 and b0 <= 0xEF and bytes.len >= 3 and isContinuation(bytes[1]) and isContinuation(bytes[2])) return 3;
    if (b0 >= 0xF0 and b0 <= 0xF4 and bytes.len >= 4 and isContinuation(bytes[1]) and isContinuation(bytes[2]) and isContinuation(bytes[3])) return 4;
    return 1;
}

fn decodeCodepoint(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0xfffd;
    const b0 = bytes[0];
    return switch (bytes.len) {
        1 => b0,
        2 => (@as(u21, b0 & 0x1f) << 6) | @as(u21, bytes[1] & 0x3f),
        3 => (@as(u21, b0 & 0x0f) << 12) | (@as(u21, bytes[1] & 0x3f) << 6) | @as(u21, bytes[2] & 0x3f),
        4 => (@as(u21, b0 & 0x07) << 18) | (@as(u21, bytes[1] & 0x3f) << 12) | (@as(u21, bytes[2] & 0x3f) << 6) | @as(u21, bytes[3] & 0x3f),
        else => 0xfffd,
    };
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
