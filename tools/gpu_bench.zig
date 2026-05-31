const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");
const bench_options = @import("bench_options");
const bench_scenes = @import("bench_scenes.zig");

const app = sokol.app;
const glue = sokol.glue;

const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const GpuFinePacket = okys.systems.backend_sparse_strip.GpuFinePacket;
const sokol_device = okys.render.sokol_device;

const gpa = std.heap.c_allocator;
const warmup_frames: usize = 60;
const measured_frames: usize = 1000;
const frame_limit = warmup_frames + measured_frames;
const scene_width_u32: u32 = @intFromFloat(bench_scenes.scene_width);
const scene_height_u32: u32 = @intFromFloat(bench_scenes.scene_height);
const active_specs = if (bench_options.tiger_only) bench_scenes.tiger_specs[0..] else bench_scenes.specs[0..];

const Accumulator = struct {
    frame_ns: u128 = 0,
    cpu_encode_ns: u128 = 0,
    commit_ns: u128 = 0,
    resource_ns: u128 = 0,
    upload_ns: u128 = 0,
    compute_encode_ns: u128 = 0,
    blit_encode_ns: u128 = 0,
    calls: usize = 0,
    tasks: usize = 0,
    dispatches: usize = 0,
    upload_bytes: usize = 0,
    fallback: sokol_device.SparseFineFallback = .none,

    fn reset(self: *Accumulator) void {
        self.* = .{};
    }

    fn add(self: *Accumulator, frame_ns: u64, commit_ns: u64, timing: sokol_device.SparseFineSubmitTiming) void {
        self.frame_ns += frame_ns;
        self.cpu_encode_ns += timing.total_ns;
        self.commit_ns += commit_ns;
        self.resource_ns += timing.resource_ns;
        self.upload_ns += timing.upload_ns;
        self.compute_encode_ns += timing.compute_encode_ns;
        self.blit_encode_ns += timing.blit_encode_ns;
        self.calls = timing.calls;
        self.tasks = timing.tasks;
        self.dispatches = timing.dispatches;
        self.upload_bytes = timing.upload_bytes;
        self.fallback = timing.fallback;
    }
};

const SceneState = struct {
    spec: bench_scenes.SceneSpec = undefined,
    frame: bench_scenes.CapturedFrame = undefined,
    frame_valid: bool = false,
    backend: ?*SparseBackend = null,
    packet: GpuFinePacket = .{},
    textures: std.ArrayList(sokol_device.PathTexture) = .empty,

    fn deinit(self: *SceneState) void {
        self.textures.deinit(gpa);
        self.packet.deinit(gpa);
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
        if (self.frame_valid) {
            self.frame.deinit();
            self.frame_valid = false;
        }
    }
};

var device: sokol_device.Device = .{};
var device_initialized = false;
var failed = false;
var scene_states: [active_specs.len]SceneState = undefined;
var initialized_scenes: usize = 0;
var current_scene: usize = 0;
var frame_index: usize = 0;
var accum: Accumulator = .{};

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
        .window_title = "Okys sparse GPU benchmark",
    });
    if (failed) std.process.exit(1);
}

fn init() callconv(.c) void {
    device = sokol_device.Device.initOwned(.{ .environment = glue.environment() });
    device_initialized = true;
    device.resize(bench_scenes.scene_width, bench_scenes.scene_height, 1);

    for (active_specs, 0..) |spec, index| {
        scene_states[index] = .{ .spec = spec };
        setupScene(&scene_states[index]) catch |err| {
            fail("setup failed for {s}: {s}", .{ spec.name, @errorName(err) });
            return;
        };
        initialized_scenes += 1;
    }
}

fn setupScene(state: *SceneState) !void {
    state.frame = try bench_scenes.captureScene(gpa, state.spec.draw);
    state.frame_valid = true;

    const backend = try SparseBackend.create(gpa);
    backend.fill_rule = .even_odd;
    state.backend = backend;
    state.frame.replay(backend.interface());

    var profile: okys.systems.backend_sparse_strip.Profile = .{};
    if (!backend.buildGpuFinePacket(&state.packet, &profile)) {
        return error.UnsupportedGpuFinePacket;
    }

    try state.textures.ensureTotalCapacity(gpa, backend.texture_views.items.len);
    for (backend.texture_views.items) |texture| {
        state.textures.appendAssumeCapacity(.{
            .id = @intFromEnum(texture.id),
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = texture.pixels,
        });
    }
}

fn frame() callconv(.c) void {
    if (failed) return;
    if (current_scene >= scene_states.len) {
        app.requestQuit();
        return;
    }

    const state = &scene_states[current_scene];
    const backend = state.backend orelse {
        fail("missing backend for {s}", .{state.spec.name});
        return;
    };

    device.resize(bench_scenes.scene_width, bench_scenes.scene_height, 1);
    var timing: sokol_device.SparseFineSubmitTiming = .{};
    const frame_start = nowNs();
    const pass = sokol_device.swapchainPassWithAction(
        sokol_device.clearPassAction(.{ .r = 0.08, .g = 0.09, .b = 0.10, .a = 1.0 }),
        glue.swapchain(),
    );
    const drew = device.drawSparseFineSurfaceTimed(
        pass,
        &state.packet,
        backend.segments.items,
        state.textures.items,
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
    if (!drew or timing.fallback != .none) {
        fail("sparse GPU fallback for {s}: {s}", .{ state.spec.name, fallbackName(timing.fallback) });
        return;
    }

    const commit_start = nowNs();
    sokol_device.Device.commit();
    const commit_ns = nowNs() - commit_start;
    const frame_ns = nowNs() - frame_start;

    if (frame_index >= warmup_frames) {
        accum.add(frame_ns, commit_ns, timing);
    }

    frame_index += 1;
    if (frame_index == frame_limit) {
        printResult(state.spec.name, accum);
        current_scene += 1;
        frame_index = 0;
        accum.reset();
        if (current_scene >= scene_states.len) app.requestQuit();
    }
}

fn cleanup() callconv(.c) void {
    for (scene_states[0..initialized_scenes]) |*state| {
        state.deinit();
    }
    initialized_scenes = 0;
    if (device_initialized) {
        device.deinit();
        device_initialized = false;
    }
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    failed = true;
    std.debug.print("okys gpu bench: " ++ fmt ++ "\n", args);
    app.requestQuit();
}

fn printHeader() void {
    _ = std.c.printf("scene\tbackend\ttiming_scope\tframes\tframe_avg_ns\tsubmit_avg_ns\tcpu_encode_avg_ns\tcommit_avg_ns\tresource_avg_ns\tupload_avg_ns\tcompute_encode_avg_ns\tblit_encode_avg_ns\tcalls\ttasks\tdispatches\tupload_bytes\tfallback\n");
}

fn printResult(scene_name: []const u8, result: Accumulator) void {
    const frame_avg = average(result.frame_ns);
    const cpu_encode_avg = average(result.cpu_encode_ns);
    const commit_avg = average(result.commit_ns);
    const submit_avg = cpu_encode_avg + commit_avg;
    _ = std.c.printf(
        "%.*s\tsparse_strip\tgpu_packet_submit\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%.*s\n",
        @as(c_int, @intCast(scene_name.len)),
        cString(scene_name),
        u64ForPrint(measured_frames),
        u64ForPrint(frame_avg),
        u64ForPrint(submit_avg),
        u64ForPrint(cpu_encode_avg),
        u64ForPrint(commit_avg),
        u64ForPrint(average(result.resource_ns)),
        u64ForPrint(average(result.upload_ns)),
        u64ForPrint(average(result.compute_encode_ns)),
        u64ForPrint(average(result.blit_encode_ns)),
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
