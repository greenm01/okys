const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const GlyphAtlas = okys.state.glyph_atlas.GlyphAtlas;
const GlyphId = okys.types.text.GlyphId;
const GlyphMetrics = okys.types.text.GlyphMetrics;
const Context = okys.state.context.Context;
const state_ops = okys.ops.state;
const text_ops = okys.ops.text;
const frame_ops = okys.ops.frame;
const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const StencilBackend = okys.systems.backend_stencil.Backend;
const CallType = okys.systems.backend_stencil.CallType;
const MockBackend = @import("mock_backend.zig").MockBackend;

test "glyph atlas writes alpha mask as white rgba with transparent padding" {
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(testing.allocator);

    try atlas.initStorage(testing.allocator, @enumFromInt(7), 8, 8);
    const id = try atlas.addGlyphAlpha(testing.allocator, &.{ 0, 64, 128, 255 }, 2, 2, .{
        .advance_x = 3,
    });
    try testing.expect(id != .none);

    const glyph = atlas.get(id).?;
    try testing.expectEqual(@as(u32, 1), glyph.atlas_x);
    try testing.expectEqual(@as(u32, 1), glyph.atlas_y);
    try testing.expectEqual(@as(f32, 3), glyph.advance_x);

    const first = (@as(usize, glyph.atlas_y) * atlas.width + glyph.atlas_x) * 4;
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 0 }, atlas.pixels.items[first..][0..4]);
    const last = ((@as(usize, glyph.atlas_y) + 1) * atlas.width + glyph.atlas_x + 1) * 4;
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, atlas.pixels.items[last..][0..4]);
    try testing.expectEqual(@as(u8, 0), atlas.pixels.items[0]);
}

test "glyph atlas shelf packing advances rows and rejects overflow" {
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(testing.allocator);

    try atlas.initStorage(testing.allocator, @enumFromInt(9), 8, 8);
    const mask = [_]u8{255} ** 4;
    const a = try atlas.addGlyphAlpha(testing.allocator, &mask, 2, 2, .{});
    const b = try atlas.addGlyphAlpha(testing.allocator, &mask, 2, 2, .{});
    const c = try atlas.addGlyphAlpha(testing.allocator, &mask, 2, 2, .{});
    _ = try atlas.addGlyphAlpha(testing.allocator, &mask, 2, 2, .{});

    try testing.expectEqual(@as(u32, 1), atlas.get(a).?.atlas_x);
    try testing.expectEqual(@as(u32, 5), atlas.get(b).?.atlas_x);
    try testing.expectEqual(@as(u32, 1), atlas.get(c).?.atlas_x);
    try testing.expectEqual(@as(u32, 5), atlas.get(c).?.atlas_y);
    try testing.expectError(error.OutOfSpace, atlas.addGlyphAlpha(testing.allocator, &mask, 2, 2, .{}));
}

test "glyph atlas rejects invalid masks and uninitialized storage" {
    var atlas: GlyphAtlas = .{};
    defer atlas.deinit(testing.allocator);

    try testing.expectError(error.NotInitialized, atlas.addGlyphAlpha(testing.allocator, &.{255}, 1, 1, .{}));
    try atlas.initStorage(testing.allocator, @enumFromInt(10), 4, 4);
    try testing.expectError(error.InvalidGlyph, atlas.addGlyphAlpha(testing.allocator, &.{255}, 2, 1, .{}));
    try testing.expectError(error.InvalidGlyph, atlas.addGlyphAlpha(testing.allocator, &.{}, 0, 1, .{}));
}

test "text ops create atlas upload glyph and draw textured quad" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    var mock: MockBackend = .{};
    ctx.installBackend(mock.interface());

    try testing.expect(text_ops.initGlyphAtlas(ctx, 16, 16));
    try testing.expectEqual(@as(usize, 1), mock.create_texture_calls);
    try testing.expectEqual(@as(u32, 16), mock.last_texture_width);
    try testing.expectEqual(@as(usize, 0), mock.last_texture_data_len);

    const mask = [_]u8{ 0, 255, 128, 64 };
    const glyph = text_ops.addGlyphAlpha(ctx, &mask, 2, 2, GlyphMetrics{
        .offset_x = 1,
        .offset_y = 2,
        .advance_x = 4,
    });
    try testing.expect(glyph != GlyphId.none);
    try testing.expectEqual(@as(usize, 1), mock.update_texture_calls);
    try testing.expectEqual(@as(usize, 16 * 16 * 4), mock.last_update_data_len);

    text_ops.drawGlyph(ctx, glyph, 10, 20);
    try testing.expectEqual(@as(usize, 1), mock.triangles_calls);
    try testing.expectEqual(@as(usize, 6), mock.last_triangles.vertex_count);
    try testing.expectEqual(@intFromEnum(ctx.glyph_atlas.image_id), @as(u32, @intCast(mock.last_triangles.paint.image)));
    try testing.expectApproxEqAbs(@as(f32, 11), mock.last_triangles.first_vertex.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 22), mock.last_triangles.first_vertex.y, 0.001);
}

test "draw glyph honors current transform" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    var mock: MockBackend = .{};
    ctx.installBackend(mock.interface());

    try testing.expect(text_ops.initGlyphAtlas(ctx, 16, 16));
    const glyph = text_ops.addGlyphAlpha(ctx, &.{255}, 1, 1, .{});
    state_ops.translate(ctx, 5, 7);
    text_ops.drawGlyph(ctx, glyph, 10, 20);

    try testing.expectEqual(@as(usize, 1), mock.triangles_calls);
    try testing.expectApproxEqAbs(@as(f32, 15), mock.last_triangles.first_vertex.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 27), mock.last_triangles.first_vertex.y, 0.001);
}

test "glyph triangles queue through stencil backend with atlas paint" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try StencilBackend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 32, 32, 1);
    try testing.expect(text_ops.initGlyphAtlas(ctx, 16, 16));
    const glyph = text_ops.addGlyphAlpha(ctx, &.{ 255, 255, 255, 255 }, 2, 2, .{});
    text_ops.drawGlyph(ctx, glyph, 4, 5);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(CallType.triangles, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 6), backend.calls.items[0].vertices.count);
    try testing.expectEqual(@intFromEnum(ctx.glyph_atlas.image_id), @as(u32, @intCast(backend.calls.items[0].paint.image)));
}

test "glyph triangles render through sparse backend proof surface" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try SparseBackend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 32, 32, 1);
    try testing.expect(text_ops.initGlyphAtlas(ctx, 16, 16));
    const glyph = text_ops.addGlyphAlpha(ctx, &.{ 255, 255, 255, 255 }, 2, 2, .{});
    text_ops.drawGlyph(ctx, glyph, 4, 5);

    try testing.expect(backend.build());
    try testing.expect(backend.surface.items.len > 0);
    try testing.expect(rgbaAt(backend, 4, 5)[3] > 0);
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 0, 0));
}

fn rgbaAt(backend: *const SparseBackend, x: usize, y: usize) [4]u8 {
    const width: usize = @intFromFloat(@ceil(backend.viewport_width));
    const index = (y * width + x) * 4;
    return backend.surface.items[index..][0..4].*;
}
