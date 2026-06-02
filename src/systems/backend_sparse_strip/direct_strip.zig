//! Estimate a Vello Hybrid-style direct strip packet from the current sparse
//! fine packet. This is diagnostic scaffolding for the raster-pipeline fast
//! lane; it does not render or change fallback behavior.

const std = @import("std");
const color = @import("../../types/color.zig");
const encode = @import("encode.zig");
const gpu_fine = @import("gpu_fine.zig");
const strip = @import("strip.zig");

pub const gpu_strip_size: usize = 32;
pub const solid_paint_size: usize = 16;

pub const Stats = struct {
    supported: bool = false,
    calls: usize = 0,
    eligible_calls: usize = 0,
    fallback_calls: usize = 0,
    fallback_images: usize = 0,
    fallback_scissors: usize = 0,
    fallback_clips: usize = 0,
    fallback_gradients: usize = 0,
    fallback_triangles: usize = 0,
    strip_instances: usize = 0,
    alpha_strip_instances: usize = 0,
    solid_span_instances: usize = 0,
    solid_span_tiles: usize = 0,
    max_solid_span_tiles: usize = 0,
    alpha_bytes: usize = 0,
    strip_instance_bytes: usize = 0,
    paint_bytes: usize = 0,
    upload_bytes: usize = 0,

    pub fn uploadSavingsVs(self: Stats, current_upload_bytes: usize) usize {
        if (current_upload_bytes <= self.upload_bytes) return 0;
        return current_upload_bytes - self.upload_bytes;
    }
};

pub fn estimate(calls: []const encode.EncodedCall, packet: *const gpu_fine.Packet) Stats {
    var stats: Stats = .{ .calls = calls.len };

    for (calls) |call| {
        if (eligibleCall(call, &stats)) {
            stats.eligible_calls += 1;
        } else {
            stats.fallback_calls += 1;
        }
    }
    stats.supported = stats.fallback_calls == 0;
    stats.paint_bytes = stats.eligible_calls * solid_paint_size;

    for (packet.tasks.items) |task| {
        const call_index: usize = @intCast(task.call_index);
        if (call_index >= calls.len or !eligibleCallFast(calls[call_index])) continue;

        const kind = task.segment_count_kind;
        if ((kind & gpu_fine.task_kind_alpha_mask) != 0) {
            stats.alpha_strip_instances += 1;
            stats.alpha_bytes += strip.tile_area;
        } else if ((kind & gpu_fine.task_kind_fill_span_mask) != 0) {
            const tile_count = @as(usize, @intCast(@max(kind & gpu_fine.task_payload_mask, 1)));
            stats.solid_span_instances += 1;
            stats.solid_span_tiles += tile_count;
            stats.max_solid_span_tiles = @max(stats.max_solid_span_tiles, tile_count);
        } else {
            stats.solid_span_instances += 1;
            stats.solid_span_tiles += 1;
            stats.max_solid_span_tiles = @max(stats.max_solid_span_tiles, 1);
        }
    }

    stats.strip_instances = stats.alpha_strip_instances + stats.solid_span_instances;
    stats.strip_instance_bytes = stats.strip_instances * gpu_strip_size;
    stats.upload_bytes = stats.alpha_bytes + stats.strip_instance_bytes + stats.paint_bytes;
    return stats;
}

fn eligibleCall(call: encode.EncodedCall, stats: *Stats) bool {
    var ok = true;
    if (call.paint.image != 0) {
        stats.fallback_images += 1;
        ok = false;
    }
    if (!scissorDisabled(&call.scissor)) {
        stats.fallback_scissors += 1;
        ok = false;
    }
    if (call.clips.count != 0) {
        stats.fallback_clips += 1;
        ok = false;
    }
    if (!sameColor(call.paint.inner_color, call.paint.outer_color)) {
        stats.fallback_gradients += 1;
        ok = false;
    }
    if (call.kind == .triangles) {
        stats.fallback_triangles += 1;
        ok = false;
    }
    return ok;
}

fn eligibleCallFast(call: encode.EncodedCall) bool {
    return call.paint.image == 0 and
        scissorDisabled(&call.scissor) and
        call.clips.count == 0 and
        sameColor(call.paint.inner_color, call.paint.outer_color) and
        call.kind != .triangles;
}

fn sameColor(a: color.Color, b: color.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn scissorDisabled(scissor: *const color.Scissor) bool {
    return scissor.extent[0] < 0 or scissor.extent[1] < 0;
}

test "direct strip estimator counts eligible alpha and solid span tasks" {
    const paint = color.solid(color.rgbaf(1, 0, 0, 1));
    const no_scissor: color.Scissor = .{ .xform = .{ 1, 0, 0, 1, 0, 0 }, .extent = .{ -1, -1 } };
    const calls = [_]encode.EncodedCall{
        .{
            .kind = .fill,
            .paint = paint,
            .scissor = no_scissor,
        },
    };
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try packet.tasks.append(std.testing.allocator, .{
        .call_index = 0,
        .segment_count_kind = gpu_fine.task_kind_alpha_mask | 3,
    });
    try packet.tasks.append(std.testing.allocator, .{
        .call_index = 0,
        .segment_count_kind = gpu_fine.task_kind_fill_span_mask | 4,
    });

    const stats = estimate(&calls, &packet);
    try std.testing.expect(stats.supported);
    try std.testing.expectEqual(@as(usize, 1), stats.eligible_calls);
    try std.testing.expectEqual(@as(usize, 2), stats.strip_instances);
    try std.testing.expectEqual(@as(usize, 1), stats.alpha_strip_instances);
    try std.testing.expectEqual(@as(usize, strip.tile_area), stats.alpha_bytes);
    try std.testing.expectEqual(@as(usize, 4), stats.solid_span_tiles);
    try std.testing.expectEqual(@as(usize, strip.tile_area + gpu_strip_size * 2 + solid_paint_size), stats.upload_bytes);
}

test "direct strip estimator rejects image scissor clip gradient and triangle calls" {
    var gradient = color.solid(color.rgbaf(1, 0, 0, 1));
    gradient.outer_color = color.rgbaf(0, 0, 1, 1);
    var image = color.solid(color.rgbaf(1, 1, 1, 1));
    image.image = 7;
    const no_scissor: color.Scissor = .{ .xform = .{ 1, 0, 0, 1, 0, 0 }, .extent = .{ -1, -1 } };
    const scissor: color.Scissor = .{ .xform = .{ 1, 0, 0, 1, 0, 0 }, .extent = .{ 8, 8 } };
    const calls = [_]encode.EncodedCall{
        .{ .kind = .fill, .paint = image, .scissor = no_scissor },
        .{ .kind = .fill, .paint = gradient, .scissor = no_scissor },
        .{ .kind = .stroke, .paint = color.solid(color.rgbaf(0, 1, 0, 1)), .scissor = scissor },
        .{ .kind = .triangles, .paint = color.solid(color.rgbaf(0, 0, 1, 1)), .scissor = no_scissor },
        .{ .kind = .fill, .paint = color.solid(color.rgbaf(1, 1, 0, 1)), .scissor = no_scissor, .clips = .{ .start = 0, .count = 1 } },
    };
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);

    const stats = estimate(&calls, &packet);
    try std.testing.expect(!stats.supported);
    try std.testing.expectEqual(@as(usize, 0), stats.eligible_calls);
    try std.testing.expectEqual(@as(usize, 5), stats.fallback_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_images);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_gradients);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_scissors);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_triangles);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_clips);
}
