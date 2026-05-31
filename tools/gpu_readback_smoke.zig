const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");

const app = sokol.app;
const c_api = okys.c_api;
const graphics_runtime = okys.render.graphics_runtime;
const sokol_device = okys.render.sokol_device;

const OKY_ANTIALIAS: c_int = 1 << 0;
const OKY_SPARSE_STRIP: c_int = 1 << 2;
const width_px: u32 = 128;
const height_px: u32 = 96;

var ctx: ?*okys.state.context.Context = null;
var target: ?sokol_device.GlOffscreenTarget = null;
var pixels: []u8 = &.{};
var failed = false;

pub fn main() void {
    app.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = width_px,
        .height = height_px,
        .sample_count = 1,
        .swap_interval = 0,
        .high_dpi = false,
        .window_title = "Okys GPU readback smoke",
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
    const c = ctx orelse {
        fail("missing context", .{});
        return;
    };
    const t = target orelse {
        fail("missing offscreen target", .{});
        return;
    };

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
    if (c_api.okySetRenderTarget(c, &render_target) != 1) {
        fail("okySetRenderTarget failed", .{});
        return;
    }

    c_api.okyBeginFrame(c, @floatFromInt(width_px), @floatFromInt(height_px), 1.0);
    c_api.okyBeginPath(c);
    c_api.okyRect(c, 16, 18, 72, 42);
    c_api.okyFillColor(c, c_api.okyRGBA(32, 144, 220, 255));
    c_api.okyFill(c);
    c_api.okyBeginPath(c);
    c_api.okyCircle(c, 88, 56, 18);
    c_api.okyFillColor(c, c_api.okyRGBA(242, 196, 64, 255));
    c_api.okyFill(c);
    c_api.okyEndFrame(c);

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
    if (status != @intFromEnum(graphics_runtime.ReadPixelsStatus.ok)) {
        fail("okyReadPixels failed with status {d}", .{status});
        return;
    }

    const center = pixelAt(52, 39);
    const corner = pixelAt(4, 4);
    const digest = fnv1a64(pixels);
    if (center[2] < 160 or center[3] < 250 or corner[3] > 8) {
        fail("unexpected probes hash=0x{x} center={any} corner={any}", .{ digest, center, corner });
        return;
    }
    std.debug.print(
        "okys gpu readback smoke ok\tbackend=gl\tformat=rgba8\tsize={d}x{d}\thash=0x{x}\tcenter={any}\tcorner={any}\n",
        .{ width_px, height_px, digest, center, corner },
    );
    app.requestQuit();
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

fn fail(comptime fmt: []const u8, args: anytype) void {
    failed = true;
    std.debug.print("okys gpu readback smoke: " ++ fmt ++ "\n", args);
    app.requestQuit();
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
