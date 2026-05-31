//! GPU-facing sparse fine packet construction. This keeps the CPU frontend,
//! flatten, bin, and coarse stages authoritative while encoding Fill and
//! AlphaFill work as flat per-call task ranges for compute dispatch.

const std = @import("std");
const color = @import("../../types/color.zig");
const encode = @import("encode.zig");
const strip = @import("strip.zig");
const xforms = @import("../transform.zig");

pub const task_fill: u32 = 0;
pub const task_alpha_fill: u32 = 1;
pub const call_flag_opaque: u32 = 1 << 0;

pub const FallbackReason = enum(u8) {
    none,
    unsupported_paint,
    unsupported_scissor,
};

pub const SolidPaint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const GpuCall = extern struct {
    paint_mat0: [4]f32 = .{ 0, 0, 0, 0 },
    paint_mat1: [4]f32 = .{ 0, 0, 0, 0 },
    paint_mat2: [4]f32 = .{ 0, 0, 0, 0 },
    scissor_mat0: [4]f32 = .{ 0, 0, 0, 0 },
    scissor_mat1: [4]f32 = .{ 0, 0, 0, 0 },
    scissor_mat2: [4]f32 = .{ 0, 0, 0, 0 },
    inner_color: [4]f32 = .{ 0, 0, 0, 0 },
    outer_color: [4]f32 = .{ 0, 0, 0, 0 },
    scissor_extent_scale: [4]f32 = .{ 1, 1, 1, 1 },
    extent_radius_feather: [4]f32 = .{ 0, 0, 0, 1 },
    params: [4]f32 = .{ 0, 0, 0, 0 },
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    segment_start: u32 = 0,
    segment_count: u32 = 0,
    task_start: u32 = 0,
    task_count: u32 = 0,
    flags: u32 = 0,
    fill_rule: u32 = 0,
    image_id: u32 = 0,
    _pad1: u32 = 0,
};

pub const GpuFineTask = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    call_index: u32 = 0,
    kind: u32 = 0,
    segment_start: u32 = 0,
    segment_count: u32 = 0,
    strip_index: u32 = 0,
    _pad0: u32 = 0,
};

pub const GpuStripIndex = extern struct {
    value: u32 = 0,
};

pub const PacketStats = struct {
    supported: bool = false,
    fallback_reason: FallbackReason = .none,
    calls: usize = 0,
    tasks: usize = 0,
    fill_tasks: usize = 0,
    alpha_fill_tasks: usize = 0,
    dispatches: usize = 0,
    workgroups: usize = 0,
    upload_bytes: usize = 0,
};

pub const Packet = struct {
    calls: std.ArrayList(GpuCall) = .empty,
    tasks: std.ArrayList(GpuFineTask) = .empty,
    strip_indices: std.ArrayList(GpuStripIndex) = .empty,
    stats: PacketStats = .{},

    pub fn deinit(self: *Packet, gpa: std.mem.Allocator) void {
        self.calls.deinit(gpa);
        self.tasks.deinit(gpa);
        self.strip_indices.deinit(gpa);
    }

    pub fn clearRetainingCapacity(self: *Packet) void {
        self.calls.clearRetainingCapacity();
        self.tasks.clearRetainingCapacity();
        self.strip_indices.clearRetainingCapacity();
        self.stats = .{};
    }
};

const BoundarySet = std.AutoHashMap(u64, void);

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    strip_segment_indices: []const u32,
    strips: []const strip.Strip,
    packet: *Packet,
) !bool {
    packet.clearRetainingCapacity();
    packet.stats.calls = calls.len;
    try packet.calls.ensureTotalCapacity(gpa, calls.len);
    try packet.strip_indices.ensureTotalCapacity(gpa, strip_segment_indices.len);
    for (strip_segment_indices) |segment_index| {
        packet.strip_indices.appendAssumeCapacity(.{ .value = segment_index });
    }

    for (calls) |call| {
        packet.calls.appendAssumeCapacity(packCall(fill_rule, call, segments));
    }

    const width = pixelExtent(viewport_width);
    const height = pixelExtent(viewport_height);
    if (width == 0 or height == 0) {
        packet.stats.supported = true;
        return true;
    }

    var boundary_tiles = BoundarySet.init(gpa);
    defer boundary_tiles.deinit();
    try boundary_tiles.ensureTotalCapacity(@intCast(strips.len));
    for (strips) |s| {
        try boundary_tiles.put(boundaryKey(s.call_index, strip.tileCoord(@floatFromInt(s.x)), strip.tileCoord(@floatFromInt(s.y))), {});
    }

    for (calls, 0..) |call, call_index_usize| {
        const call_index: u32 = @intCast(call_index_usize);
        const task_start = packet.tasks.items.len;
        const call_fill_rule = fillRuleForCall(fill_rule, call.kind);

        for (strips, 0..) |s, strip_index| {
            if (s.call_index != call_index) continue;
            try packet.tasks.append(gpa, .{
                .x = s.x,
                .y = s.y,
                .call_index = call_index,
                .kind = task_alpha_fill,
                .segment_start = s.segment_indices.start,
                .segment_count = s.segment_indices.count,
                .strip_index = @intCast(strip_index),
            });
            packet.stats.alpha_fill_tasks += 1;
        }

        try appendFillTasks(
            gpa,
            call,
            call_index,
            call_fill_rule,
            segments,
            &boundary_tiles,
            width,
            height,
            &packet.tasks,
            &packet.stats,
        );

        const task_count = packet.tasks.items.len - task_start;
        packet.calls.items[call_index_usize].task_start = @intCast(task_start);
        packet.calls.items[call_index_usize].task_count = @intCast(task_count);
        if (task_count > 0) packet.stats.dispatches += 1;
    }

    packet.stats.supported = true;
    packet.stats.tasks = packet.tasks.items.len;
    packet.stats.workgroups = packet.tasks.items.len;
    packet.stats.upload_bytes =
        @sizeOf(GpuCall) * packet.calls.items.len +
        @sizeOf(GpuFineTask) * packet.tasks.items.len +
        @sizeOf(GpuStripIndex) * packet.strip_indices.items.len +
        @sizeOf(encode.Segment) * segments.len +
        @sizeOf(strip.Strip) * strips.len;
    return true;
}

fn appendFillTasks(
    gpa: std.mem.Allocator,
    call: encode.EncodedCall,
    call_index: u32,
    fill_rule: strip.FillRule,
    segments: []const encode.Segment,
    boundary_tiles: *const BoundarySet,
    width: u32,
    height: u32,
    tasks: *std.ArrayList(GpuFineTask),
    stats: *PacketStats,
) !void {
    const bounds = callBounds(call, segments);
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3]) return;

    const max_tile_x = strip.tileCoord(@as(f32, @floatFromInt(width)) - 0.001);
    const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
    var tile_y = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
    const tile_y_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
    const tile_size_f: f32 = @floatFromInt(strip.tile_size);

    while (tile_y <= tile_y_end) : (tile_y += 1) {
        var tile_x = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
        const tile_x_end = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);
        while (tile_x <= tile_x_end) : (tile_x += 1) {
            if (boundary_tiles.contains(boundaryKey(call_index, tile_x, tile_y))) continue;
            const sample_x = @as(f32, @floatFromInt(tile_x)) * tile_size_f + 0.5;
            const sample_y = @as(f32, @floatFromInt(tile_y)) * tile_size_f + 0.5;
            if (coverageAtForCall(fill_rule, sample_x, sample_y, call.segments, segments) == 0) continue;
            try tasks.append(gpa, .{
                .x = @intCast(strip.tileOrigin(@intCast(tile_x))),
                .y = @intCast(strip.tileOrigin(@intCast(tile_y))),
                .call_index = call_index,
                .kind = task_fill,
            });
            stats.fill_tasks += 1;
        }
    }
}

pub fn solidPaint(call: encode.EncodedCall) ?SolidPaint {
    if (call.paint.image != 0 or !scissorDisabled(&call.scissor)) return null;
    if (!sameColor(call.paint.inner_color, call.paint.outer_color)) return null;
    const c = call.paint.inner_color;
    return .{
        .r = c.r * c.a,
        .g = c.g * c.a,
        .b = c.b * c.a,
        .a = c.a,
    };
}

pub fn hasImageCalls(packet: *const Packet) bool {
    for (packet.calls.items) |call| {
        if (call.image_id != 0) return true;
    }
    return false;
}

fn packCall(default_rule: strip.FillRule, call: encode.EncodedCall, segments: []const encode.Segment) GpuCall {
    const paint_matrix = matrixColumns(inverseOrIdentity(&call.paint.xform));
    const scissor_enabled = !scissorDisabled(&call.scissor);
    const scissor_matrix = if (scissor_enabled)
        matrixColumns(xforms.inverse(&call.scissor.xform) orelse .{ 0, 0, 0, 0, 0, 0 })
    else
        [_][4]f32{ zeroColumn(), zeroColumn(), zeroColumn() };
    const scissor_scale = if (scissor_enabled) .{
        @sqrt(call.scissor.xform[0] * call.scissor.xform[0] + call.scissor.xform[2] * call.scissor.xform[2]),
        @sqrt(call.scissor.xform[1] * call.scissor.xform[1] + call.scissor.xform[3] * call.scissor.xform[3]),
    } else [2]f32{ 1, 1 };
    const inner = premul(call.paint.inner_color);
    const outer = premul(call.paint.outer_color);
    const image_id: u32 = if (call.paint.image > 0) @intCast(call.paint.image) else 0;

    return .{
        .paint_mat0 = paint_matrix[0],
        .paint_mat1 = paint_matrix[1],
        .paint_mat2 = paint_matrix[2],
        .scissor_mat0 = scissor_matrix[0],
        .scissor_mat1 = scissor_matrix[1],
        .scissor_mat2 = scissor_matrix[2],
        .inner_color = colorVec(inner),
        .outer_color = colorVec(outer),
        .scissor_extent_scale = .{
            call.scissor.extent[0],
            call.scissor.extent[1],
            scissor_scale[0],
            scissor_scale[1],
        },
        .extent_radius_feather = .{
            call.paint.extent[0],
            call.paint.extent[1],
            call.paint.radius,
            call.paint.feather,
        },
        .params = .{
            if (scissor_enabled) 1 else 0,
            if (image_id != 0) 1 else 0,
            if (image_id != 0) @floatFromInt(image_id) else 0,
            0,
        },
        .bounds = callBounds(call, segments),
        .segment_start = call.segments.start,
        .segment_count = call.segments.count,
        .flags = if (isOpaque(call)) call_flag_opaque else 0,
        .fill_rule = @intFromEnum(fillRuleForCall(default_rule, call.kind)),
        .image_id = image_id,
    };
}

pub fn fillRuleForCall(default_rule: strip.FillRule, kind: strip.CallKind) strip.FillRule {
    return switch (kind) {
        .fill => default_rule,
        .stroke, .triangles => .nonzero,
    };
}

pub fn callBounds(call: encode.EncodedCall, segments: []const encode.Segment) [4]f32 {
    if (call.bounds[0] < call.bounds[2] and call.bounds[1] < call.bounds[3]) {
        return call.bounds;
    }

    var bounds = [4]f32{ 1e6, 1e6, -1e6, -1e6 };
    const start: usize = @intCast(call.segments.start);
    const count: usize = @intCast(call.segments.count);
    for (segments[start..][0..count]) |seg| {
        bounds[0] = @min(bounds[0], @min(seg.x0, seg.x1));
        bounds[1] = @min(bounds[1], @min(seg.y0, seg.y1));
        bounds[2] = @max(bounds[2], @max(seg.x0, seg.x1));
        bounds[3] = @max(bounds[3], @max(seg.y0, seg.y1));
    }
    return bounds;
}

fn coverageAtForCall(
    fill_rule: strip.FillRule,
    px: f32,
    py: f32,
    range: strip.Range,
    segments: []const encode.Segment,
) u8 {
    var winding: i32 = 0;
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (segments[start..][0..count]) |seg| {
        winding += crossingWinding(px, py, seg);
    }
    return if (filled(fill_rule, winding)) 255 else 0;
}

fn crossingWinding(px: f32, py: f32, seg: encode.Segment) i32 {
    if (seg.y0 <= py and seg.y1 > py) {
        const x = intersectX(py, seg);
        if (x > px) return 1;
    } else if (seg.y1 <= py and seg.y0 > py) {
        const x = intersectX(py, seg);
        if (x > px) return -1;
    }
    return 0;
}

fn intersectX(py: f32, seg: encode.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return seg.x0;
    const t = (py - seg.y0) / dy;
    return seg.x0 + t * (seg.x1 - seg.x0);
}

fn filled(fill_rule: strip.FillRule, winding: i32) bool {
    return switch (fill_rule) {
        .nonzero => winding != 0,
        .even_odd => @mod(winding, 2) != 0,
    };
}

fn boundaryKey(call_index: u32, tile_x: i32, tile_y: i32) u64 {
    return (@as(u64, call_index) << 42) |
        (@as(u64, @intCast(tile_y)) << 21) |
        @as(u64, @intCast(tile_x));
}

fn pixelExtent(value: f32) u32 {
    if (value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn sameColor(a: color.Color, b: color.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn scissorDisabled(scissor: *const color.Scissor) bool {
    return scissor.extent[0] < 0 or scissor.extent[1] < 0;
}

fn isOpaque(call: encode.EncodedCall) bool {
    return call.paint.image == 0 and scissorDisabled(&call.scissor) and call.paint.inner_color.a >= 1 and call.paint.outer_color.a >= 1;
}

fn premul(c: color.Color) color.Color {
    return .{
        .r = c.r * c.a,
        .g = c.g * c.a,
        .b = c.b * c.a,
        .a = c.a,
    };
}

fn inverseOrIdentity(t: *const color.Transform) color.Transform {
    return xforms.inverse(t) orelse xforms.identity();
}

fn matrixColumns(t: color.Transform) [3][4]f32 {
    return .{
        .{ t[0], t[1], 0, 0 },
        .{ t[2], t[3], 0, 0 },
        .{ t[4], t[5], 1, 0 },
    };
}

fn zeroColumn() [4]f32 {
    return .{ 0, 0, 0, 0 };
}

fn colorVec(c: color.Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}

comptime {
    std.debug.assert(@sizeOf(GpuCall) == 224);
    std.debug.assert(@offsetOf(GpuCall, "paint_mat0") == 0);
    std.debug.assert(@offsetOf(GpuCall, "scissor_mat0") == 48);
    std.debug.assert(@offsetOf(GpuCall, "inner_color") == 96);
    std.debug.assert(@offsetOf(GpuCall, "bounds") == 176);
    std.debug.assert(@offsetOf(GpuCall, "segment_start") == 192);
    std.debug.assert(@offsetOf(GpuCall, "task_start") == 200);
    std.debug.assert(@sizeOf(GpuFineTask) == 32);
    std.debug.assert(@offsetOf(GpuFineTask, "x") == 0);
    std.debug.assert(@offsetOf(GpuFineTask, "call_index") == 8);
    std.debug.assert(@offsetOf(GpuFineTask, "segment_start") == 16);
    std.debug.assert(@sizeOf(GpuStripIndex) == 4);
}
