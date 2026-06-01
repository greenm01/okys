const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");
const bench_scenes = @import("bench_scenes");

const app = sokol.app;
const c_api = okys.c_api;
const graphics_runtime = okys.render.graphics_runtime;
const image_ops = okys.ops.image;
const sokol_device = okys.render.sokol_device;

const OKY_ANTIALIAS: c_int = 1 << 0;
const OKY_SPARSE_STRIP: c_int = 1 << 2;
const width_px: u32 = @intFromFloat(bench_scenes.scene_width);
const height_px: u32 = @intFromFloat(bench_scenes.scene_height);
const active_specs = bench_scenes.specs[0..];

const Probe = struct {
    x: u32,
    y: u32,
    rgba: [4]u8,
    tolerance: u8 = 2,
};

const Fixture = struct {
    name: []const u8,
    hash: u64,
    probes: []const Probe,
};

const fixtures = [_]Fixture{
    .{
        .name = "mixed_demo",
        .hash = 0xa7b286c5ed6030b3,
        .probes = &.{
            .{ .x = 10, .y = 10, .rgba = .{ 36, 38, 41, 255 } },
            .{ .x = 100, .y = 100, .rgba = .{ 51, 148, 219, 255 } },
            .{ .x = 400, .y = 100, .rgba = .{ 232, 116, 84, 255 } },
            .{ .x = 685, .y = 120, .rgba = .{ 153, 205, 85, 255 } },
        },
    },
    .{
        .name = "rounded_rect_grid",
        .hash = 0x00db32f44c697f57,
        .probes = &.{
            .{ .x = 10, .y = 10, .rgba = .{ 31, 33, 36, 255 } },
            .{ .x = 64, .y = 58, .rgba = .{ 45, 118, 147, 255 } },
            .{ .x = 685, .y = 120, .rgba = .{ 176, 209, 222, 255 } },
        },
    },
    .{
        .name = "arcs_icons",
        .hash = 0xf6b64f06e8686865,
        .probes = &.{
            .{ .x = 10, .y = 10, .rgba = .{ 28, 31, 33, 255 } },
            .{ .x = 64, .y = 58, .rgba = .{ 48, 126, 157, 255 } },
            .{ .x = 400, .y = 100, .rgba = .{ 66, 66, 62, 255 } },
            .{ .x = 685, .y = 120, .rgba = .{ 82, 126, 157, 255 } },
        },
    },
    .{
        .name = "nested_scissors",
        .hash = 0x41e40fd9850eef94,
        .probes = &.{
            .{ .x = 10, .y = 10, .rgba = .{ 33, 36, 38, 255 } },
            .{ .x = 64, .y = 58, .rgba = .{ 182, 188, 199, 255 } },
            .{ .x = 100, .y = 100, .rgba = .{ 39, 71, 136, 255 } },
            .{ .x = 400, .y = 100, .rgba = .{ 96, 101, 160, 255 } },
        },
    },
};

const custom_fixtures = [_]Fixture{
    .{
        .name = "large_mask_image_pattern",
        .hash = 0xb8e92b3350993d05,
        .probes = &.{
            .{ .x = 72, .y = 52, .rgba = .{ 64, 64, 69, 255 } },
            .{ .x = 160, .y = 120, .rgba = .{ 255, 255, 255, 255 } },
            .{ .x = 180, .y = 130, .rgba = .{ 255, 255, 255, 255 } },
        },
    },
};

var ctx: ?*okys.state.context.Context = null;
var target: ?sokol_device.GlOffscreenTarget = null;
var pixels: []u8 = &.{};
var current_scene: usize = 0;
var current_custom_scene: usize = 0;
var failed = false;

pub fn main() void {
    printHeader();
    app.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = width_px,
        .height = height_px,
        .sample_count = 1,
        .swap_interval = 0,
        .high_dpi = false,
        .window_title = "Okys GPU golden",
    });
    if (failed) std.process.exit(1);
}

fn init() callconv(.c) void {
    ctx = c_api.okyCreate(OKY_ANTIALIAS | OKY_SPARSE_STRIP) orelse {
        fail("context creation failed", .{});
        return;
    };
    if (c_api.okySetupGL(ctx, 1) != 1) {
        fail("okySetupGL failed", .{});
        return;
    }
    target = sokol_device.createGlOffscreenTarget(width_px, height_px) orelse {
        fail("offscreen GL target creation failed", .{});
        return;
    };
    pixels = std.heap.c_allocator.alloc(u8, width_px * height_px * 4) catch {
        fail("pixel allocation failed", .{});
        return;
    };
}

fn frame() callconv(.c) void {
    if (failed) return;
    if (current_scene >= active_specs.len) {
        if (current_custom_scene >= custom_fixtures.len) {
            app.requestQuit();
        } else {
            renderCustomScene(custom_fixtures[current_custom_scene]) catch |err| {
                fail("custom render failed for {s}: {s}", .{ custom_fixtures[current_custom_scene].name, @errorName(err) });
                return;
            };
            current_custom_scene += 1;
            if (current_custom_scene >= custom_fixtures.len) app.requestQuit();
        }
        return;
    }

    const spec = active_specs[current_scene];
    const fixture = fixtureFor(spec.name) orelse {
        fail("missing fixture for {s}", .{spec.name});
        return;
    };
    renderScene(spec) catch |err| {
        fail("render failed for {s}: {s}", .{ spec.name, @errorName(err) });
        return;
    };
    readPixels() catch |err| {
        fail("readback failed for {s}: {s}", .{ spec.name, @errorName(err) });
        return;
    };

    const actual_hash = fnv1a64(pixels);
    const probe_ok = compareProbes(fixture, spec.name);
    const hash_ok = fixture.hash == 0 or fixture.hash == actual_hash;
    printResult(spec.name, actual_hash, fixture.hash, hash_ok, probe_ok);
    if (!hash_ok or !probe_ok) {
        failed = true;
        app.requestQuit();
        return;
    }

    current_scene += 1;
}

fn cleanup() callconv(.c) void {
    if (pixels.len != 0) {
        std.heap.c_allocator.free(pixels);
        pixels = &.{};
    }
    if (target) |t| {
        sokol_device.destroyGlOffscreenTarget(t);
        target = null;
    }
    if (ctx) |c| {
        c_api.okyDelete(c);
        ctx = null;
    }
}

fn renderScene(spec: bench_scenes.SceneSpec) !void {
    const c = ctx orelse return error.MissingContext;
    const t = target orelse return error.MissingTarget;

    var render_target: graphics_runtime.RenderTarget = .{
        .backend = @intFromEnum(graphics_runtime.GraphicsBackend.gl),
        .width_px = width_px,
        .height_px = height_px,
        .color_format = @intFromEnum(graphics_runtime.PixelFormat.rgba8),
        .depth_format = @intFromEnum(graphics_runtime.PixelFormat.depth_stencil),
        .sample_count = 1,
        .gl_framebuffer = t.framebuffer,
        .metal_current_drawable = null,
        .metal_depth_stencil_texture = null,
        .metal_msaa_color_texture = null,
        .d3d11_render_view = null,
        .d3d11_resolve_view = null,
        .d3d11_depth_stencil_view = null,
        .vulkan_render_image = null,
        .vulkan_render_view = null,
        .vulkan_resolve_image = null,
        .vulkan_resolve_view = null,
        .vulkan_depth_stencil_image = null,
        .vulkan_depth_stencil_view = null,
        .vulkan_render_finished_semaphore = null,
        .vulkan_present_complete_semaphore = null,
        .webgpu_render_view = null,
        .webgpu_resolve_view = null,
        .webgpu_depth_stencil_view = null,
    };
    if (c_api.okySetRenderTarget(c, &render_target) != 1) return error.SetRenderTargetFailed;

    c_api.okyBeginFrame(c, bench_scenes.scene_width, bench_scenes.scene_height, 1.0);
    const image_id = bench_scenes.createCheckerImage(c);
    spec.draw(c, image_id);
    c_api.okyEndFrame(c);
    if (image_id != .none) image_ops.deleteImage(c, image_id);
}

fn renderCustomScene(fixture: Fixture) !void {
    const c = ctx orelse return error.MissingContext;
    const t = target orelse return error.MissingTarget;

    var render_target: graphics_runtime.RenderTarget = .{
        .backend = @intFromEnum(graphics_runtime.GraphicsBackend.gl),
        .width_px = width_px,
        .height_px = height_px,
        .color_format = @intFromEnum(graphics_runtime.PixelFormat.rgba8),
        .depth_format = @intFromEnum(graphics_runtime.PixelFormat.depth_stencil),
        .sample_count = 1,
        .gl_framebuffer = t.framebuffer,
        .metal_current_drawable = null,
        .metal_depth_stencil_texture = null,
        .metal_msaa_color_texture = null,
        .d3d11_render_view = null,
        .d3d11_resolve_view = null,
        .d3d11_depth_stencil_view = null,
        .vulkan_render_image = null,
        .vulkan_render_view = null,
        .vulkan_resolve_image = null,
        .vulkan_resolve_view = null,
        .vulkan_depth_stencil_image = null,
        .vulkan_depth_stencil_view = null,
        .vulkan_render_finished_semaphore = null,
        .vulkan_present_complete_semaphore = null,
        .webgpu_render_view = null,
        .webgpu_resolve_view = null,
        .webgpu_depth_stencil_view = null,
    };
    if (c_api.okySetRenderTarget(c, &render_target) != 1) return error.SetRenderTargetFailed;

    c_api.okyBeginFrame(c, bench_scenes.scene_width, bench_scenes.scene_height, 1.0);
    const image_id = createLargeMaskImage(c);
    drawLargeMaskImagePattern(c, image_id);
    c_api.okyEndFrame(c);
    if (image_id != .none) image_ops.deleteImage(c, image_id);

    try readPixels();
    const actual_hash = fnv1a64(pixels);
    const probe_ok = compareProbes(fixture, fixture.name);
    const hash_ok = fixture.hash == 0 or fixture.hash == actual_hash;
    printResult(fixture.name, actual_hash, fixture.hash, hash_ok, probe_ok);
    if (!hash_ok or !probe_ok) {
        failed = true;
        app.requestQuit();
    }
}

fn createLargeMaskImage(c: *okys.state.context.Context) okys.types.image.ImageId {
    const image_width: usize = 128;
    const image_height: usize = 96;
    var image_pixels: [image_width * image_height * 4]u8 = undefined;
    var y: usize = 0;
    while (y < image_height) : (y += 1) {
        var x: usize = 0;
        while (x < image_width) : (x += 1) {
            const inside_mark = x >= 30 and x < 98 and y >= 22 and y < 74;
            const index = (y * image_width + x) * 4;
            image_pixels[index + 0] = 255;
            image_pixels[index + 1] = 255;
            image_pixels[index + 2] = 255;
            image_pixels[index + 3] = if (inside_mark) 255 else 0;
        }
    }
    return image_ops.createImageRGBA(c, image_width, image_height, &image_pixels);
}

fn drawLargeMaskImagePattern(c: *okys.state.context.Context, image_id: okys.types.image.ImageId) void {
    const color = okys.types.color;
    const paint_ops = okys.ops.paint;
    const path_ops = okys.ops.path;
    const render_ops = okys.ops.render;

    paint_ops.fillColor(c, color.rgbaf(0.25, 0.25, 0.27, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, bench_scenes.scene_width, bench_scenes.scene_height);
    render_ops.fill(c);

    if (image_id == .none) return;
    paint_ops.fillPaint(c, paint_ops.imagePattern(c, 80, 60, 160, 120, 0, @intCast(@intFromEnum(image_id)), 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 80, 60, 160, 120);
    render_ops.fill(c);
}

fn readPixels() !void {
    const c = ctx orelse return error.MissingContext;
    var desc: graphics_runtime.ReadPixelsDesc = .{
        .x = 0,
        .y = 0,
        .w = width_px,
        .h = height_px,
        .format = @intFromEnum(graphics_runtime.PixelFormat.rgba8),
        .dst_stride_bytes = width_px * 4,
        .dst = pixels.ptr,
    };
    const status = c_api.okyReadPixels(c, &desc);
    if (status != @intFromEnum(graphics_runtime.ReadPixelsStatus.ok)) return error.ReadPixelsFailed;
}

fn compareProbes(fixture: Fixture, scene_name: []const u8) bool {
    var ok = true;
    for (fixture.probes) |probe| {
        const actual = pixelAt(probe.x, probe.y);
        if (!withinTolerance(actual, probe.rgba, probe.tolerance)) {
            ok = false;
            std.debug.print(
                "probe mismatch\t{s}\tx={d}\ty={d}\texpected={any}\tactual={any}\ttolerance={d}\n",
                .{ scene_name, probe.x, probe.y, probe.rgba, actual, probe.tolerance },
            );
        }
    }
    return ok;
}

fn withinTolerance(actual: [4]u8, expected: [4]u8, tolerance: u8) bool {
    for (actual, expected) |a, e| {
        const delta = if (a > e) a - e else e - a;
        if (delta > tolerance) return false;
    }
    return true;
}

fn fixtureFor(name: []const u8) ?Fixture {
    for (fixtures) |fixture| {
        if (std.mem.eql(u8, fixture.name, name)) return fixture;
    }
    return null;
}

fn pixelAt(x: u32, y: u32) [4]u8 {
    const offset = (@as(usize, y) * width_px + x) * 4;
    return pixels[offset..][0..4].*;
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    failed = true;
    std.debug.print("okys gpu golden: " ++ fmt ++ "\n", args);
    app.requestQuit();
}

fn printHeader() void {
    _ = std.c.printf("scene\tbackend\tformat\twidth\theight\thash\texpected_hash\thash_ok\tprobes_ok\n");
}

fn printResult(scene_name: []const u8, hash: u64, expected_hash: u64, hash_ok: bool, probes_ok: bool) void {
    _ = std.c.printf(
        "%.*s\tgl_sparse_strip\trgba8\t%llu\t%llu\t0x%llx\t0x%llx\t%.*s\t%.*s\n",
        @as(c_int, @intCast(scene_name.len)),
        cString(scene_name),
        u64ForPrint(width_px),
        u64ForPrint(height_px),
        u64ForPrint(hash),
        u64ForPrint(expected_hash),
        @as(c_int, @intCast(boolName(hash_ok).len)),
        cString(boolName(hash_ok)),
        @as(c_int, @intCast(boolName(probes_ok).len)),
        cString(boolName(probes_ok)),
    );
}

fn boolName(value: bool) []const u8 {
    return if (value) "ok" else "fail";
}

fn cString(value: []const u8) [*c]const u8 {
    return @ptrCast(value.ptr);
}

fn u64ForPrint(value: anytype) c_ulonglong {
    return @intCast(value);
}
