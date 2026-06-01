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
pub const task_kind_alpha_mask: u32 = 0x80000000;
pub const call_flag_opaque: u32 = 1 << 0;

const SparseConfig = struct {
    const tile_size: u16 = strip.tile_size;
    const tile_area: u32 = strip.tile_area;
    const crossing_insertion_sort_threshold: usize = 32;

    comptime {
        std.debug.assert(tile_size == 4);
        std.debug.assert(tile_area == tile_size * tile_size);
        std.debug.assert((tile_size & (tile_size - 1)) == 0);
    }
};

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
    clip_start: u32 = 0,
    clip_count: u32 = 0,
    _pad1: u32 = 0,
    _pad2: [8]u8 = .{0} ** 8,
};

pub const GpuClip = extern struct {
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    segment_start: u32 = 0,
    segment_count: u32 = 0,
    fill_rule: u32 = 0,
    _pad0: u32 = 0,
};

pub const GpuClipIndex = extern struct {
    value: u32 = 0,
};

pub const GpuSegment = extern struct {
    slope: f32 = 0,
    intercept: f32 = 0,
    min_y: f32 = 0,
    max_y: f32 = 0,
    sign: f32 = 0,
    _pad0: f32 = 0,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const GpuFineTask = extern struct {
    xy: u32 = 0,
    call_index: u32 = 0,
    segment_start: u32 = 0,
    segment_count_kind: u32 = 0,
};

pub const GpuSegmentIndex = extern struct {
    value: u32 = 0,
};

pub const TaskCoord = struct {
    x: u32 = 0,
    y: u32 = 0,
};

pub const PacketStats = struct {
    supported: bool = false,
    fallback_reason: FallbackReason = .none,
    calls: usize = 0,
    clips: usize = 0,
    clip_indices: usize = 0,
    tasks: usize = 0,
    fill_tasks: usize = 0,
    alpha_fill_tasks: usize = 0,
    dispatches: usize = 0,
    workgroups: usize = 0,
    upload_bytes: usize = 0,
};

pub const Profile = struct {
    pack_records_ns: u64 = 0,
    strip_group_ns: u64 = 0,
    boundary_mark_ns: u64 = 0,
    fill_task_ns: u64 = 0,
    crossing_collect_ns: u64 = 0,
    crossing_sort_ns: u64 = 0,
    fill_emit_ns: u64 = 0,
    crossing_rows: usize = 0,
    crossing_items: usize = 0,
    crossing_sort_rows: usize = 0,
    max_crossings_per_row: usize = 0,
    boundary_checks: usize = 0,
    boundary_hits: usize = 0,
    fill_candidates: usize = 0,
    alpha_segment_refs: usize = 0,
    max_alpha_segments_per_task: usize = 0,
};

pub const Packet = struct {
    calls: std.ArrayList(GpuCall) = .empty,
    clips: std.ArrayList(GpuClip) = .empty,
    clip_indices: std.ArrayList(GpuClipIndex) = .empty,
    segments: std.ArrayList(GpuSegment) = .empty,
    tasks: std.ArrayList(GpuFineTask) = .empty,
    segment_indices: std.ArrayList(GpuSegmentIndex) = .empty,
    scratch: Scratch = .{},
    stats: PacketStats = .{},

    pub fn deinit(self: *Packet, gpa: std.mem.Allocator) void {
        self.calls.deinit(gpa);
        self.clips.deinit(gpa);
        self.clip_indices.deinit(gpa);
        self.segments.deinit(gpa);
        self.tasks.deinit(gpa);
        self.segment_indices.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    pub fn clearRetainingCapacity(self: *Packet) void {
        self.calls.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.clip_indices.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.tasks.clearRetainingCapacity();
        self.segment_indices.clearRetainingCapacity();
        self.scratch.clearBoundaryMask();
        self.scratch.crossings.clearRetainingCapacity();
        self.stats = .{};
    }
};

const Scratch = struct {
    strips_by_call_starts: []usize = &.{},
    strips_by_call_indices: []usize = &.{},
    strips_by_call_cursors: []usize = &.{},
    crossings: std.ArrayList(Crossing) = .empty,
    boundary_words: []u64 = &.{},
    boundary_touched_words: std.ArrayList(usize) = .empty,

    fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        freeSlice(gpa, self.strips_by_call_starts);
        freeSlice(gpa, self.strips_by_call_indices);
        freeSlice(gpa, self.strips_by_call_cursors);
        self.crossings.deinit(gpa);
        freeSlice(gpa, self.boundary_words);
        self.boundary_touched_words.deinit(gpa);
        self.* = .{};
    }

    fn clearBoundaryMask(self: *Scratch) void {
        for (self.boundary_touched_words.items) |word_index| {
            self.boundary_words[word_index] = 0;
        }
        self.boundary_touched_words.clearRetainingCapacity();
    }

    fn ensureBoundaryWords(self: *Scratch, gpa: std.mem.Allocator, word_count: usize) !void {
        if (self.boundary_words.len < word_count) {
            freeSlice(gpa, self.boundary_words);
            self.boundary_words = try gpa.alloc(u64, word_count);
            @memset(self.boundary_words, 0);
        }
    }
};

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    strip_segment_indices: []const u32,
    strips: []const strip.Strip,
    packet: *Packet,
    profile: ?*Profile,
) !bool {
    if (profile) |p| p.* = .{};
    packet.clearRetainingCapacity();
    packet.stats.calls = calls.len;
    packet.stats.clips = clips.len;
    packet.stats.clip_indices = call_clip_indices.len;
    try packet.calls.ensureTotalCapacity(gpa, calls.len);
    try packet.clips.ensureTotalCapacity(gpa, clips.len);
    try packet.clip_indices.ensureTotalCapacity(gpa, call_clip_indices.len);
    try packet.segments.ensureTotalCapacity(gpa, segments.len);
    _ = strip_segment_indices;

    const pack_start = profileStart(profile);
    for (clips) |clip| {
        packet.clips.appendAssumeCapacity(packClip(clip));
    }
    for (call_clip_indices) |clip_index| {
        packet.clip_indices.appendAssumeCapacity(.{ .value = clip_index });
    }
    for (segments) |seg| {
        packet.segments.appendAssumeCapacity(packSegment(seg));
    }
    for (calls) |call| {
        packet.calls.appendAssumeCapacity(packCall(fill_rule, call, segments));
    }
    if (profile) |p| p.pack_records_ns += elapsedSince(pack_start);

    const width = pixelExtent(viewport_width);
    const height = pixelExtent(viewport_height);
    if (width == 0 or height == 0) {
        packet.stats.supported = true;
        return true;
    }

    const width_tiles = tileCountForPixels(width);
    const height_tiles = tileCountForPixels(height);
    try packet.scratch.ensureBoundaryWords(gpa, wordCountForBits(width_tiles * height_tiles));

    const strip_group_start = profileStart(profile);
    const strips_by_call = try StripsByCall.init(gpa, &packet.scratch, calls.len, strips);
    if (profile) |p| p.strip_group_ns += elapsedSince(strip_group_start);

    for (calls, 0..) |call, call_index_usize| {
        const call_index: u32 = @intCast(call_index_usize);
        const task_start = packet.tasks.items.len;
        const call_fill_rule = fillRuleForCall(fill_rule, call.kind);
        const call_strips = strips_by_call.indicesForCall(call_index_usize);

        const boundary_start = profileStart(profile);
        packet.scratch.clearBoundaryMask();
        try markBoundaryStrips(gpa, &packet.scratch, width_tiles, height_tiles, strips, call_strips);
        if (profile) |p| p.boundary_mark_ns += elapsedSince(boundary_start);

        var current_alpha_y: ?u16 = null;
        var current_alpha_segments: strip.Range = .{};
        for (call_strips) |strip_index| {
            const s = strips[strip_index];
            if (current_alpha_y == null or current_alpha_y.? != s.y) {
                current_alpha_y = s.y;
                current_alpha_segments = try appendAlphaTaskSegmentIndices(
                    gpa,
                    &packet.segment_indices,
                    call.segments,
                    segments,
                    s.y,
                );
            }
            try packet.tasks.append(gpa, alphaTask(s.x, s.y, call_index, current_alpha_segments));
            packet.stats.alpha_fill_tasks += 1;
            if (profile) |p| {
                p.alpha_segment_refs += current_alpha_segments.count;
                p.max_alpha_segments_per_task = @max(p.max_alpha_segments_per_task, current_alpha_segments.count);
            }
        }

        const fill_task_start = profileStart(profile);
        try appendFillTasks(
            gpa,
            call,
            call_index,
            call_fill_rule,
            packet.calls.items[call_index_usize].bounds,
            segments,
            &packet.scratch,
            width_tiles,
            width,
            height,
            &packet.tasks,
            &packet.stats,
            profile,
        );
        if (profile) |p| p.fill_task_ns += elapsedSince(fill_task_start);

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
        @sizeOf(GpuClip) * packet.clips.items.len +
        @sizeOf(GpuClipIndex) * packet.clip_indices.items.len +
        @sizeOf(GpuSegment) * packet.segments.items.len +
        @sizeOf(GpuFineTask) * packet.tasks.items.len +
        @sizeOf(GpuSegmentIndex) * packet.segment_indices.items.len;
    packet.scratch.clearBoundaryMask();
    return true;
}

const StripsByCall = struct {
    starts: []usize = &.{},
    indices: []usize = &.{},

    fn init(gpa: std.mem.Allocator, scratch: *Scratch, call_count: usize, strips: []const strip.Strip) !StripsByCall {
        try ensureSliceCapacity(usize, gpa, &scratch.strips_by_call_starts, call_count + 1);
        try ensureSliceCapacity(usize, gpa, &scratch.strips_by_call_indices, strips.len);
        try ensureSliceCapacity(usize, gpa, &scratch.strips_by_call_cursors, call_count);

        const starts = scratch.strips_by_call_starts[0 .. call_count + 1];
        const indices = scratch.strips_by_call_indices[0..strips.len];
        const cursors = scratch.strips_by_call_cursors[0..call_count];

        @memset(starts, 0);

        for (strips) |s| {
            const call_index: usize = @intCast(s.call_index);
            if (call_index < call_count) starts[call_index + 1] += 1;
        }

        var i: usize = 1;
        while (i < starts.len) : (i += 1) {
            starts[i] += starts[i - 1];
        }

        @memcpy(cursors, starts[0..call_count]);

        for (strips, 0..) |s, strip_index| {
            const call_index: usize = @intCast(s.call_index);
            if (call_index >= call_count) continue;
            const out_index = cursors[call_index];
            indices[out_index] = strip_index;
            cursors[call_index] += 1;
        }

        return .{
            .starts = starts,
            .indices = indices,
        };
    }

    fn indicesForCall(self: *const StripsByCall, call_index: usize) []const usize {
        return self.indices[self.starts[call_index]..self.starts[call_index + 1]];
    }
};

const Crossing = struct {
    x: f32,
    winding: i32,
};

pub fn fillTaskAux() u32 {
    return task_fill;
}

pub fn fillTask(x: u16, y: u16, call_index: u32) GpuFineTask {
    return .{
        .xy = packTaskXY(x, y),
        .call_index = call_index,
        .segment_start = 0,
        .segment_count_kind = fillTaskAux(),
    };
}

pub fn alphaTask(x: u16, y: u16, call_index: u32, segment_indices: strip.Range) GpuFineTask {
    return .{
        .xy = packTaskXY(x, y),
        .call_index = call_index,
        .segment_start = segment_indices.start,
        .segment_count_kind = task_kind_alpha_mask | segment_indices.count,
    };
}

pub fn taskIsAlpha(task: GpuFineTask) bool {
    return (task.segment_count_kind & task_kind_alpha_mask) != 0;
}

pub fn taskSegmentCount(task: GpuFineTask) u32 {
    return task.segment_count_kind & ~task_kind_alpha_mask;
}

pub fn taskCoord(task: GpuFineTask) TaskCoord {
    return .{
        .x = task.xy & 0xffff,
        .y = task.xy >> 16,
    };
}

fn packTaskXY(x: u16, y: u16) u32 {
    return @as(u32, x) | (@as(u32, y) << 16);
}

fn appendAlphaTaskSegmentIndices(
    gpa: std.mem.Allocator,
    segment_indices: *std.ArrayList(GpuSegmentIndex),
    call_segments: strip.Range,
    segments: []const encode.Segment,
    tile_y: u16,
) !strip.Range {
    const start = segment_indices.items.len;
    const tile_top: f32 = @floatFromInt(tile_y);
    const tile_bottom = tile_top + @as(f32, @floatFromInt(strip.tile_size));
    const segment_start: usize = @intCast(call_segments.start);
    const segment_count: usize = @intCast(call_segments.count);
    try segment_indices.ensureUnusedCapacity(gpa, segment_count);
    for (segments[segment_start..][0..segment_count], 0..) |seg, offset| {
        if (!segmentOverlapsY(seg, tile_top, tile_bottom)) continue;
        segment_indices.appendAssumeCapacity(.{ .value = @intCast(segment_start + offset) });
    }
    return .{
        .start = @intCast(start),
        .count = @intCast(segment_indices.items.len - start),
    };
}

fn segmentOverlapsY(seg: encode.Segment, tile_top: f32, tile_bottom: f32) bool {
    const min_y = @min(seg.y0, seg.y1);
    const max_y = @max(seg.y0, seg.y1);
    return max_y > min_y and max_y > tile_top and min_y < tile_bottom;
}

fn appendFillTasks(
    gpa: std.mem.Allocator,
    call: encode.EncodedCall,
    call_index: u32,
    fill_rule: strip.FillRule,
    bounds: [4]f32,
    segments: []const encode.Segment,
    scratch: *Scratch,
    width_tiles: usize,
    width: u32,
    height: u32,
    tasks: *std.ArrayList(GpuFineTask),
    stats: *PacketStats,
    profile: ?*Profile,
) !void {
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3]) return;

    const max_tile_x = strip.tileCoord(@as(f32, @floatFromInt(width)) - 0.001);
    const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
    var tile_y = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
    const tile_y_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
    const tile_size_f: f32 = @floatFromInt(strip.tile_size);

    while (tile_y <= tile_y_end) : (tile_y += 1) {
        const sample_y = @as(f32, @floatFromInt(tile_y)) * tile_size_f + 0.5;
        const crossing_result = try collectCrossings(gpa, call.segments, segments, sample_y, &scratch.crossings);
        if (profile) |p| {
            p.crossing_rows += 1;
            p.crossing_items += scratch.crossings.items.len;
            p.max_crossings_per_row = @max(p.max_crossings_per_row, scratch.crossings.items.len);
        }
        if (scratch.crossings.items.len == 0) continue;

        const sorted = sortCrossingsIfNeeded(scratch.crossings.items, crossing_result.sorted);
        if (profile) |p| {
            if (sorted) {
                p.crossing_sort_rows += 1;
            }
        }

        var winding = crossing_result.winding;
        var tile_x = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
        const tile_x_end = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);
        var crossing_index: usize = 0;
        while (tile_x <= tile_x_end) : (tile_x += 1) {
            const sample_x = @as(f32, @floatFromInt(tile_x)) * tile_size_f + 0.5;
            while (crossing_index < scratch.crossings.items.len and scratch.crossings.items[crossing_index].x <= sample_x) : (crossing_index += 1) {
                winding -= scratch.crossings.items[crossing_index].winding;
            }
            if (!filled(fill_rule, winding)) continue;
            if (profile) |p| p.fill_candidates += 1;
            if (profile) |p| p.boundary_checks += 1;
            if (containsBoundaryTile(scratch, width_tiles, tile_x, tile_y)) {
                if (profile) |p| p.boundary_hits += 1;
                continue;
            }
            try tasks.append(gpa, fillTask(
                @intCast(strip.tileOrigin(@intCast(tile_x))),
                @intCast(strip.tileOrigin(@intCast(tile_y))),
                call_index,
            ));
            stats.fill_tasks += 1;
        }
    }
}

const CrossingResult = struct {
    winding: i32 = 0,
    sorted: bool = true,
};

fn collectCrossings(
    gpa: std.mem.Allocator,
    range: strip.Range,
    segments: []const encode.Segment,
    py: f32,
    crossings: *std.ArrayList(Crossing),
) !CrossingResult {
    crossings.clearRetainingCapacity();
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    try crossings.ensureTotalCapacity(gpa, count);

    var winding: i32 = 0;
    var sorted = true;
    var have_last = false;
    var last_x: f32 = 0;
    for (segments[start..][0..count]) |seg| {
        const delta = crossingDelta(py, seg) orelse continue;
        const x = intersectX(py, seg);
        if (have_last and x < last_x) sorted = false;
        crossings.appendAssumeCapacity(.{
            .x = x,
            .winding = delta,
        });
        have_last = true;
        last_x = x;
        winding += delta;
    }
    return .{ .winding = winding, .sorted = sorted };
}

fn sortCrossingsIfNeeded(crossings: []Crossing, already_sorted: bool) bool {
    if (already_sorted or crossings.len <= 1) return false;
    if (crossings.len <= SparseConfig.crossing_insertion_sort_threshold) {
        insertionSortCrossings(crossings);
    } else {
        std.mem.sort(Crossing, crossings, {}, crossingLessThan);
    }
    return true;
}

fn insertionSortCrossings(crossings: []Crossing) void {
    var i: usize = 1;
    while (i < crossings.len) : (i += 1) {
        const value = crossings[i];
        var j = i;
        while (j > 0 and value.x < crossings[j - 1].x) : (j -= 1) {
            crossings[j] = crossings[j - 1];
        }
        crossings[j] = value;
    }
}

fn crossingDelta(py: f32, seg: encode.Segment) ?i32 {
    if (seg.y0 <= py and seg.y1 > py) return 1;
    if (seg.y1 <= py and seg.y0 > py) return -1;
    return null;
}

fn crossingLessThan(_: void, a: Crossing, b: Crossing) bool {
    return a.x < b.x;
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
        .clip_start = call.clips.start,
        .clip_count = call.clips.count,
    };
}

fn packClip(clip: encode.ClipRecord) GpuClip {
    return .{
        .bounds = clip.bounds,
        .segment_start = clip.segments.start,
        .segment_count = clip.segments.count,
        .fill_rule = @intFromEnum(clip.rule),
    };
}

fn packSegment(seg: encode.Segment) GpuSegment {
    const min_y = @min(seg.y0, seg.y1);
    const max_y = @max(seg.y0, seg.y1);
    const dy = seg.y1 - seg.y0;
    if (dy == 0) {
        return .{
            .min_y = min_y,
            .max_y = max_y,
        };
    }
    const slope = (seg.x1 - seg.x0) / dy;
    return .{
        .slope = slope,
        .intercept = seg.x0 - slope * seg.y0,
        .min_y = min_y,
        .max_y = max_y,
        .sign = if (dy > 0) 1 else -1,
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

fn markBoundaryStrips(
    gpa: std.mem.Allocator,
    scratch: *Scratch,
    width_tiles: usize,
    height_tiles: usize,
    strips: []const strip.Strip,
    strip_indices: []const usize,
) !void {
    try scratch.boundary_touched_words.ensureUnusedCapacity(gpa, strip_indices.len);
    for (strip_indices) |strip_index| {
        const s = strips[strip_index];
        const tile_x: usize = @intCast(s.x / SparseConfig.tile_size);
        const tile_y: usize = @intCast(s.y / SparseConfig.tile_size);
        if (tile_x >= width_tiles or tile_y >= height_tiles) continue;
        const bit_index = tile_y * width_tiles + tile_x;
        const word_index = bit_index >> 6;
        const mask = @as(u64, 1) << @intCast(bit_index & 63);
        if (scratch.boundary_words[word_index] == 0) {
            scratch.boundary_touched_words.appendAssumeCapacity(word_index);
        }
        scratch.boundary_words[word_index] |= mask;
    }
}

fn containsBoundaryTile(scratch: *const Scratch, width_tiles: usize, tile_x: i32, tile_y: i32) bool {
    const x: usize = @intCast(tile_x);
    const y: usize = @intCast(tile_y);
    const bit_index = y * width_tiles + x;
    const word = scratch.boundary_words[bit_index >> 6];
    const mask = @as(u64, 1) << @intCast(bit_index & 63);
    return (word & mask) != 0;
}

fn tileCountForPixels(pixels: u32) usize {
    return (@as(usize, pixels) + SparseConfig.tile_size - 1) / SparseConfig.tile_size;
}

fn wordCountForBits(bit_count: usize) usize {
    return (bit_count + 63) / 64;
}

fn ensureSliceCapacity(comptime T: type, gpa: std.mem.Allocator, slice: *[]T, len: usize) !void {
    if (slice.*.len >= len) return;
    freeSlice(gpa, slice.*);
    slice.* = try gpa.alloc(T, len);
}

fn freeSlice(gpa: std.mem.Allocator, slice: anytype) void {
    if (slice.len != 0) gpa.free(slice);
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
    std.debug.assert(@sizeOf(GpuCall) == 240);
    std.debug.assert(@offsetOf(GpuCall, "paint_mat0") == 0);
    std.debug.assert(@offsetOf(GpuCall, "scissor_mat0") == 48);
    std.debug.assert(@offsetOf(GpuCall, "inner_color") == 96);
    std.debug.assert(@offsetOf(GpuCall, "bounds") == 176);
    std.debug.assert(@offsetOf(GpuCall, "segment_start") == 192);
    std.debug.assert(@offsetOf(GpuCall, "task_start") == 200);
    std.debug.assert(@offsetOf(GpuCall, "clip_start") == 220);
    std.debug.assert(@sizeOf(GpuClip) == 32);
    std.debug.assert(@offsetOf(GpuClip, "bounds") == 0);
    std.debug.assert(@offsetOf(GpuClip, "segment_start") == 16);
    std.debug.assert(@sizeOf(GpuClipIndex) == 4);
    std.debug.assert(@sizeOf(GpuSegment) == 32);
    std.debug.assert(@offsetOf(GpuSegment, "slope") == 0);
    std.debug.assert(@offsetOf(GpuSegment, "sign") == 16);
    std.debug.assert(@sizeOf(GpuSegmentIndex) == 4);
    std.debug.assert(@sizeOf(GpuFineTask) == 16);
    std.debug.assert(@offsetOf(GpuFineTask, "xy") == 0);
    std.debug.assert(@offsetOf(GpuFineTask, "call_index") == 4);
    std.debug.assert(@offsetOf(GpuFineTask, "segment_start") == 8);
    std.debug.assert(@offsetOf(GpuFineTask, "segment_count_kind") == 12);
}
