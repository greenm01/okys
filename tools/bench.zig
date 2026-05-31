const std = @import("std");
const okys = @import("okys");
const bench_options = @import("bench_options");
const bench_scenes = @import("bench_scenes.zig");

const ImageId = okys.types.image.ImageId;
const CapturedFrame = okys.render.frame_capture.CapturedFrame;
const Context = okys.state.context.Context;
const FrameProfile = okys.state.frame_profile.FrameProfile;
const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const StencilBackend = okys.systems.backend_stencil.Backend;
const SparseCall = okys.systems.backend_sparse_strip.EncodedCall;
const SparseProfile = okys.systems.backend_sparse_strip.Profile;
const SparseSegment = okys.systems.backend_sparse_strip.Segment;
const SparseStrip = okys.systems.backend_sparse_strip.Strip;
const SparseTile = okys.systems.backend_sparse_strip.TileRef;
const StencilCall = okys.systems.backend_stencil.Call;
const StencilDrawOp = okys.systems.backend_stencil.DrawOp;
const StencilPath = okys.systems.backend_stencil.QueuedPath;
const StencilUniform = okys.systems.backend_stencil.PaintUniform;
const Vertex = okys.types.path.Vertex;
const frame_ops = okys.ops.frame;

const OKY_ANTIALIAS = bench_scenes.oky_antialias;
const OKY_STENCIL_STROKES = bench_scenes.oky_stencil_strokes;

const warmup_iterations: usize = 5;
const measured_iterations: usize = 50;
const scene_width = bench_scenes.scene_width;
const scene_height = bench_scenes.scene_height;
const active_specs = if (bench_options.tiger_only) bench_scenes.tiger_specs[0..] else bench_scenes.specs[0..];

const Scene = struct {
    name: []const u8,
    frame: *const CapturedFrame,
    draw: bench_scenes.SceneDraw,
};

const Stats = struct {
    calls: usize = 0,
    segments: usize = 0,
    tiles: usize = 0,
    strips: usize = 0,
    vertices: usize = 0,
    indices: usize = 0,
    draw_ops: usize = 0,
    buffer_bytes: usize = 0,
};

const ProfileStats = struct {
    bin_ns: u64 = 0,
    coarse_ns: u64 = 0,
    texture_views_ns: u64 = 0,
    fine_ns: u64 = 0,
    clear_ns: u64 = 0,
    boundary_index_ns: u64 = 0,
    boundary_alpha_ns: u64 = 0,
    boundary_composite_ns: u64 = 0,
    solid_scan_ns: u64 = 0,
    solid_composite_ns: u64 = 0,
    boundary_tiles: usize = 0,
    solid_tiles: usize = 0,
    boundary_pixels: usize = 0,
    solid_pixels: usize = 0,
    composite_pixels: usize = 0,
    solid_fast_pixels: usize = 0,
    opaque_write_pixels: usize = 0,
    rect_fast_calls: usize = 0,
    rect_fast_pixels: usize = 0,
    fill_ops: usize = 0,
    alpha_fill_ops: usize = 0,
    fill_pixels: usize = 0,
    alpha_fill_pixels: usize = 0,
    packet_bytes: usize = 0,
    gpu_fine_upload_bytes: usize = 0,
    packet_capacity_bytes: usize = 0,
    packet_slack_bytes: usize = 0,
    alpha_bytes: usize = 0,
    surface_bytes: usize = 0,
    texture_bytes: usize = 0,
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
    upload_budget_bytes: usize = 0,
    upload_budget_warnings: usize = 0,
    frontend_frame_ns: u64 = 0,
    stroke_outline_ns: u64 = 0,
    stroke_outline_builds: usize = 0,
    stroke_calls: usize = 0,
    stroke_source_paths: usize = 0,
    stroke_source_points: usize = 0,
    stroke_source_open_paths: usize = 0,
    stroke_source_closed_paths: usize = 0,
    stroke_outline_paths: usize = 0,
    stroke_outline_points: usize = 0,
    max_stroke_outline_expansion_pct: usize = 0,
};

const Result = struct {
    replay_ns: u64,
    build_ns: u64,
    stats: Stats,
    profile: ProfileStats = .{},
};

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var scenes: std.ArrayList(Scene) = .empty;
    defer scenes.deinit(gpa);
    try scenes.ensureTotalCapacity(gpa, active_specs.len);
    var frames: std.ArrayList(CapturedFrame) = .empty;
    try frames.ensureTotalCapacity(gpa, active_specs.len);
    defer {
        for (frames.items) |*frame| frame.deinit();
        frames.deinit(gpa);
    }

    for (active_specs) |spec| {
        const frame = try bench_scenes.captureScene(gpa, spec.draw);
        frames.appendAssumeCapacity(frame);
        scenes.appendAssumeCapacity(.{
            .name = spec.name,
            .frame = &frames.items[frames.items.len - 1],
            .draw = spec.draw,
        });
    }

    printHeader();
    for (scenes.items) |scene| {
        const frontend = try benchFrontend(gpa, scene.draw);
        printResult(scene.name, "frontend", "frame_build_capture", frontend);

        const stencil = try benchStencil(gpa, scene.frame);
        printResult(scene.name, "stencil_cover", "cpu_build_only", stencil);

        const sparse = try benchSparse(gpa, scene.frame);
        printResult(scene.name, "sparse_strip", "cpu_raster_composite", sparse);
    }
}

fn benchFrontend(gpa: std.mem.Allocator, draw: bench_scenes.SceneDraw) !Result {
    var frame = CapturedFrame.init(gpa);
    defer frame.deinit();
    const ctx = try Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();
    ctx.installBackend(frame.interface());
    ctx.frame_profile.enabled = true;

    var frame_total: u128 = 0;
    var profile_total: ProfileStats = .{};
    var profile_last: ProfileStats = .{};
    const fake_image: ImageId = @enumFromInt(1);

    var i: usize = 0;
    while (i < warmup_iterations + measured_iterations) : (i += 1) {
        frame.clear();

        const frame_start = nowNs();
        frame_ops.beginFrame(ctx, scene_width, scene_height, 1);
        draw(ctx, fake_image);
        frame_ops.cancelFrame(ctx);
        const frame_ns = nowNs() - frame_start;

        if (i >= warmup_iterations) {
            frame_total += frame_ns;
            const stats = frontendProfileStats(frame_ns, ctx.frame_profile);
            addProfileDurations(&profile_total, stats);
            profile_last = stats;
        }
    }

    return .{
        .replay_ns = 0,
        .build_ns = average(frame_total),
        .stats = .{},
        .profile = averageProfile(profile_total, profile_last),
    };
}

fn benchStencil(gpa: std.mem.Allocator, frame: *const CapturedFrame) !Result {
    var replay_total: u128 = 0;
    var build_total: u128 = 0;
    var stats: Stats = .{};

    var i: usize = 0;
    while (i < warmup_iterations + measured_iterations) : (i += 1) {
        const backend = try StencilBackend.createWithFlags(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
        defer backend.destroy();
        backend.fill_rule = .even_odd;

        const replay_start = nowNs();
        frame.replay(backend.interface());
        const replay_ns = nowNs() - replay_start;

        const build_start = nowNs();
        if (!backend.buildStencilPass()) return error.BenchmarkBuildFailed;
        const build_ns = nowNs() - build_start;

        if (i >= warmup_iterations) {
            replay_total += replay_ns;
            build_total += build_ns;
            stats = stencilStats(backend);
        }
    }

    return .{
        .replay_ns = average(replay_total),
        .build_ns = average(build_total),
        .stats = stats,
    };
}

fn benchSparse(gpa: std.mem.Allocator, frame: *const CapturedFrame) !Result {
    var replay_total: u128 = 0;
    var build_total: u128 = 0;
    var profile_total: ProfileStats = .{};
    var profile_last: ProfileStats = .{};
    var stats: Stats = .{};

    var i: usize = 0;
    while (i < warmup_iterations + measured_iterations) : (i += 1) {
        const backend = try SparseBackend.create(gpa);
        defer backend.destroy();
        backend.fill_rule = .even_odd;

        const replay_start = nowNs();
        frame.replay(backend.interface());
        const replay_ns = nowNs() - replay_start;

        var profile: SparseProfile = .{};
        const build_start = nowNs();
        if (!backend.buildProfiled(&profile)) return error.BenchmarkBuildFailed;
        const build_ns = nowNs() - build_start;

        if (i >= warmup_iterations) {
            replay_total += replay_ns;
            build_total += build_ns;
            const profile_stats = profileStats(profile);
            addProfileDurations(&profile_total, profile_stats);
            profile_last = profile_stats;
            stats = sparseStats(backend);
        }
    }

    return .{
        .replay_ns = average(replay_total),
        .build_ns = average(build_total),
        .stats = stats,
        .profile = averageProfile(profile_total, profile_last),
    };
}

fn average(total: u128) u64 {
    return @intCast(total / measured_iterations);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn stencilStats(backend: *const StencilBackend) Stats {
    var texture_bytes: usize = 0;
    for (backend.textures.values()) |texture| {
        texture_bytes += texture.pixels.items.len;
    }

    return .{
        .calls = backend.calls.items.len,
        .vertices = backend.vertices.items.len,
        .indices = backend.indices.items.len,
        .draw_ops = backend.draw_ops.items.len,
        .buffer_bytes = bytesOf(StencilCall, backend.calls.items.len) +
            bytesOf(StencilPath, backend.paths.items.len) +
            bytesOf(Vertex, backend.vertices.items.len) +
            bytesOf(u16, backend.indices.items.len) +
            bytesOf(StencilUniform, backend.uniforms.items.len) +
            bytesOf(StencilDrawOp, backend.draw_ops.items.len) +
            texture_bytes,
    };
}

fn sparseStats(backend: *const SparseBackend) Stats {
    var texture_bytes: usize = 0;
    for (backend.textures.values()) |texture| {
        texture_bytes += texture.pixels.items.len;
    }

    return .{
        .calls = backend.calls.items.len,
        .segments = backend.segments.items.len,
        .tiles = backend.tiles.items.len,
        .strips = backend.strips.items.len,
        .buffer_bytes = bytesOf(SparseCall, backend.calls.items.len) +
            bytesOf(SparseSegment, backend.segments.items.len) +
            bytesOf(SparseTile, backend.tiles.items.len) +
            bytesOf(SparseStrip, backend.strips.items.len) +
            bytesOf(u32, backend.strip_segment_indices.items.len) +
            backend.alphas.items.len +
            backend.surface.items.len +
            texture_bytes,
    };
}

fn profileStats(profile: SparseProfile) ProfileStats {
    return .{
        .bin_ns = profile.bin_ns,
        .coarse_ns = profile.coarse_ns,
        .texture_views_ns = profile.texture_views_ns,
        .fine_ns = profile.fine_ns,
        .clear_ns = profile.fine_profile.clear_ns,
        .boundary_index_ns = profile.fine_profile.boundary_index_ns,
        .boundary_alpha_ns = profile.fine_profile.boundary_alpha_ns,
        .boundary_composite_ns = profile.fine_profile.boundary_composite_ns,
        .solid_scan_ns = profile.fine_profile.solid_scan_ns,
        .solid_composite_ns = profile.fine_profile.solid_composite_ns,
        .boundary_tiles = profile.fine_profile.boundary_tiles,
        .solid_tiles = profile.fine_profile.solid_tiles,
        .boundary_pixels = profile.fine_profile.boundary_pixels,
        .solid_pixels = profile.fine_profile.solid_pixels,
        .composite_pixels = profile.fine_profile.composite_pixels,
        .solid_fast_pixels = profile.fine_profile.solid_fast_pixels,
        .opaque_write_pixels = profile.fine_profile.opaque_write_pixels,
        .rect_fast_calls = profile.fine_profile.rect_fast_calls,
        .rect_fast_pixels = profile.fine_profile.rect_fast_pixels,
        .fill_ops = profile.fine_profile.fill_ops,
        .alpha_fill_ops = profile.fine_profile.alpha_fill_ops,
        .fill_pixels = profile.fine_profile.fill_pixels,
        .alpha_fill_pixels = profile.fine_profile.alpha_fill_pixels,
        .packet_bytes = profile.frame_packet.frame_packet_bytes,
        .gpu_fine_upload_bytes = profile.frame_packet.gpu_fine_upload_bytes,
        .packet_capacity_bytes = profile.frame_packet.packet_capacity_bytes,
        .packet_slack_bytes = profile.frame_packet.packet_slack_bytes,
        .alpha_bytes = profile.frame_packet.alpha_bytes,
        .surface_bytes = profile.frame_packet.surface_bytes,
        .texture_bytes = profile.frame_packet.texture_bytes,
        .max_strip_segments = profile.frame_packet.max_strip_segments,
        .multi_call_tiles = profile.frame_packet.multi_call_tiles,
        .max_calls_per_tile = profile.frame_packet.max_calls_per_tile,
        .strip_call_order_breaks = profile.frame_packet.strip_call_order_breaks,
        .strip_spatial_order_breaks = profile.frame_packet.strip_spatial_order_breaks,
        .frame_bounds_x0 = profile.frame_packet.frame_bounds_x0,
        .frame_bounds_y0 = profile.frame_packet.frame_bounds_y0,
        .frame_bounds_x1 = profile.frame_packet.frame_bounds_x1,
        .frame_bounds_y1 = profile.frame_packet.frame_bounds_y1,
        .command_bound_pixels = profile.frame_packet.command_bound_pixels,
        .candidate_tiles_from_bounds = profile.frame_packet.candidate_tiles_from_bounds,
        .empty_bound_calls = profile.frame_packet.empty_bound_calls,
        .clipped_out_calls = profile.frame_packet.clipped_out_calls,
        .fill_box_candidate_calls = profile.frame_packet.fill_box_candidate_calls,
        .max_segments_per_call = profile.frame_packet.max_segments_per_call,
        .max_tile_refs_per_call = profile.frame_packet.max_tile_refs_per_call,
        .max_strips_per_call = profile.frame_packet.max_strips_per_call,
        .max_alpha_bytes_per_call = profile.frame_packet.max_alpha_bytes_per_call,
        .dense_strip_warnings = profile.frame_packet.dense_strip_warnings,
        .upload_budget_bytes = profile.frame_packet.upload_budget_bytes,
        .upload_budget_warnings = profile.frame_packet.upload_budget_warnings,
    };
}

fn frontendProfileStats(frame_ns: u64, profile: FrameProfile) ProfileStats {
    return .{
        .frontend_frame_ns = frame_ns,
        .stroke_outline_ns = profile.stroke_outline_ns,
        .stroke_outline_builds = profile.stroke_outline_builds,
        .stroke_calls = profile.stroke_calls,
        .stroke_source_paths = profile.stroke_source_paths,
        .stroke_source_points = profile.stroke_source_points,
        .stroke_source_open_paths = profile.stroke_source_open_paths,
        .stroke_source_closed_paths = profile.stroke_source_closed_paths,
        .stroke_outline_paths = profile.stroke_outline_paths,
        .stroke_outline_points = profile.stroke_outline_points,
        .max_stroke_outline_expansion_pct = profile.max_stroke_outline_expansion_pct,
    };
}

fn addProfileDurations(total: *ProfileStats, profile: ProfileStats) void {
    total.frontend_frame_ns += profile.frontend_frame_ns;
    total.stroke_outline_ns += profile.stroke_outline_ns;
    total.bin_ns += profile.bin_ns;
    total.coarse_ns += profile.coarse_ns;
    total.texture_views_ns += profile.texture_views_ns;
    total.fine_ns += profile.fine_ns;
    total.clear_ns += profile.clear_ns;
    total.boundary_index_ns += profile.boundary_index_ns;
    total.boundary_alpha_ns += profile.boundary_alpha_ns;
    total.boundary_composite_ns += profile.boundary_composite_ns;
    total.solid_scan_ns += profile.solid_scan_ns;
    total.solid_composite_ns += profile.solid_composite_ns;
}

fn averageProfile(total: ProfileStats, last: ProfileStats) ProfileStats {
    return .{
        .frontend_frame_ns = average(total.frontend_frame_ns),
        .stroke_outline_ns = average(total.stroke_outline_ns),
        .stroke_outline_builds = last.stroke_outline_builds,
        .stroke_calls = last.stroke_calls,
        .stroke_source_paths = last.stroke_source_paths,
        .stroke_source_points = last.stroke_source_points,
        .stroke_source_open_paths = last.stroke_source_open_paths,
        .stroke_source_closed_paths = last.stroke_source_closed_paths,
        .stroke_outline_paths = last.stroke_outline_paths,
        .stroke_outline_points = last.stroke_outline_points,
        .max_stroke_outline_expansion_pct = last.max_stroke_outline_expansion_pct,
        .bin_ns = average(total.bin_ns),
        .coarse_ns = average(total.coarse_ns),
        .texture_views_ns = average(total.texture_views_ns),
        .fine_ns = average(total.fine_ns),
        .clear_ns = average(total.clear_ns),
        .boundary_index_ns = average(total.boundary_index_ns),
        .boundary_alpha_ns = average(total.boundary_alpha_ns),
        .boundary_composite_ns = average(total.boundary_composite_ns),
        .solid_scan_ns = average(total.solid_scan_ns),
        .solid_composite_ns = average(total.solid_composite_ns),
        .boundary_tiles = last.boundary_tiles,
        .solid_tiles = last.solid_tiles,
        .boundary_pixels = last.boundary_pixels,
        .solid_pixels = last.solid_pixels,
        .composite_pixels = last.composite_pixels,
        .solid_fast_pixels = last.solid_fast_pixels,
        .opaque_write_pixels = last.opaque_write_pixels,
        .rect_fast_calls = last.rect_fast_calls,
        .rect_fast_pixels = last.rect_fast_pixels,
        .fill_ops = last.fill_ops,
        .alpha_fill_ops = last.alpha_fill_ops,
        .fill_pixels = last.fill_pixels,
        .alpha_fill_pixels = last.alpha_fill_pixels,
        .packet_bytes = last.packet_bytes,
        .gpu_fine_upload_bytes = last.gpu_fine_upload_bytes,
        .packet_capacity_bytes = last.packet_capacity_bytes,
        .packet_slack_bytes = last.packet_slack_bytes,
        .alpha_bytes = last.alpha_bytes,
        .surface_bytes = last.surface_bytes,
        .texture_bytes = last.texture_bytes,
        .max_strip_segments = last.max_strip_segments,
        .multi_call_tiles = last.multi_call_tiles,
        .max_calls_per_tile = last.max_calls_per_tile,
        .strip_call_order_breaks = last.strip_call_order_breaks,
        .strip_spatial_order_breaks = last.strip_spatial_order_breaks,
        .frame_bounds_x0 = last.frame_bounds_x0,
        .frame_bounds_y0 = last.frame_bounds_y0,
        .frame_bounds_x1 = last.frame_bounds_x1,
        .frame_bounds_y1 = last.frame_bounds_y1,
        .command_bound_pixels = last.command_bound_pixels,
        .candidate_tiles_from_bounds = last.candidate_tiles_from_bounds,
        .empty_bound_calls = last.empty_bound_calls,
        .clipped_out_calls = last.clipped_out_calls,
        .fill_box_candidate_calls = last.fill_box_candidate_calls,
        .max_segments_per_call = last.max_segments_per_call,
        .max_tile_refs_per_call = last.max_tile_refs_per_call,
        .max_strips_per_call = last.max_strips_per_call,
        .max_alpha_bytes_per_call = last.max_alpha_bytes_per_call,
        .dense_strip_warnings = last.dense_strip_warnings,
        .upload_budget_bytes = last.upload_budget_bytes,
        .upload_budget_warnings = last.upload_budget_warnings,
    };
}

fn bytesOf(comptime T: type, count: usize) usize {
    return @sizeOf(T) * count;
}

fn printHeader() void {
    _ = std.c.printf("scene\tbackend\ttiming_scope\titerations\treplay_avg_ns\tbuild_avg_ns\ttotal_avg_ns\tcalls\tsegments\ttiles\tstrips\tvertices\tindices\tdraw_ops\tbuffer_bytes\tpacket_bytes\tgpu_fine_upload_bytes\tpacket_capacity_bytes\tpacket_slack_bytes\talpha_bytes\tsurface_bytes\ttexture_bytes\tmax_strip_segments\tmulti_call_tiles\tmax_calls_per_tile\tstrip_call_order_breaks\tstrip_spatial_order_breaks\tfrontend_frame_ns\tstroke_outline_ns\tstroke_outline_builds\tstroke_calls\tstroke_source_paths\tstroke_source_points\tstroke_source_open_paths\tstroke_source_closed_paths\tstroke_outline_paths\tstroke_outline_points\tmax_stroke_outline_expansion_pct\tbin_ns\tcoarse_ns\ttexture_views_ns\tfine_ns\tclear_ns\tboundary_index_ns\tboundary_alpha_ns\tboundary_composite_ns\tsolid_scan_ns\tsolid_composite_ns\tboundary_tiles\tsolid_tiles\tboundary_pixels\tsolid_pixels\tcomposite_pixels\tsolid_fast_pixels\topaque_write_pixels\trect_fast_calls\trect_fast_pixels\tfill_ops\talpha_fill_ops\tfill_pixels\talpha_fill_pixels\tframe_bounds_x0\tframe_bounds_y0\tframe_bounds_x1\tframe_bounds_y1\tcommand_bound_pixels\tcandidate_tiles_from_bounds\tempty_bound_calls\tclipped_out_calls\tfill_box_candidate_calls\tmax_segments_per_call\tmax_tile_refs_per_call\tmax_strips_per_call\tmax_alpha_bytes_per_call\tdense_strip_warnings\tupload_budget_bytes\tupload_budget_warnings\n");
}

fn printResult(scene_name: []const u8, backend_name: []const u8, timing_scope: []const u8, result: Result) void {
    _ = std.c.printf(
        "%.*s\t%.*s\t%.*s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\n",
        @as(c_int, @intCast(scene_name.len)),
        cString(scene_name),
        @as(c_int, @intCast(backend_name.len)),
        cString(backend_name),
        @as(c_int, @intCast(timing_scope.len)),
        cString(timing_scope),
        u64ForPrint(measured_iterations),
        u64ForPrint(result.replay_ns),
        u64ForPrint(result.build_ns),
        u64ForPrint(result.replay_ns + result.build_ns),
        u64ForPrint(result.stats.calls),
        u64ForPrint(result.stats.segments),
        u64ForPrint(result.stats.tiles),
        u64ForPrint(result.stats.strips),
        u64ForPrint(result.stats.vertices),
        u64ForPrint(result.stats.indices),
        u64ForPrint(result.stats.draw_ops),
        u64ForPrint(result.stats.buffer_bytes),
        u64ForPrint(result.profile.packet_bytes),
        u64ForPrint(result.profile.gpu_fine_upload_bytes),
        u64ForPrint(result.profile.packet_capacity_bytes),
        u64ForPrint(result.profile.packet_slack_bytes),
        u64ForPrint(result.profile.alpha_bytes),
        u64ForPrint(result.profile.surface_bytes),
        u64ForPrint(result.profile.texture_bytes),
        u64ForPrint(result.profile.max_strip_segments),
        u64ForPrint(result.profile.multi_call_tiles),
        u64ForPrint(result.profile.max_calls_per_tile),
        u64ForPrint(result.profile.strip_call_order_breaks),
        u64ForPrint(result.profile.strip_spatial_order_breaks),
        u64ForPrint(result.profile.frontend_frame_ns),
        u64ForPrint(result.profile.stroke_outline_ns),
        u64ForPrint(result.profile.stroke_outline_builds),
        u64ForPrint(result.profile.stroke_calls),
        u64ForPrint(result.profile.stroke_source_paths),
        u64ForPrint(result.profile.stroke_source_points),
        u64ForPrint(result.profile.stroke_source_open_paths),
        u64ForPrint(result.profile.stroke_source_closed_paths),
        u64ForPrint(result.profile.stroke_outline_paths),
        u64ForPrint(result.profile.stroke_outline_points),
        u64ForPrint(result.profile.max_stroke_outline_expansion_pct),
        u64ForPrint(result.profile.bin_ns),
        u64ForPrint(result.profile.coarse_ns),
        u64ForPrint(result.profile.texture_views_ns),
        u64ForPrint(result.profile.fine_ns),
        u64ForPrint(result.profile.clear_ns),
        u64ForPrint(result.profile.boundary_index_ns),
        u64ForPrint(result.profile.boundary_alpha_ns),
        u64ForPrint(result.profile.boundary_composite_ns),
        u64ForPrint(result.profile.solid_scan_ns),
        u64ForPrint(result.profile.solid_composite_ns),
        u64ForPrint(result.profile.boundary_tiles),
        u64ForPrint(result.profile.solid_tiles),
        u64ForPrint(result.profile.boundary_pixels),
        u64ForPrint(result.profile.solid_pixels),
        u64ForPrint(result.profile.composite_pixels),
        u64ForPrint(result.profile.solid_fast_pixels),
        u64ForPrint(result.profile.opaque_write_pixels),
        u64ForPrint(result.profile.rect_fast_calls),
        u64ForPrint(result.profile.rect_fast_pixels),
        u64ForPrint(result.profile.fill_ops),
        u64ForPrint(result.profile.alpha_fill_ops),
        u64ForPrint(result.profile.fill_pixels),
        u64ForPrint(result.profile.alpha_fill_pixels),
        u64ForPrint(result.profile.frame_bounds_x0),
        u64ForPrint(result.profile.frame_bounds_y0),
        u64ForPrint(result.profile.frame_bounds_x1),
        u64ForPrint(result.profile.frame_bounds_y1),
        u64ForPrint(result.profile.command_bound_pixels),
        u64ForPrint(result.profile.candidate_tiles_from_bounds),
        u64ForPrint(result.profile.empty_bound_calls),
        u64ForPrint(result.profile.clipped_out_calls),
        u64ForPrint(result.profile.fill_box_candidate_calls),
        u64ForPrint(result.profile.max_segments_per_call),
        u64ForPrint(result.profile.max_tile_refs_per_call),
        u64ForPrint(result.profile.max_strips_per_call),
        u64ForPrint(result.profile.max_alpha_bytes_per_call),
        u64ForPrint(result.profile.dense_strip_warnings),
        u64ForPrint(result.profile.upload_budget_bytes),
        u64ForPrint(result.profile.upload_budget_warnings),
    );
}

fn cString(value: []const u8) [*c]const u8 {
    return @ptrCast(value.ptr);
}

fn u64ForPrint(value: anytype) c_ulonglong {
    return @intCast(value);
}
