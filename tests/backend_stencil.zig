const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Vertex = okys.types.path.Vertex;
const Backend = okys.systems.backend_stencil.Backend;
const CallType = okys.systems.backend_stencil.CallType;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

const default_scissor: color.Scissor = .{
    .xform = .{ 1, 0, 0, 1, 0, 0 },
    .extent = .{ -1, -1 },
};

test "stencil backend records viewport and clears queues on flush" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    iface.viewport(iface.ctx, 320, 240, 2);
    try testing.expectEqual(@as(f32, 320), backend.viewport_width);
    try testing.expectEqual(@as(f32, 240), backend.viewport_height);
    try testing.expectEqual(@as(f32, 2), backend.viewport_dpr);

    const paint = color.solid(color.rgbaf(1, 0, 0, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};
    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);

    iface.flush(iface.ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expectEqual(@as(usize, 0), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 0), backend.paths.items.len);
    try testing.expectEqual(@as(usize, 0), backend.vertices.items.len);
}

test "stencil backend queues non-convex fill fan and cover quad" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(0.2, 0.4, 0.6, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 20 },
        .{ .x = 0, .y = 20 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false, .winding = .cw }};

    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 20 }, &paths, &points);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(CallType.fill, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 4), backend.calls.items[0].cover.count);
    try testing.expectEqual(@as(u32, 8), backend.calls.items[0].vertices.count);
    try testing.expectEqual(@as(usize, 1), backend.paths.items.len);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.count);
    try testing.expectEqual(@as(f32, 10), backend.vertices.items[0].x);
    try testing.expectEqual(@as(f32, 20), backend.vertices.items[0].y);
    try testing.expectEqual(@as(f32, 0), backend.vertices.items[4].x);
    try testing.expectEqual(@as(f32, 0), backend.vertices.items[4].y);
}

test "stencil backend queues convex fill without cover quad" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 10 }, &paths, &points);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(CallType.fill_convex, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 0), backend.calls.items[0].cover.count);
    try testing.expectEqual(@as(usize, 3), backend.vertices.items.len);
}

test "stencil backend queues antialiased non-convex fill fringe" {
    const backend = try Backend.createWithFlags(testing.allocator, OKY_ANTIALIAS);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 100, 100, 2);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0, .dmx = 1, .dmy = 0 },
        .{ .x = 10, .y = 0, .dmx = 0, .dmy = 1 },
        .{ .x = 10, .y = 10, .dmx = -1, .dmy = 0 },
        .{ .x = 0, .y = 10, .dmx = 0, .dmy = -1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 10 }, &paths, &points);

    try testing.expectEqual(CallType.fill, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 18), backend.calls.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 8), backend.paths.items[0].fringe.start);
    try testing.expectEqual(@as(u32, 10), backend.paths.items[0].fringe.count);
    try testing.expectApproxEqAbs(@as(f32, 0.25), backend.vertices.items[4].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), backend.vertices.items[8].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -0.25), backend.vertices.items[9].x, 0.001);
}

test "stencil backend queues antialiased convex fill fringe" {
    const backend = try Backend.createWithFlags(testing.allocator, OKY_ANTIALIAS);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0, .dmx = 1, .dmy = 0 },
        .{ .x = 10, .y = 0, .dmx = 0, .dmy = 1 },
        .{ .x = 0, .y = 10, .dmx = -1, .dmy = 0 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 10 }, &paths, &points);

    try testing.expectEqual(CallType.fill_convex, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 0), backend.calls.items[0].cover.count);
    try testing.expectEqual(@as(u32, 11), backend.calls.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.paths.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 3), backend.paths.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 3), backend.paths.items[0].fringe.start);
    try testing.expectEqual(@as(u32, 8), backend.paths.items[0].fringe.count);
}

test "stencil backend drops degenerate fill paths" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 2, .closed = false }};

    iface.fill(iface.ctx, &paint, &default_scissor, .{ 0, 0, 10, 0 }, &paths, &points);

    try testing.expectEqual(@as(usize, 0), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 0), backend.vertices.items.len);
}

test "stencil backend queues stroke and triangle snapshots" {
    const backend = try Backend.createWithFlags(testing.allocator, OKY_STENCIL_STROKES);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(0, 1, 0, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};

    iface.stroke(iface.ctx, &paint, &default_scissor, 3, &paths, &points);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(CallType.stroke, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(f32, 3), backend.calls.items[0].width);
    try testing.expectEqual(@as(u32, 4), backend.calls.items[0].cover.count);
    try testing.expectEqual(@as(usize, 8), backend.vertices.items.len);

    const verts = [_]Vertex{
        .{ .x = 0, .y = 0, .u = 0, .v = 0 },
        .{ .x = 1, .y = 0, .u = 1, .v = 0 },
        .{ .x = 0, .y = 1, .u = 0, .v = 1 },
    };
    iface.triangles(iface.ctx, &paint, &default_scissor, &verts);
    try testing.expectEqual(@as(usize, 2), backend.calls.items.len);
    try testing.expectEqual(CallType.triangles, backend.calls.items[1].call_type);
    try testing.expectEqual(@as(u32, 3), backend.calls.items[1].vertices.count);
}

test "stencil backend queues direct convex stroke when stencil strokes are off" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(0, 1, 0, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.stroke(iface.ctx, &paint, &default_scissor, 3, &paths, &points);

    try testing.expectEqual(CallType.stroke_convex, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 0), backend.calls.items[0].cover.count);
    try testing.expectEqual(@as(usize, 3), backend.vertices.items.len);
}

test "stencil backend queues antialiased stenciled stroke fringe" {
    const backend = try Backend.createWithFlags(testing.allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(0, 1, 0, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0, .dmx = 1, .dmy = 0 },
        .{ .x = 10, .y = 0, .dmx = 0, .dmy = 1 },
        .{ .x = 10, .y = 10, .dmx = -1, .dmy = 0 },
        .{ .x = 0, .y = 10, .dmx = 0, .dmy = -1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};

    iface.stroke(iface.ctx, &paint, &default_scissor, 3, &paths, &points);

    try testing.expectEqual(CallType.stroke, backend.calls.items[0].call_type);
    try testing.expectEqual(@as(u32, 18), backend.calls.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 4), backend.paths.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 8), backend.paths.items[0].fringe.start);
    try testing.expectEqual(@as(u32, 10), backend.paths.items[0].fringe.count);
}

test "stencil backend texture callbacks store dimensions" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    const id: ImageId = @enumFromInt(42);

    try testing.expect(iface.create_texture(iface.ctx, id, 7, 9, .rgba8, null));
    try testing.expectEqual([2]u32{ 7, 9 }, iface.texture_size(iface.ctx, id).?);
    iface.delete_texture(iface.ctx, id);
    try testing.expect(iface.texture_size(iface.ctx, id) == null);
}

test "stencil backend texture callbacks retain and update rgba pixels" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    const id: ImageId = @enumFromInt(42);

    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    try testing.expect(iface.create_texture(iface.ctx, id, 2, 2, .rgba8, &pixels));
    try testing.expectEqualSlices(u8, &pixels, backend.textures.get(id).?.pixels.items);

    const replacement = [_]u8{ 16, 32, 48, 255 };
    iface.update_texture(iface.ctx, id, 1, 0, 1, 1, &replacement);
    try testing.expectEqualSlices(u8, &replacement, backend.textures.get(id).?.pixels.items[4..8]);
}
