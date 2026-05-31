//! Internal glyph-atlas text verbs. This first lane proves atlas storage and
//! textured quads without font loading, shaping, or public C ABI surface.

const Context = @import("../state/context.zig").Context;
const color = @import("../types/color.zig");
const image_ops = @import("image_ops.zig");
const paint_ops = @import("paint_ops.zig");
const text = @import("../types/text.zig");
const Vertex = @import("../types/path.zig").Vertex;
const xforms = @import("../systems/transform.zig");

const GlyphId = text.GlyphId;
const GlyphMetrics = text.GlyphMetrics;
const GlyphRecord = text.GlyphRecord;
const GlyphRunMetrics = text.GlyphRunMetrics;

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
