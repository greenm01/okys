const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const Context = okys.state.context.Context;
const dash = okys.systems.dash;
const frame_ops = okys.ops.frame;
const mock_backend = @import("mock_backend.zig");
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

test "line dash state copies saves restores resets and rejects invalid patterns" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 6, 3 };
    state_ops.lineDash(ctx, &pattern);
    state_ops.lineDashOffset(ctx, 1.5);
    try testing.expectEqual(@as(u8, 2), ctx.state().line_dash_count);
    try testing.expectApproxEqAbs(@as(f32, 6), ctx.state().line_dash[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), ctx.state().line_dash_offset, 0.001);

    state_ops.save(ctx);
    const replacement = [_]f32{ 2, 2 };
    state_ops.lineDash(ctx, &replacement);
    state_ops.lineDashOffset(ctx, 0.25);
    state_ops.restore(ctx);
    try testing.expectEqual(@as(u8, 2), ctx.state().line_dash_count);
    try testing.expectApproxEqAbs(@as(f32, 6), ctx.state().line_dash[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), ctx.state().line_dash_offset, 0.001);

    const invalid = [_]f32{ 4, -1 };
    state_ops.lineDash(ctx, &invalid);
    try testing.expectEqual(@as(u8, 0), ctx.state().line_dash_count);

    state_ops.lineDash(ctx, &pattern);
    state_ops.reset(ctx);
    try testing.expectEqual(@as(u8, 0), ctx.state().line_dash_count);
    try testing.expectApproxEqAbs(@as(f32, 0), ctx.state().line_dash_offset, 0.001);
}

test "dash cache splits a straight line into visible open fragments" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 10, 5 };
    state_ops.lineDash(ctx, &pattern);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 30, 0);

    try testing.expect(dash.build(ctx));
    try testing.expectEqual(@as(usize, 2), ctx.dash_cache.paths.items.len);
    try expectPathEndpoints(ctx, 0, 0, 10);
    try expectPathEndpoints(ctx, 1, 15, 25);
}

test "dash offset starts inside the pattern" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 10, 10 };
    state_ops.lineDash(ctx, &pattern);
    state_ops.lineDashOffset(ctx, 5);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 30, 0);

    try testing.expect(dash.build(ctx));
    try testing.expectEqual(@as(usize, 2), ctx.dash_cache.paths.items.len);
    try expectPathEndpoints(ctx, 0, 0, 5);
    try expectPathEndpoints(ctx, 1, 15, 25);
}

test "odd dash pattern repeats logically" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 10, 5, 2 };
    state_ops.lineDash(ctx, &pattern);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 35, 0);

    try testing.expect(dash.build(ctx));
    try testing.expectEqual(@as(usize, 4), ctx.dash_cache.paths.items.len);
    try expectPathEndpoints(ctx, 0, 0, 10);
    try expectPathEndpoints(ctx, 1, 15, 17);
    try expectPathEndpoints(ctx, 2, 27, 32);
    try expectPathEndpoints(ctx, 3, 34, 35);
}

test "dash lengths follow transform scale" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 10, 5 };
    state_ops.lineDash(ctx, &pattern);
    state_ops.scale(ctx, 2, 2);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 30, 0);

    try testing.expect(dash.build(ctx));
    try testing.expectEqual(@as(usize, 2), ctx.dash_cache.paths.items.len);
    try expectPathEndpoints(ctx, 0, 0, 20);
    try expectPathEndpoints(ctx, 1, 30, 50);
}

test "closed paths are dashed into open visible fragments" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const pattern = [_]f32{ 10, 10 };
    state_ops.lineDash(ctx, &pattern);
    path_ops.rect(ctx, 0, 0, 10, 10);

    try testing.expect(dash.build(ctx));
    try testing.expect(ctx.dash_cache.paths.items.len >= 2);
    for (ctx.dash_cache.paths.items) |p| {
        try testing.expect(!p.closed);
        try testing.expect(p.point_count >= 2);
    }
}

test "dashed stroke crosses render boundary as normal outline geometry" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 80, 40, 1);
    paint_ops.strokeColor(ctx, color.rgbaf(1, 1, 1, 1));
    state_ops.strokeWidth(ctx, 4);
    state_ops.lineCap(ctx, .round);
    const pattern = [_]f32{ 10, 5 };
    state_ops.lineDash(ctx, &pattern);
    path_ops.moveTo(ctx, 0, 20);
    path_ops.lineTo(ctx, 40, 20);

    render_ops.stroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expect(backend.last_stroke.path_count >= 3);
    try testing.expect(backend.last_stroke.point_count > backend.last_stroke.path_count * 4);
}

fn expectPathEndpoints(ctx: *const Context, path_index: usize, start_x: f32, end_x: f32) !void {
    const range = ctx.dash_cache.paths.items[path_index];
    const pts = ctx.dash_cache.points.items[range.point_start..][0..range.point_count];
    try testing.expect(pts.len >= 2);
    try testing.expectApproxEqAbs(start_x, pts[0].x, 0.001);
    try testing.expectApproxEqAbs(end_x, pts[pts.len - 1].x, 0.001);
}
