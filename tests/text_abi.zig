const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const text_ops = okys.ops.text;
const Context = okys.state.context.Context;

test "text metrics expose deterministic fallback values" {
    var ascender: f32 = 0;
    var descender: f32 = 0;
    var lineh: f32 = 0;
    const metrics = text_ops.textMetrics();
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

test "glyph positions report byte pointers and fallback bounds" {
    const bytes = "AéB";
    var positions: [4]text_ops.TextGlyphPosition = undefined;
    const count = text_ops.glyphPositions(5, bytes, &positions);

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
    const count = text_ops.breakLines(bytes, 7 * text_ops.fallback_advance, &rows);

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
    const count = text_ops.breakLines(bytes, 100, &rows);

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
    try testing.expectEqual(@as(c_int, 0), text_ops.glyphPositions(0, bytes, &positions));
    try testing.expectEqual(@as(c_int, 0), text_ops.breakLines(bytes, 10, &rows));
}

test "text box is safe before real font drawing exists" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const bytes = "one two three";
    text_ops.textBox(ctx, 0, 0, 24, bytes);
}
