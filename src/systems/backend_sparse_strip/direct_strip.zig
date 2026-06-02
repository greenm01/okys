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
pub const strip_kind_alpha: u16 = 1 << 0;
pub const strip_kind_solid: u16 = 1 << 1;
pub const strip_flag_opaque: u16 = 1 << 2;

const invalid_paint_index = std.math.maxInt(u32);

pub const GpuStrip = extern struct {
    x: u16 = 0,
    y: u16 = 0,
    width_px: u16 = 0,
    flags: u16 = 0,
    alpha_start: u32 = 0,
    alpha_count: u32 = 0,
    paint_index: u32 = 0,
    call_index: u32 = 0,
    order: u32 = 0,
    _pad0: u32 = 0,
};

pub const SolidPaint = extern struct {
    rgba: [4]f32 = .{ 0, 0, 0, 0 },
};

pub const Profile = struct {
    build_ns: u64 = 0,
    alpha_ns: u64 = 0,
    strip_emit_ns: u64 = 0,
};

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
    compact_strip_instances: usize = 0,
    compact_alpha_strip_instances: usize = 0,
    compact_solid_span_instances: usize = 0,
    compact_alpha_bytes: usize = 0,
    compact_strip_instance_bytes: usize = 0,
    compact_upload_bytes: usize = 0,
    materialized_strip_instances: usize = 0,
    materialized_alpha_strip_instances: usize = 0,
    materialized_solid_span_instances: usize = 0,
    materialized_alpha_bytes: usize = 0,
    materialized_strip_instance_bytes: usize = 0,
    materialized_paint_bytes: usize = 0,
    materialized_upload_bytes: usize = 0,

    pub fn uploadSavingsVs(self: Stats, current_upload_bytes: usize) usize {
        if (current_upload_bytes <= self.upload_bytes) return 0;
        return current_upload_bytes - self.upload_bytes;
    }

    pub fn compactUploadSavingsVs(self: Stats, current_upload_bytes: usize) usize {
        if (current_upload_bytes <= self.compact_upload_bytes) return 0;
        return current_upload_bytes - self.compact_upload_bytes;
    }

    pub fn materializedUploadSavingsVs(self: Stats, current_upload_bytes: usize) usize {
        if (current_upload_bytes <= self.materialized_upload_bytes) return 0;
        return current_upload_bytes - self.materialized_upload_bytes;
    }
};

pub const Packet = struct {
    strips: std.ArrayList(GpuStrip) = .empty,
    paints: std.ArrayList(SolidPaint) = .empty,
    alphas: std.ArrayList(u8) = .empty,
    stats: Stats = .{},

    pub fn deinit(self: *Packet, gpa: std.mem.Allocator) void {
        self.strips.deinit(gpa);
        self.paints.deinit(gpa);
        self.alphas.deinit(gpa);
    }

    pub fn clearRetainingCapacity(self: *Packet) void {
        self.strips.clearRetainingCapacity();
        self.paints.clearRetainingCapacity();
        self.alphas.clearRetainingCapacity();
        self.stats = .{};
    }
};

pub fn build(
    gpa: std.mem.Allocator,
    calls: []const encode.EncodedCall,
    gpu_packet: *const gpu_fine.Packet,
    packet: *Packet,
    profile: ?*Profile,
) !bool {
    const build_start = profileStart(profile);
    packet.clearRetainingCapacity();
    packet.stats.calls = calls.len;

    try packet.strips.ensureTotalCapacity(gpa, gpu_packet.tasks.items.len);
    try packet.alphas.ensureTotalCapacity(gpa, gpu_packet.stats.alpha_fill_tasks * strip.tile_area);
    try packet.paints.ensureTotalCapacity(gpa, calls.len);

    var paint_indices = try gpa.alloc(u32, calls.len);
    defer gpa.free(paint_indices);
    @memset(paint_indices, invalid_paint_index);

    for (calls, 0..) |call, call_index| {
        if (eligibleCall(call, &packet.stats)) {
            packet.stats.eligible_calls += 1;
            paint_indices[call_index] = @intCast(packet.paints.items.len);
            packet.paints.appendAssumeCapacity(solidPaint(call));
        } else {
            packet.stats.fallback_calls += 1;
        }
    }
    packet.stats.supported = packet.stats.fallback_calls == 0;

    var run: MaterializedRun = .{};
    for (gpu_packet.tasks.items) |task| {
        const call_index: usize = @intCast(task.call_index);
        if (call_index >= calls.len or paint_indices[call_index] == invalid_paint_index) {
            try run.flush(gpa, packet, profile);
            continue;
        }

        const coord = gpu_fine.taskCoord(task);
        if (gpu_fine.taskIsAlpha(task)) {
            const alpha_start = packet.alphas.items.len;
            const alpha_profile_start = profileStart(profile);
            try appendAlphaTile(gpa, gpu_packet, task, coord, &packet.alphas);
            if (profile) |p| p.alpha_ns += elapsedSince(alpha_profile_start);
            packet.stats.alpha_strip_instances += 1;
            packet.stats.alpha_bytes += strip.tile_area;
            try run.append(gpa, packet, profile, .{
                .kind = .alpha,
                .x = coord.x,
                .y = coord.y,
                .width_tiles = 1,
                .alpha_start = @intCast(alpha_start),
                .alpha_count = strip.tile_area,
                .paint_index = paint_indices[call_index],
                .call_index = task.call_index,
            });
        } else {
            const tile_count = gpu_fine.taskFillTileCount(task);
            packet.stats.solid_span_instances += 1;
            packet.stats.solid_span_tiles += tile_count;
            packet.stats.max_solid_span_tiles = @max(packet.stats.max_solid_span_tiles, tile_count);
            try run.append(gpa, packet, profile, .{
                .kind = .solid,
                .x = coord.x,
                .y = coord.y,
                .width_tiles = tile_count,
                .alpha_start = 0,
                .alpha_count = 0,
                .paint_index = paint_indices[call_index],
                .call_index = task.call_index,
            });
        }
    }
    try run.flush(gpa, packet, profile);

    packet.stats.strip_instances = packet.stats.alpha_strip_instances + packet.stats.solid_span_instances;
    packet.stats.strip_instance_bytes = packet.stats.strip_instances * gpu_strip_size;
    packet.stats.paint_bytes = packet.stats.eligible_calls * solid_paint_size;
    packet.stats.upload_bytes = packet.stats.alpha_bytes + packet.stats.strip_instance_bytes + packet.stats.paint_bytes;
    packet.stats.compact_strip_instances = packet.stats.compact_alpha_strip_instances + packet.stats.compact_solid_span_instances;
    packet.stats.compact_alpha_bytes = packet.stats.alpha_bytes;
    packet.stats.compact_strip_instance_bytes = packet.stats.compact_strip_instances * gpu_strip_size;
    packet.stats.compact_upload_bytes = packet.stats.compact_alpha_bytes + packet.stats.compact_strip_instance_bytes + packet.stats.paint_bytes;
    packet.stats.materialized_strip_instances = packet.strips.items.len;
    packet.stats.materialized_alpha_strip_instances = packet.stats.compact_alpha_strip_instances;
    packet.stats.materialized_solid_span_instances = packet.stats.compact_solid_span_instances;
    packet.stats.materialized_alpha_bytes = packet.alphas.items.len;
    packet.stats.materialized_strip_instance_bytes = packet.strips.items.len * @sizeOf(GpuStrip);
    packet.stats.materialized_paint_bytes = packet.paints.items.len * @sizeOf(SolidPaint);
    packet.stats.materialized_upload_bytes =
        packet.stats.materialized_alpha_bytes +
        packet.stats.materialized_strip_instance_bytes +
        packet.stats.materialized_paint_bytes;
    if (profile) |p| p.build_ns += elapsedSince(build_start);
    return packet.stats.supported;
}

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

    var compact_run: CompactRun = .{};
    for (packet.tasks.items) |task| {
        const call_index: usize = @intCast(task.call_index);
        if (call_index >= calls.len or !eligibleCallFast(calls[call_index])) {
            compact_run.flush(&stats);
            continue;
        }

        const kind = task.segment_count_kind;
        const coord = gpu_fine.taskCoord(task);
        if ((kind & gpu_fine.task_kind_alpha_mask) != 0) {
            stats.alpha_strip_instances += 1;
            stats.alpha_bytes += strip.tile_area;
            compact_run.append(&stats, .alpha, task.call_index, coord.x, coord.y, 1);
        } else if ((kind & gpu_fine.task_kind_fill_span_mask) != 0) {
            const tile_count = @as(usize, @intCast(@max(kind & gpu_fine.task_payload_mask, 1)));
            stats.solid_span_instances += 1;
            stats.solid_span_tiles += tile_count;
            stats.max_solid_span_tiles = @max(stats.max_solid_span_tiles, tile_count);
            compact_run.append(&stats, .solid, task.call_index, coord.x, coord.y, @intCast(tile_count));
        } else {
            stats.solid_span_instances += 1;
            stats.solid_span_tiles += 1;
            stats.max_solid_span_tiles = @max(stats.max_solid_span_tiles, 1);
            compact_run.append(&stats, .solid, task.call_index, coord.x, coord.y, 1);
        }
    }
    compact_run.flush(&stats);

    stats.strip_instances = stats.alpha_strip_instances + stats.solid_span_instances;
    stats.strip_instance_bytes = stats.strip_instances * gpu_strip_size;
    stats.upload_bytes = stats.alpha_bytes + stats.strip_instance_bytes + stats.paint_bytes;
    stats.compact_strip_instances = stats.compact_alpha_strip_instances + stats.compact_solid_span_instances;
    stats.compact_alpha_bytes = stats.alpha_bytes;
    stats.compact_strip_instance_bytes = stats.compact_strip_instances * gpu_strip_size;
    stats.compact_upload_bytes = stats.compact_alpha_bytes + stats.compact_strip_instance_bytes + stats.paint_bytes;
    return stats;
}

const MaterializedAppend = struct {
    kind: CompactKind,
    x: u32,
    y: u32,
    width_tiles: u32,
    alpha_start: u32,
    alpha_count: u32,
    paint_index: u32,
    call_index: u32,
};

const MaterializedRun = struct {
    active: bool = false,
    kind: CompactKind = .alpha,
    x: u32 = 0,
    y: u32 = 0,
    end_x: u32 = 0,
    alpha_start: u32 = 0,
    alpha_count: u32 = 0,
    paint_index: u32 = 0,
    call_index: u32 = 0,

    fn append(
        self: *MaterializedRun,
        gpa: std.mem.Allocator,
        packet: *Packet,
        profile: ?*Profile,
        next: MaterializedAppend,
    ) !void {
        const width_px = next.width_tiles * @as(u32, strip.tile_size);
        const end_x = next.x + width_px;
        if (self.active and
            self.kind == next.kind and
            self.call_index == next.call_index and
            self.paint_index == next.paint_index and
            self.y == next.y and
            self.end_x == next.x and
            (next.kind == .solid or self.alpha_start + self.alpha_count == next.alpha_start))
        {
            self.end_x = end_x;
            self.alpha_count += next.alpha_count;
            return;
        }

        try self.flush(gpa, packet, profile);
        self.active = true;
        self.kind = next.kind;
        self.x = next.x;
        self.y = next.y;
        self.end_x = end_x;
        self.alpha_start = next.alpha_start;
        self.alpha_count = next.alpha_count;
        self.paint_index = next.paint_index;
        self.call_index = next.call_index;
    }

    fn flush(self: *MaterializedRun, gpa: std.mem.Allocator, packet: *Packet, profile: ?*Profile) !void {
        if (!self.active) return;
        const strip_profile_start = profileStart(profile);
        const flags: u16 = switch (self.kind) {
            .alpha => strip_kind_alpha,
            .solid => strip_kind_solid,
        };
        try packet.strips.append(gpa, .{
            .x = @intCast(self.x),
            .y = @intCast(self.y),
            .width_px = @intCast(self.end_x - self.x),
            .flags = flags,
            .alpha_start = self.alpha_start,
            .alpha_count = self.alpha_count,
            .paint_index = self.paint_index,
            .call_index = self.call_index,
            .order = @intCast(packet.strips.items.len),
        });
        switch (self.kind) {
            .alpha => packet.stats.compact_alpha_strip_instances += 1,
            .solid => packet.stats.compact_solid_span_instances += 1,
        }
        if (profile) |p| p.strip_emit_ns += elapsedSince(strip_profile_start);
        self.active = false;
    }
};

fn appendAlphaTile(
    gpa: std.mem.Allocator,
    packet: *const gpu_fine.Packet,
    task: gpu_fine.GpuFineTask,
    coord: gpu_fine.TaskCoord,
    alphas: *std.ArrayList(u8),
) !void {
    const fill_rule = fillRuleFromGpu(packet.calls.items[task.call_index].fill_rule);
    const start: usize = @intCast(task.segment_start);
    const count: usize = @intCast(gpu_fine.taskSegmentCount(task));
    const indices = packet.segment_indices.items[start..][0..count];

    try alphas.ensureUnusedCapacity(gpa, strip.tile_area);
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            alphas.appendAssumeCapacity(pixelCoverage(
                fill_rule,
                @intCast(coord.x + local_x),
                @intCast(coord.y + local_y),
                packet.segments.items,
                indices,
            ));
        }
    }
}

fn pixelCoverage(
    fill_rule: strip.FillRule,
    x: u16,
    y: u16,
    segments: []const gpu_fine.GpuSegment,
    indices: []const gpu_fine.GpuSegmentIndex,
) u8 {
    var area: f32 = 0;
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    for (indices) |segment_index| {
        if (segment_index.value >= segments.len) continue;
        area += segmentArea(px, py, segments[segment_index.value]);
    }
    return areaToAlpha(fill_rule, area);
}

fn segmentArea(px: f32, py: f32, seg: gpu_fine.GpuSegment) f32 {
    if (seg.sign == 0) return 0;
    const y0 = @max(seg.min_y, py);
    const y1 = @min(seg.max_y, py + 1);
    if (y0 >= y1) return 0;

    const intercept = seg.intercept - px;
    const x0 = seg.slope * y0 + intercept;
    const x1 = seg.slope * y1 + intercept;
    if (x0 <= 0 and x1 <= 0) return 0;
    if (x0 >= 1 and x1 >= 1) return seg.sign * (y1 - y0);
    return seg.sign * integrateClampedLinear(seg.slope, intercept, y0, y1);
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

fn addStop(stops: *[4]f32, count: *usize, value: f32, min: f32, max: f32) void {
    if (value <= min or value >= max) return;
    stops[count.*] = value;
    count.* += 1;
}

fn lessThanF32(_: void, a: f32, b: f32) bool {
    return a < b;
}

fn areaToAlpha(fill_rule: strip.FillRule, area: f32) u8 {
    const coverage = switch (fill_rule) {
        .nonzero => @min(@abs(area), 1),
        .even_odd => blk: {
            const folded = area - 2 * @floor(area * 0.5 + 0.5);
            break :blk @min(@abs(folded), 1);
        },
    };
    return normToU8(coverage);
}

fn normToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    return @intFromFloat(clamped * 255 + 0.5);
}

fn fillRuleFromGpu(fill_rule: u32) strip.FillRule {
    return if (fill_rule == @intFromEnum(strip.FillRule.even_odd)) .even_odd else .nonzero;
}

fn solidPaint(call: encode.EncodedCall) SolidPaint {
    const c = call.paint.inner_color;
    return .{
        .rgba = .{
            c.r * c.a,
            c.g * c.a,
            c.b * c.a,
            c.a,
        },
    };
}

fn profileStart(profile: ?*Profile) u64 {
    return if (profile != null) nowNs() else 0;
}

fn elapsedSince(start: u64) u64 {
    if (start == 0) return 0;
    return nowNs() - start;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const CompactKind = enum {
    alpha,
    solid,
};

const CompactRun = struct {
    active: bool = false,
    kind: CompactKind = .alpha,
    call_index: u32 = 0,
    y: u32 = 0,
    end_x: u32 = 0,

    fn append(self: *CompactRun, stats: *Stats, kind: CompactKind, call_index: u32, x: u32, y: u32, width_tiles: u32) void {
        const width_px = @as(u32, strip.tile_size) * width_tiles;
        const end_x = x + width_px;
        if (self.active and
            self.kind == kind and
            self.call_index == call_index and
            self.y == y and
            self.end_x == x)
        {
            self.end_x = end_x;
            return;
        }

        self.flush(stats);
        self.active = true;
        self.kind = kind;
        self.call_index = call_index;
        self.y = y;
        self.end_x = end_x;
    }

    fn flush(self: *CompactRun, stats: *Stats) void {
        if (!self.active) return;
        switch (self.kind) {
            .alpha => stats.compact_alpha_strip_instances += 1,
            .solid => stats.compact_solid_span_instances += 1,
        }
        self.active = false;
    }
};

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
    try std.testing.expectEqual(@as(usize, 2), stats.compact_strip_instances);
    try std.testing.expectEqual(stats.upload_bytes, stats.compact_upload_bytes);
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

test "direct strip compact estimator coalesces adjacent alpha tasks" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(0, 0, 0, .{}));
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(strip.tile_size, 0, 0, .{}));

    const stats = estimate(&calls, &packet);
    try std.testing.expectEqual(@as(usize, 2), stats.alpha_strip_instances);
    try std.testing.expectEqual(@as(usize, 1), stats.compact_alpha_strip_instances);
    try std.testing.expectEqual(@as(usize, 1), stats.compact_strip_instances);
    try std.testing.expectEqual(@as(usize, strip.tile_area * 2), stats.compact_alpha_bytes);
}

test "direct strip compact estimator splits nonadjacent alpha tasks" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(0, 0, 0, .{}));
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(strip.tile_size * 2, 0, 0, .{}));

    const stats = estimate(&calls, &packet);
    try std.testing.expectEqual(@as(usize, 2), stats.alpha_strip_instances);
    try std.testing.expectEqual(@as(usize, 2), stats.compact_alpha_strip_instances);
}

test "direct strip compact estimator coalesces adjacent fill spans past current task cap" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(0, 0, 0, 2));
    try packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(strip.tile_size * 2, 0, 0, 2));

    const stats = estimate(&calls, &packet);
    try std.testing.expectEqual(@as(usize, 2), stats.solid_span_instances);
    try std.testing.expectEqual(@as(usize, 1), stats.compact_solid_span_instances);
    try std.testing.expectEqual(@as(usize, 4), stats.solid_span_tiles);
}

test "direct strip compact estimator flushes on call row and kind changes" {
    const calls = [_]encode.EncodedCall{ eligibleTestCall(), eligibleTestCall() };
    var packet: gpu_fine.Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(0, 0, 0, .{}));
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(strip.tile_size, 0, 1, .{}));
    try packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(strip.tile_size * 2, strip.tile_size, 1, .{}));
    try packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(strip.tile_size * 3, strip.tile_size, 1, 1));

    const stats = estimate(&calls, &packet);
    try std.testing.expectEqual(@as(usize, 4), stats.strip_instances);
    try std.testing.expectEqual(@as(usize, 4), stats.compact_strip_instances);
}

test "direct strip materialized packet writes alpha bytes" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var gpu_packet: gpu_fine.Packet = .{};
    defer gpu_packet.deinit(std.testing.allocator);
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.segments.append(std.testing.allocator, .{
        .slope = 0,
        .intercept = 0.5,
        .min_y = 0,
        .max_y = strip.tile_size,
        .sign = 1,
    });
    try gpu_packet.segment_indices.append(std.testing.allocator, .{ .value = 0 });
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(0, 0, 0, .{ .start = 0, .count = 1 }));
    gpu_packet.stats.alpha_fill_tasks = 1;

    var packet: Packet = .{};
    defer packet.deinit(std.testing.allocator);
    var profile: Profile = .{};
    try std.testing.expect(try build(std.testing.allocator, &calls, &gpu_packet, &packet, &profile));

    try std.testing.expectEqual(@as(usize, 1), packet.strips.items.len);
    try std.testing.expectEqual(@as(usize, strip.tile_area), packet.alphas.items.len);
    try std.testing.expectEqual(@as(u8, 128), packet.alphas.items[0]);
    try std.testing.expectEqual(@as(u16, strip_kind_alpha), packet.strips.items[0].flags);
    try std.testing.expectEqual(@as(u32, strip.tile_area), packet.strips.items[0].alpha_count);
    try std.testing.expectEqual(@as(usize, strip.tile_area + gpu_strip_size + solid_paint_size), packet.stats.materialized_upload_bytes);
}

test "direct strip materialized packet coalesces adjacent alpha tasks" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var gpu_packet: gpu_fine.Packet = .{};
    defer gpu_packet.deinit(std.testing.allocator);
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.segments.append(std.testing.allocator, .{
        .slope = 0,
        .intercept = 0.5,
        .min_y = 0,
        .max_y = strip.tile_size,
        .sign = 1,
    });
    try gpu_packet.segments.append(std.testing.allocator, .{
        .slope = 0,
        .intercept = @as(f32, @floatFromInt(strip.tile_size)) + 0.5,
        .min_y = 0,
        .max_y = strip.tile_size,
        .sign = 1,
    });
    try gpu_packet.segment_indices.append(std.testing.allocator, .{ .value = 0 });
    try gpu_packet.segment_indices.append(std.testing.allocator, .{ .value = 1 });
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(0, 0, 0, .{ .start = 0, .count = 1 }));
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.alphaTask(strip.tile_size, 0, 0, .{ .start = 1, .count = 1 }));
    gpu_packet.stats.alpha_fill_tasks = 2;

    var packet: Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try std.testing.expect(try build(std.testing.allocator, &calls, &gpu_packet, &packet, null));

    try std.testing.expectEqual(@as(usize, 1), packet.strips.items.len);
    try std.testing.expectEqual(@as(u16, strip.tile_size * 2), packet.strips.items[0].width_px);
    try std.testing.expectEqual(@as(u32, strip.tile_area * 2), packet.strips.items[0].alpha_count);
    try std.testing.expectEqual(@as(usize, strip.tile_area * 2), packet.stats.materialized_alpha_bytes);
}

test "direct strip materialized packet coalesces adjacent fill spans" {
    const calls = [_]encode.EncodedCall{eligibleTestCall()};
    var gpu_packet: gpu_fine.Packet = .{};
    defer gpu_packet.deinit(std.testing.allocator);
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(0, 0, 0, 2));
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(strip.tile_size * 2, 0, 0, 2));

    var packet: Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try std.testing.expect(try build(std.testing.allocator, &calls, &gpu_packet, &packet, null));

    try std.testing.expectEqual(@as(usize, 1), packet.strips.items.len);
    try std.testing.expectEqual(@as(u16, strip.tile_size * 4), packet.strips.items[0].width_px);
    try std.testing.expectEqual(@as(u16, strip_kind_solid), packet.strips.items[0].flags);
    try std.testing.expectEqual(@as(usize, 1), packet.stats.materialized_solid_span_instances);
}

test "direct strip materialized packet flushes before ineligible task" {
    const calls = [_]encode.EncodedCall{ eligibleTestCall(), .{
        .kind = .triangles,
        .paint = color.solid(color.rgbaf(1, 0, 0, 1)),
        .scissor = .{ .xform = .{ 1, 0, 0, 1, 0, 0 }, .extent = .{ -1, -1 } },
    }, eligibleTestCall() };
    var gpu_packet: gpu_fine.Packet = .{};
    defer gpu_packet.deinit(std.testing.allocator);
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.calls.append(std.testing.allocator, .{ .fill_rule = @intFromEnum(strip.FillRule.nonzero) });
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(0, 0, 0, 1));
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(strip.tile_size, 0, 1, 1));
    try gpu_packet.tasks.append(std.testing.allocator, gpu_fine.fillSpanTask(strip.tile_size, 0, 2, 1));

    var packet: Packet = .{};
    defer packet.deinit(std.testing.allocator);
    try std.testing.expect(!try build(std.testing.allocator, &calls, &gpu_packet, &packet, null));

    try std.testing.expectEqual(@as(usize, 2), packet.strips.items.len);
    try std.testing.expectEqual(@as(u16, strip.tile_size), packet.strips.items[0].width_px);
    try std.testing.expectEqual(@as(u16, strip.tile_size), packet.strips.items[1].width_px);
    try std.testing.expectEqual(@as(usize, 1), packet.stats.fallback_calls);
}

fn eligibleTestCall() encode.EncodedCall {
    return .{
        .kind = .fill,
        .paint = color.solid(color.rgbaf(1, 0, 0, 1)),
        .scissor = .{ .xform = .{ 1, 0, 0, 1, 0, 0 }, .extent = .{ -1, -1 } },
    };
}

comptime {
    std.debug.assert(@sizeOf(GpuStrip) == gpu_strip_size);
    std.debug.assert(@offsetOf(GpuStrip, "x") == 0);
    std.debug.assert(@offsetOf(GpuStrip, "alpha_start") == 8);
    std.debug.assert(@offsetOf(GpuStrip, "paint_index") == 16);
    std.debug.assert(@sizeOf(SolidPaint) == solid_paint_size);
}
