const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const Context = okys.state.context.Context;
const Backend = okys.systems.backend_stencil.Backend;
const PathDrawKind = okys.render.sokol_device.PathDrawKind;
const DrawOpKind = okys.systems.backend_stencil.DrawOpKind;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

const Scene = struct {
    ctx: *Context,
    backend: *Backend,
};

test "golden replay covers fills paints holes scissor and thin overlap cases" {
    var scene = try createScene(OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer scene.ctx.destroy();
    scene.backend.fill_rule = .even_odd;

    const checker = [_]u8{
        255, 255, 255, 255, 0,   0,   0,   255,
        0,   0,   0,   255, 255, 255, 255, 255,
    };
    const image_id = image_ops.createImageRGBA(scene.ctx, 2, 2, &checker);
    try testing.expect(image_id != .none);

    paint_ops.fillColor(scene.ctx, color.rgbaf(0.25, 0.5, 0.75, 1.0));
    path_ops.beginPath(scene.ctx);
    path_ops.rect(scene.ctx, 10, 10, 80, 50);
    render_ops.fill(scene.ctx);

    paint_ops.fillPaint(scene.ctx, paint_ops.linearGradient(
        scene.ctx,
        110,
        15,
        210,
        80,
        color.rgbaf(1.0, 0.0, 0.0, 0.8),
        color.rgbaf(0.0, 0.0, 1.0, 0.6),
    ));
    path_ops.beginPath(scene.ctx);
    path_ops.moveTo(scene.ctx, 112, 70);
    path_ops.bezierTo(scene.ctx, 130, 12, 190, 12, 212, 70);
    path_ops.lineTo(scene.ctx, 170, 104);
    path_ops.closePath(scene.ctx);
    render_ops.fill(scene.ctx);

    paint_ops.fillColor(scene.ctx, color.rgbaf(0.1, 0.9, 0.45, 0.7));
    path_ops.beginPath(scene.ctx);
    path_ops.rect(scene.ctx, 20, 120, 100, 90);
    path_ops.rect(scene.ctx, 45, 145, 50, 40);
    render_ops.fill(scene.ctx);

    paint_ops.fillPaint(scene.ctx, paint_ops.imagePattern(scene.ctx, 140, 130, 64, 64, 0.3, @intCast(@intFromEnum(image_id)), 0.5));
    path_ops.beginPath(scene.ctx);
    path_ops.roundedRect(scene.ctx, 140, 125, 80, 68, 12);
    render_ops.fill(scene.ctx);

    state_ops.save(scene.ctx);
    state_ops.scissor(scene.ctx, 18, 216, 168, 32);
    paint_ops.fillColor(scene.ctx, color.rgbaf(1.0, 1.0, 1.0, 0.6));
    path_ops.beginPath(scene.ctx);
    path_ops.rect(scene.ctx, 10, 220, 205, 3);
    render_ops.fill(scene.ctx);
    path_ops.beginPath(scene.ctx);
    path_ops.rect(scene.ctx, 10, 224, 205, 3);
    render_ops.fill(scene.ctx);
    state_ops.restore(scene.ctx);

    try testing.expect(scene.backend.buildStencilPass());

    try testing.expect(countPathDraws(scene.backend, .convex) >= 3);
    try testing.expect(countPathDraws(scene.backend, .fringe) >= 3);
    try testing.expect(countPathDraws(scene.backend, .stencil_even_odd) >= 1);
    try testing.expect(countPathDraws(scene.backend, .cover) >= 1);
    try testing.expect(countPathDraws(scene.backend, .fringe_stencil) >= 1);
    try testing.expect(countDrawOps(scene.backend, .stencil_fill) >= 2);
    try testing.expect(countDrawOps(scene.backend, .cover_fill) >= 1);
    try testing.expect(scene.backend.indices.items.len > 0);
    try testing.expect(scene.backend.vertices.items.len > 50);
    try testing.expect(scene.backend.uniforms.items.len >= 6);
    try testing.expect(scene.backend.frag_params.items.len == scene.backend.uniforms.items.len);
    try testing.expect(hasImageUniform(scene.backend, @intCast(@intFromEnum(image_id))));
    try testing.expect(hasScissorUniform(scene.backend));
}

test "golden replay matches nanovg style forced stenciled strokes" {
    var scene = try createScene(OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer scene.ctx.destroy();

    paint_ops.strokeColor(scene.ctx, color.rgbaf(0.95, 0.8, 0.25, 1.0));
    state_ops.strokeWidth(scene.ctx, 8);
    state_ops.lineJoin(scene.ctx, .round);
    state_ops.lineCap(scene.ctx, .round);
    path_ops.beginPath(scene.ctx);
    path_ops.moveTo(scene.ctx, 32, 60);
    path_ops.lineTo(scene.ctx, 78, 32);
    path_ops.lineTo(scene.ctx, 125, 78);
    path_ops.bezierTo(scene.ctx, 160, 112, 205, 34, 238, 82);
    render_ops.stroke(scene.ctx);

    paint_ops.strokeColor(scene.ctx, color.rgbaf(0.2, 0.7, 1.0, 1.0));
    state_ops.strokeWidth(scene.ctx, 0.5);
    state_ops.lineJoin(scene.ctx, .bevel);
    state_ops.lineCap(scene.ctx, .square);
    path_ops.beginPath(scene.ctx);
    path_ops.moveTo(scene.ctx, 24, 150);
    path_ops.lineTo(scene.ctx, 245, 153);
    render_ops.stroke(scene.ctx);

    try testing.expect(scene.backend.buildStencilPass());

    try testing.expectEqual(@as(usize, 2), scene.backend.calls.items.len);
    try testing.expect(countPathDraws(scene.backend, .stencil_nonzero) >= 2);
    try testing.expect(countPathDraws(scene.backend, .fringe_stencil) >= 2);
    try testing.expect(countPathDraws(scene.backend, .cover) >= 2);
    try testing.expectEqual(@as(usize, 0), countPathDraws(scene.backend, .convex));
    try testing.expect(scene.backend.uniforms.items[0].edge_alpha_multiplier == 1);
    try testing.expect(scene.backend.uniforms.items[1].edge_alpha_multiplier == 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), scene.backend.uniforms.items[1].inner_color.a, 0.001);
}

fn createScene(flags: u32) !Scene {
    const ctx = try Context.create(testing.allocator, flags);
    errdefer ctx.destroy();

    const backend = try Backend.createWithFlags(testing.allocator, flags);
    ctx.installBackend(backend.interface());
    frame_ops.beginFrame(ctx, 256, 256, 1);
    return .{ .ctx = ctx, .backend = backend };
}

fn countPathDraws(backend: *const Backend, kind: PathDrawKind) usize {
    var count: usize = 0;
    for (backend.path_draws.items) |draw| {
        if (draw.kind == kind) count += 1;
    }
    return count;
}

fn countDrawOps(backend: *const Backend, kind: DrawOpKind) usize {
    var count: usize = 0;
    for (backend.draw_ops.items) |op| {
        if (op.kind == kind) count += 1;
    }
    return count;
}

fn hasImageUniform(backend: *const Backend, image_id: i32) bool {
    for (backend.uniforms.items) |uniform| {
        if (uniform.image == image_id) return true;
    }
    return false;
}

fn hasScissorUniform(backend: *const Backend) bool {
    for (backend.uniforms.items) |uniform| {
        if (uniform.scissor_enabled) return true;
    }
    return false;
}
