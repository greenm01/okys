const testing = @import("std").testing;

const okys = @import("okys");
const ImageId = okys.types.image.ImageId;
const Textures = okys.state.textures.Textures;

test "texture table issues monotonic ids and stores dimensions" {
    var textures = Textures.init(testing.allocator);
    defer textures.deinit();

    const first = try textures.create(16, 8, .rgba8);
    const second = try textures.create(4, 4, .a8);

    try testing.expect(first != .none);
    try testing.expect(second != .none);
    try testing.expect(@intFromEnum(second) > @intFromEnum(first));
    try testing.expectEqual(@as(usize, 2), textures.list.items.len);
    try testing.expectEqual([2]u32{ 16, 8 }, textures.size(first).?);
    try testing.expectEqual([2]u32{ 4, 4 }, textures.size(second).?);
}

test "texture table deletes by swap remove without reusing ids" {
    var textures = Textures.init(testing.allocator);
    defer textures.deinit();

    const first = try textures.create(1, 1, .rgba8);
    const second = try textures.create(2, 2, .rgba8);

    try testing.expect(textures.remove(first));
    try testing.expect(textures.get(first) == null);
    try testing.expect(textures.get(second) != null);

    const third = try textures.create(3, 3, .rgba8);
    try testing.expect(@intFromEnum(third) > @intFromEnum(second));
}

test "texture table rejects null and zero-sized resources" {
    var textures = Textures.init(testing.allocator);
    defer textures.deinit();

    try testing.expectEqual(ImageId.none, try textures.create(0, 1, .rgba8));
    try testing.expectEqual(ImageId.none, try textures.create(1, 0, .rgba8));
    try testing.expect(!textures.remove(.none));
    try testing.expect(textures.size(.none) == null);
}
