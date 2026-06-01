const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const backend_selection_tests = @import("backend_selection.zig");
const sparse_cpu_golden_tests = @import("sparse_cpu_golden.zig");
const sparse_gpu_packet_parity_tests = @import("sparse_gpu_packet_parity.zig");
const backend_sparse_strip_tests = @import("backend_sparse_strip.zig");
const backend_stencil_draw_plan_tests = @import("backend_stencil_draw_plan.zig");
const backend_stencil_golden_tests = @import("backend_stencil_golden.zig");
const backend_stencil_replay_tests = @import("backend_stencil_replay.zig");
const backend_stencil_tests = @import("backend_stencil.zig");
const captured_frame_golden_tests = @import("captured_frame_golden.zig");
const frame_capture_tests = @import("frame_capture.zig");
const frame_profile_tests = @import("frame_profile.zig");
const glyph_atlas_tests = @import("glyph_atlas.zig");
const diagnostics_tests = @import("diagnostics.zig");
const draw_list_tests = @import("draw_list.zig");
const image_ops_tests = @import("image_ops.zig");
const mock_backend = @import("mock_backend.zig");
const qoi_tests = @import("qoi.zig");
const sokol_device_tests = @import("sokol_device.zig");
const texture_tests = @import("textures.zig");
const tiger_data_tests = @import("tiger_data.zig");
const stroke_dash_tests = @import("stroke_dash.zig");
const text_abi_tests = @import("text_abi.zig");
const color = okys.types.color;
const Context = okys.state.context.Context;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;
const frame_ops = okys.ops.frame;
const flatten = okys.systems.flatten;
const stroke = okys.systems.stroke;
const xforms = okys.systems.transform;

const OKY_ANTIALIAS: u32 = 1 << 0;

test "all production modules analyze" {
    _ = okys.types.color;
    _ = okys.types.command;
    _ = okys.types.path;
    _ = okys.types.image;
    _ = okys.types.text;
    _ = okys.state.arena;
    _ = okys.state.commands;
    _ = okys.state.path_cache;
    _ = okys.state.draw_state;
    _ = okys.state.frame_profile;
    _ = okys.state.textures;
    _ = okys.state.glyph_atlas;
    _ = okys.state.fonts;
    _ = okys.state.diagnostics;
    _ = okys.state.context;
    _ = okys.ops.frame;
    _ = okys.ops.path;
    _ = okys.ops.paint;
    _ = okys.ops.render;
    _ = okys.ops.state;
    _ = okys.ops.image;
    _ = okys.ops.text;
    _ = okys.systems.transform;
    _ = okys.systems.dash;
    _ = okys.systems.flatten;
    _ = okys.systems.stroke;
    _ = okys.systems.convex;
    _ = okys.systems.qoi;
    _ = okys.systems.backend_stencil;
    _ = okys.systems.backend_stencil.draw_plan;
    _ = okys.systems.backend_stencil.replay;
    _ = okys.systems.backend_sparse_strip;
    _ = okys.systems.backend_sparse_strip.encode;
    _ = okys.systems.backend_sparse_strip.bin;
    _ = okys.systems.backend_sparse_strip.coarse;
    _ = okys.systems.backend_sparse_strip.debug;
    _ = okys.systems.backend_sparse_strip.fine;
    _ = okys.systems.backend_sparse_strip.gpu_fine;
    _ = okys.systems.backend_sparse_strip.strip;
    _ = okys.render.backend_selection;
    _ = okys.render.draw_list;
    _ = okys.render.frame_capture;
    _ = okys.render.interface;
    _ = okys.render.sokol_device;
    _ = okys.render.webgpu_runtime;
    _ = okys.c_api;
    _ = backend_selection_tests;
    _ = sparse_cpu_golden_tests;
    _ = sparse_gpu_packet_parity_tests;
    _ = backend_sparse_strip_tests;
    _ = backend_stencil_draw_plan_tests;
    _ = backend_stencil_golden_tests;
    _ = backend_stencil_replay_tests;
    _ = backend_stencil_tests;
    _ = captured_frame_golden_tests;
    _ = frame_capture_tests;
    _ = frame_profile_tests;
    _ = glyph_atlas_tests;
    _ = diagnostics_tests;
    _ = draw_list_tests;
    _ = image_ops_tests;
    _ = mock_backend;
    _ = qoi_tests;
    _ = sokol_device_tests;
    _ = texture_tests;
    _ = tiger_data_tests;
    _ = stroke_dash_tests;
    _ = text_abi_tests;
}

test "webgpu texture format maps to sokol formats" {
    try testing.expectEqual(@as(?okys.render.sokol_device.PixelFormat, .BGRA8), okys.render.webgpu_runtime.pixelFormatFromInt(1));
    try testing.expectEqual(@as(?okys.render.sokol_device.PixelFormat, .RGBA8), okys.render.webgpu_runtime.pixelFormatFromInt(2));
    try testing.expectEqual(@as(?okys.render.sokol_device.PixelFormat, null), okys.render.webgpu_runtime.pixelFormatFromInt(0));
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

test "butt cap line outline does not extend past endpoints" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.strokeWidth(ctx, 10);
    state_ops.lineCap(ctx, .butt);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 20, 0);
    stroke.buildOutline(ctx);

    try testing.expectEqual(@as(usize, 1), ctx.stroke_outline.paths.items.len);
    try testing.expectApproxEqAbs(@as(f32, 0), ctx.stroke_outline.bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), ctx.stroke_outline.bounds[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, -5), ctx.stroke_outline.bounds[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), ctx.stroke_outline.bounds[3], 0.001);
}

test "square cap line outline extends by half stroke width" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.strokeWidth(ctx, 10);
    state_ops.lineCap(ctx, .square);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 20, 0);
    stroke.buildOutline(ctx);

    try testing.expectApproxEqAbs(@as(f32, -5), ctx.stroke_outline.bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 25), ctx.stroke_outline.bounds[2], 0.001);
}

test "round cap line outline has more points than butt cap" {
    const butt = try Context.create(testing.allocator, 0);
    defer butt.destroy();
    const round = try Context.create(testing.allocator, 0);
    defer round.destroy();

    state_ops.strokeWidth(butt, 10);
    state_ops.lineCap(butt, .butt);
    path_ops.moveTo(butt, 0, 0);
    path_ops.lineTo(butt, 20, 0);
    stroke.buildOutline(butt);

    state_ops.strokeWidth(round, 10);
    state_ops.lineCap(round, .round);
    path_ops.moveTo(round, 0, 0);
    path_ops.lineTo(round, 20, 0);
    stroke.buildOutline(round);

    try testing.expect(round.stroke_outline.points.items.len > butt.stroke_outline.points.items.len);
}

test "closed rectangle stroke produces closed outline contours" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.strokeWidth(ctx, 4);
    path_ops.rect(ctx, 0, 0, 20, 10);
    stroke.buildOutline(ctx);

    try testing.expectEqual(@as(usize, 2), ctx.stroke_outline.paths.items.len);
    const outline_path = ctx.stroke_outline.paths.items[0];
    try testing.expect(outline_path.closed);
    const pts = ctx.stroke_outline.points.items[outline_path.point_start..][0..outline_path.point_count];
    try testing.expect(@abs(polyArea(pts)) > 0.001);
    try testing.expect(pts[0].dmx != 0 or pts[0].dmy != 0);
}

test "low miter limit adds bevel points on sharp closed stroke" {
    const miter = try Context.create(testing.allocator, 0);
    defer miter.destroy();
    const bevel = try Context.create(testing.allocator, 0);
    defer bevel.destroy();

    state_ops.strokeWidth(miter, 4);
    state_ops.miterLimit(miter, 10);
    path_ops.rect(miter, 0, 0, 20, 10);
    stroke.buildOutline(miter);

    state_ops.strokeWidth(bevel, 4);
    state_ops.miterLimit(bevel, 0.5);
    path_ops.rect(bevel, 0, 0, 20, 10);
    stroke.buildOutline(bevel);

    try testing.expect(bevel.stroke_outline.points.items.len > miter.stroke_outline.points.items.len);
}

test "round join adds points compared with bevel join" {
    const bevel = try Context.create(testing.allocator, 0);
    defer bevel.destroy();
    const round = try Context.create(testing.allocator, 0);
    defer round.destroy();

    state_ops.strokeWidth(bevel, 6);
    state_ops.lineJoin(bevel, .bevel);
    path_ops.moveTo(bevel, 0, 0);
    path_ops.lineTo(bevel, 20, 0);
    path_ops.lineTo(bevel, 20, 20);
    stroke.buildOutline(bevel);

    state_ops.strokeWidth(round, 6);
    state_ops.lineJoin(round, .round);
    path_ops.moveTo(round, 0, 0);
    path_ops.lineTo(round, 20, 0);
    path_ops.lineTo(round, 20, 20);
    stroke.buildOutline(round);

    try testing.expect(round.stroke_outline.points.items.len > bevel.stroke_outline.points.items.len);
}

test "degenerate stroke inputs produce no outline" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    state_ops.strokeWidth(ctx, 0);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 20, 0);
    stroke.buildOutline(ctx);
    try testing.expectEqual(@as(usize, 0), ctx.stroke_outline.paths.items.len);

    state_ops.strokeWidth(ctx, 4);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    stroke.buildOutline(ctx);
    try testing.expectEqual(@as(usize, 0), ctx.stroke_outline.paths.items.len);
}

test "backend receives viewport flush and deinit lifecycle calls" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 320, 240, 2);
    try testing.expectEqual(@as(usize, 1), backend.viewport_calls);
    try testing.expectApproxEqAbs(@as(f32, 320), backend.viewport_width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 240), backend.viewport_height, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2), backend.viewport_dpr, 0.001);

    frame_ops.endFrame(ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_calls);

    ctx.destroy();
    try testing.expectEqual(@as(usize, 1), backend.deinit_calls);
}

test "fill records flattened geometry and style snapshots" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    paint_ops.fillColor(ctx, color.rgbaf(0.25, 0.5, 0.75, 0.8));
    state_ops.save(ctx);
    paint_ops.fillColor(ctx, color.rgbaf(1, 0, 0, 1));
    state_ops.restore(ctx);
    state_ops.scissor(ctx, 2, 4, 30, 40);
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 10, 20, 30, 40);

    render_ops.fill(ctx);

    try testing.expectEqual(@as(usize, 1), backend.fill_calls);
    try testing.expectEqual(@as(usize, 1), backend.last_fill.path_count);
    try testing.expectEqual(@as(usize, 4), backend.last_fill.point_count);
    try testing.expectEqual(@intFromPtr(ctx.cache.paths.items.ptr), backend.last_fill.paths_ptr);
    try testing.expectEqual(@intFromPtr(ctx.cache.points.items.ptr), backend.last_fill.points_ptr);
    try testing.expectApproxEqAbs(@as(f32, 10), backend.last_fill.bounds[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), backend.last_fill.bounds[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), backend.last_fill.bounds[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), backend.last_fill.bounds[3], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), backend.last_fill.paint.inner_color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), backend.last_fill.paint.inner_color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 15), backend.last_fill.scissor.extent[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), backend.last_fill.scissor.extent[1], 0.001);

    paint_ops.fillColor(ctx, color.rgbaf(1, 0, 0, 1));
    state_ops.resetScissor(ctx);
    try testing.expectApproxEqAbs(@as(f32, 0.25), backend.last_fill.paint.inner_color.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 15), backend.last_fill.scissor.extent[0], 0.001);
}

test "stroke records shared outline geometry and style snapshots" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    state_ops.strokeWidth(ctx, 10);
    state_ops.lineCap(ctx, .round);
    paint_ops.strokeColor(ctx, color.rgbaf(0.1, 0.2, 0.3, 0.4));
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 20, 0);

    render_ops.stroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expectEqual(@intFromPtr(ctx.stroke_outline.paths.items.ptr), backend.last_stroke.paths_ptr);
    try testing.expectEqual(@intFromPtr(ctx.stroke_outline.points.items.ptr), backend.last_stroke.points_ptr);
    try testing.expect(backend.last_stroke.path_count > 0);
    try testing.expect(backend.last_stroke.point_count > ctx.cache.points.items.len);
    try testing.expectApproxEqAbs(@as(f32, 10), backend.last_stroke.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), backend.last_stroke.paint.inner_color.g, 0.001);

    paint_ops.strokeColor(ctx, color.rgbaf(1, 1, 1, 1));
    state_ops.strokeWidth(ctx, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.2), backend.last_stroke.paint.inner_color.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), backend.last_stroke.width, 0.001);
}

test "stroke render uses transform-scaled width" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    state_ops.strokeWidth(ctx, 2);
    state_ops.scale(ctx, 2, 4);
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 10, 0);

    render_ops.stroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expectApproxEqAbs(@as(f32, 6), backend.last_stroke.width, 0.001);
}

test "thin antialiased stroke scales alpha and clamps to fringe width" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, OKY_ANTIALIAS);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 100, 100, 2);
    state_ops.strokeWidth(ctx, 0.25);
    paint_ops.strokeColor(ctx, color.rgbaf(0.1, 0.2, 0.3, 0.8));
    path_ops.moveTo(ctx, 0, 0);
    path_ops.lineTo(ctx, 10, 0);

    render_ops.stroke(ctx);

    try testing.expectEqual(@as(usize, 1), backend.stroke_calls);
    try testing.expectApproxEqAbs(@as(f32, 0.5), backend.last_stroke.width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), backend.last_stroke.paint.inner_color.a, 0.001);
}

test "empty draw calls and no backend do not emit render calls" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    render_ops.fill(ctx);
    render_ops.stroke(ctx);
    try testing.expectEqual(@as(usize, 0), backend.fill_calls);
    try testing.expectEqual(@as(usize, 0), backend.stroke_calls);

    ctx.clearBackend();
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 10, 10);
    render_ops.fill(ctx);
    try testing.expectEqual(@as(usize, 1), ctx.cache.paths.items.len);
}

test "cancel frame clears transient draw data without flushing" {
    var backend: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    ctx.installBackend(backend.interface());

    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 10, 10);
    render_ops.fill(ctx);
    state_ops.strokeWidth(ctx, 2);
    render_ops.stroke(ctx);

    try testing.expect(ctx.commands.data.items.len > 0);
    try testing.expect(ctx.cache.paths.items.len > 0);
    try testing.expect(ctx.stroke_outline.paths.items.len > 0);

    frame_ops.cancelFrame(ctx);
    try testing.expectEqual(@as(usize, 0), ctx.commands.data.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.cache.paths.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.stroke_outline.paths.items.len);
    try testing.expectEqual(@as(usize, 0), backend.flush_calls);
}

fn polyArea(pts: []const okys.types.path.Point) f32 {
    var area: f32 = 0;
    for (pts, 0..) |p0, i| {
        const p1 = pts[(i + 1) % pts.len];
        area += p0.x * p1.y - p1.x * p0.y;
    }
    return area * 0.5;
}
