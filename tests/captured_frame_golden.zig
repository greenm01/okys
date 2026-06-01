const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const BackendSparse = okys.systems.backend_sparse_strip.Backend;
const BackendStencil = okys.systems.backend_stencil.Backend;
const CapturedFrame = okys.render.frame_capture.CapturedFrame;
const EventKind = okys.render.frame_capture.EventKind;
const Context = okys.state.context.Context;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;
const text_ops = okys.ops.text;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

test "captured frame golden replays text clips dashes images and subrect uploads" {
    var frame = try captureGoldenScene(testing.allocator);
    defer frame.deinit();

    try testing.expect(countEvents(frame, .viewport) == 1);
    try testing.expect(countEvents(frame, .create_texture) >= 2);
    try testing.expect(countEvents(frame, .update_texture) >= 3);
    try testing.expect(countEvents(frame, .fill) >= 4);
    try testing.expect(countEvents(frame, .stroke) >= 1);
    try testing.expect(countEvents(frame, .triangles) >= 2);
    try testing.expect(countEvents(frame, .push_clip_path) == 1);
    try testing.expect(countEvents(frame, .pop_clip_path) == 1);
    try testing.expect(hasTextureSubrectUpdate(frame));

    var mock: mock_backend.MockBackend = .{};
    frame.replay(mock.interface());
    try testing.expectEqual(@as(usize, 1), mock.viewport_calls);
    try testing.expect(mock.fill_calls >= 4);
    try testing.expect(mock.stroke_calls >= 1);
    try testing.expect(mock.triangles_calls >= 2);
    try testing.expectEqual(@as(usize, 1), mock.push_clip_path_calls);
    try testing.expectEqual(@as(usize, 1), mock.pop_clip_path_calls);
    try testing.expectEqual(@as(usize, 0), mock.clip_depth);
    try testing.expect(mock.update_texture_calls >= 3);
    try testing.expect(mock.last_update_data_len < 2048 * 2048 * 4);

    const stencil = try BackendStencil.createWithFlags(testing.allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer stencil.destroy();
    frame.replay(stencil.interface());
    try testing.expectEqual(@as(usize, 1), stencil.clip_push_count);
    try testing.expectEqual(@as(usize, 1), stencil.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), stencil.clip_depth);
    try testing.expect(stencil.buildStencilPass());
    try testing.expect(stencil.path_draws.items.len > 0);
    try testing.expect(stencil.frag_params.items.len > 0);
    try testing.expect(stencil.calls.items.len >= 6);

    const sparse = try BackendSparse.create(testing.allocator);
    defer sparse.destroy();
    sparse.fill_rule = .even_odd;
    frame.replay(sparse.interface());
    try testing.expectEqual(@as(usize, 1), sparse.clip_push_count);
    try testing.expectEqual(@as(usize, 1), sparse.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), sparse.clip_depth);
    try testing.expect(sparse.build());
    // Re-baselined after text crispness change: 8x glyph coverage supersampling
    // (sample_grid 4 -> 8) + per-glyph baseline snap to the device-pixel grid.
    try expectSurfaceHash(sparse.surface.items, 0x3c3a89753d0edef1);
    try expectPixel(sparse.surface.items, 96, 3, 3, .{ 20, 26, 33, 255 });
    try expectPixel(sparse.surface.items, 96, 14, 14, .{ 169, 186, 213, 255 });
    try expectPixel(sparse.surface.items, 96, 50, 26, .{ 141, 154, 174, 255 });
    try expectPixel(sparse.surface.items, 96, 26, 54, .{ 97, 120, 73, 255 });
}

fn captureGoldenScene(gpa: std.mem.Allocator) !CapturedFrame {
    var frame = CapturedFrame.init(gpa);
    errdefer frame.deinit();

    const ctx = try Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();
    ctx.installBackend(frame.interface());

    const font_id = loadTestFont(ctx) orelse return error.SkipZigTest;

    frame_ops.beginFrame(ctx, 96, 72, 1);
    const image_id = createImage(ctx);

    paint_ops.fillColor(ctx, color.rgbaf(0.08, 0.10, 0.13, 1));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 96, 72);
    render_ops.fill(ctx);

    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 4, 4, 88, 62, 8);
    render_ops.pushClipPath(ctx, .nonzero);

    paint_ops.fillColor(ctx, color.rgbaf(0.16, 0.24, 0.34, 1));
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 8, 8, 80, 28, 5);
    render_ops.fill(ctx);

    if (image_id != .none) {
        updateImageSubrect(ctx, image_id);
        paint_ops.fillPaint(ctx, paint_ops.imagePattern(ctx, 12, 12, 20, 20, 0.2, @intCast(@intFromEnum(image_id)), 0.85));
        path_ops.beginPath(ctx);
        path_ops.roundedRect(ctx, 12, 12, 30, 22, 4);
        render_ops.fill(ctx);
    }

    state_ops.save(ctx);
    state_ops.scissor(ctx, 6, 38, 84, 22);
    paint_ops.fillColor(ctx, color.rgbaf(0.75, 0.92, 0.48, 0.45));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 40, 96, 16);
    render_ops.fill(ctx);
    state_ops.restore(ctx);

    paint_ops.strokeColor(ctx, color.rgbaf(1.0, 0.78, 0.2, 0.9));
    state_ops.strokeWidth(ctx, 3);
    state_ops.lineCap(ctx, .round);
    state_ops.lineJoin(ctx, .round);
    state_ops.lineDash(ctx, &.{ 8, 4 });
    state_ops.lineDashOffset(ctx, 2);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 10, 62);
    path_ops.lineTo(ctx, 36, 44);
    path_ops.bezierTo(ctx, 48, 34, 72, 68, 88, 48);
    render_ops.stroke(ctx);
    state_ops.lineDash(ctx, &.{});

    text_ops.fontFaceId(ctx, font_id);
    text_ops.fontSize(ctx, 18);
    paint_ops.fillColor(ctx, color.rgbaf(0.92, 0.94, 1.0, 0.95));
    _ = text_ops.text(ctx, 48, 28, "AV");

    render_ops.popClipPath(ctx);

    frame_ops.cancelFrame(ctx);
    return frame;
}

fn createImage(ctx: *Context) ImageId {
    const pixels = [_]u8{
        255, 255, 255, 255, 35,  90,  175, 255,
        35,  90,  175, 255, 255, 255, 255, 255,
    };
    return image_ops.createImageRGBA(ctx, 2, 2, &pixels);
}

fn updateImageSubrect(ctx: *Context, id: ImageId) void {
    const pixel = [_]u8{ 180, 210, 255, 255 };
    image_ops.updateImageRect(ctx, id, 1, 0, 1, 1, &pixel);
}

fn loadTestFont(ctx: *Context) ?c_int {
    const id = text_ops.createFont(ctx, "golden", "/usr/share/fonts/TTF/Vera.ttf");
    return if (id > 0) id else null;
}

fn countEvents(frame: CapturedFrame, kind: EventKind) usize {
    var count: usize = 0;
    for (frame.events.items) |event| {
        if (event.kind == kind) count += 1;
    }
    return count;
}

fn hasTextureSubrectUpdate(frame: CapturedFrame) bool {
    for (frame.events.items) |event| {
        if (event.kind != .update_texture) continue;
        if (event.tex_x != 0 or event.tex_y != 0) return true;
        if (event.tex_width < 2048 and event.tex_height < 2048) return true;
    }
    return false;
}

fn expectSurfaceHash(surface: []const u8, expected: u64) !void {
    const actual = fnv1a64(surface);
    if (actual != expected) {
        std.debug.print("surface hash mismatch: expected 0x{x}, actual 0x{x}\n", .{ expected, actual });
        return error.SurfaceHashMismatch;
    }
}

fn expectPixel(surface: []const u8, width: u32, x: u32, y: u32, expected: [4]u8) !void {
    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    const actual = [4]u8{
        surface[index + 0],
        surface[index + 1],
        surface[index + 2],
        surface[index + 3],
    };
    if (!std.mem.eql(u8, &actual, &expected)) {
        std.debug.print("pixel {d},{d} mismatch: expected {any}, actual {any}\n", .{ x, y, expected, actual });
        return error.PixelMismatch;
    }
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}
