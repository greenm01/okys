const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const text_ops = okys.ops.text;
const Context = okys.state.context.Context;

test "text metrics expose deterministic fallback values" {
    var ascender: f32 = 0;
    var descender: f32 = 0;
    var lineh: f32 = 0;
    const metrics = text_ops.textMetrics(null);
    ascender = metrics.ascender;
    descender = metrics.descender;
    lineh = metrics.line_height;

    try testing.expectApproxEqAbs(@as(f32, 12.8), ascender, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -3.2), descender, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 22.4), lineh, 0.001);
}

test "text advances over utf8 codepoint starts and stops at newline" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const bytes = "AéB\nhidden";
    const advanced = text_ops.text(ctx, 10, 20, bytes);
    try testing.expectApproxEqAbs(@as(f32, 34), advanced, 0.001);
}

test "text bounds measure fallback text without drawing" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const bytes = "AéB\nhidden";
    var bounds: [4]f32 = undefined;
    const width = text_ops.textBounds(ctx, 10, 20, bytes, &bounds);

    try testing.expectApproxEqAbs(@as(f32, 24), width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 7.2), bounds[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 34), bounds[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 23.2), bounds[3], 0.001);
}

test "text bounds accepts null output and returns measured width" {
    const width = text_ops.textBounds(null, 10, 20, "abcd", null);
    try testing.expectApproxEqAbs(@as(f32, 32), width, 0.001);
}

test "glyph positions report byte pointers and fallback bounds" {
    const bytes = "AéB";
    var positions: [4]text_ops.TextGlyphPosition = undefined;
    const count = text_ops.glyphPositions(null, 5, bytes, &positions);

    try testing.expectEqual(@as(c_int, 3), count);
    try testing.expectEqual(bytes.ptr, positions[0].str.?);
    try testing.expectEqual(bytes.ptr + 1, positions[1].str.?);
    try testing.expectEqual(bytes.ptr + 3, positions[2].str.?);
    try testing.expectApproxEqAbs(@as(f32, 5), positions[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 13), positions[1].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 29), positions[2].maxx, 0.001);
}

test "text break lines prefers whitespace and reports next row pointer" {
    const bytes = "one two three";
    var rows: [3]text_ops.TextRow = undefined;
    const count = text_ops.breakLines(null, bytes, 7 * text_ops.fallback_advance, &rows);

    try testing.expectEqual(@as(c_int, 2), count);
    try testing.expectEqual(bytes.ptr, rows[0].start.?);
    try testing.expectEqual(bytes.ptr + 7, rows[0].end.?);
    try testing.expectEqual(bytes.ptr + 8, rows[0].next.?);
    try testing.expectApproxEqAbs(@as(f32, 56), rows[0].width, 0.001);
    try testing.expectEqual(bytes.ptr + 8, rows[1].start.?);
    try testing.expectEqual(bytes.ptr + bytes.len, rows[1].end.?);
}

test "text break lines handles hard newlines" {
    const bytes = "a\nb";
    var rows: [3]text_ops.TextRow = undefined;
    const count = text_ops.breakLines(null, bytes, 100, &rows);

    try testing.expectEqual(@as(c_int, 2), count);
    try testing.expectEqual(bytes.ptr, rows[0].start.?);
    try testing.expectEqual(bytes.ptr + 1, rows[0].end.?);
    try testing.expectEqual(bytes.ptr + 2, rows[0].next.?);
    try testing.expectEqual(bytes.ptr + 2, rows[1].start.?);
    try testing.expectEqual(bytes.ptr + 3, rows[1].end.?);
}

test "text layout tolerates empty inputs and limits" {
    try testing.expectApproxEqAbs(@as(f32, 0), text_ops.textWidth(""), 0.001);

    const bytes = "abc";
    var positions: [0]text_ops.TextGlyphPosition = .{};
    var rows: [0]text_ops.TextRow = .{};
    try testing.expectEqual(@as(c_int, 0), text_ops.glyphPositions(null, 0, bytes, &positions));
    try testing.expectEqual(@as(c_int, 0), text_ops.breakLines(null, bytes, 10, &rows));
}

test "text box is safe before real font drawing exists" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const bytes = "one two three";
    text_ops.textBox(ctx, 0, 0, 24, bytes);
}

test "font loading uses Tatfi metrics and glyph advances" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const id = loadTestFont(ctx) orelse return error.SkipZigTest;
    try testing.expectEqual(id, text_ops.findFont(ctx, "sans"));

    text_ops.fontFaceId(ctx, id);
    text_ops.fontSize(ctx, 32);
    const metrics = text_ops.textMetrics(ctx);
    try testing.expect(metrics.ascender > 20);
    try testing.expect(metrics.descender < 0);
    try testing.expect(metrics.line_height > 25);

    const advanced = text_ops.text(ctx, 10, 20, "ABC");
    try testing.expect(advanced > 40);

    var bounds: [4]f32 = undefined;
    const measured = text_ops.textBounds(ctx, 10, 20, "ABC", &bounds);
    try testing.expectApproxEqAbs(advanced - 10, measured, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10) + measured, bounds[2], 0.001);

    var positions: [4]text_ops.TextGlyphPosition = undefined;
    const count = text_ops.glyphPositions(ctx, 0, "ABC", &positions);
    try testing.expectEqual(@as(c_int, 3), count);
    try testing.expect(positions[1].x > positions[0].x);
}

test "Tatfi kern pairs feed text layout" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const id = text_ops.createFont(ctx, "kern", "/usr/share/fonts/TTF/Vera.ttf");
    if (id <= 0) return error.SkipZigTest;

    text_ops.fontFaceId(ctx, id);
    text_ops.fontSize(ctx, 32);

    const glyph_a = ctx.fonts.resolveGlyph(ctx.gpa, id, ctx.state().font_size, 'A') orelse return error.SkipZigTest;
    const glyph_v = ctx.fonts.resolveGlyph(ctx.gpa, id, ctx.state().font_size, 'V') orelse return error.SkipZigTest;
    const kern = ctx.fonts.glyphPairKerning(id, ctx.state().font_size, glyph_a.glyph_id, glyph_v.glyph_id) orelse return error.SkipZigTest;
    try testing.expect(kern < 0);

    const width_a = text_ops.text(ctx, 0, 0, "A");
    const width_v = text_ops.text(ctx, 0, 0, "V");
    const width_av = text_ops.text(ctx, 0, 0, "AV");
    const bounds_av = text_ops.textBounds(ctx, 0, 0, "AV", null);
    try testing.expectApproxEqAbs(width_a + width_v + kern, width_av, 0.001);
    try testing.expectApproxEqAbs(width_av, bounds_av, 0.001);
    try testing.expect(width_av < width_a + width_v);

    var positions: [2]text_ops.TextGlyphPosition = undefined;
    const count = text_ops.glyphPositions(ctx, 0, "AV", &positions);
    try testing.expectEqual(@as(c_int, 2), count);
    try testing.expectApproxEqAbs(width_a + kern, positions[1].x, 0.001);

    var rows: [2]text_ops.TextRow = undefined;
    const row_count = text_ops.breakLines(ctx, "AV AV", width_av + 0.001, &rows);
    try testing.expectEqual(@as(c_int, 2), row_count);
    try testing.expectApproxEqAbs(width_av, rows[0].width, 0.001);
}

test "font text state saves and restores" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    text_ops.fontSize(ctx, 20);
    okys.ops.state.save(ctx);

    text_ops.fontSize(ctx, 40);
    try testing.expectApproxEqAbs(@as(f32, 40), ctx.state().font_size, 0.001);
    okys.ops.state.restore(ctx);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.state().font_size, 0.001);
}

fn loadTestFont(ctx: *Context) ?c_int {
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    };
    for (candidates) |path| {
        const id = text_ops.createFont(ctx, "sans", path);
        if (id > 0) return id;
    }
    return null;
}
