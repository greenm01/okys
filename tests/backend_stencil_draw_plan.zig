const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Vertex = okys.types.path.Vertex;
const stencil = okys.systems.backend_stencil;
const Backend = stencil.Backend;

const OKY_ANTIALIAS: u32 = 1 << 0;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "draw plan emits indexed stencil triangles then cover quad for non-convex fill" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    var paint = color.solid(color.rgbaf(0.5, 0.25, 0.125, 0.5));
    paint.image = 7;
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 20 },
        .{ .x = 0, .y = 20 },
    };
    const paths = [_]PathRange{.{
        .point_start = 0,
        .point_count = 4,
        .closed = true,
        .convex = false,
        .winding = .cw,
    }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 20 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(@as(usize, 1), backend.uniforms.items.len);
    try testing.expectEqual(@as(usize, 2), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.stencil_fill, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.Primitive.triangles, backend.draw_ops.items[0].primitive);
    try testing.expectEqual(stencil.StencilMode.nonzero, backend.draw_ops.items[0].stencil_mode);
    try testing.expectEqual(@as(u32, 4), backend.draw_ops.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 4), backend.draw_ops.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[0].indices.start);
    try testing.expectEqual(@as(u32, 6), backend.draw_ops.items[0].indices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[0].uniform_index);
    try testing.expectEqual(.cw, backend.draw_ops.items[0].winding);
    try testing.expectEqualSlices(u16, &.{ 4, 5, 6, 4, 6, 7 }, backend.indices.items);

    try testing.expectEqual(stencil.DrawOpKind.cover_fill, backend.draw_ops.items[1].kind);
    try testing.expectEqual(stencil.Primitive.triangle_strip, backend.draw_ops.items[1].primitive);
    try testing.expectEqual(stencil.StencilMode.none, backend.draw_ops.items[1].stencil_mode);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].vertices.start);
    try testing.expectEqual(@as(u32, 4), backend.draw_ops.items[1].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].indices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].uniform_index);

    const uniform = backend.uniforms.items[0];
    try testing.expectEqual(@as(f32, 0), uniform.edge_alpha_multiplier);
    try testing.expectEqual(@as(i32, 7), uniform.image);
    try testing.expect(!uniform.scissor_enabled);
    try testing.expectApproxEqAbs(@as(f32, 0.25), uniform.inner_color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.125), uniform.inner_color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0625), uniform.inner_color.b, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), uniform.inner_color.a, 0.001);
}

test "draw plan emits convex fills as indexed triangle ops" {
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

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(@as(usize, 1), backend.uniforms.items.len);
    try testing.expectEqual(@as(usize, 1), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.convex_fill, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.Primitive.triangles, backend.draw_ops.items[0].primitive);
    try testing.expectEqual(stencil.StencilMode.none, backend.draw_ops.items[0].stencil_mode);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[0].vertices.start);
    try testing.expectEqual(@as(u32, 3), backend.draw_ops.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[0].indices.start);
    try testing.expectEqual(@as(u32, 3), backend.draw_ops.items[0].indices.count);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, backend.indices.items);
}

test "draw plan emits antialiased stencil fill fringe before cover" {
    const backend = try Backend.createWithFlags(testing.allocator, OKY_ANTIALIAS);
    defer backend.destroy();
    const iface = backend.interface();

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0, .dmx = 1, .dmy = 0 },
        .{ .x = 10, .y = 0, .dmx = 0, .dmy = 1 },
        .{ .x = 10, .y = 10, .dmx = -1, .dmy = 0 },
        .{ .x = 0, .y = 10, .dmx = 0, .dmy = -1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(@as(usize, 1), backend.uniforms.items.len);
    try testing.expectEqual(@as(f32, 1), backend.uniforms.items[0].edge_alpha_multiplier);
    try testing.expectEqual(@as(usize, 3), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.stencil_fill, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.DrawOpKind.fringe_stencil_fill, backend.draw_ops.items[1].kind);
    try testing.expectEqual(stencil.DrawOpKind.cover_fill, backend.draw_ops.items[2].kind);
    try testing.expectEqual(stencil.Primitive.triangle_strip, backend.draw_ops.items[1].primitive);
    try testing.expectEqual(stencil.StencilMode.none, backend.draw_ops.items[1].stencil_mode);
    try testing.expectEqual(@as(u32, 8), backend.draw_ops.items[1].vertices.start);
    try testing.expectEqual(@as(u32, 10), backend.draw_ops.items[1].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].indices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].uniform_index);
}

test "draw plan emits antialiased convex fill fringe after indexed fill" {
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

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(@as(f32, 1), backend.uniforms.items[0].edge_alpha_multiplier);
    try testing.expectEqual(@as(usize, 2), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.convex_fill, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.DrawOpKind.fringe_fill, backend.draw_ops.items[1].kind);
    try testing.expectEqual(stencil.Primitive.triangle_strip, backend.draw_ops.items[1].primitive);
    try testing.expectEqual(@as(u32, 3), backend.draw_ops.items[1].vertices.start);
    try testing.expectEqual(@as(u32, 8), backend.draw_ops.items[1].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].uniform_index);
}

test "draw plan can encode even-odd stencil fills internally" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    backend.fill_rule = .even_odd;

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = false }};

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(stencil.StencilMode.even_odd, backend.draw_ops.items[0].stencil_mode);
    try testing.expectEqual(@as(u32, 6), backend.draw_ops.items[0].indices.count);
    try testing.expectEqual(stencil.DrawOpKind.cover_fill, backend.draw_ops.items[1].kind);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[1].indices.count);
}

test "draw plan emits direct triangles with packed scissor uniform" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    var paint = color.solid(color.rgbaf(0.2, 0.4, 0.8, 1));
    paint.xform = .{ 2, 0, 0, 4, 10, 20 };
    const scissor: color.Scissor = .{
        .xform = .{ 2, 0, 0, 4, 10, 20 },
        .extent = .{ 5, 6 },
    };
    const verts = [_]Vertex{
        .{ .x = 0, .y = 0, .u = 0, .v = 0 },
        .{ .x = 1, .y = 0, .u = 1, .v = 0 },
        .{ .x = 0, .y = 1, .u = 0, .v = 1 },
    };

    iface.triangles(iface.ctx, &paint, &scissor, &verts);
    try testing.expect(backend.buildDrawPlan());

    try testing.expectEqual(@as(usize, 1), backend.draw_ops.items.len);
    try testing.expectEqual(stencil.DrawOpKind.triangles, backend.draw_ops.items[0].kind);
    try testing.expectEqual(stencil.Primitive.triangles, backend.draw_ops.items[0].primitive);
    try testing.expectEqual(@as(u32, 3), backend.draw_ops.items[0].vertices.count);
    try testing.expectEqual(@as(u32, 0), backend.draw_ops.items[0].indices.count);
    try testing.expectEqual(@as(usize, 0), backend.indices.items.len);

    const uniform = backend.uniforms.items[0];
    try testing.expect(uniform.scissor_enabled);
    try testing.expectApproxEqAbs(@as(f32, 0.5), uniform.paint_xform[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), uniform.paint_xform[3], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), uniform.paint_xform[4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), uniform.paint_xform[5], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), uniform.scissor_xform[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), uniform.scissor_xform[3], 0.001);
    try testing.expectEqual([2]f32{ 5, 6 }, uniform.scissor_extent);
    try testing.expectEqual([2]f32{ 2, 4 }, uniform.scissor_scale);
}

test "draw plan is transient and clears on flush" {
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

    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 0, 0, 10, 10 }, &paths, &points);
    try testing.expect(backend.buildDrawPlan());
    try testing.expect(backend.draw_ops.items.len > 0);
    try testing.expect(backend.indices.items.len > 0);
    try testing.expect(backend.uniforms.items.len > 0);

    iface.flush(iface.ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expectEqual(@as(usize, 0), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 0), backend.paths.items.len);
    try testing.expectEqual(@as(usize, 0), backend.vertices.items.len);
    try testing.expectEqual(@as(usize, 0), backend.indices.items.len);
    try testing.expectEqual(@as(usize, 0), backend.draw_ops.items.len);
    try testing.expectEqual(@as(usize, 0), backend.uniforms.items.len);
}
