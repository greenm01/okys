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
    try testing.expectEqual(@as(usize, 2), backend.path_draws.items.len);
    try testing.expectEqual(.stencil_nonzero, backend.path_draws.items[0].kind);
    try testing.expectEqual(.cover, backend.path_draws.items[1].kind);
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
    try testing.expectEqual(.stencil_even_odd, backend.path_draws.items[0].kind);
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
    try testing.expectEqual(@as(usize, 0), backend.cover_draws.items.len);
    try testing.expectEqual(@as(usize, 1), backend.path_draws.items.len);
    try testing.expectEqual(.convex, backend.path_draws.items[0].kind);
    try testing.expectEqual(@as(u32, 0), backend.path_draws.items[0].base_element);
    try testing.expectEqual(@as(u32, 3), backend.path_draws.items[0].element_count);
    try testing.expectEqual(@as(u32, 0), backend.path_draws.items[0].uniform_index);
}

test "convex replay emits direct indexed paint draw without stencil or cover" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    var paint = color.solid(color.rgbaf(0.25, 0.5, 0.75, 0.5));
    paint.xform = .{ 2, 0, 0, 2, 4, 6 };
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 0), backend.stencil_draws.items.len);
    try testing.expectEqual(@as(usize, 0), backend.cover_draws.items.len);
    try testing.expectEqual(@as(usize, 1), backend.path_draws.items.len);
    try testing.expectEqual(.convex, backend.path_draws.items[0].kind);
    try testing.expectEqual(@as(u32, 0), backend.path_draws.items[0].base_element);
    try testing.expectEqual(@as(u32, 3), backend.path_draws.items[0].element_count);
    try testing.expectEqual(@as(u32, 0), backend.path_draws.items[0].uniform_index);
    try testing.expectEqual(@as(usize, 1), backend.frag_params.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0.125), backend.frag_params.items[0].inner_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), backend.frag_params.items[0].inner_color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.375), backend.frag_params.items[0].inner_color[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), backend.frag_params.items[0].inner_color[3], 0.001);
}

test "cover replay emits cover quad and packs fragment params" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    var paint = color.solid(color.rgbaf(0.5, 0.25, 0.125, 0.5));
    paint.xform = .{ 2, 0, 0, 4, 10, 20 };
    paint.extent = .{ 7, 8 };
    paint.radius = 2;
    paint.feather = 3;
    const scissor: color.Scissor = .{
        .xform = .{ 2, 0, 0, 4, 10, 20 },
        .extent = .{ 5, 6 },
    };
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 1), backend.cover_draws.items.len);
    try testing.expectEqual(@as(u32, 0), backend.cover_draws.items[0].base_element);
    try testing.expectEqual(@as(u32, 4), backend.cover_draws.items[0].element_count);
    try testing.expectEqual(@as(u32, 0), backend.cover_draws.items[0].uniform_index);
    try testing.expectEqual(.cover, backend.path_draws.items[1].kind);
    try testing.expectEqual(@as(u32, 0), backend.path_draws.items[1].base_element);
    try testing.expectEqual(@as(u32, 4), backend.path_draws.items[1].element_count);
    try testing.expectEqual(@as(usize, 1), backend.frag_params.items.len);

    const params = backend.frag_params.items[0];
    try testing.expectApproxEqAbs(@as(f32, 0.5), params.paint_mat0[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), params.paint_mat1[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), params.paint_mat2[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), params.paint_mat2[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), params.scissor_mat0[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), params.scissor_mat1[1], 0.001);
    try testing.expectEqual([4]f32{ 5, 6, 2, 4 }, params.scissor_extent_scale);
    try testing.expectEqual([4]f32{ 7, 8, 2, 3 }, params.extent_radius_feather);
    try testing.expectApproxEqAbs(@as(f32, 0.25), params.inner_color[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.125), params.inner_color[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), params.inner_color[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), params.inner_color[3], 0.001);
}

test "disabled scissor packs a pass through shader mask" {
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

    const params = backend.frag_params.items[0];
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, params.scissor_mat0);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, params.scissor_mat1);
    try testing.expectEqual([4]f32{ 0, 0, 0, 0 }, params.scissor_mat2);
    try testing.expectEqual([4]f32{ 1, 1, 1, 1 }, params.scissor_extent_scale);
}

test "mixed non convex and convex fills preserve replay order" {
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
    const non_convex = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};
    const convex = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &non_convex, &points);
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &convex, points[0..3]);
    try testing.expect(backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 3), backend.path_draws.items.len);
    try testing.expectEqual(.stencil_nonzero, backend.path_draws.items[0].kind);
    try testing.expectEqual(.cover, backend.path_draws.items[1].kind);
    try testing.expectEqual(.convex, backend.path_draws.items[2].kind);
    try testing.expectEqual(@as(u32, 1), backend.path_draws.items[2].uniform_index);
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
    try testing.expectEqual(@as(usize, 0), backend.path_draws.items.len);
    try testing.expectEqual(@as(usize, 0), backend.stencil_draws.items.len);
    try testing.expectEqual(@as(usize, 0), backend.cover_draws.items.len);
    try testing.expectEqual(@as(usize, 0), backend.frag_params.items.len);
}
