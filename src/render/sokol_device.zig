//! Shared sokol_gfx device layer. This is the only module that may import
//! sokol.gfx directly.

const sokol = @import("sokol");
const sg = sokol.gfx;
const std = @import("std");
const blit_shader = @import("okys_blit_shader");
const gpu_fine = @import("../systems/backend_sparse_strip/gpu_fine.zig");
const sparse_encode = @import("../systems/backend_sparse_strip/encode.zig");
const image = @import("../types/image.zig");
const path = @import("../types/path.zig");
const path_shader = @import("okys_path_shader");
const sparse_fine_shader = @import("okys_sparse_fine_shader");
const smoke_shader = @import("okys_shader");

pub const Desc = sg.Desc;
pub const Buffer = sg.Buffer;
pub const Shader = sg.Shader;
pub const Pipeline = sg.Pipeline;
pub const Pass = sg.Pass;
pub const Bindings = sg.Bindings;
pub const Color = sg.Color;
pub const Image = sg.Image;
pub const Sampler = sg.Sampler;
pub const View = sg.View;
pub const PassAction = sg.PassAction;
pub const Swapchain = sg.Swapchain;
pub const BufferDesc = sg.BufferDesc;
pub const PipelineDesc = sg.PipelineDesc;

pub const blit_position_attr = blit_shader.ATTR_blit_position;
pub const blit_uv_attr = blit_shader.ATTR_blit_uv;
pub const blit_vs_params_slot = blit_shader.UB_vs_params;
pub const blit_view_slot = blit_shader.VIEW_sparse_tex;
pub const blit_sampler_slot = blit_shader.SMP_sparse_smp;
pub const BlitVsParams = blit_shader.VsParams;
pub const SparseClearParams = sparse_fine_shader.ClearParams;
pub const SparseFineParams = sparse_fine_shader.FineParams;
pub const sparse_clear_surface_view_slot = sparse_fine_shader.VIEW_clear_surface_img;
pub const sparse_calls_view_slot = sparse_fine_shader.VIEW_calls_buf;
pub const sparse_segments_view_slot = sparse_fine_shader.VIEW_segments_buf;
pub const sparse_clips_view_slot = sparse_fine_shader.VIEW_clips_buf;
pub const sparse_tasks_view_slot = sparse_fine_shader.VIEW_tasks_buf;
pub const sparse_fine_surface_view_slot = sparse_fine_shader.VIEW_fine_surface_img;
pub const sparse_image_view_slot = sparse_fine_shader.VIEW_image_tex;
pub const sparse_clip_indices_view_slot = sparse_fine_shader.VIEW_clip_indices_buf;
pub const sparse_image_sampler_slot = sparse_fine_shader.SMP_image_smp;
pub const sparse_clear_params_slot = sparse_fine_shader.UB_clear_params;
pub const sparse_fine_params_slot = sparse_fine_shader.UB_fine_params;

pub const smoke_position_attr = smoke_shader.ATTR_smoke_position;
pub const smoke_color_attr = smoke_shader.ATTR_smoke_color0;

pub const path_position_attr = path_shader.ATTR_path_stencil_position;
pub const path_uv_attr = path_shader.ATTR_path_stencil_uv;
pub const path_cover_position_attr = path_shader.ATTR_path_cover_position;
pub const path_cover_uv_attr = path_shader.ATTR_path_cover_uv;
pub const path_vs_params_slot = path_shader.UB_vs_params;
pub const path_fs_params_slot = path_shader.UB_fs_params;
pub const path_image_view_slot = path_shader.VIEW_image_tex;
pub const path_image_sampler_slot = path_shader.SMP_image_smp;
pub const PathVsParams = path_shader.VsParams;
pub const PathFsParams = path_shader.FsParams;
pub const max_path_textures = 64;

const path_default_texture_pixels = [_]u8{ 255, 255, 255, 255 };

pub const SparseFineFallback = enum {
    none,
    unsupported_packet,
    empty_surface,
    empty_packet,
    missing_texture,
    missing_resources,
};

pub const SparseFineSubmitTiming = struct {
    ok: bool = false,
    fallback: SparseFineFallback = .none,
    total_ns: u64 = 0,
    resource_ns: u64 = 0,
    upload_ns: u64 = 0,
    compute_encode_ns: u64 = 0,
    blit_encode_ns: u64 = 0,
    calls: usize = 0,
    tasks: usize = 0,
    dispatches: usize = 0,
    upload_bytes: usize = 0,
};

pub const PathPipelineKind = enum {
    stencil_nonzero,
    stencil_even_odd,
    cover,
    convex,
    fringe_stencil,
    fringe,
    triangles,
};

pub const PathDrawKind = enum {
    stencil_nonzero,
    stencil_even_odd,
    cover,
    convex,
    fringe_stencil,
    fringe,
    triangles,
};

pub const PathDraw = struct {
    kind: PathDrawKind,
    base_element: u32,
    element_count: u32,
    uniform_index: u32,
};

pub const StencilDraw = struct {
    mode: PathPipelineKind,
    base_element: u32,
    element_count: u32,
};

pub const CoverDraw = struct {
    base_element: u32,
    element_count: u32,
    uniform_index: u32,
};

pub const SmokeVertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

pub const SmokeTriangle = struct {
    vertices: [3]SmokeVertex,
};

pub const PathTexture = struct {
    id: u32,
    width: u32,
    height: u32,
    format: image.TexFormat,
    pixels: []const u8,
    generation: u64 = 0,
};

const PathTextureResource = struct {
    id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    generation: u64 = 0,
    image: Image = .{},
    view: View = .{},
};

const StorageBufferResource = struct {
    buffer: Buffer = .{},
    view: View = .{},
    capacity: usize = 0,
};

pub const BlitRect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const BlitVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

pub const Device = struct {
    owns_setup: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    dpr: f32 = 1.0,
    blit_shader: Shader = .{},
    blit_pipeline: Pipeline = .{},
    blit_vertices: Buffer = .{},
    blit_image: Image = .{},
    blit_sampler: Sampler = .{},
    blit_view: View = .{},
    blit_width: u32 = 0,
    blit_height: u32 = 0,
    smoke_shader: Shader = .{},
    smoke_pipeline: Pipeline = .{},
    smoke_vertices: Buffer = .{},
    smoke_bindings: Bindings = .{},
    path_stencil_shader: Shader = .{},
    path_cover_shader: Shader = .{},
    path_stencil_nonzero_pipeline: Pipeline = .{},
    path_stencil_even_odd_pipeline: Pipeline = .{},
    path_cover_pipeline: Pipeline = .{},
    path_convex_pipeline: Pipeline = .{},
    path_fringe_stencil_pipeline: Pipeline = .{},
    path_fringe_pipeline: Pipeline = .{},
    path_triangles_pipeline: Pipeline = .{},
    path_texture_sampler: Sampler = .{},
    path_default_image: Image = .{},
    path_default_view: View = .{},
    path_textures: [max_path_textures]PathTextureResource = @splat(.{}),
    path_vertex_buffer: Buffer = .{},
    path_index_buffer: Buffer = .{},
    path_vertex_capacity: usize = 0,
    path_index_capacity: usize = 0,
    sparse_clear_shader: Shader = .{},
    sparse_fine_shader: Shader = .{},
    sparse_clear_pipeline: Pipeline = .{},
    sparse_fine_pipeline: Pipeline = .{},
    sparse_surface_image: Image = .{},
    sparse_surface_storage_view: View = .{},
    sparse_surface_texture_view: View = .{},
    sparse_surface_width: u32 = 0,
    sparse_surface_height: u32 = 0,
    sparse_call_buffer: StorageBufferResource = .{},
    sparse_segment_buffer: StorageBufferResource = .{},
    sparse_clip_buffer: StorageBufferResource = .{},
    sparse_clip_index_buffer: StorageBufferResource = .{},
    sparse_task_buffer: StorageBufferResource = .{},

    pub fn initOwned(desc: Desc) Device {
        sg.setup(desc);
        return .{ .owns_setup = true };
    }

    pub fn attach() Device {
        return .{};
    }

    pub fn deinit(self: *Device) void {
        self.destroyBlitResources();
        self.destroySmokeResources();
        self.destroySparseFineResources();
        self.destroyPathTextureResources();
        self.destroyPathResources();
        if (self.owns_setup) {
            sg.shutdown();
            self.owns_setup = false;
        }
    }

    pub fn resize(self: *Device, width: f32, height: f32, dpr: f32) void {
        self.dpr = if (dpr > 0.0) dpr else 1.0;
        self.width = pixelExtent(width, self.dpr);
        self.height = pixelExtent(height, self.dpr);
    }

    pub fn createSmokeResources(self: *Device) void {
        self.destroySmokeResources();

        const triangle = smokeTriangle();
        self.smoke_shader = sg.makeShader(smoke_shader.smokeShaderDesc(sg.queryBackend()));
        self.smoke_vertices = sg.makeBuffer(smokeVertexBufferDesc(&triangle));
        self.smoke_pipeline = sg.makePipeline(smokePipelineDesc(self.smoke_shader));
        self.smoke_bindings = smokeBindings(self.smoke_vertices);
    }

    pub fn destroySmokeResources(self: *Device) void {
        if (self.smoke_pipeline.id != 0) {
            sg.destroyPipeline(self.smoke_pipeline);
            self.smoke_pipeline = .{};
        }
        if (self.smoke_shader.id != 0) {
            sg.destroyShader(self.smoke_shader);
            self.smoke_shader = .{};
        }
        if (self.smoke_vertices.id != 0) {
            sg.destroyBuffer(self.smoke_vertices);
            self.smoke_vertices = .{};
        }
        self.smoke_bindings = .{};
    }

    pub fn createBlitResources(self: *Device, surface_width: u32, surface_height: u32) void {
        self.destroyBlitResources();

        self.blit_shader = sg.makeShader(blit_shader.blitShaderDesc(sg.queryBackend()));
        self.blit_pipeline = sg.makePipeline(blitPipelineDesc(self.blit_shader));
        self.blit_vertices = sg.makeBuffer(blitVertexBufferDesc());
        self.blit_image = sg.makeImage(blitImageDesc(surface_width, surface_height));
        self.blit_sampler = sg.makeSampler(blitSamplerDesc());
        self.blit_view = sg.makeView(blitTextureViewDesc(self.blit_image));
        self.blit_width = surface_width;
        self.blit_height = surface_height;
    }

    pub fn destroyBlitResources(self: *Device) void {
        if (self.blit_view.id != 0) {
            sg.destroyView(self.blit_view);
            self.blit_view = .{};
        }
        if (self.blit_sampler.id != 0) {
            sg.destroySampler(self.blit_sampler);
            self.blit_sampler = .{};
        }
        if (self.blit_image.id != 0) {
            sg.destroyImage(self.blit_image);
            self.blit_image = .{};
        }
        if (self.blit_vertices.id != 0) {
            sg.destroyBuffer(self.blit_vertices);
            self.blit_vertices = .{};
        }
        if (self.blit_pipeline.id != 0) {
            sg.destroyPipeline(self.blit_pipeline);
            self.blit_pipeline = .{};
        }
        if (self.blit_shader.id != 0) {
            sg.destroyShader(self.blit_shader);
            self.blit_shader = .{};
        }
        self.blit_width = 0;
        self.blit_height = 0;
    }

    pub fn drawRgbaSurface(
        self: *Device,
        pass: Pass,
        pixels: []const u8,
        surface_width: u32,
        surface_height: u32,
        dest: BlitRect,
        view_width: f32,
        view_height: f32,
    ) void {
        if (surface_width == 0 or surface_height == 0) return;
        if (pixels.len != @as(usize, surface_width) * @as(usize, surface_height) * 4) return;
        self.ensureBlitResources(surface_width, surface_height);

        var image_data: sg.ImageData = .{};
        image_data.mip_levels[0] = rangeFromSlice(u8, pixels);
        sg.updateImage(self.blit_image, image_data);

        const vertices = blitQuad(dest);
        sg.updateBuffer(self.blit_vertices, rangeFromSlice(BlitVertex, vertices[0..]));

        self.beginPass(pass);
        const params = blitVsParams(view_width, view_height);
        sg.applyPipeline(self.blit_pipeline);
        sg.applyBindings(blitBindings(self.blit_vertices, self.blit_view, self.blit_sampler));
        sg.applyUniforms(blit_vs_params_slot, rangeFromValue(BlitVsParams, &params));
        sg.draw(0, 4, 1);
        sg.endPass();
    }

    pub fn drawSparseFineSurface(
        self: *Device,
        pass: Pass,
        packet: *const gpu_fine.Packet,
        segments: []const sparse_encode.Segment,
        textures: []const PathTexture,
        surface_width: u32,
        surface_height: u32,
        dest: BlitRect,
        view_width: f32,
        view_height: f32,
    ) bool {
        var timing: SparseFineSubmitTiming = .{};
        return self.drawSparseFineSurfaceTimed(
            pass,
            packet,
            segments,
            textures,
            surface_width,
            surface_height,
            dest,
            view_width,
            view_height,
            &timing,
        );
    }

    pub fn drawSparseFineSurfaceTimed(
        self: *Device,
        pass: Pass,
        packet: *const gpu_fine.Packet,
        segments: []const sparse_encode.Segment,
        textures: []const PathTexture,
        surface_width: u32,
        surface_height: u32,
        dest: BlitRect,
        view_width: f32,
        view_height: f32,
        timing: *SparseFineSubmitTiming,
    ) bool {
        const total_start = nowNs();
        timing.* = .{
            .calls = packet.calls.items.len,
            .tasks = packet.tasks.items.len,
            .dispatches = packet.stats.dispatches,
            .upload_bytes = packet.stats.upload_bytes,
        };
        defer timing.total_ns = elapsedSince(total_start);

        if (!packet.stats.supported) {
            timing.fallback = .unsupported_packet;
            return false;
        }
        if (surface_width == 0 or surface_height == 0) {
            timing.fallback = .empty_surface;
            return false;
        }
        if (packet.calls.items.len == 0 or packet.tasks.items.len == 0) {
            timing.fallback = .empty_packet;
            return false;
        }

        const resource_start = nowNs();
        self.ensurePathTextureResources(textures);
        if (!self.sparseTexturesAvailable(packet)) {
            timing.resource_ns = elapsedSince(resource_start);
            timing.fallback = .missing_texture;
            return false;
        }

        self.ensureSparseFineResources(surface_width, surface_height, packet, segments);
        timing.resource_ns = elapsedSince(resource_start);
        if (self.sparse_clear_pipeline.id == 0 or self.sparse_fine_pipeline.id == 0) {
            timing.fallback = .missing_resources;
            return false;
        }
        if (self.sparse_surface_storage_view.id == 0 or self.sparse_surface_texture_view.id == 0) {
            timing.fallback = .missing_resources;
            return false;
        }
        if (self.path_texture_sampler.id == 0 or self.path_default_view.id == 0) {
            timing.fallback = .missing_resources;
            return false;
        }

        const upload_start = nowNs();
        uploadStorageBuffer(gpu_fine.GpuCall, self.sparse_call_buffer.buffer, packet.calls.items);
        uploadStorageBuffer(gpu_fine.GpuClip, self.sparse_clip_buffer.buffer, packet.clips.items);
        uploadStorageBuffer(gpu_fine.GpuClipIndex, self.sparse_clip_index_buffer.buffer, packet.clip_indices.items);
        uploadStorageBuffer(gpu_fine.GpuFineTask, self.sparse_task_buffer.buffer, packet.tasks.items);
        uploadStorageBuffer(sparse_encode.Segment, self.sparse_segment_buffer.buffer, segments);
        timing.upload_ns = elapsedSince(upload_start);

        const compute_start = nowNs();
        sg.beginPass(.{ .compute = true, .label = "okys_sparse_fine_compute" });
        sg.applyPipeline(self.sparse_clear_pipeline);
        sg.applyBindings(sparseClearBindings(self.sparse_surface_storage_view));
        const clear_params: SparseClearParams = .{
            .surface_width = @intCast(surface_width),
            .surface_height = @intCast(surface_height),
        };
        sg.applyUniforms(sparse_clear_params_slot, rangeFromValue(SparseClearParams, &clear_params));
        sg.dispatch(dispatchGroups(surface_width, 8), dispatchGroups(surface_height, 8), 1);

        sg.applyPipeline(self.sparse_fine_pipeline);
        for (packet.calls.items) |call| {
            if (call.task_count == 0) continue;
            const texture = self.sparseTextureForCall(call);
            sg.applyBindings(sparseFineBindings(
                self.sparse_call_buffer.view,
                self.sparse_segment_buffer.view,
                self.sparse_clip_buffer.view,
                self.sparse_task_buffer.view,
                self.sparse_clip_index_buffer.view,
                self.sparse_surface_storage_view,
                texture.view,
                self.path_texture_sampler,
            ));
            const fine_params: SparseFineParams = .{
                .surface_width = @intCast(surface_width),
                .surface_height = @intCast(surface_height),
                .task_start = @intCast(call.task_start),
                .task_count = @intCast(call.task_count),
            };
            sg.applyUniforms(sparse_fine_params_slot, rangeFromValue(SparseFineParams, &fine_params));
            sg.dispatch(@intCast(call.task_count), 1, 1);
        }
        sg.endPass();
        timing.compute_encode_ns = elapsedSince(compute_start);

        const blit_start = nowNs();
        self.ensureBlitResources(surface_width, surface_height);
        const vertices = blitQuad(dest);
        sg.updateBuffer(self.blit_vertices, rangeFromSlice(BlitVertex, vertices[0..]));

        self.beginPass(pass);
        const params = blitVsParams(view_width, view_height);
        sg.applyPipeline(self.blit_pipeline);
        sg.applyBindings(blitBindings(self.blit_vertices, self.sparse_surface_texture_view, self.blit_sampler));
        sg.applyUniforms(blit_vs_params_slot, rangeFromValue(BlitVsParams, &params));
        sg.draw(0, 4, 1);
        sg.endPass();
        timing.blit_encode_ns = elapsedSince(blit_start);
        timing.ok = true;
        return true;
    }

    pub fn createPathResources(self: *Device, vertex_capacity: usize, index_capacity: usize) void {
        self.destroyPathResources();
        const vertex_count = @max(vertex_capacity, 1);
        const index_count = @max(index_capacity, 1);
        self.path_stencil_shader = sg.makeShader(path_shader.pathStencilShaderDesc(sg.queryBackend()));
        self.path_cover_shader = sg.makeShader(path_shader.pathCoverShaderDesc(sg.queryBackend()));
        self.path_stencil_nonzero_pipeline = sg.makePipeline(pathPipelineDesc(self.path_stencil_shader, .stencil_nonzero));
        self.path_stencil_even_odd_pipeline = sg.makePipeline(pathPipelineDesc(self.path_stencil_shader, .stencil_even_odd));
        self.path_cover_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .cover));
        self.path_convex_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .convex));
        self.path_fringe_stencil_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .fringe_stencil));
        self.path_fringe_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .fringe));
        self.path_triangles_pipeline = sg.makePipeline(pathPipelineDesc(self.path_cover_shader, .triangles));
        self.path_vertex_buffer = sg.makeBuffer(pathVertexBufferDesc(vertex_count));
        self.path_index_buffer = sg.makeBuffer(pathIndexBufferDesc(index_count));
        self.path_vertex_capacity = vertex_count;
        self.path_index_capacity = index_count;
    }

    pub fn destroyPathResources(self: *Device) void {
        if (self.path_triangles_pipeline.id != 0) {
            sg.destroyPipeline(self.path_triangles_pipeline);
            self.path_triangles_pipeline = .{};
        }
        if (self.path_fringe_pipeline.id != 0) {
            sg.destroyPipeline(self.path_fringe_pipeline);
            self.path_fringe_pipeline = .{};
        }
        if (self.path_fringe_stencil_pipeline.id != 0) {
            sg.destroyPipeline(self.path_fringe_stencil_pipeline);
            self.path_fringe_stencil_pipeline = .{};
        }
        if (self.path_convex_pipeline.id != 0) {
            sg.destroyPipeline(self.path_convex_pipeline);
            self.path_convex_pipeline = .{};
        }
        if (self.path_cover_pipeline.id != 0) {
            sg.destroyPipeline(self.path_cover_pipeline);
            self.path_cover_pipeline = .{};
        }
        if (self.path_stencil_even_odd_pipeline.id != 0) {
            sg.destroyPipeline(self.path_stencil_even_odd_pipeline);
            self.path_stencil_even_odd_pipeline = .{};
        }
        if (self.path_stencil_nonzero_pipeline.id != 0) {
            sg.destroyPipeline(self.path_stencil_nonzero_pipeline);
            self.path_stencil_nonzero_pipeline = .{};
        }
        if (self.path_cover_shader.id != 0) {
            sg.destroyShader(self.path_cover_shader);
            self.path_cover_shader = .{};
        }
        if (self.path_stencil_shader.id != 0) {
            sg.destroyShader(self.path_stencil_shader);
            self.path_stencil_shader = .{};
        }
        if (self.path_vertex_buffer.id != 0) {
            sg.destroyBuffer(self.path_vertex_buffer);
            self.path_vertex_buffer = .{};
        }
        if (self.path_index_buffer.id != 0) {
            sg.destroyBuffer(self.path_index_buffer);
            self.path_index_buffer = .{};
        }
        self.path_vertex_capacity = 0;
        self.path_index_capacity = 0;
    }

    pub fn destroyPathTextureResources(self: *Device) void {
        for (&self.path_textures) |*texture| {
            self.destroyPathTextureResource(texture);
        }
        if (self.path_default_view.id != 0) {
            sg.destroyView(self.path_default_view);
            self.path_default_view = .{};
        }
        if (self.path_default_image.id != 0) {
            sg.destroyImage(self.path_default_image);
            self.path_default_image = .{};
        }
        if (self.path_texture_sampler.id != 0) {
            sg.destroySampler(self.path_texture_sampler);
            self.path_texture_sampler = .{};
        }
    }

    pub fn beginPass(self: *const Device, pass: Pass) void {
        sg.beginPass(pass);
        self.applyViewport();
    }

    pub fn endPass() void {
        sg.endPass();
    }

    pub fn commit() void {
        sg.commit();
    }

    pub fn drawSmokeTriangle(self: *Device, pass: Pass) void {
        if (self.smoke_pipeline.id == 0 or self.smoke_vertices.id == 0) {
            self.createSmokeResources();
        }

        self.beginPass(pass);
        sg.applyPipeline(self.smoke_pipeline);
        sg.applyBindings(self.smoke_bindings);
        sg.draw(0, 3, 1);
        sg.endPass();
        sg.commit();
    }

    pub fn drawStencilPass(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        draws: []const StencilDraw,
        view_width: f32,
        view_height: f32,
    ) void {
        if (draws.len == 0) return;
        var path_draws: [32]PathDraw = undefined;
        if (draws.len > path_draws.len) return;
        var draw_count: usize = 0;
        for (draws) |draw| {
            const kind = stencilDrawKind(draw.mode) orelse continue;
            path_draws[draw_count] = .{
                .kind = kind,
                .base_element = draw.base_element,
                .element_count = draw.element_count,
                .uniform_index = 0,
            };
            draw_count += 1;
        }
        self.drawPathPass(pass, vertices, indices, path_draws[0..draw_count], &.{}, view_width, view_height);
    }

    pub fn drawStencilCoverPass(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        stencil_draws: []const StencilDraw,
        cover_draws: []const CoverDraw,
        frag_params: []const PathFsParams,
        view_width: f32,
        view_height: f32,
    ) void {
        if (stencil_draws.len + cover_draws.len == 0) return;
        var path_draws: [128]PathDraw = undefined;
        if (stencil_draws.len + cover_draws.len > path_draws.len) return;

        var draw_count: usize = 0;
        for (stencil_draws) |draw| {
            const kind = stencilDrawKind(draw.mode) orelse continue;
            path_draws[draw_count] = .{
                .kind = kind,
                .base_element = draw.base_element,
                .element_count = draw.element_count,
                .uniform_index = 0,
            };
            draw_count += 1;
        }
        for (cover_draws) |draw| {
            path_draws[draw_count] = .{
                .kind = .cover,
                .base_element = draw.base_element,
                .element_count = draw.element_count,
                .uniform_index = draw.uniform_index,
            };
            draw_count += 1;
        }

        self.drawPathPass(pass, vertices, indices, path_draws[0..draw_count], frag_params, view_width, view_height);
    }

    pub fn drawPathPass(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        path_draws: []const PathDraw,
        frag_params: []const PathFsParams,
        view_width: f32,
        view_height: f32,
    ) void {
        self.drawPathPassWithTextures(pass, vertices, indices, path_draws, frag_params, &.{}, view_width, view_height);
    }

    pub fn drawPathPassWithTextures(
        self: *Device,
        pass: Pass,
        vertices: []const path.Vertex,
        indices: []const u16,
        path_draws: []const PathDraw,
        frag_params: []const PathFsParams,
        textures: []const PathTexture,
        view_width: f32,
        view_height: f32,
    ) void {
        if (vertices.len == 0 or path_draws.len == 0) return;
        if (needsIndexBuffer(path_draws) and indices.len == 0) return;
        self.ensurePathResources(vertices.len, indices.len);
        self.ensurePathTextureResources(textures);

        sg.updateBuffer(self.path_vertex_buffer, rangeFromSlice(path.Vertex, vertices));
        if (indices.len > 0) {
            sg.updateBuffer(self.path_index_buffer, rangeFromSlice(u16, indices));
        }

        self.beginPass(pass);
        const params = pathVsParams(view_width, view_height);
        const indexed_bindings = pathIndexedBindings(self.path_vertex_buffer, self.path_index_buffer, 0, 0);
        const vertex_bindings = pathVertexBindings(self.path_vertex_buffer, 0);

        for (path_draws) |draw| {
            if (draw.element_count == 0) continue;
            const pipeline = self.pathPipeline(draw.kind);
            if (pipeline.id == 0) continue;
            const indexed = draw.kind == .stencil_nonzero or draw.kind == .stencil_even_odd or draw.kind == .convex;
            sg.applyPipeline(pipeline);
            sg.applyUniforms(path_vs_params_slot, rangeFromValue(PathVsParams, &params));
            switch (draw.kind) {
                .cover, .convex, .fringe_stencil, .fringe, .triangles => {
                    const uniform_index: usize = @intCast(draw.uniform_index);
                    if (uniform_index >= frag_params.len) continue;
                    const texture = self.pathTextureForParams(&frag_params[uniform_index]);
                    const bindings = if (indexed)
                        pathIndexedTextureBindings(self.path_vertex_buffer, self.path_index_buffer, 0, 0, texture.view, self.path_texture_sampler)
                    else
                        pathVertexTextureBindings(self.path_vertex_buffer, 0, texture.view, self.path_texture_sampler);
                    sg.applyBindings(bindings);
                    sg.applyUniforms(path_fs_params_slot, rangeFromValue(PathFsParams, &frag_params[uniform_index]));
                },
                .stencil_nonzero, .stencil_even_odd => {
                    sg.applyBindings(if (indexed) indexed_bindings else vertex_bindings);
                },
            }
            sg.draw(draw.base_element, draw.element_count, 1);
        }

        sg.endPass();
    }

    fn applyViewport(self: *const Device) void {
        if (self.width <= 0 or self.height <= 0) {
            return;
        }
        sg.applyViewport(0, 0, self.width, self.height, true);
    }

    fn ensureBlitResources(self: *Device, surface_width: u32, surface_height: u32) void {
        const missing = self.blit_shader.id == 0 or
            self.blit_pipeline.id == 0 or
            self.blit_vertices.id == 0 or
            self.blit_image.id == 0 or
            self.blit_sampler.id == 0 or
            self.blit_view.id == 0;
        if (!missing and self.blit_width == surface_width and self.blit_height == surface_height) {
            return;
        }
        self.createBlitResources(surface_width, surface_height);
    }

    fn ensurePathTextureResources(self: *Device, textures: []const PathTexture) void {
        if (self.path_texture_sampler.id == 0) {
            self.path_texture_sampler = sg.makeSampler(pathTextureSamplerDesc());
        }
        if (self.path_default_image.id == 0 or self.path_default_view.id == 0) {
            self.createDefaultPathTexture();
        }
        self.prunePathTextures(textures);
        for (textures) |texture| {
            self.uploadPathTexture(texture);
        }
    }

    fn createDefaultPathTexture(self: *Device) void {
        if (self.path_default_view.id != 0) {
            sg.destroyView(self.path_default_view);
            self.path_default_view = .{};
        }
        if (self.path_default_image.id != 0) {
            sg.destroyImage(self.path_default_image);
            self.path_default_image = .{};
        }
        self.path_default_image = sg.makeImage(pathDefaultTextureImageDesc());
        self.path_default_view = sg.makeView(pathTextureViewDesc(self.path_default_image));
    }

    fn prunePathTextures(self: *Device, textures: []const PathTexture) void {
        for (&self.path_textures) |*resource| {
            if (resource.id == 0) continue;
            if (findPathTextureInput(textures, resource.id) == null) {
                self.destroyPathTextureResource(resource);
            }
        }
    }

    fn uploadPathTexture(self: *Device, texture: PathTexture) void {
        if (texture.id == 0 or texture.format != .rgba8) return;
        if (texture.width == 0 or texture.height == 0) return;
        if (texture.pixels.len != @as(usize, texture.width) * @as(usize, texture.height) * 4) return;

        const resource = self.pathTextureResource(texture.id) orelse return;
        var created = false;
        if (resource.image.id == 0 or resource.width != texture.width or resource.height != texture.height) {
            self.destroyPathTextureResource(resource);
            resource.id = texture.id;
            resource.width = texture.width;
            resource.height = texture.height;
            resource.image = sg.makeImage(pathTextureImageDesc(texture.width, texture.height));
            resource.view = sg.makeView(pathTextureViewDesc(resource.image));
            created = true;
        }
        if (!created and resource.generation == texture.generation) return;

        var image_data: sg.ImageData = .{};
        image_data.mip_levels[0] = rangeFromSlice(u8, texture.pixels);
        sg.updateImage(resource.image, image_data);
        resource.generation = texture.generation;
    }

    fn pathTextureResource(self: *Device, id: u32) ?*PathTextureResource {
        for (&self.path_textures) |*resource| {
            if (resource.id == id) return resource;
        }
        for (&self.path_textures) |*resource| {
            if (resource.id == 0) {
                resource.id = id;
                return resource;
            }
        }
        return null;
    }

    fn destroyPathTextureResource(self: *Device, resource: *PathTextureResource) void {
        _ = self;
        if (resource.view.id != 0) {
            sg.destroyView(resource.view);
        }
        if (resource.image.id != 0) {
            sg.destroyImage(resource.image);
        }
        resource.* = .{};
    }

    fn pathTextureForParams(self: *const Device, params: *const PathFsParams) PathTextureResource {
        if (params.params[1] > 0.5 and params.params[2] > 0) {
            const id: u32 = @intFromFloat(params.params[2]);
            for (self.path_textures) |texture| {
                if (texture.id == id and texture.view.id != 0) return texture;
            }
        }
        return .{ .view = self.path_default_view };
    }

    fn sparseTexturesAvailable(self: *const Device, packet: *const gpu_fine.Packet) bool {
        for (packet.calls.items) |call| {
            if (call.image_id == 0) continue;
            for (self.path_textures) |texture| {
                if (texture.id == call.image_id and texture.view.id != 0) break;
            } else {
                return false;
            }
        }
        return true;
    }

    fn sparseTextureForCall(self: *const Device, call: gpu_fine.GpuCall) PathTextureResource {
        if (call.image_id != 0) {
            for (self.path_textures) |texture| {
                if (texture.id == call.image_id and texture.view.id != 0) return texture;
            }
        }
        return .{ .view = self.path_default_view };
    }

    fn ensurePathResources(self: *Device, vertex_capacity: usize, index_capacity: usize) void {
        const index_count = @max(index_capacity, 1);
        const missing = self.path_stencil_shader.id == 0 or
            self.path_cover_shader.id == 0 or
            self.path_stencil_nonzero_pipeline.id == 0 or
            self.path_stencil_even_odd_pipeline.id == 0 or
            self.path_cover_pipeline.id == 0 or
            self.path_convex_pipeline.id == 0 or
            self.path_fringe_stencil_pipeline.id == 0 or
            self.path_fringe_pipeline.id == 0 or
            self.path_triangles_pipeline.id == 0 or
            self.path_vertex_buffer.id == 0 or
            self.path_index_buffer.id == 0;
        if (!missing and self.path_vertex_capacity >= vertex_capacity and self.path_index_capacity >= index_count) {
            return;
        }
        self.createPathResources(vertex_capacity, index_count);
    }

    fn ensureSparseFineResources(
        self: *Device,
        surface_width: u32,
        surface_height: u32,
        packet: *const gpu_fine.Packet,
        segments: []const sparse_encode.Segment,
    ) void {
        if (self.sparse_clear_shader.id == 0) {
            self.sparse_clear_shader = sg.makeShader(sparse_fine_shader.sparseClearShaderDesc(sg.queryBackend()));
        }
        if (self.sparse_fine_shader.id == 0) {
            self.sparse_fine_shader = sg.makeShader(sparse_fine_shader.sparseFineShaderDesc(sg.queryBackend()));
        }
        if (self.sparse_clear_pipeline.id == 0 and self.sparse_clear_shader.id != 0) {
            self.sparse_clear_pipeline = sg.makePipeline(sparseComputePipelineDesc(self.sparse_clear_shader, "okys_sparse_clear_pipeline"));
        }
        if (self.sparse_fine_pipeline.id == 0 and self.sparse_fine_shader.id != 0) {
            self.sparse_fine_pipeline = sg.makePipeline(sparseComputePipelineDesc(self.sparse_fine_shader, "okys_sparse_fine_pipeline"));
        }

        self.ensureStorageBuffer(&self.sparse_call_buffer, bytesFor(gpu_fine.GpuCall, packet.calls.items.len), "okys_sparse_calls");
        self.ensureStorageBuffer(&self.sparse_segment_buffer, bytesFor(sparse_encode.Segment, segments.len), "okys_sparse_segments");
        self.ensureStorageBuffer(&self.sparse_clip_buffer, bytesFor(gpu_fine.GpuClip, packet.clips.items.len), "okys_sparse_clips");
        self.ensureStorageBuffer(&self.sparse_clip_index_buffer, bytesFor(gpu_fine.GpuClipIndex, packet.clip_indices.items.len), "okys_sparse_clip_indices");
        self.ensureStorageBuffer(&self.sparse_task_buffer, bytesFor(gpu_fine.GpuFineTask, packet.tasks.items.len), "okys_sparse_fine_tasks");
        self.ensureSparseSurface(surface_width, surface_height);
    }

    fn ensureStorageBuffer(self: *Device, resource: *StorageBufferResource, byte_count: usize, label: [*c]const u8) void {
        _ = self;
        const capacity = @max(byte_count, 4);
        if (resource.buffer.id != 0 and resource.view.id != 0 and resource.capacity >= capacity) {
            return;
        }
        destroyStorageBuffer(resource);
        resource.buffer = sg.makeBuffer(storageBufferDesc(capacity, label));
        resource.view = sg.makeView(storageBufferViewDesc(resource.buffer, label));
        resource.capacity = capacity;
    }

    fn ensureSparseSurface(self: *Device, surface_width: u32, surface_height: u32) void {
        const missing = self.sparse_surface_image.id == 0 or
            self.sparse_surface_storage_view.id == 0 or
            self.sparse_surface_texture_view.id == 0;
        if (!missing and self.sparse_surface_width == surface_width and self.sparse_surface_height == surface_height) {
            return;
        }
        self.destroySparseSurface();
        self.sparse_surface_image = sg.makeImage(sparseSurfaceImageDesc(surface_width, surface_height));
        self.sparse_surface_storage_view = sg.makeView(sparseSurfaceStorageViewDesc(self.sparse_surface_image));
        self.sparse_surface_texture_view = sg.makeView(sparseSurfaceTextureViewDesc(self.sparse_surface_image));
        self.sparse_surface_width = surface_width;
        self.sparse_surface_height = surface_height;
    }

    fn destroySparseFineResources(self: *Device) void {
        self.destroySparseSurface();
        destroyStorageBuffer(&self.sparse_task_buffer);
        destroyStorageBuffer(&self.sparse_clip_index_buffer);
        destroyStorageBuffer(&self.sparse_clip_buffer);
        destroyStorageBuffer(&self.sparse_segment_buffer);
        destroyStorageBuffer(&self.sparse_call_buffer);
        if (self.sparse_fine_pipeline.id != 0) {
            sg.destroyPipeline(self.sparse_fine_pipeline);
            self.sparse_fine_pipeline = .{};
        }
        if (self.sparse_clear_pipeline.id != 0) {
            sg.destroyPipeline(self.sparse_clear_pipeline);
            self.sparse_clear_pipeline = .{};
        }
        if (self.sparse_fine_shader.id != 0) {
            sg.destroyShader(self.sparse_fine_shader);
            self.sparse_fine_shader = .{};
        }
        if (self.sparse_clear_shader.id != 0) {
            sg.destroyShader(self.sparse_clear_shader);
            self.sparse_clear_shader = .{};
        }
    }

    fn destroySparseSurface(self: *Device) void {
        if (self.sparse_surface_texture_view.id != 0) {
            sg.destroyView(self.sparse_surface_texture_view);
            self.sparse_surface_texture_view = .{};
        }
        if (self.sparse_surface_storage_view.id != 0) {
            sg.destroyView(self.sparse_surface_storage_view);
            self.sparse_surface_storage_view = .{};
        }
        if (self.sparse_surface_image.id != 0) {
            sg.destroyImage(self.sparse_surface_image);
            self.sparse_surface_image = .{};
        }
        self.sparse_surface_width = 0;
        self.sparse_surface_height = 0;
    }

    fn pathPipeline(self: *const Device, kind: PathDrawKind) Pipeline {
        return switch (kind) {
            .stencil_nonzero => self.path_stencil_nonzero_pipeline,
            .stencil_even_odd => self.path_stencil_even_odd_pipeline,
            .cover => self.path_cover_pipeline,
            .convex => self.path_convex_pipeline,
            .fringe_stencil => self.path_fringe_stencil_pipeline,
            .fringe => self.path_fringe_pipeline,
            .triangles => self.path_triangles_pipeline,
        };
    }
};

pub fn smokeTriangle() SmokeTriangle {
    return .{
        .vertices = .{
            .{ .x = 0.0, .y = 0.5, .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 },
            .{ .x = 0.5, .y = -0.5, .r = 0.0, .g = 1.0, .b = 0.0, .a = 1.0 },
            .{ .x = -0.5, .y = -0.5, .r = 0.0, .g = 0.0, .b = 1.0, .a = 1.0 },
        },
    };
}

pub fn clearPassAction(clear_color: Color) PassAction {
    var action: PassAction = .{};
    action.colors[0].load_action = .CLEAR;
    action.colors[0].store_action = .STORE;
    action.colors[0].clear_value = clear_color;
    return action;
}

pub fn loadPassAction() PassAction {
    var action: PassAction = .{};
    action.colors[0].load_action = .LOAD;
    action.colors[0].store_action = .STORE;
    action.stencil.load_action = .LOAD;
    action.stencil.store_action = .STORE;
    return action;
}

pub fn stencilCoverPassAction(clear_color: Color) PassAction {
    var action = clearPassAction(clear_color);
    action.stencil.load_action = .CLEAR;
    action.stencil.store_action = .STORE;
    action.stencil.clear_value = 0;
    return action;
}

pub fn passWithAction(action: PassAction) Pass {
    return .{ .action = action, .label = "okys_pass" };
}

pub fn swapchainPassWithAction(action: PassAction, swapchain: Swapchain) Pass {
    return .{ .action = action, .swapchain = swapchain, .label = "okys_swapchain_pass" };
}

pub fn blitVertexBufferDesc() BufferDesc {
    return .{
        .size = 4 * @sizeOf(BlitVertex),
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "okys_blit_vertices",
    };
}

pub fn blitImageDesc(width: u32, height: u32) sg.ImageDesc {
    return .{
        .type = ._2D,
        .usage = .{ .stream_update = true },
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = .RGBA8,
        .label = "okys_sparse_surface",
    };
}

pub fn blitSamplerDesc() sg.SamplerDesc {
    return .{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .mipmap_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
        .label = "okys_sparse_surface_sampler",
    };
}

pub fn blitTextureViewDesc(image_handle: Image) sg.ViewDesc {
    return .{
        .texture = .{ .image = image_handle },
        .label = "okys_sparse_surface_view",
    };
}

pub fn sparseComputePipelineDesc(shader: Shader, label: [*c]const u8) PipelineDesc {
    return .{
        .compute = true,
        .shader = shader,
        .label = label,
    };
}

pub fn sparseSurfaceImageDesc(width: u32, height: u32) sg.ImageDesc {
    return .{
        .type = ._2D,
        .usage = .{ .storage_image = true },
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = .RGBA8,
        .label = "okys_sparse_compute_surface",
    };
}

pub fn sparseSurfaceStorageViewDesc(image_handle: Image) sg.ViewDesc {
    return .{
        .storage_image = .{ .image = image_handle },
        .label = "okys_sparse_compute_surface_storage_view",
    };
}

pub fn sparseSurfaceTextureViewDesc(image_handle: Image) sg.ViewDesc {
    return .{
        .texture = .{ .image = image_handle },
        .label = "okys_sparse_compute_surface_texture_view",
    };
}

pub fn storageBufferDesc(size: usize, label: [*c]const u8) BufferDesc {
    return .{
        .size = size,
        .usage = .{ .storage_buffer = true, .stream_update = true },
        .label = label,
    };
}

pub fn storageBufferViewDesc(buffer: Buffer, label: [*c]const u8) sg.ViewDesc {
    return .{
        .storage_buffer = .{ .buffer = buffer },
        .label = label,
    };
}

pub fn sparseClearBindings(surface_view: View) Bindings {
    var bindings: Bindings = .{};
    bindings.views[sparse_clear_surface_view_slot] = surface_view;
    return bindings;
}

pub fn sparseFineBindings(
    calls_view: View,
    segments_view: View,
    clips_view: View,
    tasks_view: View,
    clip_indices_view: View,
    surface_view: View,
    image_view: View,
    image_sampler: Sampler,
) Bindings {
    var bindings: Bindings = .{};
    bindings.views[sparse_calls_view_slot] = calls_view;
    bindings.views[sparse_segments_view_slot] = segments_view;
    bindings.views[sparse_clips_view_slot] = clips_view;
    bindings.views[sparse_tasks_view_slot] = tasks_view;
    bindings.views[sparse_clip_indices_view_slot] = clip_indices_view;
    bindings.views[sparse_fine_surface_view_slot] = surface_view;
    bindings.views[sparse_image_view_slot] = image_view;
    bindings.samplers[sparse_image_sampler_slot] = image_sampler;
    return bindings;
}

fn destroyStorageBuffer(resource: *StorageBufferResource) void {
    if (resource.view.id != 0) {
        sg.destroyView(resource.view);
    }
    if (resource.buffer.id != 0) {
        sg.destroyBuffer(resource.buffer);
    }
    resource.* = .{};
}

fn uploadStorageBuffer(comptime T: type, buffer: Buffer, items: []const T) void {
    if (buffer.id == 0 or items.len == 0) return;
    sg.updateBuffer(buffer, rangeFromSlice(T, items));
}

fn dispatchGroups(count: u32, group_size: u32) i32 {
    return @intCast((count + group_size - 1) / group_size);
}

fn bytesFor(comptime T: type, count: usize) usize {
    return @sizeOf(T) * count;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn elapsedSince(start: u64) u64 {
    return nowNs() - start;
}

pub fn pathTextureImageDesc(width: u32, height: u32) sg.ImageDesc {
    return .{
        .type = ._2D,
        .usage = .{ .stream_update = true },
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = .RGBA8,
        .label = "okys_path_texture",
    };
}

pub fn pathDefaultTextureImageDesc() sg.ImageDesc {
    return .{
        .type = ._2D,
        .usage = .{ .immutable = true },
        .width = 1,
        .height = 1,
        .pixel_format = .RGBA8,
        .data = .{ .mip_levels = pathDefaultTextureData() },
        .label = "okys_path_default_texture",
    };
}

pub fn pathDefaultTextureData() [16]sg.Range {
    var mip_levels: [16]sg.Range = @splat(.{});
    mip_levels[0] = rangeFromSlice(u8, path_default_texture_pixels[0..]);
    return mip_levels;
}

pub fn pathTextureSamplerDesc() sg.SamplerDesc {
    return .{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .mipmap_filter = .NEAREST,
        .wrap_u = .REPEAT,
        .wrap_v = .REPEAT,
        .label = "okys_path_texture_sampler",
    };
}

pub fn pathTextureViewDesc(image_handle: Image) sg.ViewDesc {
    return .{
        .texture = .{ .image = image_handle },
        .label = "okys_path_texture_view",
    };
}

pub fn blitPipelineDesc(shader: Shader) PipelineDesc {
    var desc: PipelineDesc = .{};
    desc.shader = shader;
    desc.layout.buffers[0].stride = @sizeOf(BlitVertex);
    desc.layout.attrs[blit_position_attr].offset = @offsetOf(BlitVertex, "x");
    desc.layout.attrs[blit_position_attr].format = .FLOAT2;
    desc.layout.attrs[blit_uv_attr].offset = @offsetOf(BlitVertex, "u");
    desc.layout.attrs[blit_uv_attr].format = .FLOAT2;
    desc.primitive_type = .TRIANGLE_STRIP;
    desc.label = "okys_blit_pipeline";
    return desc;
}

pub fn blitBindings(vertex_buffer: Buffer, view: View, sampler: Sampler) Bindings {
    var bindings: Bindings = .{};
    bindings.vertex_buffers[0] = vertex_buffer;
    bindings.views[blit_view_slot] = view;
    bindings.samplers[blit_sampler_slot] = sampler;
    return bindings;
}

pub fn smokeVertexBufferDesc(triangle: *const SmokeTriangle) BufferDesc {
    return .{
        .usage = .{ .vertex_buffer = true, .immutable = true },
        .data = .{
            .ptr = @ptrCast(&triangle.vertices),
            .size = @sizeOf(@TypeOf(triangle.vertices)),
        },
        .label = "okys_smoke_vertices",
    };
}

pub fn smokePipelineDesc(shader: Shader) PipelineDesc {
    var desc: PipelineDesc = .{};
    desc.shader = shader;
    desc.layout.buffers[0].stride = @sizeOf(SmokeVertex);
    desc.layout.attrs[smoke_position_attr].offset = @offsetOf(SmokeVertex, "x");
    desc.layout.attrs[smoke_position_attr].format = .FLOAT2;
    desc.layout.attrs[smoke_color_attr].offset = @offsetOf(SmokeVertex, "r");
    desc.layout.attrs[smoke_color_attr].format = .FLOAT4;
    desc.primitive_type = .TRIANGLES;
    desc.label = "okys_smoke_pipeline";
    return desc;
}

pub fn smokeBindings(vertex_buffer: Buffer) Bindings {
    var bindings: Bindings = .{};
    bindings.vertex_buffers[0] = vertex_buffer;
    return bindings;
}

pub fn pathVertexBufferDesc(vertex_capacity: usize) BufferDesc {
    return .{
        .size = vertex_capacity * @sizeOf(path.Vertex),
        .usage = .{ .vertex_buffer = true, .stream_update = true },
        .label = "okys_path_vertices",
    };
}

pub fn pathIndexBufferDesc(index_capacity: usize) BufferDesc {
    return .{
        .size = index_capacity * @sizeOf(u16),
        .usage = .{ .index_buffer = true, .stream_update = true },
        .label = "okys_path_indices",
    };
}

pub fn pathVertexBindings(vertex_buffer: Buffer, vertex_offset_bytes: i32) Bindings {
    var bindings: Bindings = .{};
    bindings.vertex_buffers[0] = vertex_buffer;
    bindings.vertex_buffer_offsets[0] = vertex_offset_bytes;
    return bindings;
}

pub fn pathIndexedBindings(vertex_buffer: Buffer, index_buffer: Buffer, vertex_offset_bytes: i32, index_offset_bytes: i32) Bindings {
    var bindings = pathVertexBindings(vertex_buffer, vertex_offset_bytes);
    bindings.index_buffer = index_buffer;
    bindings.index_buffer_offset = index_offset_bytes;
    return bindings;
}

pub fn pathVertexTextureBindings(vertex_buffer: Buffer, vertex_offset_bytes: i32, view: View, sampler: Sampler) Bindings {
    var bindings = pathVertexBindings(vertex_buffer, vertex_offset_bytes);
    bindings.views[path_image_view_slot] = view;
    bindings.samplers[path_image_sampler_slot] = sampler;
    return bindings;
}

pub fn pathIndexedTextureBindings(vertex_buffer: Buffer, index_buffer: Buffer, vertex_offset_bytes: i32, index_offset_bytes: i32, view: View, sampler: Sampler) Bindings {
    var bindings = pathVertexTextureBindings(vertex_buffer, vertex_offset_bytes, view, sampler);
    bindings.index_buffer = index_buffer;
    bindings.index_buffer_offset = index_offset_bytes;
    return bindings;
}

pub fn blitVsParams(view_width: f32, view_height: f32) BlitVsParams {
    return .{
        .view_size = .{
            if (view_width > 0) view_width else 1,
            if (view_height > 0) view_height else 1,
        },
    };
}

pub fn pathVsParams(view_width: f32, view_height: f32) PathVsParams {
    return .{
        .view_size = .{
            if (view_width > 0) view_width else 1,
            if (view_height > 0) view_height else 1,
        },
    };
}

pub fn pathPipelineDesc(shader: Shader, kind: PathPipelineKind) PipelineDesc {
    var desc: PipelineDesc = .{};
    desc.shader = shader;
    desc.layout.buffers[0].stride = @sizeOf(path.Vertex);
    desc.layout.attrs[path_position_attr].offset = @offsetOf(path.Vertex, "x");
    desc.layout.attrs[path_position_attr].format = .FLOAT2;
    desc.layout.attrs[path_uv_attr].offset = @offsetOf(path.Vertex, "u");
    desc.layout.attrs[path_uv_attr].format = .FLOAT2;
    desc.face_winding = .CCW;

    switch (kind) {
        .stencil_nonzero => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].write_mask = .NONE;
            desc.stencil = stencilState(.ALWAYS, .INCR_WRAP, .DECR_WRAP);
            desc.label = "okys_path_stencil_nonzero_pipeline";
        },
        .stencil_even_odd => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].write_mask = .NONE;
            desc.stencil = stencilState(.ALWAYS, .INVERT, .INVERT);
            desc.label = "okys_path_stencil_even_odd_pipeline";
        },
        .cover => {
            desc.primitive_type = .TRIANGLE_STRIP;
            desc.stencil = stencilState(.NOT_EQUAL, .ZERO, .ZERO);
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_cover_pipeline";
        },
        .convex => {
            desc.primitive_type = .TRIANGLES;
            desc.index_type = .UINT16;
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_convex_pipeline";
        },
        .fringe_stencil => {
            desc.primitive_type = .TRIANGLE_STRIP;
            desc.stencil = stencilReadState(.EQUAL);
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_fringe_stencil_pipeline";
        },
        .fringe => {
            desc.primitive_type = .TRIANGLE_STRIP;
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_fringe_pipeline";
        },
        .triangles => {
            desc.primitive_type = .TRIANGLES;
            desc.colors[0].blend = alphaBlend();
            desc.label = "okys_path_triangles_pipeline";
        },
    }

    return desc;
}

fn blitQuad(dest: BlitRect) [4]BlitVertex {
    const x0 = dest.x;
    const y0 = dest.y;
    const x1 = dest.x + dest.width;
    const y1 = dest.y + dest.height;
    return .{
        .{ .x = x0, .y = y0, .u = 0.0, .v = 0.0 },
        .{ .x = x1, .y = y0, .u = 1.0, .v = 0.0 },
        .{ .x = x0, .y = y1, .u = 0.0, .v = 1.0 },
        .{ .x = x1, .y = y1, .u = 1.0, .v = 1.0 },
    };
}

comptime {
    std.debug.assert(@sizeOf(gpu_fine.GpuCall) == @sizeOf(sparse_fine_shader.Gpucall));
    std.debug.assert(@sizeOf(gpu_fine.GpuClip) == @sizeOf(sparse_fine_shader.Gpuclip));
    std.debug.assert(@sizeOf(gpu_fine.GpuClipIndex) == @sizeOf(sparse_fine_shader.Gpuclipindex));
    std.debug.assert(@sizeOf(gpu_fine.GpuFineTask) == @sizeOf(sparse_fine_shader.Gpufinetask));
    std.debug.assert(@sizeOf(sparse_encode.Segment) == @sizeOf(sparse_fine_shader.Segment));
}

fn findPathTextureInput(textures: []const PathTexture, id: u32) ?*const PathTexture {
    for (textures) |*texture| {
        if (texture.id == id) return texture;
    }
    return null;
}

fn pixelExtent(points: f32, dpr: f32) i32 {
    if (points <= 0.0) {
        return 0;
    }
    return @intFromFloat(@ceil(points * dpr));
}

fn alphaBlend() sg.BlendState {
    return .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .op_rgb = .ADD,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        .op_alpha = .ADD,
    };
}

fn stencilState(compare: sg.CompareFunc, front_pass: sg.StencilOp, back_pass: sg.StencilOp) sg.StencilState {
    return .{
        .enabled = true,
        .front = .{
            .compare = compare,
            .fail_op = .KEEP,
            .depth_fail_op = .KEEP,
            .pass_op = front_pass,
        },
        .back = .{
            .compare = compare,
            .fail_op = .KEEP,
            .depth_fail_op = .KEEP,
            .pass_op = back_pass,
        },
        .read_mask = 0xff,
        .write_mask = 0xff,
        .ref = 0,
    };
}

fn stencilReadState(compare: sg.CompareFunc) sg.StencilState {
    var state = stencilState(compare, .KEEP, .KEEP);
    state.write_mask = 0;
    return state;
}

fn needsIndexBuffer(draws: []const PathDraw) bool {
    for (draws) |draw| {
        switch (draw.kind) {
            .stencil_nonzero, .stencil_even_odd, .convex => return true,
            .cover, .fringe_stencil, .fringe, .triangles => {},
        }
    }
    return false;
}

fn stencilDrawKind(mode: PathPipelineKind) ?PathDrawKind {
    return switch (mode) {
        .stencil_nonzero => .stencil_nonzero,
        .stencil_even_odd => .stencil_even_odd,
        .cover, .convex, .fringe_stencil, .fringe, .triangles => null,
    };
}

fn rangeFromSlice(comptime T: type, values: []const T) sg.Range {
    return .{
        .ptr = values.ptr,
        .size = values.len * @sizeOf(T),
    };
}

fn rangeFromValue(comptime T: type, value: *const T) sg.Range {
    return .{
        .ptr = value,
        .size = @sizeOf(T),
    };
}
