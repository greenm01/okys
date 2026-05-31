const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");
const bench_scenes = @import("bench_scenes");
const demo_options = @import("demo_options");

const app = sokol.app;
const debugtext = sokol.debugtext;
const gfx = sokol.gfx;
const glue = sokol.glue;

const Context = okys.state.context.Context;
const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const GpuFinePacket = okys.systems.backend_sparse_strip.GpuFinePacket;
const Profile = okys.systems.backend_sparse_strip.Profile;
const frame_ops = okys.ops.frame;
const sokol_device = okys.render.sokol_device;

const gpa = std.heap.c_allocator;
const OKY_ANTIALIAS: u32 = bench_scenes.oky_antialias;
const OKY_STENCIL_STROKES: u32 = bench_scenes.oky_stencil_strokes;
const timing_window_len = 60;
const hud_height: f32 = 176;
const tiger_cache_size: u32 = 768;
const tiger_cache_margin: f32 = 22;
const tiger_cache_scale_bias: f32 = 0.94;
const tiger_display_scale: f32 = 1.72;
const rotation_radians_per_second: f32 = std.math.tau / 4.5;

const TimingWindow = struct {
    samples: [timing_window_len]u64 = @splat(0),
    index: usize = 0,
    count: usize = 0,
    total: u128 = 0,

    fn add(self: *TimingWindow, value: u64) void {
        if (self.count < self.samples.len) {
            self.count += 1;
        } else {
            self.total -= self.samples[self.index];
        }
        self.samples[self.index] = value;
        self.total += value;
        self.index = (self.index + 1) % self.samples.len;
    }

    fn average(self: *const TimingWindow) u64 {
        if (self.count == 0) return 0;
        return @intCast(self.total / self.count);
    }
};

var device: sokol_device.Device = .{};
var ctx: ?*Context = null;
var backend: ?*SparseBackend = null;
var packet: GpuFinePacket = .{};
var device_textures: std.ArrayList(sokol_device.PathTexture) = .empty;
var timing: sokol_device.SparseFineSubmitTiming = .{};
var profile: Profile = .{};
var frame_interval_window: TimingWindow = .{};
var work_window: TimingWindow = .{};
var build_window: TimingWindow = .{};
var submit_window: TimingWindow = .{};
var commit_window: TimingWindow = .{};
var last_frame_start_ns: u64 = 0;
var start_ns: u64 = 0;
var cache_ready = false;

pub fn main() void {
    app.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .width = 1100,
        .height = 900,
        .sample_count = 1,
        .swap_interval = if (demo_options.vsync) 1 else 0,
        .high_dpi = false,
        .window_title = "Okys sparse-strip Ghostscript Tiger",
    });
}

fn event(e: [*c]const app.Event) callconv(.c) void {
    const ev = e.*;
    if (ev.type == .KEY_DOWN and ev.key_code == .ESCAPE) {
        app.requestQuit();
    }
}

fn init() callconv(.c) void {
    device = sokol_device.Device.initOwned(.{ .environment = glue.environment() });

    var debug_desc: debugtext.Desc = .{};
    debug_desc.fonts[0] = debugtext.fontKc853();
    debug_desc.context.max_commands = 1024;
    debug_desc.context.char_buf_size = 8192;
    debugtext.setup(debug_desc);

    const c = Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES) catch {
        app.requestQuit();
        return;
    };
    const b = SparseBackend.create(gpa) catch {
        c.destroy();
        app.requestQuit();
        return;
    };
    b.fill_rule = .even_odd;
    c.installBackend(b.interface());

    ctx = c;
    backend = b;
    start_ns = nowNs();
    last_frame_start_ns = start_ns;
}

fn frame() callconv(.c) void {
    const c = ctx orelse return;
    const b = backend orelse return;
    const width = app.widthf();
    const height = app.heightf();
    const dpr = app.dpiScale();
    const frame_start = nowNs();
    if (last_frame_start_ns != 0 and frame_start > last_frame_start_ns) {
        frame_interval_window.add(frame_start - last_frame_start_ns);
    }
    last_frame_start_ns = frame_start;

    const work_start = nowNs();
    device.resize(width, height, dpr);

    const pass = sokol_device.swapchainPassWithAction(
        sokol_device.clearPassAction(.{ .r = 0.08, .g = 0.09, .b = 0.10, .a = 1.0 }),
        glue.swapchain(),
    );

    const angle = secondsSinceStart(frame_start) * rotation_radians_per_second;
    if (!cache_ready) {
        cache_ready = buildTigerCache(c, b, pass, width, height);
        if (cache_ready) {
            drawCachedTiger(
                sokol_device.swapchainPassWithAction(sokol_device.loadPassAction(), glue.swapchain()),
                width,
                height,
                angle,
            );
        }
    } else {
        drawCachedTiger(pass, width, height, angle);
    }

    if (!cache_ready) {
        device.beginPass(pass);
        gfx.endPass();
    }

    drawHud(width, height, frame_start);

    const commit_start = nowNs();
    sokol_device.Device.commit();
    commit_window.add(nowNs() - commit_start);
    work_window.add(nowNs() - work_start);
}

fn buildTigerCache(c: *Context, b: *SparseBackend, pass: sokol_device.Pass, width: f32, height: f32) bool {
    const build_start = nowNs();
    frame_ops.beginFrame(c, @floatFromInt(tiger_cache_size), @floatFromInt(tiger_cache_size), 1);
    drawTigerCache(c);
    profile = .{};
    const packet_ok = b.buildGpuFinePacket(&packet, &profile);
    build_window.add(nowNs() - build_start);

    timing = .{};
    if (!packet_ok) {
        timing.fallback = .unsupported_packet;
        b.clearQueued();
        return false;
    }

    const drew_sparse = device.drawSparseFineSurfaceTimed(
        pass,
        &packet,
        b.segments.items,
        sparseTexturesForDevice(b),
        tiger_cache_size,
        tiger_cache_size,
        .{
            .x = -@as(f32, @floatFromInt(tiger_cache_size)) * 2.0,
            .y = -@as(f32, @floatFromInt(tiger_cache_size)) * 2.0,
            .width = @floatFromInt(tiger_cache_size),
            .height = @floatFromInt(tiger_cache_size),
        },
        width,
        height,
        &timing,
    );
    if (drew_sparse and timing.fallback == .none) {
        submit_window.add(timing.total_ns);
    }
    b.clearQueued();
    return drew_sparse and timing.fallback == .none;
}

fn drawCachedTiger(pass: sokol_device.Pass, width: f32, height: f32, angle: f32) void {
    device.drawTextureViewQuad(
        pass,
        device.sparse_surface_texture_view,
        tigerQuad(width, height, angle),
        width,
        height,
    );
}

fn drawTigerCache(c: *Context) void {
    const cache_size: f32 = @floatFromInt(tiger_cache_size);
    const tiger_scale = bench_scenes.tigerScaleForPivotBox(
        cache_size,
        cache_size,
        tiger_cache_margin,
        bench_scenes.tiger_nose_source_x,
        bench_scenes.tiger_nose_source_y,
    ) * tiger_cache_scale_bias;
    bench_scenes.drawTiger(c, .{
        .center_x = cache_size * 0.5,
        .center_y = cache_size * 0.5,
        .scale = tiger_scale,
        .angle = 0,
        .pivot_x = bench_scenes.tiger_nose_source_x,
        .pivot_y = bench_scenes.tiger_nose_source_y,
    });
}

fn tigerQuad(width: f32, height: f32, angle: f32) [4]sokol_device.BlitVertex {
    const top_height = @max(height - hud_height, 1.0);
    const pivot_x = width * 0.5;
    const pivot_y = top_height * 0.5;
    const half = @as(f32, @floatFromInt(tiger_cache_size)) * 0.5 * tiger_display_scale;
    return .{
        tigerVertex(pivot_x, pivot_y, -half, -half, angle, 0, 0),
        tigerVertex(pivot_x, pivot_y, half, -half, angle, 1, 0),
        tigerVertex(pivot_x, pivot_y, -half, half, angle, 0, 1),
        tigerVertex(pivot_x, pivot_y, half, half, angle, 1, 1),
    };
}

fn tigerVertex(pivot_x: f32, pivot_y: f32, x: f32, y: f32, angle: f32, u: f32, v: f32) sokol_device.BlitVertex {
    const cs = @cos(angle);
    const sn = @sin(angle);
    return .{
        .x = pivot_x + x * cs - y * sn,
        .y = pivot_y + x * sn + y * cs,
        .u = u,
        .v = v,
    };
}

fn cleanup() callconv(.c) void {
    if (ctx) |c| {
        c.destroy();
        ctx = null;
        backend = null;
    }
    packet.deinit(gpa);
    device_textures.deinit(gpa);
    debugtext.shutdown();
    device.deinit();
}

fn drawHud(width: f32, height: f32, frame_start: u64) void {
    const text_scale = 1.0;
    debugtext.canvas(width * text_scale, height * text_scale);
    debugtext.origin(1, @max((height - hud_height) * text_scale / 8.0 + 1.0, 1.0));
    debugtext.home();
    debugtext.color4b(235, 240, 245, 235);

    const frame_avg_ns = frame_interval_window.average();
    const uptime = secondsSinceStart(frame_start);
    hudLine("okys sparse-strip tiger    vsync {s}    callback {d:.3} ms    work {d:.3} ms", .{
        if (demo_options.vsync) "on" else "off",
        nsToMs(frame_avg_ns),
        nsToMs(work_window.average()),
    });
    hudLine("fps {d:.1}    angle {d:.1} deg    frame count {d}", .{
        fpsFromFrameNs(frame_avg_ns),
        radiansToDegrees(uptime * rotation_radians_per_second),
        app.frameCount(),
    });
    hudLine("cpu build: avg {d:.3} ms    bin {d:.3} ms    coarse {d:.3} ms    texture views {d:.3} ms", .{
        nsToMs(build_window.average()),
        nsToMs(profile.bin_ns),
        nsToMs(profile.coarse_ns),
        nsToMs(profile.texture_views_ns),
    });
    hudLine("sparse submit: avg {d:.3} ms    last {d:.3} ms    commit avg {d:.3} ms", .{
        nsToMs(submit_window.average()),
        nsToMs(timing.total_ns),
        nsToMs(commit_window.average()),
    });
    hudLine("resource/upload/compute/blit: {d:.3} / {d:.3} / {d:.3} / {d:.3} ms", .{
        nsToMs(timing.resource_ns),
        nsToMs(timing.upload_ns),
        nsToMs(timing.compute_encode_ns),
        nsToMs(timing.blit_encode_ns),
    });
    hudLine("packet: {d} calls    {d} tasks    {d} dispatches", .{
        timing.calls,
        timing.tasks,
        timing.dispatches,
    });
    hudLine("upload: {d:.2} MB    fallback {s}", .{
        bytesToMb(timing.upload_bytes),
        fallbackName(timing.fallback),
    });

    const hud_pass = sokol_device.swapchainPassWithAction(sokol_device.loadPassAction(), glue.swapchain());
    device.beginPass(hud_pass);
    debugtext.draw();
    gfx.endPass();
}

fn hudLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    debugtext.puts(line);
    debugtext.crlf();
}

fn sparseTexturesForDevice(b: *SparseBackend) []const sokol_device.PathTexture {
    device_textures.clearRetainingCapacity();
    device_textures.ensureTotalCapacity(gpa, b.texture_views.items.len) catch return &.{};
    for (b.texture_views.items) |texture| {
        device_textures.appendAssumeCapacity(.{
            .id = @intFromEnum(texture.id),
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .pixels = texture.pixels,
            .generation = texture.generation,
        });
    }
    return device_textures.items;
}

fn secondsSinceStart(now: u64) f32 {
    if (start_ns == 0 or now <= start_ns) return 0;
    return @as(f32, @floatFromInt(now - start_ns)) / 1_000_000_000.0;
}

fn fpsFromFrameNs(ns: u64) f64 {
    if (ns == 0) return 0;
    return 1_000_000_000.0 / @as(f64, @floatFromInt(ns));
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn bytesToMb(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn radiansToDegrees(radians: f32) f64 {
    const turns = radians / std.math.tau;
    const normalized = turns - @floor(turns);
    return @as(f64, @floatCast(normalized * 360.0));
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

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
