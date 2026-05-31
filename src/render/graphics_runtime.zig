//! Generic sokol C-ABI bridge runtime. The host owns the native window,
//! graphics device, and swapchain. Okys owns sokol_gfx setup and submits the
//! recorded immediate-mode frame at okyEndFrame.

const std = @import("std");
const backend_selection = @import("backend_selection.zig");
const RenderInterface = @import("interface.zig").RenderInterface;
const sokol_device = @import("sokol_device.zig");
const SparseBackend = @import("../systems/backend_sparse_strip/backend.zig").Backend;
const SparseProfile = @import("../systems/backend_sparse_strip/backend.zig").Profile;
const GpuFinePacket = @import("../systems/backend_sparse_strip/backend.zig").GpuFinePacket;
const StencilBackend = @import("../systems/backend_stencil/backend.zig").Backend;

pub const GraphicsBackend = enum(c_int) {
    gl = 1,
    metal = 2,
    d3d11 = 3,
    vulkan = 4,
    webgpu = 5,
};

pub const PixelFormat = enum(c_int) {
    none = 0,
    bgra8 = 1,
    rgba8 = 2,
    depth_stencil = 3,
    depth = 4,
};

pub const GraphicsDesc = extern struct {
    backend: c_int,
    color_format: c_int,
    depth_format: c_int,
    sample_count: c_int,

    metal_device: ?*const anyopaque,

    d3d11_device: ?*const anyopaque,
    d3d11_device_context: ?*const anyopaque,

    vulkan_instance: ?*const anyopaque,
    vulkan_physical_device: ?*const anyopaque,
    vulkan_device: ?*const anyopaque,
    vulkan_queue: ?*const anyopaque,
    vulkan_queue_family_index: u32,

    webgpu_device: ?*const anyopaque,
};

pub const RenderTarget = extern struct {
    backend: c_int,
    width_px: c_int,
    height_px: c_int,
    color_format: c_int,
    depth_format: c_int,
    sample_count: c_int,

    gl_framebuffer: u32,

    metal_current_drawable: ?*const anyopaque,
    metal_depth_stencil_texture: ?*const anyopaque,
    metal_msaa_color_texture: ?*const anyopaque,

    d3d11_render_view: ?*const anyopaque,
    d3d11_resolve_view: ?*const anyopaque,
    d3d11_depth_stencil_view: ?*const anyopaque,

    vulkan_render_image: ?*const anyopaque,
    vulkan_render_view: ?*const anyopaque,
    vulkan_resolve_image: ?*const anyopaque,
    vulkan_resolve_view: ?*const anyopaque,
    vulkan_depth_stencil_image: ?*const anyopaque,
    vulkan_depth_stencil_view: ?*const anyopaque,
    vulkan_render_finished_semaphore: ?*const anyopaque,
    vulkan_present_complete_semaphore: ?*const anyopaque,

    webgpu_render_view: ?*const anyopaque,
    webgpu_resolve_view: ?*const anyopaque,
    webgpu_depth_stencil_view: ?*const anyopaque,
};

const BackendStorage = union(enum) {
    stencil: *StencilBackend,
    sparse: *SparseBackend,

    fn interface(self: BackendStorage) RenderInterface {
        return switch (self) {
            .stencil => |backend| backend.interface(),
            .sparse => |backend| backend.interface(),
        };
    }

    fn deinit(self: BackendStorage) void {
        switch (self) {
            .stencil => |backend| backend.destroy(),
            .sparse => |backend| backend.destroy(),
        }
    }

    fn clearQueued(self: BackendStorage) void {
        switch (self) {
            .stencil => |backend| backend.clearQueued(),
            .sparse => |backend| backend.clearQueued(),
        }
    }
};

pub const Runtime = struct {
    gpa: std.mem.Allocator,
    backend: BackendStorage,
    device: sokol_device.Device,
    graphics_backend: GraphicsBackend,
    color_format: sokol_device.PixelFormat,
    depth_format: sokol_device.PixelFormat,
    sample_count: i32,
    target: ?RenderTarget = null,
    packet: GpuFinePacket = .{},
    textures: std.ArrayList(sokol_device.PathTexture) = .empty,

    pub fn create(gpa: std.mem.Allocator, flags: u32, desc: GraphicsDesc) !*Runtime {
        const graphics_backend = try graphicsBackendFromInt(desc.backend);
        if (!validDesc(desc, graphics_backend)) return error.InvalidGraphicsDesc;
        const color_format = if (desc.color_format == @intFromEnum(PixelFormat.none))
            defaultColorFormat(graphics_backend)
        else
            pixelFormatFromInt(desc.color_format) orelse defaultColorFormat(graphics_backend);
        const depth_format = pixelFormatFromInt(desc.depth_format) orelse defaultDepthFormat(graphics_backend);
        const sample_count = normalizedSampleCount(desc.sample_count);
        const backend = try createBackend(gpa, flags);
        errdefer backend.deinit();

        const self = try gpa.create(Runtime);
        self.* = .{
            .gpa = gpa,
            .backend = backend,
            .device = sokol_device.Device.initOwned(deviceDesc(desc, graphics_backend, color_format, depth_format, sample_count)),
            .graphics_backend = graphics_backend,
            .color_format = color_format,
            .depth_format = depth_format,
            .sample_count = sample_count,
        };
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const gpa = self.gpa;
        self.textures.deinit(gpa);
        self.packet.deinit(gpa);
        self.device.deinit();
        self.backend.deinit();
        gpa.destroy(self);
    }

    pub fn interface(self: *Runtime) RenderInterface {
        return self.backend.interface();
    }

    pub fn setRenderTarget(self: *Runtime, target: RenderTarget) bool {
        if (target.width_px <= 0 or target.height_px <= 0) return false;
        const backend = graphicsBackendFromInt(target.backend) catch return false;
        if (backend != self.graphics_backend) return false;
        if (!validTarget(target, backend)) return false;
        self.target = normalizedTarget(target, self.color_format, self.depth_format, self.sample_count);
        return true;
    }

    pub fn submit(self: *Runtime, view_width: f32, view_height: f32, dpr: f32) bool {
        defer self.backend.clearQueued();

        const target = self.currentTarget(view_width, view_height, dpr) orelse {
            _ = self.buildWithoutSubmit();
            return false;
        };
        const swapchain = swapchainFromTarget(target);
        self.device.resize(view_width, view_height, dpr);

        return switch (self.backend) {
            .stencil => |backend| self.submitStencil(backend, swapchain),
            .sparse => |backend| self.submitSparse(backend, swapchain, view_width, view_height),
        };
    }

    fn submitStencil(self: *Runtime, backend: *StencilBackend, swapchain: sokol_device.Swapchain) bool {
        const pass = sokol_device.swapchainPassWithAction(sokol_device.loadColorClearStencilPassAction(), swapchain);
        const drew = backend.submitToDevice(&self.device, pass);
        sokol_device.Device.commit();
        return drew;
    }

    fn submitSparse(self: *Runtime, backend: *SparseBackend, swapchain: sokol_device.Swapchain, view_width: f32, view_height: f32) bool {
        if (backend.calls.items.len == 0) {
            sokol_device.Device.commit();
            return true;
        }
        var profile: SparseProfile = .{};
        if (!backend.buildGpuFinePacket(&self.packet, &profile)) return false;
        if (!self.rebuildTextures(backend)) return false;

        var timing: sokol_device.SparseFineSubmitTiming = .{};
        const pass = sokol_device.swapchainPassWithAction(sokol_device.loadPassAction(), swapchain);
        const target_width: u32 = @intCast(swapchain.width);
        const target_height: u32 = @intCast(swapchain.height);
        const drew = self.device.drawSparseFineSurfaceTimed(
            pass,
            &self.packet,
            backend.segments.items,
            self.textures.items,
            target_width,
            target_height,
            .{ .x = 0, .y = 0, .width = view_width, .height = view_height },
            view_width,
            view_height,
            &timing,
        );
        if (!drew or timing.fallback != .none) return false;
        sokol_device.Device.commit();
        return true;
    }

    fn rebuildTextures(self: *Runtime, backend: *SparseBackend) bool {
        self.textures.clearRetainingCapacity();
        self.textures.ensureTotalCapacity(self.gpa, backend.texture_views.items.len) catch return false;
        for (backend.texture_views.items) |texture| {
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

    fn buildWithoutSubmit(self: *Runtime) bool {
        return switch (self.backend) {
            .stencil => |backend| backend.buildStencilPass(),
            .sparse => |backend| backend.build(),
        };
    }

    fn currentTarget(self: *const Runtime, view_width: f32, view_height: f32, dpr: f32) ?RenderTarget {
        if (self.target) |target| return target;
        if (self.graphics_backend != .gl) return null;
        const width = pixelExtent(view_width, dpr);
        const height = pixelExtent(view_height, dpr);
        if (width == 0 or height == 0) return null;
        return .{
            .backend = @intFromEnum(GraphicsBackend.gl),
            .width_px = @intCast(width),
            .height_px = @intCast(height),
            .color_format = @intFromEnum(pixelFormatToPublic(self.color_format)),
            .depth_format = @intFromEnum(pixelFormatToPublic(self.depth_format)),
            .sample_count = self.sample_count,
            .gl_framebuffer = 0,
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
    }
};

fn createBackend(gpa: std.mem.Allocator, flags: u32) !BackendStorage {
    return switch (backend_selection.fromCreateFlags(flags)) {
        .stencil_cover => .{ .stencil = try StencilBackend.createWithFlags(gpa, flags) },
        .sparse_strip => .{ .sparse = try SparseBackend.create(gpa) },
    };
}

fn validDesc(desc: GraphicsDesc, backend: GraphicsBackend) bool {
    return switch (backend) {
        .gl => true,
        .metal => desc.metal_device != null,
        .d3d11 => desc.d3d11_device != null and desc.d3d11_device_context != null,
        .vulkan => desc.vulkan_instance != null and
            desc.vulkan_physical_device != null and
            desc.vulkan_device != null and
            desc.vulkan_queue != null,
        .webgpu => desc.webgpu_device != null,
    };
}

fn validTarget(target: RenderTarget, backend: GraphicsBackend) bool {
    return switch (backend) {
        .gl => true,
        .metal => target.metal_current_drawable != null,
        .d3d11 => target.d3d11_render_view != null,
        .vulkan => target.vulkan_render_image != null and
            target.vulkan_render_view != null and
            target.vulkan_render_finished_semaphore != null and
            target.vulkan_present_complete_semaphore != null,
        .webgpu => target.webgpu_render_view != null,
    };
}

fn deviceDesc(
    desc: GraphicsDesc,
    backend: GraphicsBackend,
    color_format: sokol_device.PixelFormat,
    depth_format: sokol_device.PixelFormat,
    sample_count: i32,
) sokol_device.Desc {
    var result: sokol_device.Desc = .{};
    result.environment.defaults = .{
        .color_format = color_format,
        .depth_format = depth_format,
        .sample_count = sample_count,
    };
    switch (backend) {
        .gl => {},
        .metal => result.environment.metal = .{ .device = desc.metal_device },
        .d3d11 => result.environment.d3d11 = .{
            .device = desc.d3d11_device,
            .device_context = desc.d3d11_device_context,
        },
        .vulkan => result.environment.vulkan = .{
            .instance = desc.vulkan_instance,
            .physical_device = desc.vulkan_physical_device,
            .device = desc.vulkan_device,
            .queue = desc.vulkan_queue,
            .queue_family_index = desc.vulkan_queue_family_index,
        },
        .webgpu => result.environment.wgpu = .{ .device = desc.webgpu_device },
    }
    return result;
}

fn swapchainFromTarget(target: RenderTarget) sokol_device.Swapchain {
    var swapchain: sokol_device.Swapchain = .{
        .width = target.width_px,
        .height = target.height_px,
        .sample_count = normalizedSampleCount(target.sample_count),
        .color_format = pixelFormatFromInt(target.color_format) orelse .RGBA8,
        .depth_format = pixelFormatFromInt(target.depth_format) orelse .NONE,
    };
    const backend = graphicsBackendFromInt(target.backend) catch return swapchain;
    switch (backend) {
        .gl => swapchain.gl = .{ .framebuffer = target.gl_framebuffer },
        .metal => swapchain.metal = .{
            .current_drawable = target.metal_current_drawable,
            .depth_stencil_texture = target.metal_depth_stencil_texture,
            .msaa_color_texture = target.metal_msaa_color_texture,
        },
        .d3d11 => swapchain.d3d11 = .{
            .render_view = target.d3d11_render_view,
            .resolve_view = target.d3d11_resolve_view,
            .depth_stencil_view = target.d3d11_depth_stencil_view,
        },
        .vulkan => swapchain.vulkan = .{
            .render_image = target.vulkan_render_image,
            .render_view = target.vulkan_render_view,
            .resolve_image = target.vulkan_resolve_image,
            .resolve_view = target.vulkan_resolve_view,
            .depth_stencil_image = target.vulkan_depth_stencil_image,
            .depth_stencil_view = target.vulkan_depth_stencil_view,
            .render_finished_semaphore = target.vulkan_render_finished_semaphore,
            .present_complete_semaphore = target.vulkan_present_complete_semaphore,
        },
        .webgpu => swapchain.wgpu = .{
            .render_view = target.webgpu_render_view,
            .resolve_view = target.webgpu_resolve_view,
            .depth_stencil_view = target.webgpu_depth_stencil_view,
        },
    }
    return swapchain;
}

fn normalizedTarget(
    target: RenderTarget,
    color_format: sokol_device.PixelFormat,
    depth_format: sokol_device.PixelFormat,
    sample_count: i32,
) RenderTarget {
    var normalized = target;
    if (normalized.color_format == @intFromEnum(PixelFormat.none) or pixelFormatFromInt(normalized.color_format) == null) {
        normalized.color_format = @intFromEnum(pixelFormatToPublic(color_format));
    }
    if (pixelFormatFromInt(normalized.depth_format) == null) {
        normalized.depth_format = @intFromEnum(pixelFormatToPublic(depth_format));
    }
    normalized.sample_count = normalizedSampleCount(if (normalized.sample_count > 0) normalized.sample_count else sample_count);
    return normalized;
}

pub fn graphicsBackendFromInt(value: c_int) !GraphicsBackend {
    return switch (value) {
        @intFromEnum(GraphicsBackend.gl) => .gl,
        @intFromEnum(GraphicsBackend.metal) => .metal,
        @intFromEnum(GraphicsBackend.d3d11) => .d3d11,
        @intFromEnum(GraphicsBackend.vulkan) => .vulkan,
        @intFromEnum(GraphicsBackend.webgpu) => .webgpu,
        else => error.InvalidGraphicsBackend,
    };
}

pub fn pixelFormatFromInt(value: c_int) ?sokol_device.PixelFormat {
    return switch (value) {
        @intFromEnum(PixelFormat.none) => .NONE,
        @intFromEnum(PixelFormat.bgra8) => .BGRA8,
        @intFromEnum(PixelFormat.rgba8) => .RGBA8,
        @intFromEnum(PixelFormat.depth_stencil) => .DEPTH_STENCIL,
        @intFromEnum(PixelFormat.depth) => .DEPTH,
        else => null,
    };
}

fn pixelFormatToPublic(format: sokol_device.PixelFormat) PixelFormat {
    return switch (format) {
        .BGRA8 => .bgra8,
        .RGBA8 => .rgba8,
        .DEPTH_STENCIL => .depth_stencil,
        .DEPTH => .depth,
        else => .none,
    };
}

fn defaultColorFormat(backend: GraphicsBackend) sokol_device.PixelFormat {
    return switch (backend) {
        .gl => .RGBA8,
        .metal, .d3d11, .vulkan, .webgpu => .BGRA8,
    };
}

fn defaultDepthFormat(backend: GraphicsBackend) sokol_device.PixelFormat {
    return switch (backend) {
        .gl => .DEPTH_STENCIL,
        .metal, .d3d11, .vulkan, .webgpu => .NONE,
    };
}

fn normalizedSampleCount(value: c_int) i32 {
    return if (value > 0) @intCast(value) else 1;
}

fn pixelExtent(points: f32, dpr: f32) u32 {
    if (points <= 0.0) return 0;
    const ratio = if (dpr > 0.0) dpr else 1.0;
    return @intFromFloat(@ceil(points * ratio));
}
