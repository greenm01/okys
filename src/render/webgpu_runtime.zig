//! WebGPU C-ABI bridge runtime. Owns the sokol device and the sparse-strip
//! backend used when okys is embedded into an external WebGPU swapchain.

const std = @import("std");
const sokol_device = @import("sokol_device.zig");
const SparseBackend = @import("../systems/backend_sparse_strip/backend.zig").Backend;
const SparseProfile = @import("../systems/backend_sparse_strip/backend.zig").Profile;
const GpuFinePacket = @import("../systems/backend_sparse_strip/backend.zig").GpuFinePacket;

pub const WebGPUTextureFormat = enum(c_int) {
    bgra8_unorm = 1,
    rgba8_unorm = 2,
};

pub fn pixelFormatFromInt(format: c_int) ?sokol_device.PixelFormat {
    return switch (format) {
        @intFromEnum(WebGPUTextureFormat.bgra8_unorm) => .BGRA8,
        @intFromEnum(WebGPUTextureFormat.rgba8_unorm) => .RGBA8,
        else => null,
    };
}

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    backend: *SparseBackend,
    device: sokol_device.Device,
    color_format: sokol_device.PixelFormat,
    packet: GpuFinePacket = .{},
    textures: std.ArrayList(sokol_device.PathTexture) = .empty,
    render_view: ?*const anyopaque = null,
    render_width: u32 = 0,
    render_height: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, wgpu_device: *const anyopaque, color_format: sokol_device.PixelFormat) !*Runtime {
        const backend = try SparseBackend.create(gpa);
        errdefer backend.destroy();

        const self = try gpa.create(Runtime);
        self.* = .{
            .gpa = gpa,
            .backend = backend,
            .device = sokol_device.Device.initOwned(sokol_device.webgpuDesc(wgpu_device, color_format)),
            .color_format = color_format,
        };
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const gpa = self.gpa;
        self.textures.deinit(gpa);
        self.packet.deinit(gpa);
        self.device.deinit();
        self.backend.destroy();
        gpa.destroy(self);
    }

    pub fn setRenderTarget(self: *Runtime, render_view: *const anyopaque, width: u32, height: u32) void {
        self.render_view = render_view;
        self.render_width = width;
        self.render_height = height;
    }

    pub fn submit(self: *Runtime, view_width: f32, view_height: f32) bool {
        defer self.backend.clearQueued();

        if (self.render_view == null or self.render_width == 0 or self.render_height == 0) {
            _ = self.backend.build();
            return false;
        }
        if (self.backend.calls.items.len == 0) {
            return true;
        }

        var profile: SparseProfile = .{};
        if (!self.backend.buildGpuFinePacket(&self.packet, &profile)) {
            return false;
        }
        if (!self.rebuildTextures()) {
            return false;
        }

        self.device.resize(view_width, view_height, 1);
        var timing: sokol_device.SparseFineSubmitTiming = .{};
        const pass = sokol_device.swapchainPassWithAction(
            sokol_device.loadPassAction(),
            sokol_device.webgpuSwapchain(self.render_view.?, self.render_width, self.render_height, self.color_format),
        );
        const drew = self.device.drawSparseFineSurfaceTimed(
            pass,
            &self.packet,
            self.backend.segments.items,
            self.textures.items,
            self.render_width,
            self.render_height,
            .{
                .x = 0,
                .y = 0,
                .width = view_width,
                .height = view_height,
            },
            view_width,
            view_height,
            &timing,
        );
        if (!drew or timing.fallback != .none) {
            return false;
        }
        sokol_device.Device.commit();
        return true;
    }

    fn rebuildTextures(self: *Runtime) bool {
        self.textures.clearRetainingCapacity();
        self.textures.ensureTotalCapacity(self.gpa, self.backend.texture_views.items.len) catch return false;
        for (self.backend.texture_views.items) |texture| {
            self.textures.appendAssumeCapacity(.{
                .id = @intFromEnum(texture.id),
                .width = texture.width,
                .height = texture.height,
                .format = texture.format,
                .pixels = texture.pixels,
                .generation = texture.generation,
            });
        }
        return true;
    }
};
