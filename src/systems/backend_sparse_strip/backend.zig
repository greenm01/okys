//! Sparse-strip backend CPU proof: encode, bin, coarse strips, scalar fine coverage.

const std = @import("std");
const color = @import("../../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const image = @import("../../types/image.zig");
const ImageId = image.ImageId;
const TexFormat = image.TexFormat;
const Texture = image.Texture;
const path = @import("../../types/path.zig");
const ClipRule = path.ClipRule;
const PathRange = path.PathRange;
const Point = path.Point;
const Vertex = path.Vertex;
const RenderInterface = @import("../../render/interface.zig").RenderInterface;

pub const encode = @import("encode.zig");
pub const bin = @import("bin.zig");
pub const coarse = @import("coarse.zig");
pub const debug = @import("debug.zig");
pub const direct_strip = @import("direct_strip.zig");
pub const fine = @import("fine.zig");
pub const gpu_fine = @import("gpu_fine.zig");
pub const strip = @import("strip.zig");

pub const EncodedCall = encode.EncodedCall;
pub const ClipRecord = encode.ClipRecord;
pub const Segment = encode.Segment;
pub const Strip = strip.Strip;
pub const TileRef = strip.TileRef;
pub const FillRule = strip.FillRule;
pub const GpuFinePacket = gpu_fine.Packet;

pub const dense_strip_segment_warning_threshold: usize = 32;
pub const gpu_fine_upload_warning_bytes: usize = 4 * 1024 * 1024;

pub const Profile = struct {
    bin_ns: u64 = 0,
    coarse_ns: u64 = 0,
    texture_views_ns: u64 = 0,
    gpu_fine_ns: u64 = 0,
    direct_strip_estimate_ns: u64 = 0,
    fine_ns: u64 = 0,
    fine_profile: fine.Profile = .{},
    gpu_fine_profile: gpu_fine.Profile = .{},
    direct_strip_estimate: direct_strip.Stats = .{},
    frame_packet: FramePacketStats = .{},

    pub fn reset(self: *Profile) void {
        self.* = .{};
    }
};

pub const FramePacketStats = struct {
    calls: usize = 0,
    clips: usize = 0,
    clip_indices: usize = 0,
    segments: usize = 0,
    tile_refs: usize = 0,
    strips: usize = 0,
    strip_indices: usize = 0,
    alpha_bytes: usize = 0,
    surface_bytes: usize = 0,
    texture_bytes: usize = 0,
    calls_bytes: usize = 0,
    clips_bytes: usize = 0,
    clip_indices_bytes: usize = 0,
    segments_bytes: usize = 0,
    tile_refs_bytes: usize = 0,
    strips_bytes: usize = 0,
    strip_indices_bytes: usize = 0,
    frame_packet_bytes: usize = 0,
    gpu_fine_upload_bytes: usize = 0,
    packet_capacity_bytes: usize = 0,
    packet_slack_bytes: usize = 0,
    max_strip_segments: usize = 0,
    multi_call_tiles: usize = 0,
    max_calls_per_tile: usize = 0,
    strip_call_order_breaks: usize = 0,
    strip_spatial_order_breaks: usize = 0,
    frame_bounds_x0: usize = 0,
    frame_bounds_y0: usize = 0,
    frame_bounds_x1: usize = 0,
    frame_bounds_y1: usize = 0,
    command_bound_pixels: usize = 0,
    candidate_tiles_from_bounds: usize = 0,
    empty_bound_calls: usize = 0,
    clipped_out_calls: usize = 0,
    fill_box_candidate_calls: usize = 0,
    max_segments_per_call: usize = 0,
    max_tile_refs_per_call: usize = 0,
    max_strips_per_call: usize = 0,
    max_alpha_bytes_per_call: usize = 0,
    dense_strip_warnings: usize = 0,
    upload_budget_bytes: usize = gpu_fine_upload_warning_bytes,
    upload_budget_warnings: usize = 0,
};

const SparseTexture = struct {
    texture: Texture,
    pixels: std.ArrayList(u8) = .empty,
    generation: u64 = 1,

    fn deinit(self: *SparseTexture, gpa: std.mem.Allocator) void {
        self.pixels.deinit(gpa);
    }

    fn view(self: *const SparseTexture) fine.Texture {
        return .{
            .id = self.texture.id,
            .width = self.texture.width,
            .height = self.texture.height,
            .format = self.texture.format,
            .pixels = self.pixels.items,
            .generation = self.generation,
        };
    }

    fn markChanged(self: *SparseTexture) void {
        self.generation = if (self.generation == std.math.maxInt(u64)) 1 else self.generation + 1;
    }
};

pub const Backend = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(EncodedCall) = .empty,
    clips: std.ArrayList(ClipRecord) = .empty,
    active_clip_stack: std.ArrayList(u32) = .empty,
    call_clip_indices: std.ArrayList(u32) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    tiles: std.ArrayList(TileRef) = .empty,
    bin_scratch: bin.Scratch = .{},
    strips: std.ArrayList(Strip) = .empty,
    strip_segment_indices: std.ArrayList(u32) = .empty,
    alphas: std.ArrayList(u8) = .empty,
    surface: std.ArrayList(u8) = .empty,
    textures: std.AutoArrayHashMapUnmanaged(ImageId, SparseTexture) = .empty,
    texture_views: std.ArrayList(fine.Texture) = .empty,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_dpr: f32 = 1,
    fill_rule: FillRule = .nonzero,
    flush_count: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    clip_push_count: usize = 0,
    clip_pop_count: usize = 0,
    last_clip_rule: ClipRule = .nonzero,
    last_clip_bounds: [4]f32 = .{ 0, 0, 0, 0 },
    last_clip_path_count: usize = 0,
    last_clip_point_count: usize = 0,

    pub fn create(gpa: std.mem.Allocator) !*Backend {
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Backend) void {
        const gpa = self.gpa;
        self.calls.deinit(gpa);
        self.clips.deinit(gpa);
        self.active_clip_stack.deinit(gpa);
        self.call_clip_indices.deinit(gpa);
        self.segments.deinit(gpa);
        self.tiles.deinit(gpa);
        self.bin_scratch.deinit(gpa);
        self.strips.deinit(gpa);
        self.strip_segment_indices.deinit(gpa);
        self.alphas.deinit(gpa);
        self.surface.deinit(gpa);
        for (self.textures.values()) |*texture| {
            texture.deinit(gpa);
        }
        self.textures.deinit(gpa);
        self.texture_views.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn interface(self: *Backend) RenderInterface {
        return .{
            .ctx = self,
            .create_texture = createTexture,
            .update_texture = updateTexture,
            .delete_texture = deleteTexture,
            .texture_size = textureSize,
            .viewport = viewport,
            .flush = renderFlush,
            .deinit = deinit,
            .fill = fill,
            .stroke = stroke,
            .triangles = triangles,
            .push_clip_path = pushClipPath,
            .pop_clip_path = popClipPath,
        };
    }

    pub fn flush(self: *Backend) void {
        _ = self.build();
        self.flush_count += 1;
        self.clearQueued();
    }

    pub fn build(self: *Backend) bool {
        return self.buildProfiled(null);
    }

    pub fn buildProfiled(self: *Backend, profile: ?*Profile) bool {
        if (profile) |p| p.reset();

        const bin_start = profileStart(profile);
        bin.build(self.gpa, self.viewport_width, self.viewport_height, self.calls.items, self.segments.items, &self.tiles, &self.bin_scratch) catch return false;
        if (profile) |p| p.bin_ns += elapsedSince(bin_start);

        const coarse_start = profileStart(profile);
        coarse.build(self.gpa, self.tiles.items, &self.strips, &self.strip_segment_indices) catch return false;
        if (profile) |p| p.coarse_ns += elapsedSince(coarse_start);

        const texture_views_start = profileStart(profile);
        self.rebuildTextureViews() catch return false;
        if (profile) |p| p.texture_views_ns += elapsedSince(texture_views_start);

        const fine_start = profileStart(profile);
        fine.build(
            self.gpa,
            self.fill_rule,
            self.viewport_width,
            self.viewport_height,
            self.calls.items,
            self.segments.items,
            self.clips.items,
            self.call_clip_indices.items,
            self.strip_segment_indices.items,
            self.texture_views.items,
            &self.strips,
            &self.alphas,
            &self.surface,
            if (profile) |p| &p.fine_profile else null,
        ) catch return false;
        if (profile) |p| p.fine_ns += elapsedSince(fine_start);
        if (profile) |p| p.frame_packet = self.framePacketStats();
        return true;
    }

    pub fn buildGpuFinePacket(self: *Backend, packet: *GpuFinePacket, profile: ?*Profile) bool {
        if (profile) |p| p.reset();

        const bin_start = profileStart(profile);
        bin.build(self.gpa, self.viewport_width, self.viewport_height, self.calls.items, self.segments.items, &self.tiles, &self.bin_scratch) catch return false;
        if (profile) |p| p.bin_ns += elapsedSince(bin_start);

        const coarse_start = profileStart(profile);
        coarse.build(self.gpa, self.tiles.items, &self.strips, &self.strip_segment_indices) catch return false;
        if (profile) |p| p.coarse_ns += elapsedSince(coarse_start);

        const texture_views_start = profileStart(profile);
        self.rebuildTextureViews() catch return false;
        if (profile) |p| p.texture_views_ns += elapsedSince(texture_views_start);

        const gpu_fine_start = profileStart(profile);
        const supported = gpu_fine.build(
            self.gpa,
            self.fill_rule,
            self.viewport_width,
            self.viewport_height,
            self.calls.items,
            self.segments.items,
            self.clips.items,
            self.call_clip_indices.items,
            self.strip_segment_indices.items,
            self.strips.items,
            packet,
            if (profile) |p| &p.gpu_fine_profile else null,
        ) catch return false;
        if (profile) |p| p.gpu_fine_ns += elapsedSince(gpu_fine_start);
        if (profile) |p| {
            const direct_strip_start = profileStart(profile);
            p.direct_strip_estimate = direct_strip.estimate(self.calls.items, packet);
            p.direct_strip_estimate_ns += elapsedSince(direct_strip_start);
            p.frame_packet = self.gpuFineFramePacketStats(packet);
        }
        return supported;
    }

    pub fn clearQueued(self: *Backend) void {
        self.calls.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        self.active_clip_stack.clearRetainingCapacity();
        self.call_clip_indices.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.tiles.clearRetainingCapacity();
        self.strips.clearRetainingCapacity();
        self.strip_segment_indices.clearRetainingCapacity();
        self.alphas.clearRetainingCapacity();
    }

    fn queuePath(self: *Backend, kind: strip.CallKind, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, width: f32, paths: []const PathRange, points: []const Point) void {
        const call_index: u32 = @intCast(self.calls.items.len);
        const range = encode.appendPathSegments(&self.segments, self.gpa, call_index, paths, points) catch return;
        if (range.count == 0) return;
        const clip_range = self.snapshotActiveClips() catch {
            self.segments.shrinkRetainingCapacity(@intCast(range.start));
            return;
        };
        self.calls.append(self.gpa, .{
            .kind = kind,
            .paint = paint.*,
            .scissor = scissor.*,
            .bounds = bounds,
            .width = width,
            .segments = range,
            .clips = clip_range,
            .convex = singleConvexPath(paths, points.len),
        }) catch {
            self.call_clip_indices.shrinkRetainingCapacity(@intCast(clip_range.start));
            self.segments.shrinkRetainingCapacity(@intCast(range.start));
        };
    }

    fn snapshotActiveClips(self: *Backend) !strip.Range {
        const start = self.call_clip_indices.items.len;
        try self.call_clip_indices.appendSlice(self.gpa, self.active_clip_stack.items);
        return .{ .start = @intCast(start), .count = @intCast(self.active_clip_stack.items.len) };
    }

    fn rebuildTextureViews(self: *Backend) !void {
        self.texture_views.clearRetainingCapacity();
        try self.texture_views.ensureTotalCapacity(self.gpa, self.textures.count());
        for (self.textures.values()) |*texture| {
            self.texture_views.appendAssumeCapacity(texture.view());
        }
    }

    fn framePacketStats(self: *const Backend) FramePacketStats {
        var texture_bytes: usize = 0;
        var texture_capacity_bytes: usize = 0;
        for (self.textures.values()) |texture| {
            texture_bytes += texture.pixels.items.len;
            texture_capacity_bytes += texture.pixels.capacity;
        }

        const strip_order = stripOrderStats(self.strips.items);
        const bounds_stats = boundsStats(self.viewport_width, self.viewport_height, self.calls.items, self.segments.items);
        const pressure = pressureStats(self.calls.items, self.tiles.items, self.strips.items);

        const calls_bytes = bytesOf(EncodedCall, self.calls.items.len);
        const clips_bytes = bytesOf(ClipRecord, self.clips.items.len);
        const call_clip_indices_bytes = bytesOf(u32, self.call_clip_indices.items.len);
        const segments_bytes = bytesOf(Segment, self.segments.items.len);
        const tile_refs_bytes = bytesOf(TileRef, self.tiles.items.len);
        const strips_bytes = bytesOf(Strip, self.strips.items.len);
        const strip_indices_bytes = bytesOf(u32, self.strip_segment_indices.items.len);
        const frame_packet_bytes = calls_bytes +
            clips_bytes +
            call_clip_indices_bytes +
            segments_bytes +
            tile_refs_bytes +
            strips_bytes +
            strip_indices_bytes +
            self.alphas.items.len +
            self.surface.items.len +
            texture_bytes;
        const packet_capacity_bytes = capacityBytes(EncodedCall, self.calls.capacity) +
            capacityBytes(ClipRecord, self.clips.capacity) +
            capacityBytes(u32, self.call_clip_indices.capacity) +
            capacityBytes(Segment, self.segments.capacity) +
            capacityBytes(TileRef, self.tiles.capacity) +
            capacityBytes(Strip, self.strips.capacity) +
            capacityBytes(u32, self.strip_segment_indices.capacity) +
            self.alphas.capacity +
            self.surface.capacity +
            texture_capacity_bytes;

        return .{
            .calls = self.calls.items.len,
            .clips = self.clips.items.len,
            .clip_indices = self.call_clip_indices.items.len,
            .segments = self.segments.items.len,
            .tile_refs = self.tiles.items.len,
            .strips = self.strips.items.len,
            .strip_indices = self.strip_segment_indices.items.len,
            .alpha_bytes = self.alphas.items.len,
            .surface_bytes = self.surface.items.len,
            .texture_bytes = texture_bytes,
            .calls_bytes = calls_bytes,
            .clips_bytes = clips_bytes,
            .clip_indices_bytes = call_clip_indices_bytes,
            .segments_bytes = segments_bytes,
            .tile_refs_bytes = tile_refs_bytes,
            .strips_bytes = strips_bytes,
            .strip_indices_bytes = strip_indices_bytes,
            .frame_packet_bytes = frame_packet_bytes,
            .gpu_fine_upload_bytes = calls_bytes + segments_bytes + strips_bytes + strip_indices_bytes,
            .packet_capacity_bytes = packet_capacity_bytes,
            .packet_slack_bytes = packet_capacity_bytes - frame_packet_bytes,
            .max_strip_segments = strip_order.max_strip_segments,
            .multi_call_tiles = strip_order.multi_call_tiles,
            .max_calls_per_tile = strip_order.max_calls_per_tile,
            .strip_call_order_breaks = strip_order.call_order_breaks,
            .strip_spatial_order_breaks = strip_order.spatial_order_breaks,
            .frame_bounds_x0 = bounds_stats.frame_bounds_x0,
            .frame_bounds_y0 = bounds_stats.frame_bounds_y0,
            .frame_bounds_x1 = bounds_stats.frame_bounds_x1,
            .frame_bounds_y1 = bounds_stats.frame_bounds_y1,
            .command_bound_pixels = bounds_stats.command_bound_pixels,
            .candidate_tiles_from_bounds = bounds_stats.candidate_tiles_from_bounds,
            .empty_bound_calls = bounds_stats.empty_bound_calls,
            .clipped_out_calls = bounds_stats.clipped_out_calls,
            .fill_box_candidate_calls = bounds_stats.fill_box_candidate_calls,
            .max_segments_per_call = pressure.max_segments_per_call,
            .max_tile_refs_per_call = pressure.max_tile_refs_per_call,
            .max_strips_per_call = pressure.max_strips_per_call,
            .max_alpha_bytes_per_call = pressure.max_alpha_bytes_per_call,
            .dense_strip_warnings = pressure.dense_strip_warnings,
            .upload_budget_warnings = @intFromBool((calls_bytes + segments_bytes + strips_bytes + strip_indices_bytes) > gpu_fine_upload_warning_bytes),
        };
    }

    fn gpuFineFramePacketStats(self: *const Backend, packet: *const GpuFinePacket) FramePacketStats {
        const calls_bytes = bytesOf(gpu_fine.GpuCall, packet.calls.items.len);
        const clips_bytes = bytesOf(gpu_fine.GpuClip, packet.clips.items.len);
        const clip_indices_bytes = bytesOf(gpu_fine.GpuClipIndex, packet.clip_indices.items.len);
        const segments_bytes = bytesOf(gpu_fine.GpuSegment, packet.segments.items.len);
        const tasks_bytes = bytesOf(gpu_fine.GpuFineTask, packet.tasks.items.len);
        const segment_indices_bytes = bytesOf(gpu_fine.GpuSegmentIndex, packet.segment_indices.items.len);
        return .{
            .calls = packet.calls.items.len,
            .clips = packet.clips.items.len,
            .clip_indices = packet.clip_indices.items.len,
            .segments = self.segments.items.len,
            .tile_refs = self.tiles.items.len,
            .strips = self.strips.items.len,
            .strip_indices = self.strip_segment_indices.items.len,
            .calls_bytes = calls_bytes,
            .clips_bytes = clips_bytes,
            .clip_indices_bytes = clip_indices_bytes,
            .segments_bytes = segments_bytes,
            .tile_refs_bytes = bytesOf(TileRef, self.tiles.items.len),
            .strips_bytes = bytesOf(Strip, self.strips.items.len),
            .strip_indices_bytes = bytesOf(u32, self.strip_segment_indices.items.len),
            .frame_packet_bytes = calls_bytes + clips_bytes + clip_indices_bytes + segments_bytes + tasks_bytes + segment_indices_bytes,
            .gpu_fine_upload_bytes = packet.stats.upload_bytes,
            .upload_budget_warnings = @intFromBool(packet.stats.upload_bytes > gpu_fine_upload_warning_bytes),
        };
    }
};

const ClippedBounds = struct {
    x0: usize = 0,
    y0: usize = 0,
    x1: usize = 0,
    y1: usize = 0,
    empty: bool = true,
};

const BoundsStats = struct {
    frame_bounds_x0: usize = 0,
    frame_bounds_y0: usize = 0,
    frame_bounds_x1: usize = 0,
    frame_bounds_y1: usize = 0,
    command_bound_pixels: usize = 0,
    candidate_tiles_from_bounds: usize = 0,
    empty_bound_calls: usize = 0,
    clipped_out_calls: usize = 0,
    fill_box_candidate_calls: usize = 0,
};

fn boundsStats(viewport_width: f32, viewport_height: f32, calls: []const EncodedCall, segments: []const Segment) BoundsStats {
    const width = viewportPixelExtent(viewport_width);
    const height = viewportPixelExtent(viewport_height);
    var stats: BoundsStats = .{};
    var has_frame_bounds = false;

    for (calls) |call| {
        const bounds = callBounds(call, segments);
        if (!validBounds(bounds)) {
            stats.empty_bound_calls += 1;
            continue;
        }

        const clipped = clipBounds(bounds, width, height);
        if (clipped.empty) {
            stats.clipped_out_calls += 1;
        } else {
            stats.command_bound_pixels += boundPixels(clipped);
            stats.candidate_tiles_from_bounds += candidateTiles(clipped);
            if (!has_frame_bounds) {
                stats.frame_bounds_x0 = clipped.x0;
                stats.frame_bounds_y0 = clipped.y0;
                stats.frame_bounds_x1 = clipped.x1;
                stats.frame_bounds_y1 = clipped.y1;
                has_frame_bounds = true;
            } else {
                stats.frame_bounds_x0 = @min(stats.frame_bounds_x0, clipped.x0);
                stats.frame_bounds_y0 = @min(stats.frame_bounds_y0, clipped.y0);
                stats.frame_bounds_x1 = @max(stats.frame_bounds_x1, clipped.x1);
                stats.frame_bounds_y1 = @max(stats.frame_bounds_y1, clipped.y1);
            }
        }

        if (fillBoxCandidate(call, segments)) stats.fill_box_candidate_calls += 1;
    }

    return stats;
}

fn viewportPixelExtent(v: f32) usize {
    if (v <= 0) return 0;
    return @intFromFloat(@ceil(v));
}

fn clipBounds(bounds: [4]f32, width: usize, height: usize) ClippedBounds {
    if (width == 0 or height == 0) return .{};
    const width_f: f32 = @floatFromInt(width);
    const height_f: f32 = @floatFromInt(height);
    const x0_f = std.math.clamp(@floor(bounds[0]), 0, width_f);
    const y0_f = std.math.clamp(@floor(bounds[1]), 0, height_f);
    const x1_f = std.math.clamp(@ceil(bounds[2]), 0, width_f);
    const y1_f = std.math.clamp(@ceil(bounds[3]), 0, height_f);
    if (x0_f >= x1_f or y0_f >= y1_f) return .{};
    return .{
        .x0 = @intFromFloat(x0_f),
        .y0 = @intFromFloat(y0_f),
        .x1 = @intFromFloat(x1_f),
        .y1 = @intFromFloat(y1_f),
        .empty = false,
    };
}

fn boundPixels(bounds: ClippedBounds) usize {
    if (bounds.empty) return 0;
    return (bounds.x1 - bounds.x0) * (bounds.y1 - bounds.y0);
}

fn candidateTiles(bounds: ClippedBounds) usize {
    if (bounds.empty) return 0;
    const x0: i32 = strip.tileCoord(@floatFromInt(bounds.x0));
    const y0: i32 = strip.tileCoord(@floatFromInt(bounds.y0));
    const x1: i32 = strip.tileCoord(@as(f32, @floatFromInt(bounds.x1)) - 0.001);
    const y1: i32 = strip.tileCoord(@as(f32, @floatFromInt(bounds.y1)) - 0.001);
    return @intCast((x1 - x0 + 1) * (y1 - y0 + 1));
}

fn callBounds(call: EncodedCall, segments: []const Segment) [4]f32 {
    if (validBounds(call.bounds)) return call.bounds;

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

fn validBounds(bounds: [4]f32) bool {
    return bounds[0] < bounds[2] and bounds[1] < bounds[3];
}

fn fillBoxCandidate(call: EncodedCall, segments: []const Segment) bool {
    if (call.kind != .fill or !call.convex or call.segments.count != 4) return false;
    if (call.paint.image != 0 or !scissorDisabled(&call.scissor)) return false;
    if (!sameColor(call.paint.inner_color, call.paint.outer_color)) return false;

    const bounds = callBounds(call, segments);
    if (!validBounds(bounds) or !alignedBounds(bounds)) return false;

    const start: usize = @intCast(call.segments.start);
    var horizontal: usize = 0;
    var vertical: usize = 0;
    for (segments[start..][0..4]) |seg| {
        if (seg.y0 == seg.y1) {
            if (!atRectY(seg.y0, bounds) or @min(seg.x0, seg.x1) != bounds[0] or @max(seg.x0, seg.x1) != bounds[2]) return false;
            horizontal += 1;
        } else if (seg.x0 == seg.x1) {
            if (!atRectX(seg.x0, bounds) or @min(seg.y0, seg.y1) != bounds[1] or @max(seg.y0, seg.y1) != bounds[3]) return false;
            vertical += 1;
        } else {
            return false;
        }
    }
    return horizontal == 2 and vertical == 2;
}

fn alignedBounds(bounds: [4]f32) bool {
    return isInteger(bounds[0]) and isInteger(bounds[1]) and isInteger(bounds[2]) and isInteger(bounds[3]);
}

fn isInteger(value: f32) bool {
    return value == @floor(value);
}

fn atRectX(x: f32, bounds: [4]f32) bool {
    return x == bounds[0] or x == bounds[2];
}

fn atRectY(y: f32, bounds: [4]f32) bool {
    return y == bounds[1] or y == bounds[3];
}

fn sameColor(a: color.Color, b: color.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn scissorDisabled(scissor: *const Scissor) bool {
    return scissor.extent[0] < 0 or scissor.extent[1] < 0;
}

const PressureStats = struct {
    max_segments_per_call: usize = 0,
    max_tile_refs_per_call: usize = 0,
    max_strips_per_call: usize = 0,
    max_alpha_bytes_per_call: usize = 0,
    dense_strip_warnings: usize = 0,
};

fn pressureStats(calls: []const EncodedCall, tiles: []const TileRef, strips: []const Strip) PressureStats {
    var stats: PressureStats = .{};
    for (calls, 0..) |call, call_index| {
        stats.max_segments_per_call = @max(stats.max_segments_per_call, call.segments.count);
        stats.max_tile_refs_per_call = @max(stats.max_tile_refs_per_call, countTilesForCall(tiles, call_index));

        var strip_count: usize = 0;
        var alpha_bytes: usize = 0;
        for (strips) |s| {
            if (s.call_index != call_index) continue;
            strip_count += 1;
            alpha_bytes += s.alpha.count;
            if (s.segment_indices.count > dense_strip_segment_warning_threshold) {
                stats.dense_strip_warnings += 1;
            }
        }
        stats.max_strips_per_call = @max(stats.max_strips_per_call, strip_count);
        stats.max_alpha_bytes_per_call = @max(stats.max_alpha_bytes_per_call, alpha_bytes);
    }
    return stats;
}

fn countTilesForCall(tiles: []const TileRef, call_index: usize) usize {
    var count: usize = 0;
    for (tiles) |tile| {
        if (tile.call_index == call_index) count += 1;
    }
    return count;
}

const StripOrderStats = struct {
    max_strip_segments: usize = 0,
    multi_call_tiles: usize = 0,
    max_calls_per_tile: usize = 0,
    call_order_breaks: usize = 0,
    spatial_order_breaks: usize = 0,
};

fn stripOrderStats(strips: []const Strip) StripOrderStats {
    var stats: StripOrderStats = .{};
    var tile_start: usize = 0;
    for (strips, 0..) |s, i| {
        stats.max_strip_segments = @max(stats.max_strip_segments, s.segment_indices.count);
        if (i > 0) {
            const prev = strips[i - 1];
            if (s.call_index < prev.call_index) stats.call_order_breaks += 1;
            if (!stripOrderLessOrEqual(prev, s)) stats.spatial_order_breaks += 1;
        }
        if (i + 1 == strips.len or strips[i + 1].x != s.x or strips[i + 1].y != s.y) {
            const calls_in_tile = countCallsInTile(strips[tile_start .. i + 1]);
            stats.max_calls_per_tile = @max(stats.max_calls_per_tile, calls_in_tile);
            if (calls_in_tile > 1) stats.multi_call_tiles += 1;
            tile_start = i + 1;
        }
    }
    return stats;
}

fn stripOrderLessOrEqual(a: Strip, b: Strip) bool {
    if (a.y != b.y) return a.y < b.y;
    if (a.x != b.x) return a.x < b.x;
    return a.call_index <= b.call_index;
}

fn countCallsInTile(strips: []const Strip) usize {
    if (strips.len == 0) return 0;
    var count: usize = 1;
    var last = strips[0].call_index;
    for (strips[1..]) |s| {
        if (s.call_index == last) continue;
        count += 1;
        last = s.call_index;
    }
    return count;
}

fn from(ctx: *anyopaque) *Backend {
    return @ptrCast(@alignCast(ctx));
}

fn createTexture(ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool {
    const self = from(ctx);
    var texture: SparseTexture = .{
        .texture = .{
            .id = id,
            .width = w,
            .height = h,
            .format = fmt,
        },
    };
    const len = byteLen(w, h, fmt) orelse return false;
    if (data) |bytes| {
        if (bytes.len != len) return false;
        texture.pixels.appendSlice(self.gpa, bytes) catch return false;
    } else {
        texture.pixels.resize(self.gpa, len) catch return false;
        @memset(texture.pixels.items, 0);
    }
    errdefer texture.deinit(self.gpa);
    self.textures.put(self.gpa, id, texture) catch return false;
    return true;
}

fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
    const self = from(ctx);
    const texture = self.textures.getPtr(id) orelse return;
    const bpp = bytesPerPixel(texture.texture.format) orelse return;
    if (w == 0 or h == 0) return;
    if (x + w > texture.texture.width or y + h > texture.texture.height) return;
    const row_bytes: usize = @as(usize, w) * bpp;
    if (data.len != row_bytes * @as(usize, h)) return;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src = @as(usize, row) * row_bytes;
        const dst = (@as(usize, y + row) * @as(usize, texture.texture.width) + x) * bpp;
        @memcpy(texture.pixels.items[dst..][0..row_bytes], data[src..][0..row_bytes]);
    }
    texture.markChanged();
}

fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
    const self = from(ctx);
    if (self.textures.fetchSwapRemove(id)) |entry| {
        var texture = entry.value;
        texture.deinit(self.gpa);
    }
}

fn textureSize(ctx: *anyopaque, id: ImageId) ?[2]u32 {
    const texture = from(ctx).textures.get(id) orelse return null;
    return .{ texture.texture.width, texture.texture.height };
}

fn viewport(ctx: *anyopaque, width: f32, height: f32, dpr: f32) void {
    const self = from(ctx);
    self.viewport_width = width;
    self.viewport_height = height;
    self.viewport_dpr = if (dpr > 0) dpr else 1;
    self.active_clip_stack.clearRetainingCapacity();
    self.clip_depth = 0;
}

fn renderFlush(ctx: *anyopaque) void {
    from(ctx).flush();
}

fn deinit(ctx: *anyopaque) void {
    from(ctx).destroy();
}

fn fill(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
    from(ctx).queuePath(.fill, paint, scissor, bounds, 0, paths, points);
}

fn stroke(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void {
    from(ctx).queuePath(.stroke, paint, scissor, .{ 0, 0, 0, 0 }, width, paths, points);
}

fn triangles(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
    const self = from(ctx);
    if (verts.len < 3) return;
    const call_index: u32 = @intCast(self.calls.items.len);
    const range = encode.appendTriangleSegments(&self.segments, self.gpa, call_index, verts) catch return;
    if (range.count == 0) return;
    const clip_range = self.snapshotActiveClips() catch {
        self.segments.shrinkRetainingCapacity(@intCast(range.start));
        return;
    };
    self.calls.append(self.gpa, .{
        .kind = .triangles,
        .paint = paint.*,
        .scissor = scissor.*,
        .segments = range,
        .clips = clip_range,
    }) catch {
        self.call_clip_indices.shrinkRetainingCapacity(@intCast(clip_range.start));
        self.segments.shrinkRetainingCapacity(@intCast(range.start));
    };
}

fn pushClipPath(ctx: *anyopaque, rule: ClipRule, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
    const self = from(ctx);
    const segment_start = self.segments.items.len;
    const range = encode.appendPathSegments(&self.segments, self.gpa, 0, paths, points) catch return;
    if (range.count == 0) {
        self.segments.shrinkRetainingCapacity(@intCast(segment_start));
        return;
    }
    const clip_index: u32 = @intCast(self.clips.items.len);
    self.clips.append(self.gpa, .{
        .rule = encode.fillRuleForClip(rule),
        .bounds = bounds,
        .segments = range,
    }) catch {
        self.segments.shrinkRetainingCapacity(@intCast(segment_start));
        return;
    };
    self.active_clip_stack.append(self.gpa, clip_index) catch {
        _ = self.clips.pop();
        self.segments.shrinkRetainingCapacity(@intCast(segment_start));
        return;
    };
    self.clip_push_count += 1;
    self.clip_depth = self.active_clip_stack.items.len;
    self.max_clip_depth = @max(self.max_clip_depth, self.clip_depth);
    self.last_clip_rule = rule;
    self.last_clip_bounds = bounds;
    self.last_clip_path_count = paths.len;
    self.last_clip_point_count = points.len;
}

fn popClipPath(ctx: *anyopaque) void {
    const self = from(ctx);
    self.clip_pop_count += 1;
    if (self.active_clip_stack.items.len > 0) _ = self.active_clip_stack.pop();
    self.clip_depth = self.active_clip_stack.items.len;
}

fn singleConvexPath(paths: []const PathRange, point_len: usize) bool {
    var valid: usize = 0;
    var convex = false;
    for (paths) |p| {
        if (!p.closed or p.point_count < 3) continue;
        if (@as(usize, p.point_start) + @as(usize, p.point_count) > point_len) continue;
        valid += 1;
        convex = p.convex;
    }
    return valid == 1 and convex;
}

fn byteLen(w: u32, h: u32, format: TexFormat) ?usize {
    const bpp = bytesPerPixel(format) orelse return null;
    return @as(usize, w) * @as(usize, h) * bpp;
}

fn bytesPerPixel(format: TexFormat) ?usize {
    return switch (format) {
        .rgba8 => 4,
        .a8 => 1,
    };
}

fn bytesOf(comptime T: type, count: usize) usize {
    return @sizeOf(T) * count;
}

fn capacityBytes(comptime T: type, capacity: usize) usize {
    return @sizeOf(T) * capacity;
}

fn profileStart(profile: ?*Profile) u64 {
    if (profile == null) return 0;
    return nowNs();
}

fn elapsedSince(start: u64) u64 {
    return nowNs() - start;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
