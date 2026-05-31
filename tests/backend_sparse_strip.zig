const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Vertex = okys.types.path.Vertex;
const sparse = okys.systems.backend_sparse_strip;
const Backend = sparse.Backend;
const Context = okys.state.context.Context;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "sparse backend records viewport and clears queued proof buffers on flush" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    iface.viewport(iface.ctx, 64, 48, 2);
    try testing.expectEqual(@as(f32, 64), backend.viewport_width);
    try testing.expectEqual(@as(f32, 48), backend.viewport_height);
    try testing.expectEqual(@as(f32, 2), backend.viewport_dpr);

    queueRect(&iface, 4, 4, 12, 12);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 4), backend.segments.items.len);

    iface.flush(iface.ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expectEqual(@as(usize, 0), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 0), backend.segments.items.len);
    try testing.expectEqual(@as(usize, 0), backend.strips.items.len);
    try testing.expectEqual(@as(usize, 0), backend.alphas.items.len);
}

test "sparse encode preserves call range and convex hint for rect" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 64, 64, 1);

    queueRect(&iface, 4, 4, 12, 12);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.fill, backend.calls.items[0].kind);
    try testing.expectEqual(@as(u32, 0), backend.calls.items[0].segments.start);
    try testing.expectEqual(@as(u32, 4), backend.calls.items[0].segments.count);
    try testing.expect(backend.calls.items[0].convex);
    try testing.expectEqual(@as(u32, 0), backend.segments.items[0].call_index);
    try testing.expectEqual(@as(u32, 0), backend.segments.items[0].path_index);
}

test "sparse binning emits one strip per covered call tile" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 64, 64, 1);

    queueRect(&iface, 0, 0, 32, 32);
    try testing.expect(backend.build());

    try testing.expectEqual(@as(usize, 16), backend.tiles.items.len);
    try testing.expectEqual(@as(usize, 4), backend.strips.items.len);
    try testing.expectEqual(@as(u16, 0), backend.strips.items[0].x);
    try testing.expectEqual(@as(u16, 0), backend.strips.items[0].y);
    try testing.expectEqual(@as(u16, 16), backend.strips.items[1].x);
    try testing.expectEqual(@as(u16, 0), backend.strips.items[1].y);
    try testing.expectEqual(@as(u32, 4), backend.strips.items[0].segment_indices.count);
}

test "sparse fine stage covers solid rect interior and leaves exterior empty" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4, 4, 12, 12);
    try testing.expect(backend.build());

    try testing.expectEqual(@as(usize, 1), backend.strips.items.len);
    const strip = backend.strips.items[0];
    try testing.expectEqual(sparse.strip.tile_area, strip.alpha.count);
    try testing.expectEqual(@as(u8, 255), alphaAt(backend, strip, 8, 8));
    try testing.expectEqual(@as(u8, 0), alphaAt(backend, strip, 1, 1));
}

test "sparse fine stage uses analytic subpixel coverage" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4.25, 4.25, 12.25, 12.25);
    try testing.expect(backend.build());

    const strip = findStrip(backend, 0, 0, 0).?;
    try expectAlphaApprox(143, alphaAt(backend, strip, 4, 4));
    try testing.expectEqual(@as(u8, 255), alphaAt(backend, strip, 5, 5));
    try expectAlphaApprox(16, alphaAt(backend, strip, 12, 12));
    try testing.expectEqual(@as(u8, 0), alphaAt(backend, strip, 3, 4));
}

test "sparse even odd coverage cuts a hole from nested paths" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 18, .y = 2 },
        .{ .x = 18, .y = 18 },
        .{ .x = 2, .y = 18 },
        .{ .x = 7, .y = 7 },
        .{ .x = 13, .y = 7 },
        .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 13 },
    };
    const paths = [_]PathRange{
        .{ .point_start = 0, .point_count = 4, .closed = true, .convex = false },
        .{ .point_start = 4, .point_count = 4, .closed = true, .convex = false },
    };
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 2, 2, 18, 18 }, &paths, &points);
    try testing.expect(backend.build());

    const strip = findStrip(backend, 0, 0, 0).?;
    try testing.expectEqual(@as(u8, 255), alphaAt(backend, strip, 4, 4));
    try testing.expectEqual(@as(u8, 0), alphaAt(backend, strip, 10, 10));
}

test "sparse even odd coverage folds self-overlapping path area" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 18, .y = 4 },
        .{ .x = 18, .y = 18 },
        .{ .x = 4, .y = 18 },
        .{ .x = 4, .y = 4 },
        .{ .x = 18, .y = 4 },
        .{ .x = 18, .y = 18 },
        .{ .x = 4, .y = 18 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 8, .closed = true, .convex = false }};
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 4, 4, 18, 18 }, &paths, &points);
    try testing.expect(backend.build());

    const strip = findStrip(backend, 0, 0, 0).?;
    try testing.expectEqual(@as(u8, 0), alphaAt(backend, strip, 8, 8));
}

test "sparse solid paint composites into proof surface" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 2, 2));
}

test "sparse solid paint composites calls in draw order" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    queuePaintedRect(&iface, color.rgbaf(0, 0, 1, 0.5), 4, 4, 20, 20);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, rgbaAt(backend, 8, 8));
}

test "sparse linear gradient resolves into proof surface" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = paint_ops.linearGradient(ctx, 0, 0, 16, 0, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1));
    queuePaintRect(&iface, paint, 0, 0, 16, 16, disabled_scissor);
    try testing.expect(backend.build());

    const mid = rgbaAt(backend, 8, 8);
    try testing.expect(mid[0] > 80 and mid[0] < 180);
    try testing.expect(mid[2] > 80 and mid[2] < 180);
    try testing.expectEqual(@as(u8, 255), mid[3]);
}

test "sparse radial gradient resolves center and edge colors" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = paint_ops.radialGradient(ctx, 8, 8, 0, 10, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1));
    queuePaintRect(&iface, paint, 0, 0, 18, 18, disabled_scissor);
    try testing.expect(backend.build());

    const center = rgbaAt(backend, 8, 8);
    const edge = rgbaAt(backend, 17, 8);
    try testing.expect(center[0] > center[2]);
    try testing.expect(edge[2] > edge[0]);
}

test "sparse image pattern samples uploaded rgba texture" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const id = image_ops.createImageRGBA(ctx, 2, 2, &pixels);
    try testing.expect(id != .none);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 2, 2, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 8, 8, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgbaAt(backend, 0, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(backend, 1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, rgbaAt(backend, 0, 1));
}

test "sparse image pattern filters between texels" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 8, 4, 1);

    const pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255,
    };
    const id = image_ops.createImageRGBA(ctx, 2, 1, &pixels);
    try testing.expect(id != .none);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 4, 1, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 4, 1, disabled_scissor);
    try testing.expect(backend.build());

    const left_blend = rgbaAt(backend, 1, 0);
    try testing.expect(left_blend[0] > left_blend[1]);
    try testing.expect(left_blend[1] > 0);

    const right_blend = rgbaAt(backend, 2, 0);
    try testing.expect(right_blend[1] > right_blend[0]);
    try testing.expect(right_blend[0] > 0);
}

test "sparse image update changes later proof output" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 16, 16, 1);

    var pixels = [_]u8{ 255, 0, 0, 255 };
    const id = image_ops.createImageRGBA(ctx, 1, 1, &pixels);
    try testing.expect(id != .none);
    pixels = .{ 0, 0, 255, 255 };
    image_ops.updateImage(ctx, id, &pixels);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 1, 1, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 4, 4, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, rgbaAt(backend, 1, 1));
}

test "sparse scissor masks proof surface" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const scissor: color.Scissor = .{
        .xform = .{ 1, 0, 0, 1, 8, 8 },
        .extent = .{ 4, 4 },
    };
    queuePaintRect(&iface, color.solid(color.rgbaf(0, 1, 0, 1)), 0, 0, 16, 16, scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 2, 2));
}

test "sparse gradient composites over solid fill in draw order" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 0, 0, 16, 16);
    const paint = paint_ops.linearGradient(ctx, 0, 0, 16, 0, color.rgbaf(0, 0, 1, 0.5), color.rgbaf(0, 0, 1, 0.5));
    queuePaintRect(&iface, paint, 0, 0, 16, 16, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, rgbaAt(backend, 8, 8));
}

test "sparse frontend curve renders through analytic proof path" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 32, 32, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0, 1, 0, 1));
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 4, 22);
    path_ops.bezierTo(ctx, 7, 4, 25, 4, 28, 22);
    path_ops.lineTo(ctx, 16, 28);
    path_ops.closePath(ctx);
    render_ops.fill(ctx);

    try testing.expect(backend.build());
    try testing.expect(backend.strips.items.len > 0);
    try testing.expect(backend.alphas.items.len > 0);
    try testing.expect(rgbaAt(backend, 16, 18)[1] > 0);
}

test "sparse backend queues stroke outlines as path segments" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 16, .y = 4 },
        .{ .x = 10, .y = 16 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.stroke(iface.ctx, &paint, &disabled_scissor, 3, &paths, &points);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.stroke, backend.calls.items[0].kind);
    try testing.expectEqual(@as(f32, 3), backend.calls.items[0].width);
    try testing.expectEqual(@as(u32, 3), backend.calls.items[0].segments.count);
}

test "sparse backend texture callbacks store dimensions" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    const id: ImageId = @enumFromInt(42);

    try testing.expect(iface.create_texture(iface.ctx, id, 7, 9, .rgba8, null));
    try testing.expectEqual([2]u32{ 7, 9 }, iface.texture_size(iface.ctx, id).?);
    iface.delete_texture(iface.ctx, id);
    try testing.expect(iface.texture_size(iface.ctx, id) == null);
}

test "sparse triangle input encodes one closed triangle segment set" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const verts = [_]Vertex{
        .{ .x = 4, .y = 4, .u = 0, .v = 0 },
        .{ .x = 14, .y = 4, .u = 0, .v = 0 },
        .{ .x = 4, .y = 14, .u = 0, .v = 0 },
    };
    iface.triangles(iface.ctx, &paint, &disabled_scissor, &verts);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.triangles, backend.calls.items[0].kind);
    try testing.expectEqual(@as(u32, 3), backend.calls.items[0].segments.count);
}

fn queueRect(iface: *const okys.render.interface.RenderInterface, x0: f32, y0: f32, x1: f32, y1: f32) void {
    queuePaintedRect(iface, color.rgbaf(1, 1, 1, 1), x0, y0, x1, y1);
}

fn queuePaintedRect(iface: *const okys.render.interface.RenderInterface, c: color.Color, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const paint = color.solid(c);
    queuePaintRect(iface, paint, x0, y0, x1, y1, disabled_scissor);
}

fn queuePaintRect(iface: *const okys.render.interface.RenderInterface, paint: color.Paint, x0: f32, y0: f32, x1: f32, y1: f32, scissor: color.Scissor) void {
    const points = [_]Point{
        .{ .x = x0, .y = y0 },
        .{ .x = x1, .y = y0 },
        .{ .x = x1, .y = y1 },
        .{ .x = x0, .y = y1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};
    iface.fill(iface.ctx, &paint, &scissor, .{ x0, y0, x1, y1 }, &paths, &points);
}

fn alphaAt(backend: *const Backend, s: sparse.Strip, x: u16, y: u16) u8 {
    const local_x = x - s.x;
    const local_y = y - s.y;
    const alpha_start: usize = @intCast(s.alpha.start);
    const index = alpha_start + @as(usize, local_y) * sparse.strip.tile_size + local_x;
    return backend.alphas.items[index];
}

fn findStrip(backend: *const Backend, x: u16, y: u16, call_index: u32) ?sparse.Strip {
    for (backend.strips.items) |s| {
        if (s.x == x and s.y == y and s.call_index == call_index) return s;
    }
    return null;
}

fn rgbaAt(backend: *const Backend, x: u32, y: u32) [4]u8 {
    const width: u32 = @intFromFloat(@ceil(backend.viewport_width));
    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    return backend.surface.items[index..][0..4].*;
}

fn expectAlphaApprox(expected: u8, actual: u8) !void {
    const delta = @abs(@as(i16, expected) - @as(i16, actual));
    try testing.expect(delta <= 1);
}
