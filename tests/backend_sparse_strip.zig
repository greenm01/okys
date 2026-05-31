const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Vertex = okys.types.path.Vertex;
const sparse = okys.systems.backend_sparse_strip;
const Backend = sparse.Backend;
const Context = okys.state.context.Context;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

test "sparse backend records viewport and clears queued proof buffers on flush" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();

    iface.viewport(iface.ctx, 64, 48, 2);
    try testing.expectEqual(@as(f32, 64), backend.viewport_width);
    try testing.expectEqual(@as(f32, 48), backend.viewport_height);
    try testing.expectEqual(@as(f32, 2), backend.viewport_dpr);

    queueRect(&iface, 4, 4, 12, 12);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 4), backend.segments.items.len);

    iface.flush(iface.ctx);
    try testing.expectEqual(@as(usize, 1), backend.flush_count);
    try testing.expectEqual(@as(usize, 0), backend.calls.items.len);
    try testing.expectEqual(@as(usize, 0), backend.segments.items.len);
    try testing.expectEqual(@as(usize, 0), backend.strips.items.len);
    try testing.expectEqual(@as(usize, 0), backend.alphas.items.len);
}

test "sparse encode preserves call range and convex hint for rect" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 64, 64, 1);

    queueRect(&iface, 4, 4, 12, 12);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.fill, backend.calls.items[0].kind);
    try testing.expectEqual(@as(u32, 0), backend.calls.items[0].segments.start);
    try testing.expectEqual(@as(u32, 4), backend.calls.items[0].segments.count);
    try testing.expect(backend.calls.items[0].convex);
    try testing.expectEqual(@as(u32, 0), backend.segments.items[0].call_index);
    try testing.expectEqual(@as(u32, 0), backend.segments.items[0].path_index);
}

test "sparse binning emits segment-local boundary tiles" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 64, 64, 1);

    queueRect(&iface, 0, 0, 32, 32);
    try testing.expect(backend.build());

    try testing.expectEqual(@as(usize, 16), backend.tiles.items.len);
    try testing.expectEqual(@as(usize, 16), backend.strips.items.len);
    try testing.expectEqual(@as(u16, 0), backend.strips.items[0].x);
    try testing.expectEqual(@as(u16, 0), backend.strips.items[0].y);
    try testing.expect(findStrip(backend, 28, 0, 0) != null);
    try testing.expect(findStrip(backend, 0, 28, 0) != null);
    try testing.expect(findStrip(backend, 28, 28, 0) != null);
    try testing.expectEqual(@as(u32, 1), backend.strips.items[0].segment_indices.count);
}

test "sparse fine stage covers solid rect interior through solid spans" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4, 4, 12, 12);
    try testing.expect(backend.build());

    try testing.expect(backend.strips.items.len > 0);
    try testing.expectEqual(sparse.strip.tile_area, backend.strips.items[0].alpha.count);
    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 1, 1));
}

test "sparse profiled build reports fine-stage work counters" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4, 4, 20, 20);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    try testing.expectEqual(backend.strips.items.len, profile.fine_profile.boundary_tiles);
    try testing.expectEqual(backend.strips.items.len * sparse.strip.tile_area, profile.fine_profile.boundary_pixels);
    try testing.expectEqual(@as(usize, 1), profile.fine_profile.rect_fast_calls);
    try testing.expect(profile.fine_profile.rect_fast_pixels > 0);
    try testing.expectEqual(profile.fine_profile.rect_fast_pixels, profile.fine_profile.solid_fast_pixels);
    try testing.expectEqual(@as(usize, 1), profile.fine_profile.fill_ops);
    try testing.expectEqual(@as(usize, 0), profile.fine_profile.alpha_fill_ops);
    try testing.expectEqual(profile.fine_profile.rect_fast_pixels, profile.fine_profile.fill_pixels);
    try testing.expectEqual(@as(usize, 0), profile.fine_profile.alpha_fill_pixels);
    try testing.expect(profile.fine_profile.opaque_write_pixels > 0);

    const packet = profile.frame_packet;
    try testing.expectEqual(backend.calls.items.len, packet.calls);
    try testing.expectEqual(backend.segments.items.len, packet.segments);
    try testing.expectEqual(backend.tiles.items.len, packet.tile_refs);
    try testing.expectEqual(backend.strips.items.len, packet.strips);
    try testing.expectEqual(backend.strip_segment_indices.items.len, packet.strip_indices);
    try testing.expectEqual(backend.alphas.items.len, packet.alpha_bytes);
    try testing.expectEqual(backend.surface.items.len, packet.surface_bytes);
    try testing.expectEqual(@as(usize, 0), packet.texture_bytes);
    try testing.expectEqual(@sizeOf(sparse.EncodedCall) * backend.calls.items.len, packet.calls_bytes);
    try testing.expectEqual(@sizeOf(sparse.Segment) * backend.segments.items.len, packet.segments_bytes);
    try testing.expectEqual(@sizeOf(sparse.TileRef) * backend.tiles.items.len, packet.tile_refs_bytes);
    try testing.expectEqual(@sizeOf(sparse.Strip) * backend.strips.items.len, packet.strips_bytes);
    try testing.expectEqual(@sizeOf(u32) * backend.strip_segment_indices.items.len, packet.strip_indices_bytes);
    try testing.expect(packet.frame_packet_bytes >= packet.gpu_fine_upload_bytes);
    try testing.expect(packet.gpu_fine_upload_bytes > 0);
    try testing.expect(packet.packet_capacity_bytes >= packet.frame_packet_bytes);
    try testing.expect(packet.max_strip_segments > 0);
    try testing.expectEqual(@as(usize, 4), packet.frame_bounds_x0);
    try testing.expectEqual(@as(usize, 4), packet.frame_bounds_y0);
    try testing.expectEqual(@as(usize, 20), packet.frame_bounds_x1);
    try testing.expectEqual(@as(usize, 20), packet.frame_bounds_y1);
    try testing.expectEqual(@as(usize, 256), packet.command_bound_pixels);
    try testing.expectEqual(@as(usize, 16), packet.candidate_tiles_from_bounds);
    try testing.expectEqual(@as(usize, 0), packet.empty_bound_calls);
    try testing.expectEqual(@as(usize, 0), packet.clipped_out_calls);
    try testing.expectEqual(@as(usize, 1), packet.fill_box_candidate_calls);
    try testing.expectEqual(@as(usize, 4), packet.max_segments_per_call);
    try testing.expectEqual(@as(usize, 4), packet.max_tile_refs_per_call);
    try testing.expectEqual(@as(usize, 4), packet.max_strips_per_call);
    try testing.expectEqual(@as(usize, 64), packet.max_alpha_bytes_per_call);
    try testing.expectEqual(@as(usize, 0), packet.dense_strip_warnings);
    try testing.expectEqual(sparse.gpu_fine_upload_warning_bytes, packet.upload_budget_bytes);
    try testing.expectEqual(@as(usize, 0), packet.upload_budget_warnings);
}

test "sparse GPU fine packet encodes solid Fill and AlphaFill tasks by call" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4.25, 4.25, 12.25, 12.25);
    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);

    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expect(packet.stats.supported);
    try testing.expectEqual(@as(usize, 1), packet.calls.items.len);
    try testing.expect(packet.stats.fill_tasks > 0);
    try testing.expect(packet.stats.alpha_fill_tasks > 0);
    try testing.expectEqual(packet.tasks.items.len, packet.stats.tasks);
    try testing.expectEqual(packet.tasks.items.len, packet.calls.items[0].task_count);
    try testing.expectEqual(@as(u32, 0), packet.calls.items[0].task_start);
    try testing.expectEqual(@as(usize, 1), packet.stats.dispatches);
    try testing.expectEqual(packet.tasks.items.len, packet.stats.workgroups);
    try testing.expect(packet.stats.upload_bytes >= @sizeOf(sparse.gpu_fine.GpuCall) + @sizeOf(sparse.gpu_fine.GpuFineTask));

    var saw_fill = false;
    var saw_alpha_fill = false;
    for (packet.tasks.items) |task| {
        try testing.expectEqual(@as(u32, 0), task.call_index);
        if (task.kind == sparse.gpu_fine.task_fill) saw_fill = true;
        if (task.kind == sparse.gpu_fine.task_alpha_fill) saw_alpha_fill = true;
    }
    try testing.expect(saw_fill);
    try testing.expect(saw_alpha_fill);
}

test "sparse GPU fine packet preserves per-call draw-order ranges" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    queuePaintedRect(&iface, color.rgbaf(0, 0, 1, 0.5), 8, 8, 24, 24);
    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);

    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expectEqual(@as(usize, 2), packet.calls.items.len);
    try testing.expect(packet.calls.items[0].task_count > 0);
    try testing.expect(packet.calls.items[1].task_count > 0);
    try testing.expectEqual(packet.calls.items[0].task_count, packet.calls.items[1].task_start);

    for (packet.tasks.items[0..packet.calls.items[0].task_count]) |task| {
        try testing.expectEqual(@as(u32, 0), task.call_index);
    }
    const second_start: usize = @intCast(packet.calls.items[1].task_start);
    for (packet.tasks.items[second_start..]) |task| {
        try testing.expectEqual(@as(u32, 1), task.call_index);
    }
}

test "sparse GPU fine packet falls back for unsupported paint and scissor" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const gradient = paint_ops.linearGradient(ctx, 0, 0, 16, 0, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1));
    queuePaintRect(&iface, gradient, 0, 0, 16, 16, disabled_scissor);
    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);

    try testing.expect(!backend.buildGpuFinePacket(&packet, null));
    try testing.expectEqual(.unsupported_paint, packet.stats.fallback_reason);

    backend.clearQueued();
    const scissor: color.Scissor = .{
        .xform = .{ 1, 0, 0, 1, 8, 8 },
        .extent = .{ 4, 4 },
    };
    queuePaintRect(&iface, color.solid(color.rgbaf(0, 1, 0, 1)), 0, 0, 16, 16, scissor);
    try testing.expect(!backend.buildGpuFinePacket(&packet, null));
    try testing.expectEqual(.unsupported_scissor, packet.stats.fallback_reason);
}

test "sparse frame packet bounds diagnostics track clipped out calls" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, -20, -20, -10, -10);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    const packet = profile.frame_packet;
    try testing.expectEqual(@as(usize, 1), packet.calls);
    try testing.expectEqual(@as(usize, 0), packet.tile_refs);
    try testing.expectEqual(@as(usize, 0), packet.strips);
    try testing.expectEqual(@as(usize, 0), packet.command_bound_pixels);
    try testing.expectEqual(@as(usize, 0), packet.candidate_tiles_from_bounds);
    try testing.expectEqual(@as(usize, 0), packet.empty_bound_calls);
    try testing.expectEqual(@as(usize, 1), packet.clipped_out_calls);
    try testing.expectEqual(@as(usize, 0), packet.frame_bounds_x0);
    try testing.expectEqual(@as(usize, 0), packet.frame_bounds_y0);
    try testing.expectEqual(@as(usize, 0), packet.frame_bounds_x1);
    try testing.expectEqual(@as(usize, 0), packet.frame_bounds_y1);
}

test "sparse frame packet pressure diagnostics flag dense strips" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    var points: [64]Point = undefined;
    for (&points, 0..) |*point, i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(points.len - 1));
        point.* = .{
            .x = 5 + t * 2,
            .y = if (i % 2 == 0) 5 else 7,
        };
    }
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = points.len, .closed = true, .convex = false }};
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 5, 5, 7, 7 }, &paths, &points);

    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    const packet = profile.frame_packet;
    try testing.expect(packet.max_segments_per_call > sparse.dense_strip_segment_warning_threshold);
    try testing.expect(packet.max_strip_segments > sparse.dense_strip_segment_warning_threshold);
    try testing.expect(packet.dense_strip_warnings > 0);
    try testing.expectEqual(@as(usize, 1), packet.candidate_tiles_from_bounds);
}

test "sparse fine stage uses analytic subpixel coverage" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4.25, 4.25, 12.25, 12.25);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    const left_top = findStrip(backend, 4, 4, 0).?;
    try expectAlphaApprox(143, alphaAt(backend, left_top, 4, 4));
    try testing.expectEqual(@as(u8, 255), alphaAt(backend, left_top, 5, 5));

    const right_bottom = findStrip(backend, 12, 12, 0).?;
    try expectAlphaApprox(16, alphaAt(backend, right_bottom, 12, 12));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 3, 4));
    try testing.expectEqual(@as(usize, 1), profile.fine_profile.rect_fast_calls);
    try testing.expect(profile.fine_profile.fill_pixels > 0);
    try testing.expect(profile.fine_profile.alpha_fill_ops > 0);
    try testing.expect(profile.fine_profile.alpha_fill_pixels > 0);
}

test "sparse rect fast path blends translucent solid paint" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    queuePaintedRect(&iface, color.rgbaf(0, 0, 1, 0.5), 4, 4, 20, 20);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual(@as(usize, 2), profile.fine_profile.rect_fast_calls);
    try testing.expect(profile.fine_profile.opaque_write_pixels > 0);
}

test "sparse even odd coverage cuts a hole from nested paths" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 18, .y = 2 },
        .{ .x = 18, .y = 18 },
        .{ .x = 2, .y = 18 },
        .{ .x = 7, .y = 7 },
        .{ .x = 13, .y = 7 },
        .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 13 },
    };
    const paths = [_]PathRange{
        .{ .point_start = 0, .point_count = 4, .closed = true, .convex = false },
        .{ .point_start = 4, .point_count = 4, .closed = true, .convex = false },
    };
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 2, 2, 18, 18 }, &paths, &points);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, rgbaAt(backend, 4, 4));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 10, 10));
}

test "sparse even odd coverage folds self-overlapping path area" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 18, .y = 4 },
        .{ .x = 18, .y = 18 },
        .{ .x = 4, .y = 18 },
        .{ .x = 4, .y = 4 },
        .{ .x = 18, .y = 4 },
        .{ .x = 18, .y = 18 },
        .{ .x = 4, .y = 18 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 8, .closed = true, .convex = false }};
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 4, 4, 18, 18 }, &paths, &points);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 8, 8));
}

test "sparse solid paint composites into proof surface" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 2, 2));
}

test "sparse solid paint composites calls in draw order" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 4, 4, 20, 20);
    queuePaintedRect(&iface, color.rgbaf(0, 0, 1, 0.5), 4, 4, 20, 20);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, rgbaAt(backend, 8, 8));
    try expectSpatialStripOrder(backend.strips.items);
    try testing.expect(profile.frame_packet.multi_call_tiles > 0);
    try testing.expectEqual(@as(usize, 2), profile.frame_packet.max_calls_per_tile);
    try testing.expect(profile.frame_packet.strip_call_order_breaks > 0);
    try testing.expectEqual(@as(usize, 0), profile.frame_packet.strip_spatial_order_breaks);
}

test "sparse linear gradient resolves into proof surface" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = paint_ops.linearGradient(ctx, 0, 0, 16, 0, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1));
    queuePaintRect(&iface, paint, 0, 0, 16, 16, disabled_scissor);
    var profile: sparse.Profile = .{};
    try testing.expect(backend.buildProfiled(&profile));

    const mid = rgbaAt(backend, 8, 8);
    try testing.expect(mid[0] > 80 and mid[0] < 180);
    try testing.expect(mid[2] > 80 and mid[2] < 180);
    try testing.expectEqual(@as(u8, 255), mid[3]);
    try testing.expectEqual(@as(usize, 0), profile.fine_profile.rect_fast_calls);
    try testing.expectEqual(@as(usize, 0), profile.fine_profile.solid_fast_pixels);
    try testing.expect(profile.fine_profile.fill_pixels > 0);
    try testing.expect(profile.fine_profile.alpha_fill_pixels > 0);
}

test "sparse radial gradient resolves center and edge colors" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = paint_ops.radialGradient(ctx, 8, 8, 0, 10, color.rgbaf(1, 0, 0, 1), color.rgbaf(0, 0, 1, 1));
    queuePaintRect(&iface, paint, 0, 0, 18, 18, disabled_scissor);
    try testing.expect(backend.build());

    const center = rgbaAt(backend, 8, 8);
    const edge = rgbaAt(backend, 17, 8);
    try testing.expect(center[0] > center[2]);
    try testing.expect(edge[2] > edge[0]);
}

test "sparse image pattern samples uploaded rgba texture" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const id = image_ops.createImageRGBA(ctx, 2, 2, &pixels);
    try testing.expect(id != .none);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 2, 2, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 8, 8, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgbaAt(backend, 0, 0));
    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(backend, 1, 0));
    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, rgbaAt(backend, 0, 1));
}

test "sparse image pattern filters between texels" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 8, 4, 1);

    const pixels = [_]u8{
        255, 0, 0, 255, 0, 255, 0, 255,
    };
    const id = image_ops.createImageRGBA(ctx, 2, 1, &pixels);
    try testing.expect(id != .none);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 4, 1, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 4, 1, disabled_scissor);
    try testing.expect(backend.build());

    const left_blend = rgbaAt(backend, 1, 0);
    try testing.expect(left_blend[0] > left_blend[1]);
    try testing.expect(left_blend[1] > 0);

    const right_blend = rgbaAt(backend, 2, 0);
    try testing.expect(right_blend[1] > right_blend[0]);
    try testing.expect(right_blend[0] > 0);
}

test "sparse image update changes later proof output" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 16, 16, 1);

    var pixels = [_]u8{ 255, 0, 0, 255 };
    const id = image_ops.createImageRGBA(ctx, 1, 1, &pixels);
    try testing.expect(id != .none);
    pixels = .{ 0, 0, 255, 255 };
    image_ops.updateImage(ctx, id, &pixels);

    const paint = paint_ops.imagePattern(ctx, 0, 0, 1, 1, 0, @intCast(@intFromEnum(id)), 1);
    queuePaintRect(&iface, paint, 0, 0, 4, 4, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 0, 0, 255, 255 }, rgbaAt(backend, 1, 1));
}

test "sparse scissor masks proof surface" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const scissor: color.Scissor = .{
        .xform = .{ 1, 0, 0, 1, 8, 8 },
        .extent = .{ 4, 4 },
    };
    queuePaintRect(&iface, color.solid(color.rgbaf(0, 1, 0, 1)), 0, 0, 16, 16, scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 0, 255, 0, 255 }, rgbaAt(backend, 8, 8));
    try testing.expectEqual([4]u8{ 0, 0, 0, 0 }, rgbaAt(backend, 2, 2));
}

test "sparse gradient composites over solid fill in draw order" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queuePaintedRect(&iface, color.rgbaf(1, 0, 0, 1), 0, 0, 16, 16);
    const paint = paint_ops.linearGradient(ctx, 0, 0, 16, 0, color.rgbaf(0, 0, 1, 0.5), color.rgbaf(0, 0, 1, 0.5));
    queuePaintRect(&iface, paint, 0, 0, 16, 16, disabled_scissor);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 128, 0, 128, 255 }, rgbaAt(backend, 8, 8));
}

test "sparse frontend curve renders through analytic proof path" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 32, 32, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0, 1, 0, 1));
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 4, 22);
    path_ops.bezierTo(ctx, 7, 4, 25, 4, 28, 22);
    path_ops.lineTo(ctx, 16, 28);
    path_ops.closePath(ctx);
    render_ops.fill(ctx);

    try testing.expect(backend.build());
    try testing.expect(backend.strips.items.len > 0);
    try testing.expect(backend.alphas.items.len > 0);
    try testing.expect(rgbaAt(backend, 16, 18)[1] > 0);
}

test "sparse backend queues stroke outlines as path segments" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 16, .y = 4 },
        .{ .x = 10, .y = 16 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 3, .closed = true, .convex = true }};

    iface.stroke(iface.ctx, &paint, &disabled_scissor, 3, &paths, &points);
    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.stroke, backend.calls.items[0].kind);
    try testing.expectEqual(@as(f32, 3), backend.calls.items[0].width);
    try testing.expectEqual(@as(u32, 3), backend.calls.items[0].segments.count);
}

test "sparse stroke coverage uses nonzero even when fill rule is even odd" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    backend.fill_rule = .even_odd;
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 20, .y = 4 },
        .{ .x = 20, .y = 20 },
        .{ .x = 4, .y = 20 },
        .{ .x = 4, .y = 4 },
        .{ .x = 20, .y = 4 },
        .{ .x = 20, .y = 20 },
        .{ .x = 4, .y = 20 },
    };
    const paths = [_]PathRange{
        .{ .point_start = 0, .point_count = 4, .closed = true, .convex = true },
        .{ .point_start = 4, .point_count = 4, .closed = true, .convex = true },
    };

    iface.stroke(iface.ctx, &paint, &disabled_scissor, 8, &paths, &points);
    try testing.expect(backend.build());

    try testing.expectEqual([4]u8{ 255, 255, 255, 255 }, rgbaAt(backend, 8, 8));
}

test "sparse backend texture callbacks store dimensions" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    const id: ImageId = @enumFromInt(42);

    try testing.expect(iface.create_texture(iface.ctx, id, 7, 9, .rgba8, null));
    try testing.expectEqual([2]u32{ 7, 9 }, iface.texture_size(iface.ctx, id).?);
    iface.delete_texture(iface.ctx, id);
    try testing.expect(iface.texture_size(iface.ctx, id) == null);
}

test "sparse triangle input encodes one closed triangle segment set" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const verts = [_]Vertex{
        .{ .x = 4, .y = 4, .u = 0, .v = 0 },
        .{ .x = 14, .y = 4, .u = 0, .v = 0 },
        .{ .x = 4, .y = 14, .u = 0, .v = 0 },
    };
    iface.triangles(iface.ctx, &paint, &disabled_scissor, &verts);

    try testing.expectEqual(@as(usize, 1), backend.calls.items.len);
    try testing.expectEqual(.triangles, backend.calls.items[0].kind);
    try testing.expectEqual(@as(u32, 3), backend.calls.items[0].segments.count);
}

test "sparse debug dumps tile segments strip metadata and coverage rows" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4.25, 4.25, 12.25, 12.25);
    try testing.expect(backend.build());

    var tile_segments = std.ArrayList(u8).empty;
    defer tile_segments.deinit(testing.allocator);
    var tile_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &tile_segments);
    try sparse.debug.writeTileSegments(&tile_writer.writer, backend.strips.items, backend.strip_segment_indices.items);
    tile_segments = tile_writer.toArrayList();
    try testing.expect(std.mem.startsWith(u8, tile_segments.items, "tile_x\ttile_y\tcall_index\tsegment_count\tsegment_indices\n"));
    try testing.expect(std.mem.indexOf(u8, tile_segments.items, "\t0\t1\t") != null);

    var strips = std.ArrayList(u8).empty;
    defer strips.deinit(testing.allocator);
    var strip_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &strips);
    try sparse.debug.writeStrips(&strip_writer.writer, backend.strips.items);
    strips = strip_writer.toArrayList();
    try testing.expect(std.mem.startsWith(u8, strips.items, "strip_index\tx\ty\tcall_index\tsegment_start\tsegment_count\talpha_start\talpha_count\tflags\n"));
    try testing.expect(std.mem.indexOf(u8, strips.items, "\t16\t") != null);

    var coverage = std.ArrayList(u8).empty;
    defer coverage.deinit(testing.allocator);
    var coverage_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &coverage);
    try sparse.debug.writeCoverage(&coverage_writer.writer, backend.strips.items, backend.alphas.items);
    coverage = coverage_writer.toArrayList();
    try testing.expect(std.mem.startsWith(u8, coverage.items, "strip_index\tx\ty\tcall_index\trow\talphas\n"));
    try testing.expect(std.mem.indexOf(u8, coverage.items, ",") != null);

    const bad_strip = sparse.Strip{
        .x = 0,
        .y = 0,
        .call_index = 0,
        .alpha = .{ .start = @intCast(backend.alphas.items.len + 1), .count = sparse.strip.tile_area },
    };
    const bad_strips = [_]sparse.Strip{bad_strip};
    var skipped = std.ArrayList(u8).empty;
    defer skipped.deinit(testing.allocator);
    var skipped_writer: std.Io.Writer.Allocating = .fromArrayList(testing.allocator, &skipped);
    try sparse.debug.writeCoverage(&skipped_writer.writer, &bad_strips, backend.alphas.items);
    skipped = skipped_writer.toArrayList();
    try testing.expectEqualStrings("strip_index\tx\ty\tcall_index\trow\talphas\n", skipped.items);
}

fn queueRect(iface: *const okys.render.interface.RenderInterface, x0: f32, y0: f32, x1: f32, y1: f32) void {
    queuePaintedRect(iface, color.rgbaf(1, 1, 1, 1), x0, y0, x1, y1);
}

fn queuePaintedRect(iface: *const okys.render.interface.RenderInterface, c: color.Color, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const paint = color.solid(c);
    queuePaintRect(iface, paint, x0, y0, x1, y1, disabled_scissor);
}

fn queuePaintRect(iface: *const okys.render.interface.RenderInterface, paint: color.Paint, x0: f32, y0: f32, x1: f32, y1: f32, scissor: color.Scissor) void {
    const points = [_]Point{
        .{ .x = x0, .y = y0 },
        .{ .x = x1, .y = y0 },
        .{ .x = x1, .y = y1 },
        .{ .x = x0, .y = y1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};
    iface.fill(iface.ctx, &paint, &scissor, .{ x0, y0, x1, y1 }, &paths, &points);
}

fn alphaAt(backend: *const Backend, s: sparse.Strip, x: u16, y: u16) u8 {
    const local_x = x - s.x;
    const local_y = y - s.y;
    const alpha_start: usize = @intCast(s.alpha.start);
    const index = alpha_start + @as(usize, local_y) * sparse.strip.tile_size + local_x;
    return backend.alphas.items[index];
}

fn findStrip(backend: *const Backend, x: u16, y: u16, call_index: u32) ?sparse.Strip {
    for (backend.strips.items) |s| {
        if (s.x == x and s.y == y and s.call_index == call_index) return s;
    }
    return null;
}

fn rgbaAt(backend: *const Backend, x: u32, y: u32) [4]u8 {
    const width: u32 = @intFromFloat(@ceil(backend.viewport_width));
    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    return backend.surface.items[index..][0..4].*;
}

fn expectAlphaApprox(expected: u8, actual: u8) !void {
    const delta = @abs(@as(i16, expected) - @as(i16, actual));
    try testing.expect(delta <= 1);
}

fn expectSpatialStripOrder(strips: []const sparse.Strip) !void {
    for (strips[1..], 1..) |s, i| {
        const prev = strips[i - 1];
        if (prev.y != s.y) {
            try testing.expect(prev.y < s.y);
        } else if (prev.x != s.x) {
            try testing.expect(prev.x < s.x);
        } else {
            try testing.expect(prev.call_index <= s.call_index);
        }
    }
}
