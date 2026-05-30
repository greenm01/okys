const testing = @import("std").testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const Context = okys.state.context.Context;
const image_ops = okys.ops.image;

test "raw rgba image creation records table entry and backend texture" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const pixels = [_]u8{ 255, 0, 0, 255 } ** 4;
    const id = image_ops.createImageRGBA(ctx, 2, 2, &pixels);

    try testing.expect(id != .none);
    try testing.expectEqual(@as(usize, 1), ctx.textures.list.items.len);
    try testing.expectEqual(@as(usize, 1), backend.create_texture_calls);
    try testing.expectEqual(id, backend.last_texture_id);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_width);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_height);
    try testing.expectEqual(@as(usize, pixels.len), backend.last_texture_data_len);
    try testing.expectEqual([2]u32{ 2, 2 }, image_ops.imageSize(ctx, id).?);
}

test "image creation rejects invalid input and rolls back backend failure" {
    var backend: mock_backend.MockBackend = .{ .fail_create_texture = true };
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const too_short = [_]u8{ 0, 0, 0, 0 };
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBA(ctx, 0, 2, null)));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBA(ctx, 2, 2, &too_short)));

    const pixels = [_]u8{ 255, 255, 255, 255 } ** 4;
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBA(ctx, 2, 2, &pixels)));
    try testing.expectEqual(@as(usize, 0), ctx.textures.list.items.len);
    try testing.expectEqual(@as(usize, 1), backend.create_texture_calls);
}

test "image update delete and size route through backend and table" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const pixels = [_]u8{ 1, 2, 3, 4 } ** 4;
    const id = image_ops.createImageRGBA(ctx, 2, 2, &pixels);
    const replacement = [_]u8{ 5, 6, 7, 8 } ** 4;

    image_ops.updateImage(ctx, id, &replacement);
    try testing.expectEqual(@as(usize, 1), backend.update_texture_calls);
    try testing.expectEqual(id, backend.last_update_id);
    try testing.expectEqual(@as(u32, 2), backend.last_update_width);
    try testing.expectEqual(@as(u32, 2), backend.last_update_height);
    try testing.expectEqual(@as(usize, replacement.len), backend.last_update_data_len);

    try testing.expectEqual([2]u32{ 2, 2 }, image_ops.imageSize(ctx, id).?);
    try testing.expectEqual(@as(usize, 1), backend.texture_size_calls);

    image_ops.deleteImage(ctx, id);
    try testing.expectEqual(@as(usize, 1), backend.delete_texture_calls);
    try testing.expectEqual(id, backend.last_deleted_id);
    try testing.expect(ctx.textures.get(id) == null);
    try testing.expect(image_ops.imageSize(ctx, id) == null);
}

test "image operations are no-ops without a backend" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pixels = [_]u8{ 1, 2, 3, 4 };
    const id = image_ops.createImageRGBA(ctx, 1, 1, &pixels);
    try testing.expectEqual(@as(u32, 0), @intFromEnum(id));

    image_ops.updateImage(ctx, @enumFromInt(99), &pixels);
    image_ops.deleteImage(ctx, @enumFromInt(99));
    try testing.expect(image_ops.imageSize(ctx, @enumFromInt(99)) == null);
}
