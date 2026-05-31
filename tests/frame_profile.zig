const testing = @import("std").testing;

const okys = @import("okys");
const color = okys.types.color;
const Context = okys.state.context.Context;
const frame_ops = okys.ops.frame;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;
const MockBackend = @import("mock_backend.zig").MockBackend;

test "frame profile disabled leaves stroke counters at zero" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    var backend: MockBackend = .{};
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 64, 64, 1);
    drawStroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expectEqual(@as(usize, 0), ctx.frame_profile.stroke_outline_builds);
    try testing.expectEqual(@as(usize, 0), ctx.frame_profile.stroke_calls);
    try testing.expectEqual(@as(u64, 0), ctx.frame_profile.stroke_outline_ns);
}

test "frame profile records stroke outline expansion" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    var backend: MockBackend = .{};
    ctx.installBackend(backend.interface());

    ctx.frame_profile.enabled = true;
    frame_ops.beginFrame(ctx, 64, 64, 1);
    drawStroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expectEqual(@as(usize, 1), ctx.frame_profile.stroke_outline_builds);
    try testing.expectEqual(@as(usize, 1), ctx.frame_profile.stroke_calls);
    try testing.expectEqual(@as(usize, 1), ctx.frame_profile.stroke_source_paths);
    try testing.expectEqual(@as(usize, 3), ctx.frame_profile.stroke_source_points);
    try testing.expectEqual(@as(usize, 1), ctx.frame_profile.stroke_source_open_paths);
    try testing.expectEqual(@as(usize, 0), ctx.frame_profile.stroke_source_closed_paths);
    try testing.expect(ctx.frame_profile.stroke_outline_paths > 0);
    try testing.expect(ctx.frame_profile.stroke_outline_points > ctx.frame_profile.stroke_source_points);
    try testing.expect(ctx.frame_profile.max_stroke_outline_expansion_pct >= 100);
    try testing.expect(ctx.frame_profile.stroke_outline_ns > 0);
}

test "begin frame resets profile counters and preserves enabled state" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    var backend: MockBackend = .{};
    ctx.installBackend(backend.interface());

    ctx.frame_profile.enabled = true;
    frame_ops.beginFrame(ctx, 64, 64, 1);
    drawStroke(ctx);
    try testing.expect(ctx.frame_profile.stroke_outline_builds > 0);

    frame_ops.beginFrame(ctx, 64, 64, 1);
    try testing.expect(ctx.frame_profile.enabled);
    try testing.expectEqual(@as(usize, 0), ctx.frame_profile.stroke_outline_builds);
    try testing.expectEqual(@as(usize, 0), ctx.frame_profile.stroke_calls);
    try testing.expectEqual(@as(u64, 0), ctx.frame_profile.stroke_outline_ns);
}

fn drawStroke(ctx: *Context) void {
    paint_ops.strokeColor(ctx, color.rgbaf(1, 1, 1, 1));
    state_ops.strokeWidth(ctx, 4);
    state_ops.lineCap(ctx, .round);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 4, 4);
    path_ops.lineTo(ctx, 24, 4);
    path_ops.lineTo(ctx, 18, 20);
    render_ops.stroke(ctx);
}
