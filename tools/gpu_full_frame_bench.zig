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

const Accumulator = struct {
    frame_ns: u128 = 0,
    frontend_ns: u128 = 0,
    build_ns: u128 = 0,
    bin_ns: u128 = 0,
    coarse_ns: u128 = 0,
    texture_views_ns: u128 = 0,
    gpu_fine_ns: u128 = 0,
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
const texture_only = gpu_full_frame_options.texture_only;

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
        .window_title = if (texture_only) "Okys Tiger texture GPU benchmark" else "Okys Tiger full-frame GPU benchmark",
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

    const context = ctx orelse {
        fail("missing context", .{});
        return;
    };
    const sparse_backend = backend orelse {
        fail("missing sparse backend", .{});
        return;
    };

    device.resize(bench_scenes.scene_width, bench_scenes.scene_height, 1);
    sparse_backend.clearQueued();

    const frame_start = nowNs();

    const frontend_start = nowNs();
    frame_ops.beginFrame(context, bench_scenes.scene_width, bench_scenes.scene_height, 1);
    bench_scenes.drawTigerScene(context, .none);
    frame_ops.cancelFrame(context);
    const frontend_ns = nowNs() - frontend_start;

    var profile: okys.systems.backend_sparse_strip.Profile = .{};
    const build_start = nowNs();
    if (!sparse_backend.buildGpuFinePacket(&packet, &profile)) {
        fail("sparse GPU packet build failed", .{});
        return;
    }
    const build_ns = nowNs() - build_start;

    var timing: sokol_device.SparseFineSubmitTiming = .{};
    const drew = if (texture_only) device.drawSparseFineTextureTimed(
        &packet,
        &.{},
        scene_width_u32,
        scene_height_u32,
        &timing,
    ) else blk: {
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
    _ = std.c.printf("scene\tbackend\ttiming_scope\tframes\tframe_avg_ns\tsubmit_avg_ns\tfrontend_avg_ns\tbuild_avg_ns\tbin_avg_ns\tcoarse_avg_ns\ttexture_views_avg_ns\tgpu_fine_avg_ns\tgpu_pack_records_avg_ns\tgpu_strip_group_avg_ns\tgpu_boundary_mark_avg_ns\tgpu_fill_task_avg_ns\tgpu_crossing_collect_avg_ns\tgpu_crossing_sort_avg_ns\tgpu_fill_emit_avg_ns\tcrossing_rows_avg\tcrossing_items_avg\tcrossing_sort_rows_avg\tmax_crossings_per_row\tboundary_checks_avg\tboundary_hits_avg\tfill_candidates_avg\talpha_segment_refs_avg\tmax_alpha_segments_per_task\tcpu_encode_avg_ns\tcommit_avg_ns\tresource_avg_ns\tupload_avg_ns\tcompute_encode_avg_ns\tblit_encode_avg_ns\tgpu_wait_avg_ns\tgpu_wait_supported\tgpu_wait_kind\tgpu_wait_status\tcalls\ttasks\tdispatches\tupload_bytes\tfallback\n");
}

fn printResult(result: Accumulator) void {
    const frame_avg = average(result.frame_ns);
    const cpu_encode_avg = average(result.cpu_encode_ns);
    const commit_avg = average(result.commit_ns);
    const submit_avg = cpu_encode_avg + commit_avg;
    const gpu_wait_avg = if (result.gpu_wait_samples > 0) @as(u64, @intCast(result.gpu_wait_ns / result.gpu_wait_samples)) else 0;
    const scene_name = "ghostscript_tiger";
    const timing_scope = if (texture_only) "gpu_texture" else "gpu_full_frame";
    _ = std.c.printf(
        "%.*s\tsparse_strip\t%.*s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%.*s\t%.*s\t%llu\t%llu\t%llu\t%llu\t%.*s\n",
        @as(c_int, @intCast(scene_name.len)),
        cString(scene_name),
        @as(c_int, @intCast(timing_scope.len)),
        cString(timing_scope),
        u64ForPrint(measured_frames),
        u64ForPrint(frame_avg),
        u64ForPrint(submit_avg),
        u64ForPrint(average(result.frontend_ns)),
        u64ForPrint(average(result.build_ns)),
        u64ForPrint(average(result.bin_ns)),
        u64ForPrint(average(result.coarse_ns)),
        u64ForPrint(average(result.texture_views_ns)),
        u64ForPrint(average(result.gpu_fine_ns)),
        u64ForPrint(average(result.gpu_pack_records_ns)),
        u64ForPrint(average(result.gpu_strip_group_ns)),
        u64ForPrint(average(result.gpu_boundary_mark_ns)),
        u64ForPrint(average(result.gpu_fill_task_ns)),
        u64ForPrint(average(result.gpu_crossing_collect_ns)),
        u64ForPrint(average(result.gpu_crossing_sort_ns)),
        u64ForPrint(average(result.gpu_fill_emit_ns)),
        u64ForPrint(average(result.crossing_rows)),
        u64ForPrint(average(result.crossing_items)),
        u64ForPrint(average(result.crossing_sort_rows)),
        u64ForPrint(result.max_crossings_per_row),
        u64ForPrint(average(result.boundary_checks)),
        u64ForPrint(average(result.boundary_hits)),
        u64ForPrint(average(result.fill_candidates)),
        u64ForPrint(average(result.alpha_segment_refs)),
        u64ForPrint(result.max_alpha_segments_per_task),
        u64ForPrint(cpu_encode_avg),
        u64ForPrint(commit_avg),
        u64ForPrint(average(result.resource_ns)),
        u64ForPrint(average(result.upload_ns)),
        u64ForPrint(average(result.compute_encode_ns)),
        u64ForPrint(average(result.blit_encode_ns)),
        u64ForPrint(gpu_wait_avg),
        u64ForPrint(@intFromBool(result.gpu_wait_samples > 0)),
        @as(c_int, @intCast(result.gpu_wait_kind.label().len)),
        cString(result.gpu_wait_kind.label()),
        @as(c_int, @intCast(result.gpu_wait_status.label().len)),
        cString(result.gpu_wait_status.label()),
        u64ForPrint(result.calls),
        u64ForPrint(result.tasks),
        u64ForPrint(result.dispatches),
        u64ForPrint(result.upload_bytes),
        @as(c_int, @intCast(fallbackName(result.fallback).len)),
        cString(fallbackName(result.fallback)),
    );
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
