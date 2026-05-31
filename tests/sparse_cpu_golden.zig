const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Context = okys.state.context.Context;
const sparse = okys.systems.backend_sparse_strip;
const Backend = sparse.Backend;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "sparse CPU proof golden covers subpixel boundary probes" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 28, 1);

    const points = [_]Point{
        .{ .x = 4.25, .y = 4.25 },
        .{ .x = 23.75, .y = 4.25 },
        .{ .x = 23.75, .y = 19.75 },
        .{ .x = 4.25, .y = 19.75 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = points.len, .closed = true, .convex = true }};
    const paint = color.solid(color.rgbaf(0.2, 0.7, 1.0, 0.75));
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 4.25, 4.25, 23.75, 19.75 }, &paths, &points);

    try testing.expect(backend.build());
    try expectSurfaceHash(backend.surface.items, 0x62d2fa4741f62f0d);
    try expectPixel(backend.surface.items, 32, 4, 4, .{ 21, 75, 107, 107 });
    try expectPixel(backend.surface.items, 32, 5, 5, .{ 38, 134, 191, 191 });
    try expectPixel(backend.surface.items, 32, 23, 19, .{ 21, 75, 107, 107 });
    try expectPixel(backend.surface.items, 32, 24, 20, .{ 0, 0, 0, 0 });
}

test "sparse CPU proof golden covers curves holes stroke paints and scissor" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 64, 48, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0.10, 0.12, 0.16, 1));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 64, 48);
    render_ops.fill(ctx);

    const gradient = paint_ops.linearGradient(ctx, 6, 6, 48, 30, color.rgbaf(1, 0.2, 0.1, 0.80), color.rgbaf(0.1, 0.25, 1, 0.70));
    paint_ops.fillPaint(ctx, gradient);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 7, 34);
    path_ops.bezierTo(ctx, 12, 5, 48, 5, 56, 34);
    path_ops.lineTo(ctx, 34, 43);
    path_ops.closePath(ctx);
    render_ops.fill(ctx);

    paint_ops.fillColor(ctx, color.rgbaf(0.95, 0.95, 0.90, 0.90));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 10, 8, 22, 22);
    path_ops.rect(ctx, 16, 14, 10, 10);
    render_ops.fill(ctx);

    const checker = [_]u8{
        255, 255, 255, 255, 30,  80,  170, 255,
        30,  80,  170, 255, 255, 255, 255, 255,
    };
    const image_id = image_ops.createImageRGBA(ctx, 2, 2, &checker);
    try testing.expect(image_id != .none);
    paint_ops.fillPaint(ctx, paint_ops.imagePattern(ctx, 34, 10, 14, 14, 0.2, @intCast(@intFromEnum(image_id)), 0.75));
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 34, 10, 22, 20, 4);
    render_ops.fill(ctx);

    paint_ops.strokeColor(ctx, color.rgbaf(1, 0.85, 0.3, 0.80));
    state_ops.strokeWidth(ctx, 4);
    state_ops.lineJoin(ctx, .round);
    state_ops.lineCap(ctx, .round);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 8, 40);
    path_ops.lineTo(ctx, 24, 28);
    path_ops.bezierTo(ctx, 36, 18, 44, 48, 58, 30);
    render_ops.stroke(ctx);

    state_ops.save(ctx);
    state_ops.scissor(ctx, 8, 36, 48, 8);
    paint_ops.fillColor(ctx, color.rgbaf(0.8, 1.0, 0.65, 0.45));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 34, 64, 10);
    render_ops.fill(ctx);
    state_ops.restore(ctx);

    try testing.expect(backend.build());
    try expectSurfaceHash(backend.surface.items, 0x6f706bc49510390c);
    try expectPixel(backend.surface.items, 64, 2, 2, .{ 26, 31, 41, 255 });
    try expectPixel(backend.surface.items, 64, 12, 12, .{ 221, 221, 211, 255 });
    try expectPixel(backend.surface.items, 64, 20, 18, .{ 232, 223, 216, 255 });
    try expectPixel(backend.surface.items, 64, 42, 16, .{ 82, 106, 182, 255 });
    try expectPixel(backend.surface.items, 64, 22, 38, .{ 144, 143, 147, 255 });
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
