const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const color = okys.types.color;
const PathRange = okys.types.path.PathRange;
const Point = okys.types.path.Point;
const Context = okys.state.context.Context;
const sparse = okys.systems.backend_sparse_strip;
const Backend = sparse.Backend;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

const disabled_scissor: color.Scissor = .{
    .xform = .{ 0, 0, 0, 0, 0, 0 },
    .extent = .{ -1, -1 },
};

const ColorF = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

test "GPU packet simulator matches sparse CPU proof for subpixel rounded rect boundaries" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 48, 32, 1);

    const points = roundedRectPoints(4.25, 4.25, 36.25, 24.25, 6.0);
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = points.len, .closed = true, .convex = false }};
    const paint = color.solid(color.rgbaf(0.2, 0.7, 1.0, 0.9));
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 4.25, 4.25, 36.25, 24.25 }, &paths, &points);

    try expectPacketMatchesCpu(backend, 2);
}

test "GPU packet simulator matches sparse CPU proof for curves holes and stroke outlines" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 64, 48, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0.1, 0.6, 0.8, 0.8));
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 7, 34);
    path_ops.bezierTo(ctx, 12, 5, 48, 5, 56, 34);
    path_ops.lineTo(ctx, 34, 43);
    path_ops.closePath(ctx);
    render_ops.fill(ctx);

    paint_ops.fillColor(ctx, color.rgbaf(0.95, 0.95, 0.9, 0.9));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 10, 8, 22, 22);
    path_ops.rect(ctx, 16, 14, 10, 10);
    render_ops.fill(ctx);

    paint_ops.strokeColor(ctx, color.rgbaf(1, 0.8, 0.2, 0.85));
    state_ops.strokeWidth(ctx, 4);
    state_ops.lineJoin(ctx, .round);
    state_ops.lineCap(ctx, .round);
    const dash_pattern = [_]f32{ 8, 4 };
    state_ops.lineDash(ctx, &dash_pattern);
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 8, 40);
    path_ops.lineTo(ctx, 24, 28);
    path_ops.bezierTo(ctx, 36, 18, 44, 48, 58, 30);
    render_ops.stroke(ctx);

    try expectPacketMatchesCpu(backend, 3);
}

test "GPU packet simulator matches sparse CPU proof for gradient image scissor and source-over" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    const backend = try Backend.create(testing.allocator);
    ctx.installBackend(backend.interface());

    frame_ops.beginFrame(ctx, 64, 48, 1);
    paint_ops.fillColor(ctx, color.rgbaf(0.12, 0.16, 0.20, 1));
    path_ops.beginPath(ctx);
    path_ops.rect(ctx, 0, 0, 64, 48);
    render_ops.fill(ctx);

    const gradient = paint_ops.linearGradient(ctx, 4, 4, 42, 28, color.rgbaf(1, 0, 0, 0.75), color.rgbaf(0, 0, 1, 0.65));
    paint_ops.fillPaint(ctx, gradient);
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 4.5, 4.5, 36, 26, 5);
    render_ops.fill(ctx);

    const checker = [_]u8{
        255, 255, 255, 255, 30,  80,  170, 255,
        30,  80,  170, 255, 255, 255, 255, 255,
    };
    const image_id = image_ops.createImageRGBA(ctx, 2, 2, &checker);
    try testing.expect(image_id != .none);
    paint_ops.fillPaint(ctx, paint_ops.imagePattern(ctx, 26, 8, 14, 14, 0.25, @intCast(@intFromEnum(image_id)), 0.8));
    path_ops.beginPath(ctx);
    path_ops.roundedRect(ctx, 26, 8, 26, 22, 4);
    render_ops.fill(ctx);

    state_ops.save(ctx);
    state_ops.scissor(ctx, 10, 30, 42, 10);
    paint_ops.fillColor(ctx, color.rgbaf(0.9, 0.95, 0.8, 0.7));
    path_ops.beginPath(ctx);
    path_ops.moveTo(ctx, 4, 34);
    path_ops.bezierTo(ctx, 22, 24, 38, 44, 60, 32);
    path_ops.lineTo(ctx, 60, 38);
    path_ops.bezierTo(ctx, 38, 48, 22, 30, 4, 40);
    path_ops.closePath(ctx);
    render_ops.fill(ctx);
    state_ops.restore(ctx);

    try expectPacketMatchesCpu(backend, 4);
}

test "GPU packet simulator matches sparse CPU proof for nested path clips" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 48, 40, 1);

    pushClipRect(&iface, 6, 6, 40, 32, .nonzero);
    pushClipRect(&iface, 16, 6, 40, 32, .nonzero);
    const paint = color.solid(color.rgbaf(0.2, 0.9, 0.4, 0.85));
    const points = roundedRectPoints(2.5, 2.5, 44.5, 34.5, 7);
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = points.len, .closed = true, .convex = false }};
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 2.5, 2.5, 44.5, 34.5 }, &paths, &points);
    iface.pop_clip_path(iface.ctx);
    iface.pop_clip_path(iface.ctx);

    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);
    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expectEqual(@as(usize, 2), packet.clips.items.len);
    try testing.expectEqual(@as(usize, 2), packet.clip_indices.items.len);
    try testing.expectEqual(@as(u32, 2), packet.calls.items[0].clip_count);
    try expectPacketMatchesCpu(backend, 4);
}

test "GPU packet simulator matches sparse CPU proof for even odd path clip" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 48, 40, 1);

    const clip_points = [_]Point{
        .{ .x = 4, .y = 4 },
        .{ .x = 42, .y = 4 },
        .{ .x = 42, .y = 34 },
        .{ .x = 4, .y = 34 },
        .{ .x = 16, .y = 12 },
        .{ .x = 30, .y = 12 },
        .{ .x = 30, .y = 26 },
        .{ .x = 16, .y = 26 },
    };
    const clip_paths = [_]PathRange{
        .{ .point_start = 0, .point_count = 4, .closed = true, .convex = false },
        .{ .point_start = 4, .point_count = 4, .closed = true, .convex = false },
    };
    iface.push_clip_path(iface.ctx, .even_odd, .{ 4, 4, 42, 34 }, &clip_paths, &clip_points);
    queueRect(&iface, 0, 0, 46, 38);
    iface.pop_clip_path(iface.ctx);

    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);
    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expectEqual(@intFromEnum(sparse.FillRule.even_odd), packet.clips.items[0].fill_rule);
    try expectPacketMatchesCpu(backend, 2);
}

test "GPU packet alpha-fill tasks use compact task records" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 48, 32, 1);

    const points = roundedRectPoints(4.25, 4.25, 36.25, 24.25, 6.0);
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = points.len, .closed = true, .convex = false }};
    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ 4.25, 4.25, 36.25, 24.25 }, &paths, &points);

    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);
    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expect(packet.stats.alpha_fill_tasks > 0);
    try testing.expectEqual(@as(usize, 16), @sizeOf(sparse.gpu_fine.GpuFineTask));

    for (packet.tasks.items) |task| {
        if (!sparse.gpu_fine.taskIsAlpha(task)) continue;
        try testing.expectEqual(@as(u32, 0), sparse.gpu_fine.taskAlphaIndex(task));
    }
}

test "GPU packet keeps horizontal edge tiles in alpha-fill tasks" {
    const backend = try Backend.create(testing.allocator);
    defer backend.destroy();
    const iface = backend.interface();
    iface.viewport(iface.ctx, 32, 32, 1);

    queueRect(&iface, 4.25, 4.25, 20.25, 20.25);
    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);
    try testing.expect(backend.buildGpuFinePacket(&packet, null));

    try expectAlphaTaskAt(packet.tasks.items, 8, 4);
    try expectAlphaTaskAt(packet.tasks.items, 12, 4);
    try expectAlphaTaskAt(packet.tasks.items, 8, 20);
    try expectAlphaTaskAt(packet.tasks.items, 12, 20);
}

fn expectPacketMatchesCpu(backend: *Backend, tolerance: u8) !void {
    try testing.expect(backend.build());
    const width = pixelExtent(backend.viewport_width);
    const height = pixelExtent(backend.viewport_height);
    const cpu = try testing.allocator.dupe(u8, backend.surface.items);
    defer testing.allocator.free(cpu);

    var packet: sparse.gpu_fine.Packet = .{};
    defer packet.deinit(testing.allocator);
    try testing.expect(backend.buildGpuFinePacket(&packet, null));
    try testing.expect(packet.stats.supported);
    try testing.expect(packet.stats.tasks > 0);

    const gpu = try simulateGpuPacket(
        testing.allocator,
        width,
        height,
        &packet,
        backend.segments.items,
        backend.texture_views.items,
    );
    defer testing.allocator.free(gpu);

    try expectSurfaceApprox(cpu, gpu, tolerance);
}

fn simulateGpuPacket(
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    packet: *const sparse.gpu_fine.Packet,
    segments: []const sparse.Segment,
    textures: []const sparse.fine.Texture,
) ![]u8 {
    const surface = try gpa.alloc(u8, @as(usize, width) * @as(usize, height) * 4);
    @memset(surface, 0);

    for (packet.calls.items) |call| {
        const start: usize = @intCast(call.task_start);
        const count: usize = @intCast(call.task_count);
        for (packet.tasks.items[start..][0..count]) |task| {
            simulateTask(width, height, call, task, packet.clips.items, packet.clip_indices.items, segments, textures, surface);
        }
    }

    return surface;
}

fn simulateTask(
    width: u32,
    height: u32,
    call: sparse.gpu_fine.GpuCall,
    task: sparse.gpu_fine.GpuFineTask,
    clips: []const sparse.gpu_fine.GpuClip,
    clip_indices: []const sparse.gpu_fine.GpuClipIndex,
    segments: []const sparse.Segment,
    textures: []const sparse.fine.Texture,
    surface: []u8,
) void {
    var local_y: u32 = 0;
    while (local_y < sparse.strip.tile_size) : (local_y += 1) {
        var local_x: u32 = 0;
        while (local_x < sparse.strip.tile_size) : (local_x += 1) {
            const x = task.x + local_x;
            const y = task.y + local_y;
            if (x >= width or y >= height) continue;

            var alpha: f32 = 1;
            if (sparse.gpu_fine.taskIsAlpha(task)) {
                var area: f32 = 0;
                const start: usize = @intCast(call.segment_start);
                const count: usize = @intCast(call.segment_count);
                for (segments[start..][0..count]) |seg| {
                    area += segmentArea(@as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)), seg);
                }
                alpha = areaToAlpha(call.fill_rule, area);
            }
            if (alpha <= 0) continue;

            const sample_pos = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            if (call.params[0] > 0.5) {
                alpha *= scissorMask(call, sample_pos);
                if (alpha <= 0) continue;
            }
            alpha *= clipMask(call, clips, clip_indices, segments, x, y);
            if (alpha <= 0) continue;

            const paint = resolvePaint(call, textures, sample_pos);
            const src = ColorF{
                .r = paint.r * alpha,
                .g = paint.g * alpha,
                .b = paint.b * alpha,
                .a = paint.a * alpha,
            };
            overPixel(width, x, y, src, surface);
        }
    }
}

fn resolvePaint(call: sparse.gpu_fine.GpuCall, textures: []const sparse.fine.Texture, p: [2]f32) ColorF {
    const pt = matPoint(call.paint_mat0, call.paint_mat1, call.paint_mat2, p);
    const extent = [2]f32{ call.extent_radius_feather[0], call.extent_radius_feather[1] };
    if (call.params[1] > 0.5) {
        const texture = findTexture(textures, call.image_id) orelse return .{};
        const sample = sampleWrappedLinear(texture, pt[0], pt[1], extent);
        const alpha = sample.a * call.inner_color[3];
        return .{
            .r = sample.r * call.inner_color[0] * sample.a,
            .g = sample.g * call.inner_color[1] * sample.a,
            .b = sample.b * call.inner_color[2] * sample.a,
            .a = alpha,
        };
    }

    const feather = @max(call.extent_radius_feather[3], 0.0001);
    const d = std.math.clamp((sdroundrect(pt, extent, call.extent_radius_feather[2]) + feather * 0.5) / feather, 0, 1);
    return mixColor(
        .{ .r = call.inner_color[0], .g = call.inner_color[1], .b = call.inner_color[2], .a = call.inner_color[3] },
        .{ .r = call.outer_color[0], .g = call.outer_color[1], .b = call.outer_color[2], .a = call.outer_color[3] },
        d,
    );
}

fn scissorMask(call: sparse.gpu_fine.GpuCall, p: [2]f32) f32 {
    const sc_pt = matPoint(call.scissor_mat0, call.scissor_mat1, call.scissor_mat2, p);
    var sx = @abs(sc_pt[0]) - call.scissor_extent_scale[0];
    var sy = @abs(sc_pt[1]) - call.scissor_extent_scale[1];
    sx = 0.5 - sx * call.scissor_extent_scale[2];
    sy = 0.5 - sy * call.scissor_extent_scale[3];
    return std.math.clamp(sx, 0, 1) * std.math.clamp(sy, 0, 1);
}

fn clipMask(call: sparse.gpu_fine.GpuCall, clips: []const sparse.gpu_fine.GpuClip, clip_indices: []const sparse.gpu_fine.GpuClipIndex, segments: []const sparse.Segment, x: u32, y: u32) f32 {
    var mask: f32 = 1;
    const start: usize = @intCast(call.clip_start);
    const count: usize = @intCast(call.clip_count);
    for (clip_indices[start..][0..count]) |clip_index| {
        if (clip_index.value >= clips.len) return 0;
        const clip = clips[clip_index.value];
        if (clip.segment_count == 0) return 0;
        var area: f32 = 0;
        const segment_start: usize = @intCast(clip.segment_start);
        const segment_count: usize = @intCast(clip.segment_count);
        for (segments[segment_start..][0..segment_count]) |seg| {
            area += segmentArea(@as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y)), seg);
        }
        mask *= areaToAlpha(clip.fill_rule, area);
        if (mask <= 0) return 0;
    }
    return mask;
}

fn matPoint(c0: [4]f32, c1: [4]f32, c2: [4]f32, p: [2]f32) [2]f32 {
    return .{
        c0[0] * p[0] + c1[0] * p[1] + c2[0],
        c0[1] * p[0] + c1[1] * p[1] + c2[1],
    };
}

fn segmentArea(px: f32, py: f32, seg: sparse.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return 0;

    const y0 = @max(@min(seg.y0, seg.y1), py);
    const y1 = @min(@max(seg.y0, seg.y1), py + 1);
    if (y0 >= y1) return 0;

    const slope = (seg.x1 - seg.x0) / dy;
    const intercept = seg.x0 - slope * seg.y0 - px;
    const sign: f32 = if (dy > 0) 1 else -1;
    return sign * integrateClampedLinear(slope, intercept, y0, y1);
}

fn integrateClampedLinear(slope: f32, intercept: f32, y0: f32, y1: f32) f32 {
    if (slope == 0) return (y1 - y0) * std.math.clamp(intercept, 0, 1);

    var stops = [_]f32{ y0, y1, 0, 0 };
    var count: usize = 2;
    addStop(&stops, &count, (0 - intercept) / slope, y0, y1);
    addStop(&stops, &count, (1 - intercept) / slope, y0, y1);
    std.mem.sort(f32, stops[0..count], {}, lessThanF32);

    var area: f32 = 0;
    var i: usize = 0;
    while (i + 1 < count) : (i += 1) {
        const a = stops[i];
        const b = stops[i + 1];
        if (a == b) continue;

        const mid = (a + b) * 0.5;
        const mid_value = slope * mid + intercept;
        if (mid_value <= 0) continue;
        if (mid_value >= 1) {
            area += b - a;
            continue;
        }

        const av = slope * a + intercept;
        const bv = slope * b + intercept;
        area += (av + bv) * 0.5 * (b - a);
    }

    return std.math.clamp(area, 0, y1 - y0);
}

fn areaToAlpha(fill_rule: u32, area: f32) f32 {
    if (fill_rule == @intFromEnum(sparse.FillRule.nonzero)) {
        return @min(@abs(area), 1);
    }
    const folded = area - 2 * @floor(area * 0.5 + 0.5);
    return @min(@abs(folded), 1);
}

fn addStop(stops: *[4]f32, count: *usize, value: f32, min: f32, max: f32) void {
    if (value <= min or value >= max) return;
    stops[count.*] = value;
    count.* += 1;
}

fn lessThanF32(_: void, a: f32, b: f32) bool {
    return a < b;
}

fn sampleWrappedLinear(texture: *const sparse.fine.Texture, x: f32, y: f32, extent: [2]f32) ColorF {
    const tx = wrappedTexelCoord(x, extent[0], texture.width);
    const ty = wrappedTexelCoord(y, extent[1], texture.height);
    const c00 = texel(texture, tx.i0, ty.i0);
    const c10 = texel(texture, tx.i1, ty.i0);
    const c01 = texel(texture, tx.i0, ty.i1);
    const c11 = texel(texture, tx.i1, ty.i1);
    return mixColor(mixColor(c00, c10, tx.t), mixColor(c01, c11, tx.t), ty.t);
}

const WrappedTexelCoord = struct {
    i0: u32,
    i1: u32,
    t: f32,
};

fn wrappedTexelCoord(value: f32, extent: f32, size: u32) WrappedTexelCoord {
    if (size == 0) return .{ .i0 = 0, .i1 = 0, .t = 0 };
    const local_extent = if (@abs(extent) > 0.0001) @abs(extent) else @as(f32, @floatFromInt(size));
    const scaled = value / local_extent * @as(f32, @floatFromInt(size)) - 0.5;
    const base = @floor(scaled);
    const base_index: i32 = @intFromFloat(base);
    return .{
        .i0 = wrapIndex(base_index, size),
        .i1 = wrapIndex(base_index + 1, size),
        .t = scaled - base,
    };
}

fn wrapIndex(index: i32, size: u32) u32 {
    const size_i32: i32 = @intCast(size);
    return @intCast(@mod(index, size_i32));
}

fn texel(texture: *const sparse.fine.Texture, x: u32, y: u32) ColorF {
    if (texture.format != .rgba8 or texture.width == 0 or texture.height == 0) return .{};
    const index = (@as(usize, y) * @as(usize, texture.width) + x) * 4;
    if (index + 3 >= texture.pixels.len) return .{};
    return .{
        .r = u8ToNorm(texture.pixels[index + 0]),
        .g = u8ToNorm(texture.pixels[index + 1]),
        .b = u8ToNorm(texture.pixels[index + 2]),
        .a = u8ToNorm(texture.pixels[index + 3]),
    };
}

fn findTexture(textures: []const sparse.fine.Texture, id: u32) ?*const sparse.fine.Texture {
    for (textures) |*texture| {
        if (@intFromEnum(texture.id) == id) return texture;
    }
    return null;
}

fn overPixel(width: u32, x: u32, y: u32, src: ColorF, surface: []u8) void {
    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    const dst_r = u8ToNorm(surface[index + 0]);
    const dst_g = u8ToNorm(surface[index + 1]);
    const dst_b = u8ToNorm(surface[index + 2]);
    const dst_a = u8ToNorm(surface[index + 3]);
    const inv_a = 1 - src.a;
    surface[index + 0] = normToU8(src.r + dst_r * inv_a);
    surface[index + 1] = normToU8(src.g + dst_g * inv_a);
    surface[index + 2] = normToU8(src.b + dst_b * inv_a);
    surface[index + 3] = normToU8(src.a + dst_a * inv_a);
}

fn sdroundrect(pt: [2]f32, ext: [2]f32, rad: f32) f32 {
    const ext2 = [2]f32{ ext[0] - rad, ext[1] - rad };
    const dx = @abs(pt[0]) - ext2[0];
    const dy = @abs(pt[1]) - ext2[1];
    return @min(@max(dx, dy), 0) + @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0)) - rad;
}

fn mixColor(a: ColorF, b: ColorF, t: f32) ColorF {
    const inv = 1 - t;
    return .{
        .r = a.r * inv + b.r * t,
        .g = a.g * inv + b.g * t,
        .b = a.b * inv + b.b * t,
        .a = a.a * inv + b.a * t,
    };
}

fn expectSurfaceApprox(expected: []const u8, actual: []const u8, tolerance: u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    var max_delta: u8 = 0;
    var bad_index: usize = 0;
    for (expected, actual, 0..) |a, b, i| {
        const delta: u8 = @intCast(@abs(@as(i16, a) - @as(i16, b)));
        if (delta > max_delta) {
            max_delta = delta;
            bad_index = i;
        }
    }
    if (max_delta > tolerance) {
        std.debug.print("surface mismatch at byte {d}: expected {d}, actual {d}, delta {d}\n", .{
            bad_index,
            expected[bad_index],
            actual[bad_index],
            max_delta,
        });
        return error.SurfaceMismatch;
    }
}

fn expectAlphaTaskAt(tasks: []const sparse.gpu_fine.GpuFineTask, x: u32, y: u32) !void {
    for (tasks) |task| {
        if (sparse.gpu_fine.taskIsAlpha(task) and task.x == x and task.y == y) return;
    }
    std.debug.print("missing alpha-fill task at {d},{d}\n", .{ x, y });
    return error.MissingAlphaFillTask;
}

fn queueRect(iface: *const okys.render.interface.RenderInterface, x0: f32, y0: f32, x1: f32, y1: f32) void {
    const paint = color.solid(color.rgbaf(1, 1, 1, 1));
    const points = [_]Point{
        .{ .x = x0, .y = y0 },
        .{ .x = x1, .y = y0 },
        .{ .x = x1, .y = y1 },
        .{ .x = x0, .y = y1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};
    iface.fill(iface.ctx, &paint, &disabled_scissor, .{ x0, y0, x1, y1 }, &paths, &points);
}

fn pushClipRect(iface: *const okys.render.interface.RenderInterface, x0: f32, y0: f32, x1: f32, y1: f32, rule: okys.types.path.ClipRule) void {
    const points = [_]Point{
        .{ .x = x0, .y = y0 },
        .{ .x = x1, .y = y0 },
        .{ .x = x1, .y = y1 },
        .{ .x = x0, .y = y1 },
    };
    const paths = [_]PathRange{.{ .point_start = 0, .point_count = 4, .closed = true, .convex = true }};
    iface.push_clip_path(iface.ctx, rule, .{ x0, y0, x1, y1 }, &paths, &points);
}

fn roundedRectPoints(x0: f32, y0: f32, x1: f32, y1: f32, radius: f32) [16]Point {
    const k = 0.55228475;
    const ox = radius * k;
    const oy = radius * k;
    return .{
        .{ .x = x0 + radius, .y = y0 },
        .{ .x = x1 - radius, .y = y0 },
        .{ .x = x1 - radius + ox, .y = y0 },
        .{ .x = x1, .y = y0 + radius - oy },
        .{ .x = x1, .y = y0 + radius },
        .{ .x = x1, .y = y1 - radius },
        .{ .x = x1, .y = y1 - radius + oy },
        .{ .x = x1 - radius + ox, .y = y1 },
        .{ .x = x1 - radius, .y = y1 },
        .{ .x = x0 + radius, .y = y1 },
        .{ .x = x0 + radius - ox, .y = y1 },
        .{ .x = x0, .y = y1 - radius + oy },
        .{ .x = x0, .y = y1 - radius },
        .{ .x = x0, .y = y0 + radius },
        .{ .x = x0, .y = y0 + radius - oy },
        .{ .x = x0 + radius - ox, .y = y0 },
    };
}

fn pixelExtent(value: f32) u32 {
    if (value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn u8ToNorm(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn normToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    return @intFromFloat(@floor(clamped * 255 + 0.5));
}
