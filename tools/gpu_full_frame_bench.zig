const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");
const bench_scenes = @import("bench_scenes.zig");
const gpu_fence_wait = @import("gpu_fence_wait");
const gpu_full_frame_options = @import("gpu_full_frame_options");

const app = sokol.app;
const glue = sokol.glue;

const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const GpuFinePacket = okys.systems.backend_sparse_strip.GpuFinePacket;
const frame_ops = okys.ops.frame;
const sokol_device = okys.render.sokol_device;

const gpa = std.heap.c_allocator;
const warmup_frames: usize = 30;
const measured_frames: usize = 300;
const frame_limit = warmup_frames + measured_frames;
const scene_width_u32: u32 = @intFromFloat(bench_scenes.scene_width);
const scene_height_u32: u32 = @intFromFloat(bench_scenes.scene_height);

const TimingMode = enum(u8) {
    full_frame = 0,
    texture = 1,
    empty = 2,
    upload = 3,
    clear = 4,

    fn label(self: TimingMode) [:0]const u8 {
        return switch (self) {
            .full_frame => "gpu_full_frame",
            .texture => "gpu_texture",
            .empty => "gpu_empty",
            .upload => "gpu_upload",
            .clear => "gpu_clear",
        };
    }

    fn title(self: TimingMode) [:0]const u8 {
        return switch (self) {
            .full_frame => "Okys Tiger full-frame GPU benchmark",
            .texture => "Okys Tiger texture GPU benchmark",
            .empty => "Okys Tiger empty GPU benchmark",
            .upload => "Okys Tiger GPU upload benchmark",
            .clear => "Okys Tiger GPU clear benchmark",
        };
    }

    fn needsPacket(self: TimingMode) bool {
        return self != .empty;
    }
};

const Accumulator = struct {
    frame_ns: u128 = 0,
    frontend_ns: u128 = 0,
    build_ns: u128 = 0,
    bin_ns: u128 = 0,
    coarse_ns: u128 = 0,
    texture_views_ns: u128 = 0,
    gpu_fine_ns: u128 = 0,
    direct_strip_estimate_ns: u128 = 0,
    gpu_pack_records_ns: u128 = 0,
    gpu_strip_group_ns: u128 = 0,
    gpu_boundary_mark_ns: u128 = 0,
    gpu_fill_task_ns: u128 = 0,
    gpu_crossing_collect_ns: u128 = 0,
    gpu_crossing_sort_ns: u128 = 0,
    gpu_fill_emit_ns: u128 = 0,
    crossing_rows: u128 = 0,
    crossing_items: u128 = 0,
    crossing_sort_rows: u128 = 0,
    max_crossings_per_row: usize = 0,
    boundary_checks: u128 = 0,
    boundary_hits: u128 = 0,
    fill_candidates: u128 = 0,
    alpha_segment_refs: u128 = 0,
    max_alpha_segments_per_task: usize = 0,
    cpu_encode_ns: u128 = 0,
    commit_ns: u128 = 0,
    resource_ns: u128 = 0,
    upload_ns: u128 = 0,
    compute_encode_ns: u128 = 0,
    blit_encode_ns: u128 = 0,
    gpu_wait_ns: u128 = 0,
    gpu_wait_samples: usize = 0,
    gpu_wait_kind: gpu_fence_wait.Kind = .none,
    gpu_wait_status: gpu_fence_wait.Status = .unsupported_backend,
    calls: usize = 0,
    tasks: usize = 0,
    dispatches: usize = 0,
    upload_bytes: usize = 0,
    nonempty_calls: usize = 0,
    fill_tasks: usize = 0,
    alpha_fill_tasks: usize = 0,
    segment_indices: usize = 0,
    fill_span_tiles: usize = 0,
    max_fill_span_tiles: usize = 0,
    calls_bytes: usize = 0,
    segments_bytes: usize = 0,
    tasks_bytes: usize = 0,
    segment_indices_bytes: usize = 0,
    direct_supported: bool = false,
    direct_calls: usize = 0,
    direct_eligible_calls: usize = 0,
    direct_fallback_calls: usize = 0,
    direct_fallback_images: usize = 0,
    direct_fallback_scissors: usize = 0,
    direct_fallback_clips: usize = 0,
    direct_fallback_gradients: usize = 0,
    direct_fallback_triangles: usize = 0,
    direct_strip_instances: usize = 0,
    direct_alpha_strip_instances: usize = 0,
    direct_solid_span_instances: usize = 0,
    direct_solid_span_tiles: usize = 0,
    direct_max_solid_span_tiles: usize = 0,
    direct_alpha_bytes: usize = 0,
    direct_strip_instance_bytes: usize = 0,
    direct_paint_bytes: usize = 0,
    direct_upload_bytes: usize = 0,
    direct_upload_savings_bytes: usize = 0,
    direct_compact_strip_instances: usize = 0,
    direct_compact_alpha_strip_instances: usize = 0,
    direct_compact_solid_span_instances: usize = 0,
    direct_compact_alpha_bytes: usize = 0,
    direct_compact_strip_instance_bytes: usize = 0,
    direct_compact_upload_bytes: usize = 0,
    direct_compact_upload_savings_bytes: usize = 0,
    batch_groups: usize = 0,
    batch_dispatches: usize = 0,
    batch_calls: usize = 0,
    batch_tasks: usize = 0,
    max_batch_calls: usize = 0,
    max_batch_tasks: usize = 0,
    batch_break_task_gap: usize = 0,
    batch_break_image_mismatch: usize = 0,
    batch_break_invalid_bounds: usize = 0,
    batch_break_overlap: usize = 0,
    fallback: sokol_device.SparseFineFallback = .none,

    fn add(
        self: *Accumulator,
        frame_ns: u64,
        frontend_ns: u64,
        build_ns: u64,
        profile: okys.systems.backend_sparse_strip.Profile,
        commit_ns: u64,
        gpu_wait: gpu_fence_wait.Result,
        timing: sokol_device.SparseFineSubmitTiming,
    ) void {
        self.frame_ns += frame_ns;
        self.frontend_ns += frontend_ns;
        self.build_ns += build_ns;
        self.bin_ns += profile.bin_ns;
        self.coarse_ns += profile.coarse_ns;
        self.texture_views_ns += profile.texture_views_ns;
        self.gpu_fine_ns += profile.gpu_fine_ns;
        self.direct_strip_estimate_ns += profile.direct_strip_estimate_ns;
        self.gpu_pack_records_ns += profile.gpu_fine_profile.pack_records_ns;
        self.gpu_strip_group_ns += profile.gpu_fine_profile.strip_group_ns;
        self.gpu_boundary_mark_ns += profile.gpu_fine_profile.boundary_mark_ns;
        self.gpu_fill_task_ns += profile.gpu_fine_profile.fill_task_ns;
        self.gpu_crossing_collect_ns += profile.gpu_fine_profile.crossing_collect_ns;
        self.gpu_crossing_sort_ns += profile.gpu_fine_profile.crossing_sort_ns;
        self.gpu_fill_emit_ns += profile.gpu_fine_profile.fill_emit_ns;
        self.crossing_rows += profile.gpu_fine_profile.crossing_rows;
        self.crossing_items += profile.gpu_fine_profile.crossing_items;
        self.crossing_sort_rows += profile.gpu_fine_profile.crossing_sort_rows;
        self.max_crossings_per_row = @max(self.max_crossings_per_row, profile.gpu_fine_profile.max_crossings_per_row);
        self.boundary_checks += profile.gpu_fine_profile.boundary_checks;
        self.boundary_hits += profile.gpu_fine_profile.boundary_hits;
        self.fill_candidates += profile.gpu_fine_profile.fill_candidates;
        self.alpha_segment_refs += profile.gpu_fine_profile.alpha_segment_refs;
        self.max_alpha_segments_per_task = @max(self.max_alpha_segments_per_task, profile.gpu_fine_profile.max_alpha_segments_per_task);
        self.cpu_encode_ns += timing.total_ns;
        self.commit_ns += commit_ns;
        self.resource_ns += timing.resource_ns;
        self.upload_ns += timing.upload_ns;
        self.compute_encode_ns += timing.compute_encode_ns;
        self.blit_encode_ns += timing.blit_encode_ns;
        if (gpu_wait.ns) |wait_ns| {
            self.gpu_wait_ns += wait_ns;
            self.gpu_wait_samples += 1;
        }
        self.gpu_wait_kind = gpu_wait.kind;
        self.gpu_wait_status = gpu_wait.status;
        self.calls = timing.calls;
        self.tasks = timing.tasks;
        self.dispatches = timing.dispatches;
        self.upload_bytes = timing.upload_bytes;
        self.nonempty_calls = timing.nonempty_calls;
        self.fill_tasks = timing.fill_tasks;
        self.alpha_fill_tasks = timing.alpha_fill_tasks;
        self.segment_indices = timing.segment_indices;
        self.fill_span_tiles = timing.fill_span_tiles;
        self.max_fill_span_tiles = timing.max_fill_span_tiles;
        self.calls_bytes = timing.calls_bytes;
        self.segments_bytes = timing.segments_bytes;
        self.tasks_bytes = timing.tasks_bytes;
        self.segment_indices_bytes = timing.segment_indices_bytes;
        self.direct_supported = profile.direct_strip_estimate.supported;
        self.direct_calls = profile.direct_strip_estimate.calls;
        self.direct_eligible_calls = profile.direct_strip_estimate.eligible_calls;
        self.direct_fallback_calls = profile.direct_strip_estimate.fallback_calls;
        self.direct_fallback_images = profile.direct_strip_estimate.fallback_images;
        self.direct_fallback_scissors = profile.direct_strip_estimate.fallback_scissors;
        self.direct_fallback_clips = profile.direct_strip_estimate.fallback_clips;
        self.direct_fallback_gradients = profile.direct_strip_estimate.fallback_gradients;
        self.direct_fallback_triangles = profile.direct_strip_estimate.fallback_triangles;
        self.direct_strip_instances = profile.direct_strip_estimate.strip_instances;
        self.direct_alpha_strip_instances = profile.direct_strip_estimate.alpha_strip_instances;
        self.direct_solid_span_instances = profile.direct_strip_estimate.solid_span_instances;
        self.direct_solid_span_tiles = profile.direct_strip_estimate.solid_span_tiles;
        self.direct_max_solid_span_tiles = profile.direct_strip_estimate.max_solid_span_tiles;
        self.direct_alpha_bytes = profile.direct_strip_estimate.alpha_bytes;
        self.direct_strip_instance_bytes = profile.direct_strip_estimate.strip_instance_bytes;
        self.direct_paint_bytes = profile.direct_strip_estimate.paint_bytes;
        self.direct_upload_bytes = profile.direct_strip_estimate.upload_bytes;
        self.direct_upload_savings_bytes = profile.direct_strip_estimate.uploadSavingsVs(timing.upload_bytes);
        self.direct_compact_strip_instances = profile.direct_strip_estimate.compact_strip_instances;
        self.direct_compact_alpha_strip_instances = profile.direct_strip_estimate.compact_alpha_strip_instances;
        self.direct_compact_solid_span_instances = profile.direct_strip_estimate.compact_solid_span_instances;
        self.direct_compact_alpha_bytes = profile.direct_strip_estimate.compact_alpha_bytes;
        self.direct_compact_strip_instance_bytes = profile.direct_strip_estimate.compact_strip_instance_bytes;
        self.direct_compact_upload_bytes = profile.direct_strip_estimate.compact_upload_bytes;
        self.direct_compact_upload_savings_bytes = profile.direct_strip_estimate.compactUploadSavingsVs(timing.upload_bytes);
        self.batch_groups = timing.batch_groups;
        self.batch_dispatches = timing.batch_dispatches;
        self.batch_calls = timing.batch_calls;
        self.batch_tasks = timing.batch_tasks;
        self.max_batch_calls = timing.max_batch_calls;
        self.max_batch_tasks = timing.max_batch_tasks;
        self.batch_break_task_gap = timing.batch_break_task_gap;
        self.batch_break_image_mismatch = timing.batch_break_image_mismatch;
        self.batch_break_invalid_bounds = timing.batch_break_invalid_bounds;
        self.batch_break_overlap = timing.batch_break_overlap;
        self.fallback = timing.fallback;
    }
};

var device: sokol_device.Device = .{};
var device_initialized = false;
var failed = false;
var ctx: ?*bench_scenes.Context = null;
var backend: ?*SparseBackend = null;
var packet: GpuFinePacket = .{};
var frame_index: usize = 0;
var accum: Accumulator = .{};
const timing_mode: TimingMode = @enumFromInt(gpu_full_frame_options.timing_mode);

pub fn main() void {
    printHeader();
    app.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = scene_width_u32,
        .height = scene_height_u32,
        .sample_count = 1,
        .swap_interval = 0,
        .high_dpi = false,
        .window_title = timing_mode.title(),
    });
    if (failed) std.process.exit(1);
}

fn init() callconv(.c) void {
    device = sokol_device.Device.initOwned(.{ .environment = glue.environment() });
    device_initialized = true;
    device.resize(bench_scenes.scene_width, bench_scenes.scene_height, 1);

    const sparse_backend = SparseBackend.create(gpa) catch |err| {
        fail("sparse backend setup failed: {s}", .{@errorName(err)});
        return;
    };
    sparse_backend.fill_rule = .even_odd;
    backend = sparse_backend;

    const context = bench_scenes.Context.create(gpa, bench_scenes.oky_antialias | bench_scenes.oky_stencil_strokes) catch |err| {
        fail("context setup failed: {s}", .{@errorName(err)});
        return;
    };
    context.backend = sparse_backend.interface();
    ctx = context;
}

fn frame() callconv(.c) void {
    if (failed) return;

    device.resize(bench_scenes.scene_width, bench_scenes.scene_height, 1);

    const frame_start = nowNs();

    var frontend_ns: u64 = 0;
    var build_ns: u64 = 0;
    var profile: okys.systems.backend_sparse_strip.Profile = .{};
    if (timing_mode.needsPacket()) {
        const context = ctx orelse {
            fail("missing context", .{});
            return;
        };
        const sparse_backend = backend orelse {
            fail("missing sparse backend", .{});
            return;
        };
        sparse_backend.clearQueued();

        const frontend_start = nowNs();
        frame_ops.beginFrame(context, bench_scenes.scene_width, bench_scenes.scene_height, 1);
        bench_scenes.drawTigerScene(context, .none);
        frame_ops.cancelFrame(context);
        frontend_ns = nowNs() - frontend_start;

        const build_start = nowNs();
        if (!sparse_backend.buildGpuFinePacket(&packet, &profile)) {
            fail("sparse GPU packet build failed", .{});
            return;
        }
        build_ns = nowNs() - build_start;
    }

    var timing: sokol_device.SparseFineSubmitTiming = .{};
    const drew = switch (timing_mode) {
        .empty => blk: {
            timing.ok = true;
            break :blk true;
        },
        .upload => device.uploadSparseFineTextureTimed(
            &packet,
            &.{},
            scene_width_u32,
            scene_height_u32,
            &timing,
        ),
        .clear => device.clearSparseFineTextureTimed(
            &packet,
            &.{},
            scene_width_u32,
            scene_height_u32,
            &timing,
        ),
        .texture => device.drawSparseFineTextureTimed(
            &packet,
            &.{},
            scene_width_u32,
            scene_height_u32,
            &timing,
        ),
        .full_frame => blk: {
            const sparse_backend = backend orelse {
                fail("missing sparse backend", .{});
                return;
            };
            const pass = sokol_device.swapchainPassWithAction(
                sokol_device.clearPassAction(.{ .r = 0.08, .g = 0.09, .b = 0.10, .a = 1.0 }),
                glue.swapchain(),
            );
            break :blk device.drawSparseFineSurfaceTimed(
                pass,
                &packet,
                sparse_backend.segments.items,
                &.{},
                scene_width_u32,
                scene_height_u32,
                .{
                    .x = 0,
                    .y = 0,
                    .width = bench_scenes.scene_width,
                    .height = bench_scenes.scene_height,
                },
                bench_scenes.scene_width,
                bench_scenes.scene_height,
                &timing,
            );
        },
    };
    if (!drew or timing.fallback != .none) {
        fail("sparse GPU fallback: {s}", .{fallbackName(timing.fallback)});
        return;
    }

    const commit_start = nowNs();
    sokol_device.Device.commit();
    const commit_ns = nowNs() - commit_start;
    const gpu_wait = gpu_fence_wait.measure(.{
        .device = &device,
        .allocator = gpa,
        .target_width = scene_width_u32,
        .target_height = scene_height_u32,
    });
    const frame_ns = nowNs() - frame_start;

    if (frame_index >= warmup_frames) {
        accum.add(frame_ns, frontend_ns, build_ns, profile, commit_ns, gpu_wait, timing);
    }

    frame_index += 1;
    if (frame_index == frame_limit) {
        printResult(accum);
        app.requestQuit();
    }
}

fn cleanup() callconv(.c) void {
    packet.deinit(gpa);
    if (ctx) |context| {
        context.backend = null;
        context.destroy();
        ctx = null;
    }
    if (backend) |sparse_backend| {
        sparse_backend.destroy();
        backend = null;
    }
    if (device_initialized) {
        device.deinit();
        device_initialized = false;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    failed = true;
    std.debug.print("okys full-frame gpu bench: " ++ fmt ++ "\n", args);
    app.requestQuit();
}

fn printHeader() void {
    _ = std.c.printf("scene\tbackend\ttiming_scope\tframes\tframe_avg_ns\tsubmit_avg_ns\tfrontend_avg_ns\tbuild_avg_ns\tbin_avg_ns\tcoarse_avg_ns\ttexture_views_avg_ns\tgpu_fine_avg_ns\tdirect_strip_estimate_avg_ns\tgpu_pack_records_avg_ns\tgpu_strip_group_avg_ns\tgpu_boundary_mark_avg_ns\tgpu_fill_task_avg_ns\tgpu_crossing_collect_avg_ns\tgpu_crossing_sort_avg_ns\tgpu_fill_emit_avg_ns\tcrossing_rows_avg\tcrossing_items_avg\tcrossing_sort_rows_avg\tmax_crossings_per_row\tboundary_checks_avg\tboundary_hits_avg\tfill_candidates_avg\talpha_segment_refs_avg\tmax_alpha_segments_per_task\tcpu_encode_avg_ns\tcommit_avg_ns\tresource_avg_ns\tupload_avg_ns\tcompute_encode_avg_ns\tblit_encode_avg_ns\tgpu_wait_avg_ns\tgpu_wait_supported\tgpu_wait_kind\tgpu_wait_status\tcalls\tnonempty_calls\ttasks\tfill_tasks\talpha_fill_tasks\tsegment_indices\tfill_span_tiles\tmax_fill_span_tiles\tdispatches\tbatch_groups\tbatch_dispatches\tbatch_calls\tbatch_tasks\tmax_batch_calls\tmax_batch_tasks\tbatch_break_task_gap\tbatch_break_image_mismatch\tbatch_break_invalid_bounds\tbatch_break_overlap\tupload_bytes\tcalls_bytes\tsegments_bytes\ttasks_bytes\tsegment_indices_bytes\tdirect_supported\tdirect_calls\tdirect_eligible_calls\tdirect_fallback_calls\tdirect_fallback_images\tdirect_fallback_scissors\tdirect_fallback_clips\tdirect_fallback_gradients\tdirect_fallback_triangles\tdirect_strip_instances\tdirect_alpha_strip_instances\tdirect_solid_span_instances\tdirect_solid_span_tiles\tdirect_max_solid_span_tiles\tdirect_alpha_bytes\tdirect_strip_instance_bytes\tdirect_paint_bytes\tdirect_upload_bytes\tdirect_upload_savings_bytes\tdirect_compact_strip_instances\tdirect_compact_alpha_strip_instances\tdirect_compact_solid_span_instances\tdirect_compact_alpha_bytes\tdirect_compact_strip_instance_bytes\tdirect_compact_upload_bytes\tdirect_compact_upload_savings_bytes\tfallback\n");
}

fn printResult(result: Accumulator) void {
    const frame_avg = average(result.frame_ns);
    const cpu_encode_avg = average(result.cpu_encode_ns);
    const commit_avg = average(result.commit_ns);
    const submit_avg = cpu_encode_avg + commit_avg;
    const gpu_wait_avg = if (result.gpu_wait_samples > 0) @as(u64, @intCast(result.gpu_wait_ns / result.gpu_wait_samples)) else 0;
    const scene_name = "ghostscript_tiger";
    const timing_scope = timing_mode.label();
    printTextField(scene_name);
    printTextField("sparse_strip");
    printTextField(timing_scope);
    printIntField(measured_frames);
    printIntField(frame_avg);
    printIntField(submit_avg);
    printIntField(average(result.frontend_ns));
    printIntField(average(result.build_ns));
    printIntField(average(result.bin_ns));
    printIntField(average(result.coarse_ns));
    printIntField(average(result.texture_views_ns));
    printIntField(average(result.gpu_fine_ns));
    printIntField(average(result.direct_strip_estimate_ns));
    printIntField(average(result.gpu_pack_records_ns));
    printIntField(average(result.gpu_strip_group_ns));
    printIntField(average(result.gpu_boundary_mark_ns));
    printIntField(average(result.gpu_fill_task_ns));
    printIntField(average(result.gpu_crossing_collect_ns));
    printIntField(average(result.gpu_crossing_sort_ns));
    printIntField(average(result.gpu_fill_emit_ns));
    printIntField(average(result.crossing_rows));
    printIntField(average(result.crossing_items));
    printIntField(average(result.crossing_sort_rows));
    printIntField(result.max_crossings_per_row);
    printIntField(average(result.boundary_checks));
    printIntField(average(result.boundary_hits));
    printIntField(average(result.fill_candidates));
    printIntField(average(result.alpha_segment_refs));
    printIntField(result.max_alpha_segments_per_task);
    printIntField(cpu_encode_avg);
    printIntField(commit_avg);
    printIntField(average(result.resource_ns));
    printIntField(average(result.upload_ns));
    printIntField(average(result.compute_encode_ns));
    printIntField(average(result.blit_encode_ns));
    printIntField(gpu_wait_avg);
    printIntField(@intFromBool(result.gpu_wait_samples > 0));
    printTextField(result.gpu_wait_kind.label());
    printTextField(result.gpu_wait_status.label());
    printIntField(result.calls);
    printIntField(result.nonempty_calls);
    printIntField(result.tasks);
    printIntField(result.fill_tasks);
    printIntField(result.alpha_fill_tasks);
    printIntField(result.segment_indices);
    printIntField(result.fill_span_tiles);
    printIntField(result.max_fill_span_tiles);
    printIntField(result.dispatches);
    printIntField(result.batch_groups);
    printIntField(result.batch_dispatches);
    printIntField(result.batch_calls);
    printIntField(result.batch_tasks);
    printIntField(result.max_batch_calls);
    printIntField(result.max_batch_tasks);
    printIntField(result.batch_break_task_gap);
    printIntField(result.batch_break_image_mismatch);
    printIntField(result.batch_break_invalid_bounds);
    printIntField(result.batch_break_overlap);
    printIntField(result.upload_bytes);
    printIntField(result.calls_bytes);
    printIntField(result.segments_bytes);
    printIntField(result.tasks_bytes);
    printIntField(result.segment_indices_bytes);
    printIntField(@intFromBool(result.direct_supported));
    printIntField(result.direct_calls);
    printIntField(result.direct_eligible_calls);
    printIntField(result.direct_fallback_calls);
    printIntField(result.direct_fallback_images);
    printIntField(result.direct_fallback_scissors);
    printIntField(result.direct_fallback_clips);
    printIntField(result.direct_fallback_gradients);
    printIntField(result.direct_fallback_triangles);
    printIntField(result.direct_strip_instances);
    printIntField(result.direct_alpha_strip_instances);
    printIntField(result.direct_solid_span_instances);
    printIntField(result.direct_solid_span_tiles);
    printIntField(result.direct_max_solid_span_tiles);
    printIntField(result.direct_alpha_bytes);
    printIntField(result.direct_strip_instance_bytes);
    printIntField(result.direct_paint_bytes);
    printIntField(result.direct_upload_bytes);
    printIntField(result.direct_upload_savings_bytes);
    printIntField(result.direct_compact_strip_instances);
    printIntField(result.direct_compact_alpha_strip_instances);
    printIntField(result.direct_compact_solid_span_instances);
    printIntField(result.direct_compact_alpha_bytes);
    printIntField(result.direct_compact_strip_instance_bytes);
    printIntField(result.direct_compact_upload_bytes);
    printIntField(result.direct_compact_upload_savings_bytes);
    printTextLast(fallbackName(result.fallback));
}

fn printTextField(value: []const u8) void {
    _ = std.c.printf("%.*s\t", @as(c_int, @intCast(value.len)), cString(value));
}

fn printTextLast(value: []const u8) void {
    _ = std.c.printf("%.*s\n", @as(c_int, @intCast(value.len)), cString(value));
}

fn printIntField(value: anytype) void {
    _ = std.c.printf("%llu\t", u64ForPrint(value));
}

fn average(total: u128) u64 {
    return @intCast(total / measured_frames);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn fallbackName(fallback: sokol_device.SparseFineFallback) []const u8 {
    return switch (fallback) {
        .none => "none",
        .unsupported_packet => "unsupported_packet",
        .empty_surface => "empty_surface",
        .empty_packet => "empty_packet",
        .missing_texture => "missing_texture",
        .missing_resources => "missing_resources",
    };
}

fn cString(value: []const u8) [*c]const u8 {
    return @ptrCast(value.ptr);
}

fn u64ForPrint(value: anytype) c_ulonglong {
    return @intCast(value);
}
