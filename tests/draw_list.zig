const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const Vertex = okys.types.path.Vertex;
const BackendSparse = okys.systems.backend_sparse_strip.Backend;
const BackendStencil = okys.systems.backend_stencil.Backend;
const Context = okys.state.context.Context;
const DrawList = okys.render.draw_list.DrawList;
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

test "draw list records through a context and replays after context teardown" {
    var list = try recordScene(testing.allocator, 64, 64);
    defer list.deinit();

    try testing.expect(!list.isEmpty());
    try testing.expect(list.eventCount() > 6);

    var mock: mock_backend.MockBackend = .{};
    list.replay(mock.interface());

    try testing.expectEqual(@as(usize, 1), mock.viewport_calls);
    try testing.expectEqual(@as(usize, 2), mock.fill_calls);
    try testing.expectEqual(@as(usize, 1), mock.stroke_calls);
    try testing.expectEqual(@as(usize, 1), mock.triangles_calls);
    try testing.expectEqual(@as(usize, 1), mock.push_clip_path_calls);
    try testing.expectEqual(@as(usize, 1), mock.pop_clip_path_calls);
    try testing.expectEqual(@as(usize, 0), mock.clip_depth);
    try testing.expect(mock.last_stroke.point_count > 0);
    try testing.expect(mock.last_stroke.points_ptr != 0);
}

test "draw list owns texture bytes subrect updates and triangle data" {
    var list = try recordScene(testing.allocator, 64, 64);
    defer list.deinit();

    var mock: mock_backend.MockBackend = .{};
    list.replay(mock.interface());

    try testing.expectEqual(@as(usize, 1), mock.create_texture_calls);
    try testing.expectEqual(@as(usize, 1), mock.update_texture_calls);
    try testing.expectEqual(@as(u32, 2), mock.last_texture_width);
    try testing.expectEqual(@as(u32, 2), mock.last_texture_height);
    try testing.expectEqual(@as(usize, 16), mock.last_texture_data_len);
    try testing.expectEqual(@as(u32, 1), mock.last_update_x);
    try testing.expectEqual(@as(u32, 0), mock.last_update_y);
    try testing.expectEqual(@as(u32, 1), mock.last_update_width);
    try testing.expectEqual(@as(u32, 2), mock.last_update_height);
    try testing.expectEqual(@as(usize, 8), mock.last_update_data_len);
    try testing.expectEqual(@as(usize, 3), mock.last_triangles.vertex_count);
    try testing.expect(mock.last_triangles.verts_ptr != 0);
    try testing.expectApproxEqAbs(@as(f32, 48), mock.last_triangles.first_vertex.x, 0.001);
}

test "draw list clear retains a reusable value for a second recording" {
    var list = try recordScene(testing.allocator, 64, 64);
    defer list.deinit();
    const first_count = list.eventCount();
    try testing.expect(first_count > 0);

    list.clear();
    try testing.expect(list.isEmpty());

    try recordSimpleFill(&list, testing.allocator, 32, 32);
    try testing.expect(list.eventCount() > 0);
    try testing.expect(list.eventCount() < first_count);

    var mock: mock_backend.MockBackend = .{};
    list.replay(mock.interface());
    try testing.expectEqual(@as(usize, 1), mock.viewport_calls);
    try testing.expectEqual(@as(usize, 1), mock.fill_calls);
    try testing.expectEqual(@as(usize, 0), mock.stroke_calls);
    try testing.expectEqual(@as(usize, 0), mock.triangles_calls);
}

test "draw list replays into stencil cover backend" {
    var list = try recordScene(testing.allocator, 64, 64);
    defer list.deinit();

    const backend = try BackendStencil.createWithFlags(testing.allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer backend.destroy();
    list.replay(backend.interface());

    try testing.expectEqual(@as(usize, 1), backend.clip_push_count);
    try testing.expectEqual(@as(usize, 1), backend.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), backend.clip_depth);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
}

test "draw list replays into sparse strip backend" {
    var list = try recordScene(testing.allocator, 64, 64);
    defer list.deinit();

    const backend = try BackendSparse.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    list.replay(backend.interface());

    try testing.expectEqual(@as(usize, 1), backend.clip_push_count);
    try testing.expectEqual(@as(usize, 1), backend.clip_pop_count);
    try testing.expectEqual(@as(usize, 0), backend.clip_depth);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expect(backend.surface.items.len > 0);
}

fn recordScene(gpa: std.mem.Allocator, w: f32, h: f32) !DrawList {
    var list = DrawList.init(gpa);
    errdefer list.deinit();
    try recordSceneInto(&list, gpa, w, h);
    return list;
}

fn recordSceneInto(list: *DrawList, gpa: std.mem.Allocator, w: f32, h: f32) !void {
    const ctx = try Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();
    ctx.installBackend(list.interface());

    frame_ops.beginFrame(ctx, w, h, 1);
    const image_id = createCheckerImage(ctx);

    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 2, 2, 54, 54);
    render_ops.pushClipPath(ctx, .even_odd);

    paint_ops.fillColor(ctx, color.rgbaf(0.1, 0.2, 0.3, 1));
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 4, 4, 24, 18, 4);
    render_ops.fill(ctx);

    if (image_id != .none) {
        updateCheckerSubrect(ctx, image_id);
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

    queueTriangle(list);
    frame_ops.endFrame(ctx);
}

fn recordSimpleFill(list: *DrawList, gpa: std.mem.Allocator, w: f32, h: f32) !void {
    const ctx = try Context.create(gpa, OKY_ANTIALIAS);
    defer ctx.destroy();
    ctx.installBackend(list.interface());

    frame_ops.beginFrame(ctx, w, h, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0.2, 0.4, 0.8, 1));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 4, 4, 12, 12);
    render_ops.fill(ctx);
    frame_ops.endFrame(ctx);
}

fn createCheckerImage(ctx: *Context) ImageId {
    const pixels = [_]u8{
        255, 255, 255, 255, 40,  80,  160, 255,
        40,  80,  160, 255, 255, 255, 255, 255,
    };
    return image_ops.createImageRGBA(ctx, 2, 2, &pixels);
}

fn updateCheckerSubrect(ctx: *Context, id: ImageId) void {
    const pixels = [_]u8{
        80, 40, 160, 255,
        80, 40, 160, 255,
    };
    image_ops.updateImageRect(ctx, id, 1, 0, 1, 2, &pixels);
}

fn queueTriangle(list: *DrawList) void {
    const paint = color.solid(color.rgbaf(0.8, 0.2, 0.2, 0.7));
    const verts = [_]Vertex{
        .{ .x = 48, .y = 40, .u = 0, .v = 0 },
        .{ .x = 58, .y = 40, .u = 1, .v = 0 },
        .{ .x = 48, .y = 54, .u = 0, .v = 1 },
    };
    const iface = list.interface();
    iface.triangles(iface.ctx, &paint, &disabled_scissor, &verts);
}
