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

test "rgba ex accepts padded decoded rows from downstream loaders" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const pixels = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  99, 99, 99, 99,
        9, 10, 11, 12, 13, 14, 15, 16, 88, 88, 88, 88,
    };
    const id = image_ops.createImageRGBAEx(ctx, 2, 2, &pixels, 12, 0);

    try testing.expect(id != .none);
    try testing.expectEqual(@as(usize, 1), backend.create_texture_calls);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_width);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_height);
    try testing.expectEqual(@as(usize, 16), backend.last_texture_data_len);
    try testing.expectEqualSlices(u8, &[_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,
        9, 10, 11, 12, 13, 14, 15, 16,
    }, &backend.last_texture_data_prefix);
}

test "rgba ex can allocate an empty texture without decoded pixels" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const id = image_ops.createImageRGBAEx(ctx, 2, 2, null, 0, 0);

    try testing.expect(id != .none);
    try testing.expectEqual(@as(usize, 1), backend.create_texture_calls);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_width);
    try testing.expectEqual(@as(u32, 2), backend.last_texture_height);
    try testing.expectEqual(@as(usize, 0), backend.last_texture_data_len);
}

test "rgba ex rejects invalid decoded pixel layout" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    const too_short = [_]u8{ 1, 2, 3, 4 };
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBAEx(ctx, 2, 2, &too_short, 8, 0)));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBAEx(ctx, 2, 2, &too_short, 4, 0)));
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBAEx(ctx, 2, 2, &too_short, 8, 1)));

    const no_backend = try Context.create(testing.allocator, 0);
    defer no_backend.destroy();
    const pixels = [_]u8{ 255, 255, 255, 255 } ** 4;
    try testing.expectEqual(@as(u32, 0), @intFromEnum(image_ops.createImageRGBAEx(no_backend, 2, 2, &pixels, 0, 0)));
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
    try testing.expectEqual(@as(u32, 0), backend.last_update_x);
    try testing.expectEqual(@as(u32, 0), backend.last_update_y);
    try testing.expectEqual(@as(u32, 2), backend.last_update_width);
    try testing.expectEqual(@as(u32, 2), backend.last_update_height);
    try testing.expectEqual(@as(usize, replacement.len), backend.last_update_data_len);

    const subrect = [_]u8{ 9, 10, 11, 12 };
    image_ops.updateImageRect(ctx, id, 1, 0, 1, 1, &subrect);
    try testing.expectEqual(@as(usize, 2), backend.update_texture_calls);
    try testing.expectEqual(id, backend.last_update_id);
    try testing.expectEqual(@as(u32, 1), backend.last_update_x);
    try testing.expectEqual(@as(u32, 0), backend.last_update_y);
    try testing.expectEqual(@as(u32, 1), backend.last_update_width);
    try testing.expectEqual(@as(u32, 1), backend.last_update_height);
    try testing.expectEqual(@as(usize, subrect.len), backend.last_update_data_len);

    image_ops.updateImageRect(ctx, id, 2, 0, 1, 1, &subrect);
    image_ops.updateImageRect(ctx, id, 0, 0, 2, 2, &subrect);
    try testing.expectEqual(@as(usize, 2), backend.update_texture_calls);

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
