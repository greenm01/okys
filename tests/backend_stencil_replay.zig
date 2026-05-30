const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Vertex = okys.types.path.Vertex;
const stencil = okys.systems.backend_stencil;
const Backend = stencil.Backend;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "stencil replay emits nonzero draw from indexed fill op" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 1), backend.stencil_draws.items.len);
    try testing.expectEqual(.stencil_nonzero, backend.stencil_draws.items[0].mode);
    try testing.expectEqual(@as(u32, 0), backend.stencil_draws.items[0].base_element);
    try testing.expectEqual(@as(u32, 6), backend.stencil_draws.items[0].element_count);
}

test "stencil replay emits even odd draw from indexed fill op" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    backend.fill_rule = .even_odd;

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 1), backend.stencil_draws.items.len);
    try testing.expectEqual(.stencil_even_odd, backend.stencil_draws.items[0].mode);
    try testing.expectEqual(@as(u32, 0), backend.stencil_draws.items[0].base_element);
    try testing.expectEqual(@as(u32, 3), backend.stencil_draws.items[0].element_count);
}

test "stencil replay skips convex fills cover fills and direct triangles" {
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
    const verts = [_]Vertex{
        .{ .x = 0, .y = 0, .u = 0, .v = 0 },
        .{ .x = 1, .y = 0, .u = 1, .v = 0 },
        .{ .x = 0, .y = 1, .u = 0, .v = 1 },
    };

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    iface.triangles(iface.ctx, &paint, &disabled_scissor, &verts);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 2), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.convex_fill, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.DrawOpKind.triangles, backend.draw_ops.items[1].kind);
    try testing.expectEqual(@as(usize, 0), backend.stencil_draws.items.len);
}

test "stencil replay clears with backend flush" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildStencilPass());
    try testing.expectEqual(@as(usize, 1), backend.stencil_draws.items.len);

    iface.flush(iface.ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expectEqual(@as(usize, 0), backend.stencil_draws.items.len);
}
