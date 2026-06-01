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
pub const task_kind_fill_span_mask: u32 = 0x40000000;
pub const task_payload_mask: u32 = 0x3fffffff;
pub const call_flag_opaque: u32 = 1 << 0;

const SparseConfig = struct {
    const tile_size: u16 = strip.tile_size;
    const tile_area: u32 = strip.tile_area;
    const crossing_insertion_sort_threshold: usize = 32;
    const max_fill_span_tiles: u32 = 2;

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
        self.stats = .{};
    }
};

const Scratch = struct {
    strips_by_call_starts: []usize = &.{},
    strips_by_call_indices: []usize = &.{},
    strips_by_call_cursors: []usize = &.{},
    row_segment_starts: []usize = &.{},
    row_segment_indices: []u32 = &.{},
    row_segment_cursors: []usize = &.{},
    row_crossing_starts: []usize = &.{},
    row_crossings: []Crossing = &.{},
    row_crossing_cursors: []usize = &.{},
    row_windings: []i32 = &.{},
    row_sorted: []bool = &.{},
    row_have_last_crossing: []bool = &.{},
    row_last_crossing_x: []f32 = &.{},
    boundary_words: []u64 = &.{},
    boundary_touched_words: std.ArrayList(usize) = .empty,

    fn deinit(self: *Scratch, gpa: std.mem.Allocator) void {
        freeSlice(gpa, self.strips_by_call_starts);
        freeSlice(gpa, self.strips_by_call_indices);
        freeSlice(gpa, self.strips_by_call_cursors);
        freeSlice(gpa, self.row_segment_starts);
        freeSlice(gpa, self.row_segment_indices);
        freeSlice(gpa, self.row_segment_cursors);
        freeSlice(gpa, self.row_crossing_starts);
        freeSlice(gpa, self.row_crossings);
        freeSlice(gpa, self.row_crossing_cursors);
        freeSlice(gpa, self.row_windings);
        freeSlice(gpa, self.row_sorted);
        freeSlice(gpa, self.row_have_last_crossing);
        freeSlice(gpa, self.row_last_crossing_x);
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
        const call_bounds = packet.calls.items[call_index_usize].bounds;
        try packet.tasks.ensureUnusedCapacity(gpa, call_strips.len + fillTaskCapacityForBounds(call_bounds, width, height));

        const boundary_start = profileStart(profile);
        packet.scratch.clearBoundaryMask();
        try markBoundaryStrips(gpa, &packet.scratch, width_tiles, height_tiles, strips, call_strips);
        if (profile) |p| p.boundary_mark_ns += elapsedSince(boundary_start);

        const row_prep_start = profileStart(profile);
        const active_rows = try ActiveSegmentRows.init(
            gpa,
            &packet.scratch,
            segments,
            call.segments,
            call_bounds,
            height,
        );
        if (profile) |p| p.crossing_collect_ns += elapsedSince(row_prep_start);

        var current_alpha_y: ?u16 = null;
        var current_alpha_segments: strip.Range = .{};
        for (call_strips) |strip_index| {
            const s = strips[strip_index];
            if (current_alpha_y == null or current_alpha_y.? != s.y) {
                current_alpha_y = s.y;
                current_alpha_segments = try appendAlphaTaskSegmentIndices(
                    gpa,
                    &packet.segment_indices,
                    active_rows.segmentIndicesForTileOrigin(s.y),
                );
            }
            packet.tasks.appendAssumeCapacity(alphaTask(s.x, s.y, call_index, current_alpha_segments));
            packet.stats.alpha_fill_tasks += 1;
            if (profile) |p| {
                p.alpha_segment_refs += current_alpha_segments.count;
                p.max_alpha_segments_per_task = @max(p.max_alpha_segments_per_task, current_alpha_segments.count);
            }
        }

        const fill_task_start = profileStart(profile);
        appendFillTasks(
            call_index,
            call_fill_rule,
            call_bounds,
            active_rows,
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

const ActiveSegmentRows = struct {
    row_base: i32 = 0,
    starts: []usize = &.{},
    indices: []u32 = &.{},
    crossing_starts: []usize = &.{},
    crossings: []Crossing = &.{},
    windings: []i32 = &.{},
    sorted: []bool = &.{},

    fn init(
        gpa: std.mem.Allocator,
        scratch: *Scratch,
        segments: []const encode.Segment,
        range: strip.Range,
        bounds: [4]f32,
        height: u32,
    ) !ActiveSegmentRows {
        if (range.count == 0 or height == 0 or bounds[1] >= bounds[3]) return .{};

        const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
        const row_base = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
        const row_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
        if (row_base > row_end) return .{};

        const row_count: usize = @intCast(row_end - row_base + 1);
        try ensureSliceCapacity(usize, gpa, &scratch.row_segment_starts, row_count + 1);
        try ensureSliceCapacity(usize, gpa, &scratch.row_segment_cursors, row_count);
        try ensureSliceCapacity(usize, gpa, &scratch.row_crossing_starts, row_count + 1);
        try ensureSliceCapacity(usize, gpa, &scratch.row_crossing_cursors, row_count);
        try ensureSliceCapacity(i32, gpa, &scratch.row_windings, row_count);
        try ensureSliceCapacity(bool, gpa, &scratch.row_sorted, row_count);
        try ensureSliceCapacity(bool, gpa, &scratch.row_have_last_crossing, row_count);
        try ensureSliceCapacity(f32, gpa, &scratch.row_last_crossing_x, row_count);

        const starts = scratch.row_segment_starts[0 .. row_count + 1];
        const cursors = scratch.row_segment_cursors[0..row_count];
        const crossing_starts = scratch.row_crossing_starts[0 .. row_count + 1];
        const crossing_cursors = scratch.row_crossing_cursors[0..row_count];
        const windings = scratch.row_windings[0..row_count];
        const sorted = scratch.row_sorted[0..row_count];
        const have_last_crossing = scratch.row_have_last_crossing[0..row_count];
        const last_crossing_x = scratch.row_last_crossing_x[0..row_count];
        @memset(starts, 0);
        @memset(crossing_starts, 0);
        @memset(windings, 0);
        @memset(sorted, true);
        @memset(have_last_crossing, false);
        @memset(last_crossing_x, 0);

        const segment_start: usize = @intCast(range.start);
        const segment_count: usize = @intCast(range.count);
        for (segments[segment_start..][0..segment_count]) |seg| {
            const rows = activeRowsForSegment(seg, row_base, row_end) orelse continue;
            var row = rows.start;
            while (row <= rows.end) : (row += 1) {
                starts[@intCast(row - row_base + 1)] += 1;
                const sample_y = sampleYForTileRow(row);
                if (crossingDelta(sample_y, seg) != null) {
                    crossing_starts[@intCast(row - row_base + 1)] += 1;
                }
            }
        }

        var i: usize = 1;
        while (i < starts.len) : (i += 1) {
            starts[i] += starts[i - 1];
            crossing_starts[i] += crossing_starts[i - 1];
        }

        const index_count = starts[row_count];
        try ensureSliceCapacity(u32, gpa, &scratch.row_segment_indices, index_count);
        const indices = scratch.row_segment_indices[0..index_count];
        const crossing_count = crossing_starts[row_count];
        try ensureSliceCapacity(Crossing, gpa, &scratch.row_crossings, crossing_count);
        const crossings = scratch.row_crossings[0..crossing_count];
        @memcpy(cursors, starts[0..row_count]);
        @memcpy(crossing_cursors, crossing_starts[0..row_count]);

        for (segments[segment_start..][0..segment_count], 0..) |seg, offset| {
            const rows = activeRowsForSegment(seg, row_base, row_end) orelse continue;
            var row = rows.start;
            while (row <= rows.end) : (row += 1) {
                const local_row: usize = @intCast(row - row_base);
                const out_index = cursors[local_row];
                indices[out_index] = @intCast(segment_start + offset);
                cursors[local_row] += 1;

                const sample_y = sampleYForTileRow(row);
                const delta = crossingDelta(sample_y, seg) orelse continue;
                const x = intersectX(sample_y, seg);
                if (have_last_crossing[local_row] and x < last_crossing_x[local_row]) {
                    sorted[local_row] = false;
                }
                const crossing_index = crossing_cursors[local_row];
                crossings[crossing_index] = .{
                    .x = x,
                    .winding = delta,
                };
                crossing_cursors[local_row] += 1;
                have_last_crossing[local_row] = true;
                last_crossing_x[local_row] = x;
                windings[local_row] += delta;
            }
        }

        return .{
            .row_base = row_base,
            .starts = starts,
            .indices = indices,
            .crossing_starts = crossing_starts,
            .crossings = crossings,
            .windings = windings,
            .sorted = sorted,
        };
    }

    fn segmentIndicesForTileOrigin(self: ActiveSegmentRows, tile_y: u16) []const u32 {
        if (self.starts.len == 0) return &.{};
        const row = strip.tileCoord(@floatFromInt(tile_y));
        if (row < self.row_base) return &.{};
        const local_row: usize = @intCast(row - self.row_base);
        if (local_row + 1 >= self.starts.len) return &.{};
        return self.indices[self.starts[local_row]..self.starts[local_row + 1]];
    }

    fn crossingsForTileOrigin(self: ActiveSegmentRows, tile_y: u16) RowCrossings {
        if (self.crossing_starts.len == 0) return .{};
        const row = strip.tileCoord(@floatFromInt(tile_y));
        if (row < self.row_base) return .{};
        const local_row: usize = @intCast(row - self.row_base);
        if (local_row + 1 >= self.crossing_starts.len) return .{};
        return .{
            .crossings = self.crossings[self.crossing_starts[local_row]..self.crossing_starts[local_row + 1]],
            .winding = self.windings[local_row],
            .sorted = self.sorted[local_row],
        };
    }
};

const ActiveRowRange = struct {
    start: i32,
    end: i32,
};

const RowCrossings = struct {
    crossings: []Crossing = &.{},
    winding: i32 = 0,
    sorted: bool = true,
};

fn activeRowsForSegment(seg: encode.Segment, row_base: i32, row_end: i32) ?ActiveRowRange {
    const min_y = @min(seg.y0, seg.y1);
    const max_y = @max(seg.y0, seg.y1);
    if (max_y <= min_y) return null;
    const start = std.math.clamp(strip.tileCoord(min_y), row_base, row_end);
    const end = std.math.clamp(strip.tileCoord(max_y - 0.001), row_base, row_end);
    if (start > end) return null;
    return .{ .start = start, .end = end };
}

fn sampleYForTileRow(row: i32) f32 {
    return @as(f32, @floatFromInt(row)) * @as(f32, @floatFromInt(strip.tile_size)) + 0.5;
}

const Crossing = struct {
    x: f32,
    winding: i32,
};

pub fn fillTaskAux() u32 {
    return task_fill;
}

pub fn fillTask(x: u16, y: u16, call_index: u32) GpuFineTask {
    return fillSpanTask(x, y, call_index, 1);
}

pub fn fillSpanTask(x: u16, y: u16, call_index: u32, tile_count: u32) GpuFineTask {
    return .{
        .xy = packTaskXY(x, y),
        .call_index = call_index,
        .segment_start = 0,
        .segment_count_kind = task_kind_fill_span_mask | tile_count,
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

pub fn taskIsFillSpan(task: GpuFineTask) bool {
    return (task.segment_count_kind & task_kind_fill_span_mask) != 0;
}

pub fn taskSegmentCount(task: GpuFineTask) u32 {
    return task.segment_count_kind & task_payload_mask;
}

pub fn taskFillTileCount(task: GpuFineTask) u32 {
    if (!taskIsFillSpan(task)) return 1;
    return @max(task.segment_count_kind & task_payload_mask, 1);
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
    row_segment_indices: []const u32,
) !strip.Range {
    const start = segment_indices.items.len;
    try segment_indices.ensureUnusedCapacity(gpa, row_segment_indices.len);
    for (row_segment_indices) |segment_index| {
        segment_indices.appendAssumeCapacity(.{ .value = segment_index });
    }
    return .{
        .start = @intCast(start),
        .count = @intCast(segment_indices.items.len - start),
    };
}

fn appendFillTasks(
    call_index: u32,
    fill_rule: strip.FillRule,
    bounds: [4]f32,
    active_rows: ActiveSegmentRows,
    scratch: *Scratch,
    width_tiles: usize,
    width: u32,
    height: u32,
    tasks: *std.ArrayList(GpuFineTask),
    stats: *PacketStats,
    profile: ?*Profile,
) void {
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3]) return;

    const max_tile_x = strip.tileCoord(@as(f32, @floatFromInt(width)) - 0.001);
    const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
    var tile_y = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
    const tile_y_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
    const tile_size_f: f32 = @floatFromInt(strip.tile_size);
    const tile_x_start = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
    const tile_x_end = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);

    while (tile_y <= tile_y_end) : (tile_y += 1) {
        const row_crossings = active_rows.crossingsForTileOrigin(@intCast(strip.tileOrigin(@intCast(tile_y))));
        if (profile) |p| {
            p.crossing_rows += 1;
            p.crossing_items += row_crossings.crossings.len;
            p.max_crossings_per_row = @max(p.max_crossings_per_row, row_crossings.crossings.len);
        }
        if (row_crossings.crossings.len == 0) continue;

        const sort_start = profileStart(profile);
        const sorted = sortCrossingsIfNeeded(row_crossings.crossings, row_crossings.sorted);
        if (profile) |p| p.crossing_sort_ns += elapsedSince(sort_start);
        if (profile) |p| {
            if (sorted) {
                p.crossing_sort_rows += 1;
            }
        }

        var winding = row_crossings.winding;
        var tile_x = tile_x_start;
        var crossing_index: usize = 0;
        var span_start_x: i32 = 0;
        var span_count: u32 = 0;
        const emit_start = profileStart(profile);
        while (tile_x <= tile_x_end) : (tile_x += 1) {
            const sample_x = @as(f32, @floatFromInt(tile_x)) * tile_size_f + 0.5;
            while (crossing_index < row_crossings.crossings.len and row_crossings.crossings[crossing_index].x <= sample_x) : (crossing_index += 1) {
                winding -= row_crossings.crossings[crossing_index].winding;
            }
            if (!filled(fill_rule, winding)) {
                appendPendingFillSpan(tasks, stats, call_index, span_start_x, tile_y, &span_count);
                continue;
            }
            if (profile) |p| p.fill_candidates += 1;
            if (profile) |p| p.boundary_checks += 1;
            if (containsBoundaryTile(scratch, width_tiles, tile_x, tile_y)) {
                if (profile) |p| p.boundary_hits += 1;
                appendPendingFillSpan(tasks, stats, call_index, span_start_x, tile_y, &span_count);
                continue;
            }
            if (span_count == 0) {
                span_start_x = tile_x;
                span_count = 1;
            } else if (tile_x == span_start_x + @as(i32, @intCast(span_count)) and span_count < SparseConfig.max_fill_span_tiles) {
                span_count += 1;
            } else {
                appendPendingFillSpan(tasks, stats, call_index, span_start_x, tile_y, &span_count);
                span_start_x = tile_x;
                span_count = 1;
            }
            if (span_count == SparseConfig.max_fill_span_tiles) {
                appendPendingFillSpan(tasks, stats, call_index, span_start_x, tile_y, &span_count);
            }
        }
        appendPendingFillSpan(tasks, stats, call_index, span_start_x, tile_y, &span_count);
        if (profile) |p| p.fill_emit_ns += elapsedSince(emit_start);
    }
}

fn appendPendingFillSpan(
    tasks: *std.ArrayList(GpuFineTask),
    stats: *PacketStats,
    call_index: u32,
    span_start_x: i32,
    tile_y: i32,
    span_count: *u32,
) void {
    if (span_count.* == 0) return;
    tasks.appendAssumeCapacity(fillSpanTask(
        @intCast(strip.tileOrigin(@intCast(span_start_x))),
        @intCast(strip.tileOrigin(@intCast(tile_y))),
        call_index,
        span_count.*,
    ));
    stats.fill_tasks += 1;
    span_count.* = 0;
}

fn fillTaskCapacityForBounds(bounds: [4]f32, width: u32, height: u32) usize {
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3] or width == 0 or height == 0) return 0;
    const max_tile_x = strip.tileCoord(@as(f32, @floatFromInt(width)) - 0.001);
    const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
    const tile_x = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
    const tile_y = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
    const tile_x_end = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);
    const tile_y_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
    if (tile_x > tile_x_end or tile_y > tile_y_end) return 0;
    return @as(usize, @intCast(tile_x_end - tile_x + 1)) * @as(usize, @intCast(tile_y_end - tile_y + 1));
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

test "sparse GPU active rows exclude horizontal segments" {
    const testing = std.testing;
    try testing.expect(activeRowsForSegment(.{
        .x0 = 0,
        .y0 = 4,
        .x1 = 8,
        .y1 = 4,
    }, 0, 4) == null);
}

test "sparse GPU active rows keep boundary rows half-open" {
    const testing = std.testing;
    const row = activeRowsForSegment(.{
        .x0 = 0,
        .y0 = 4,
        .x1 = 8,
        .y1 = 8,
    }, 0, 4).?;
    try testing.expectEqual(@as(i32, 1), row.start);
    try testing.expectEqual(@as(i32, 1), row.end);
}

test "sparse GPU active row index returns global segment indices" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);

    const segments = [_]encode.Segment{
        .{ .x0 = 0, .y0 = 4, .x1 = 8, .y1 = 4 },
        .{ .x0 = 0, .y0 = 4, .x1 = 8, .y1 = 12 },
        .{ .x0 = 0, .y0 = 12, .x1 = 8, .y1 = 16 },
    };
    const rows = try ActiveSegmentRows.init(
        testing.allocator,
        &scratch,
        &segments,
        .{ .start = 0, .count = segments.len },
        .{ 0, 4, 16, 16 },
        32,
    );

    try testing.expectEqualSlices(u32, &.{1}, rows.segmentIndicesForTileOrigin(4));
    try testing.expectEqualSlices(u32, &.{1}, rows.segmentIndicesForTileOrigin(8));
    try testing.expectEqualSlices(u32, &.{2}, rows.segmentIndicesForTileOrigin(12));
}

test "sparse GPU active rows cache fill crossings" {
    const testing = std.testing;
    var scratch: Scratch = .{};
    defer scratch.deinit(testing.allocator);

    const segments = [_]encode.Segment{
        .{ .x0 = 8, .y0 = 12, .x1 = 8, .y1 = 4 },
        .{ .x0 = 0, .y0 = 4, .x1 = 0, .y1 = 12 },
        .{ .x0 = 0, .y0 = 12, .x1 = 8, .y1 = 12 },
    };
    const rows = try ActiveSegmentRows.init(
        testing.allocator,
        &scratch,
        &segments,
        .{ .start = 0, .count = segments.len },
        .{ 0, 4, 8, 12 },
        32,
    );

    const row = rows.crossingsForTileOrigin(4);
    try testing.expectEqual(@as(usize, 2), row.crossings.len);
    try testing.expectEqual(@as(i32, 0), row.winding);
    try testing.expect(!row.sorted);
    try testing.expectApproxEqAbs(@as(f32, 8), row.crossings[0].x, 0.001);
    try testing.expectEqual(@as(i32, -1), row.crossings[0].winding);
    try testing.expectApproxEqAbs(@as(f32, 0), row.crossings[1].x, 0.001);
    try testing.expectEqual(@as(i32, 1), row.crossings[1].winding);

    const edge_row = rows.crossingsForTileOrigin(12);
    try testing.expectEqual(@as(usize, 0), edge_row.crossings.len);
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
