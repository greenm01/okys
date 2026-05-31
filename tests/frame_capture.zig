const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const Vertex = okys.types.path.Vertex;
const BackendSparse = okys.systems.backend_sparse_strip.Backend;
const BackendStencil = okys.systems.backend_stencil.Backend;
const CapturedFrame = okys.render.frame_capture.CapturedFrame;
const Context = okys.state.context.Context;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "captured frame owns draw data after source frame clears" {
    var frame = try captureScene(testing.allocator);
    defer frame.deinit();

    var mock: mock_backend.MockBackend = .{};
    frame.replay(mock.interface());

    try testing.expectEqual(@as(usize, 1), mock.viewport_calls);
    try testing.expectEqual(@as(usize, 2), mock.fill_calls);
    try testing.expectEqual(@as(usize, 1), mock.stroke_calls);
    try testing.expectEqual(@as(usize, 1), mock.push_clip_path_calls);
    try testing.expectEqual(@as(usize, 1), mock.pop_clip_path_calls);
    try testing.expectEqual(@as(usize, 0), mock.clip_depth);
    try testing.expect(mock.last_stroke.point_count > 0);
    try testing.expect(mock.last_stroke.points_ptr != 0);
}

test "captured frame owns and replays clip path data" {
    var frame = try captureScene(testing.allocator);
    defer frame.deinit();

    var mock: mock_backend.MockBackend = .{};
    frame.replay(mock.interface());

    try testing.expectEqual(@as(usize, 1), mock.push_clip_path_calls);
    try testing.expectEqual(@as(usize, 1), mock.pop_clip_path_calls);
    try testing.expectEqual(@as(usize, 1), mock.max_clip_depth);
    try testing.expectEqual(.even_odd, mock.last_clip.rule);
    try testing.expectEqual(@as(usize, 1), mock.last_clip.path_count);
    try testing.expect(mock.last_clip.point_count >= 4);
    try testing.expect(mock.last_clip.paths_ptr != 0);
    try testing.expect(mock.last_clip.points_ptr != 0);
    try testing.expectApproxEqAbs(@as(f32, 2), mock.last_clip.bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), mock.last_clip.bounds[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 56), mock.last_clip.bounds[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 56), mock.last_clip.bounds[3], 0.001);
}

test "captured frame replays texture and draw events into mock backend" {
    var frame = try captureScene(testing.allocator);
    defer frame.deinit();

    var mock: mock_backend.MockBackend = .{};
    frame.replay(mock.interface());

    try testing.expectEqual(@as(usize, 1), mock.create_texture_calls);
    try testing.expectEqual(@as(usize, 1), mock.update_texture_calls);
    try testing.expectEqual(@as(u32, 2), mock.last_texture_width);
    try testing.expectEqual(@as(u32, 2), mock.last_texture_height);
    try testing.expectEqual(@as(usize, 16), mock.last_texture_data_len);
    try testing.expectEqual(@as(usize, 16), mock.last_update_data_len);
    try testing.expectEqual(@as(usize, 1), mock.triangles_calls);
}

test "captured frame replays into stencil cover backend" {
    var frame = try captureScene(testing.allocator);
    defer frame.deinit();

    const backend = try BackendStencil.createWithFlags(testing.allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer backend.destroy();
    frame.replay(backend.interface());

    try testing.expectEqual(@as(usize, 1), backend.clip_push_count);
    try testing.expectEqual(@as(usize, 1), backend.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), backend.clip_depth);
    try testing.expect(backend.buildStencilPass());
    try testing.expect(backend.path_draws.items.len > 0);
    try testing.expect(backend.frag_params.items.len > 0);
}

test "captured frame replays into sparse strip backend" {
    var frame = try captureScene(testing.allocator);
    defer frame.deinit();

    const backend = try BackendSparse.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    frame.replay(backend.interface());

    try testing.expectEqual(@as(usize, 1), backend.clip_push_count);
    try testing.expectEqual(@as(usize, 1), backend.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), backend.clip_depth);
    try testing.expect(backend.build());
    try testing.expect(backend.strips.items.len > 0);
    try testing.expect(backend.alphas.items.len > 0);
    try testing.expect(backend.surface.items.len > 0);
}

fn captureScene(gpa: std.mem.Allocator) !CapturedFrame {
    var frame = CapturedFrame.init(gpa);
    errdefer frame.deinit();

    const ctx = try Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();
    ctx.installBackend(frame.interface());

    frame_ops.beginFrame(ctx, 64, 64, 1);
    const image_id = createCheckerImage(ctx);

    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 2, 2, 54, 54);
    render_ops.pushClipPath(ctx, .even_odd);

    paint_ops.fillColor(ctx, color.rgbaf(0.1, 0.2, 0.3, 1));
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 4, 4, 24, 18, 4);
    render_ops.fill(ctx);

    if (image_id != .none) {
        updateCheckerImage(ctx, image_id);
        paint_ops.fillPaint(ctx, paint_ops.imagePattern(ctx, 28, 4, 12, 12, 0.15, @intCast(@intFromEnum(image_id)), 0.8));
        path_ops.beginPath(ctx);
        path_ops.rect(ctx, 28, 4, 20, 18);
        render_ops.fill(ctx);
    }

    state_ops.scissor(ctx, 0, 0, 64, 64);
    paint_ops.strokeColor(ctx, color.rgbaf(1, 1, 1, 1));
    state_ops.strokeWidth(ctx, 5);
    state_ops.lineJoin(ctx, .round);
    state_ops.lineCap(ctx, .round);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 8, 42);
    path_ops.lineTo(ctx, 24, 32);
    path_ops.lineTo(ctx, 40, 46);
    render_ops.stroke(ctx);
    render_ops.popClipPath(ctx);

    queueTriangle(&frame);
    frame_ops.cancelFrame(ctx);
    return frame;
}

fn createCheckerImage(ctx: *Context) ImageId {
    const pixels = [_]u8{
        255, 255, 255, 255, 40,  80,  160, 255,
        40,  80,  160, 255, 255, 255, 255, 255,
    };
    return image_ops.createImageRGBA(ctx, 2, 2, &pixels);
}

fn updateCheckerImage(ctx: *Context, id: ImageId) void {
    const pixels = [_]u8{
        255, 255, 255, 255, 80,  40,  160, 255,
        80,  40,  160, 255, 255, 255, 255, 255,
    };
    image_ops.updateImage(ctx, id, &pixels);
}

fn queueTriangle(frame: *CapturedFrame) void {
    const paint = color.solid(color.rgbaf(0.8, 0.2, 0.2, 0.7));
    const verts = [_]Vertex{
        .{ .x = 48, .y = 40, .u = 0, .v = 0 },
        .{ .x = 58, .y = 40, .u = 1, .v = 0 },
        .{ .x = 48, .y = 54, .u = 0, .v = 1 },
    };
    const iface = frame.interface();
    iface.triangles(iface.ctx, &paint, &disabled_scissor, &verts);
}
