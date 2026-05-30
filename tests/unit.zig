const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const Context = okys.state.context.Context;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const state_ops = okys.ops.state;
const frame_ops = okys.ops.frame;
const flatten = okys.systems.flatten;
const xforms = okys.systems.transform;

test "all production modules analyze" {
    _ = okys.types.color;
    _ = okys.types.command;
    _ = okys.types.path;
    _ = okys.types.image;
    _ = okys.state.arena;
    _ = okys.state.commands;
    _ = okys.state.path_cache;
    _ = okys.state.draw_state;
    _ = okys.state.textures;
    _ = okys.state.context;
    _ = okys.ops.frame;
    _ = okys.ops.path;
    _ = okys.ops.paint;
    _ = okys.ops.state;
    _ = okys.ops.image;
    _ = okys.systems.transform;
    _ = okys.systems.flatten;
    _ = okys.systems.stroke;
    _ = okys.systems.convex;
    _ = okys.systems.backend_a;
    _ = okys.systems.backend_b;
    _ = okys.render.interface;
    _ = okys.c_api;
}

test "rgba maps 0..255 to 0..1" {
    const c = color.rgba(255, 0, 128, 255);
    try testing.expectApproxEqAbs(@as(f32, 1.0), c.r, 0.001);
    try testing.expectEqual(@as(f32, 0.0), c.g);
    try testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c.b, 0.001);
}

test "solid paint carries the color in both stops" {
    const p = color.solid(color.rgbaf(0.25, 0.5, 0.75, 1.0));
    try testing.expectEqual(p.inner_color, p.outer_color);
    try testing.expectApproxEqAbs(@as(f32, 0.5), p.inner_color.g, 0.001);
}

test "context create installs one default state" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    try testing.expectEqual(@as(usize, 1), ctx.states.items.len);
    try testing.expectEqual(@as(f32, 1.0), ctx.state().alpha);
}

test "premultiply matches NanoVG transform order" {
    var xform = xforms.identity();
    const tx = xforms.translate(10, 20);
    xforms.premultiply(&xform, &tx);
    const sc = xforms.scale(2, 3);
    xforms.premultiply(&xform, &sc);

    const p = xforms.point(&xform, 4, 5);
    try testing.expectApproxEqAbs(@as(f32, 18), p[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 35), p[1], 0.001);
}

test "inverse undoes an affine transform" {
    var xform = xforms.translate(10, -4);
    const rot = xforms.rotate(0.3);
    xforms.premultiply(&xform, &rot);

    const inv = xforms.inverse(&xform).?;
    const p = xforms.point(&xform, 7, 11);
    const original = xforms.point(&inv, p[0], p[1]);
    try testing.expectApproxEqAbs(@as(f32, 7), original[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 11), original[1], 0.001);
}

test "save and restore preserve style and transform" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.strokeWidth(ctx, 5);
    state_ops.translate(ctx, 10, 20);
    state_ops.save(ctx);
    state_ops.strokeWidth(ctx, 2);
    state_ops.resetTransform(ctx);
    state_ops.restore(ctx);

    try testing.expectEqual(@as(f32, 5), ctx.state().stroke_width);
    try testing.expectEqual(@as(f32, 10), ctx.state().xform[4]);
    try testing.expectEqual(@as(f32, 20), ctx.state().xform[5]);
}

test "scissor intersection clamps to overlap" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.scissor(ctx, 0, 0, 100, 100);
    state_ops.intersectScissor(ctx, 25, 40, 100, 20);

    try testing.expectApproxEqAbs(@as(f32, 37.5), ctx.state().scissor.extent[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), ctx.state().scissor.extent[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 62.5), ctx.state().scissor.xform[4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50), ctx.state().scissor.xform[5], 0.001);
}

test "fill paint assignment multiplies current transform" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.translate(ctx, 10, 20);
    paint_ops.fillPaint(ctx, paint_ops.linearGradient(ctx, 0, 0, 100, 0, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1)));

    try testing.expectApproxEqAbs(@as(f32, -99990), ctx.state().fill.xform[4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.state().fill.xform[5], 0.001);
}

test "image pattern carries image id and alpha" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    const p = paint_ops.imagePattern(ctx, 1, 2, 30, 40, 0, 42, 0.25);
    try testing.expectEqual(@as(i32, 42), p.image);
    try testing.expectApproxEqAbs(@as(f32, 0.25), p.inner_color.a, 0.001);
}

test "path commands transform coordinates on append" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.translate(ctx, 10, 20);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 1, 2);
    path_ops.lineTo(ctx, 3, 4);

    try testing.expectEqual(@as(usize, 6), ctx.commands.data.items.len);
    try testing.expectEqual(@as(f32, 0), ctx.commands.data.items[0]);
    try testing.expectApproxEqAbs(@as(f32, 11), ctx.commands.data.items[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 22), ctx.commands.data.items[2], 0.001);
    try testing.expectEqual(@as(f32, 1), ctx.commands.data.items[3]);
    try testing.expectApproxEqAbs(@as(f32, 13), ctx.commands.data.items[4], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 24), ctx.commands.data.items[5], 0.001);
    try testing.expectEqual(@as(f32, 3), ctx.command_x);
    try testing.expectEqual(@as(f32, 4), ctx.command_y);
}

test "quad and winding append expected command tags" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.quadTo(ctx, 10, 10, 20, 0);
    path_ops.pathWinding(ctx, .cw);

    try testing.expectEqual(@as(f32, 0), ctx.commands.data.items[0]);
    try testing.expectEqual(@as(f32, 2), ctx.commands.data.items[3]);
    try testing.expectEqual(@as(f32, 4), ctx.commands.data.items[10]);
    try testing.expectEqual(@as(f32, 2), ctx.commands.data.items[11]);
}

test "rounded rect and ellipse emit closed paths" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 0, 0, 10, 10, 2);
    const rounded_len = ctx.commands.data.items.len;
    try testing.expect(rounded_len > 0);
    try testing.expectEqual(@as(f32, 3), ctx.commands.data.items[rounded_len - 1]);

    path_ops.beginPath(ctx);
    path_ops.ellipse(ctx, 5, 5, 2, 3);
    const ellipse_len = ctx.commands.data.items.len;
    try testing.expect(ellipse_len > 0);
    try testing.expectEqual(@as(f32, 3), ctx.commands.data.items[ellipse_len - 1]);
}

test "closed rect flattens to convex four point path" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 10, 20);
    flatten.flatten(ctx);

    try testing.expectEqual(@as(usize, 1), ctx.cache.paths.items.len);
    const p = ctx.cache.paths.items[0];
    try testing.expectEqual(@as(u32, 4), p.point_count);
    try testing.expect(p.closed);
    try testing.expect(p.convex);
    try testing.expectEqual(@as(f32, 0), ctx.cache.bounds[0]);
    try testing.expectEqual(@as(f32, 0), ctx.cache.bounds[1]);
    try testing.expectEqual(@as(f32, 10), ctx.cache.bounds[2]);
    try testing.expectEqual(@as(f32, 20), ctx.cache.bounds[3]);

    const pts = ctx.cache.points.items[p.point_start..][0..p.point_count];
    try testing.expectApproxEqAbs(@as(f32, 20), pts[0].len, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), pts[1].len, 0.001);
}

test "open line remains open with no closing segment" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 3, 4);
    flatten.flatten(ctx);

    const p = ctx.cache.paths.items[0];
    try testing.expect(!p.closed);
    try testing.expect(!p.convex);
    try testing.expectEqual(@as(u32, 2), p.point_count);
    const pts = ctx.cache.points.items[p.point_start..][0..p.point_count];
    try testing.expectApproxEqAbs(@as(f32, 5), pts[0].len, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), pts[1].len, 0.001);
}

test "cubic curve flattens into line segments ending at target" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.bezierTo(ctx, 0, 100, 100, 100, 100, 0);
    flatten.flatten(ctx);

    const p = ctx.cache.paths.items[0];
    try testing.expect(p.point_count > 2);
    const pts = ctx.cache.points.items[p.point_start..][0..p.point_count];
    const last = pts[pts.len - 1];
    try testing.expectApproxEqAbs(@as(f32, 100), last.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), last.y, 0.001);
}

test "duplicate line points are merged while flattening" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 10, 0);
    flatten.flatten(ctx);

    const p = ctx.cache.paths.items[0];
    try testing.expectEqual(@as(u32, 2), p.point_count);
}

test "cw winding reverses a default rect" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 10, 20);
    path_ops.pathWinding(ctx, .cw);
    flatten.flatten(ctx);

    const p = ctx.cache.paths.items[0];
    try testing.expectEqual(.cw, p.winding);
    const pts = ctx.cache.points.items[p.point_start..][0..p.point_count];
    try testing.expectApproxEqAbs(@as(f32, 10), pts[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), pts[0].y, 0.001);
}

test "malformed command buffer produces no paths" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    ctx.commands.float(ctx.gpa, 0);
    flatten.flatten(ctx);

    try testing.expectEqual(@as(usize, 0), ctx.cache.paths.items.len);
    try testing.expectEqual(@as(f32, 0), ctx.cache.bounds[0]);
}

test "higher dpr tightens bezier flattening tolerance" {
    const low = try Context.create(testing.allocator, 0);
    defer low.destroy();
    const high = try Context.create(testing.allocator, 0);
    defer high.destroy();

    frame_ops.beginFrame(low, 100, 100, 1);
    path_ops.moveTo(low, 0, 0);
    path_ops.bezierTo(low, 0, 100, 100, 100, 100, 0);
    flatten.flatten(low);

    frame_ops.beginFrame(high, 100, 100, 2);
    path_ops.moveTo(high, 0, 0);
    path_ops.bezierTo(high, 0, 100, 100, 100, 100, 0);
    flatten.flatten(high);

    try testing.expect(high.cache.paths.items[0].point_count >= low.cache.paths.items[0].point_count);
}
