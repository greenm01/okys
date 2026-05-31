const testing = @import("std").testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const Context = okys.state.context.Context;
const flatten = okys.systems.flatten;
const image_ops = okys.ops.image;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;
const Point = okys.types.path.Point;
const PathRange = okys.types.path.PathRange;

test "context diagnostics record and reset invalid operations" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    state_ops.restore(ctx);
    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.unbalanced_restore);

    const pixels = [_]u8{ 1, 2, 3, 4 } ** 4;
    const id = image_ops.createImageRGBA(ctx, 2, 2, &pixels);
    try testing.expect(id != .none);

    const one_pixel = [_]u8{ 1, 2, 3, 4 };
    image_ops.updateImage(ctx, @enumFromInt(999), &one_pixel);
    image_ops.deleteImage(ctx, @enumFromInt(999));
    try testing.expectEqual(@as(u32, 2), ctx.diagnostics.invalid_image_id);

    image_ops.updateImage(ctx, id, &one_pixel);
    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.invalid_image_data);

    image_ops.updateImageRect(ctx, id, 2, 0, 1, 1, &one_pixel);
    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.out_of_range_image_rect);

    ctx.resetDiagnostics();
    try testing.expectEqual(@as(u32, 0), ctx.diagnostics.unbalanced_restore);
    try testing.expectEqual(@as(u32, 0), ctx.diagnostics.invalid_image_id);
    try testing.expectEqual(@as(u32, 0), ctx.diagnostics.invalid_image_data);
    try testing.expectEqual(@as(u32, 0), ctx.diagnostics.out_of_range_image_rect);
}

test "render diagnostics record out of range path slices" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    try ctx.cache.points.append(ctx.gpa, Point{ .x = 1, .y = 1 });
    try ctx.cache.paths.append(ctx.gpa, PathRange{ .point_start = 1, .point_count = 1 });
    render_ops.fill(ctx);

    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.out_of_range_path_slice);
    try testing.expectEqual(@as(usize, 0), backend.fill_calls);
}

test "flatten diagnostics record malformed command streams" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    ctx.commands.data.append(ctx.gpa, 99) catch unreachable;
    flatten.flatten(ctx);

    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.malformed_command_stream);
}

test "flatten diagnostics record truncated command streams" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    ctx.commands.data.append(ctx.gpa, 0) catch unreachable;
    ctx.commands.data.append(ctx.gpa, 12) catch unreachable;
    flatten.flatten(ctx);

    try testing.expectEqual(@as(u32, 1), ctx.diagnostics.malformed_command_stream);
}
