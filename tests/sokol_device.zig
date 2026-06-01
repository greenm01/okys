const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
const path = okys.types.path;
const sokol_device = okys.render.sokol_device;

test "smoke triangle carries position and color data" {
    const triangle = sokol_device.smokeTriangle();

    try testing.expectEqual(@as(usize, 3), triangle.vertices.len);
    try testing.expectEqual(@as(f32, 0.0), triangle.vertices[0].x);
    try testing.expectEqual(@as(f32, 0.5), triangle.vertices[0].y);
    try testing.expectEqual(@as(f32, 1.0), triangle.vertices[0].r);
    try testing.expectEqual(@as(f32, 1.0), triangle.vertices[1].g);
    try testing.expectEqual(@as(f32, 1.0), triangle.vertices[2].b);
}

test "smoke vertex buffer descriptor points at immutable vertex data" {
    const triangle = sokol_device.smokeTriangle();
    const desc = sokol_device.smokeVertexBufferDesc(&triangle);

    try testing.expect(desc.data.ptr != null);
    try testing.expectEqual(@sizeOf(@TypeOf(triangle.vertices)), desc.data.size);
    try testing.expect(desc.usage.vertex_buffer);
    try testing.expect(desc.usage.immutable);
}

test "smoke pipeline descriptor matches generated shader attributes" {
    const shader = sokol_device.Shader{ .id = 7 };
    const desc = sokol_device.smokePipelineDesc(shader);

    try testing.expectEqual(shader, desc.shader);
    try testing.expectEqual(@as(i32, @sizeOf(sokol_device.SmokeVertex)), desc.layout.buffers[0].stride);
    try testing.expectEqual(@offsetOf(sokol_device.SmokeVertex, "x"), desc.layout.attrs[sokol_device.smoke_position_attr].offset);
    try testing.expectEqual(@as(@TypeOf(desc.layout.attrs[0].format), .FLOAT2), desc.layout.attrs[sokol_device.smoke_position_attr].format);
    try testing.expectEqual(@offsetOf(sokol_device.SmokeVertex, "r"), desc.layout.attrs[sokol_device.smoke_color_attr].offset);
    try testing.expectEqual(@as(@TypeOf(desc.layout.attrs[0].format), .FLOAT4), desc.layout.attrs[sokol_device.smoke_color_attr].format);
    try testing.expectEqual(@as(@TypeOf(desc.primitive_type), .TRIANGLES), desc.primitive_type);
}

test "clear pass action clears and stores first color target" {
    const action = sokol_device.clearPassAction(.{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 });

    try testing.expectEqual(@as(@TypeOf(action.colors[0].load_action), .CLEAR), action.colors[0].load_action);
    try testing.expectEqual(@as(@TypeOf(action.colors[0].store_action), .STORE), action.colors[0].store_action);
    try testing.expectApproxEqAbs(@as(f32, 0.1), action.colors[0].clear_value.r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), action.colors[0].clear_value.g, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), action.colors[0].clear_value.b, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), action.colors[0].clear_value.a, 0.001);
}

test "offscreen pass helpers create rgba8 color attachment descriptors" {
    const image_desc = sokol_device.offscreenColorImageDesc(64, 32);
    try testing.expect(image_desc.usage.color_attachment);
    try testing.expectEqual(@as(i32, 64), image_desc.width);
    try testing.expectEqual(@as(i32, 32), image_desc.height);
    try testing.expectEqual(@as(@TypeOf(image_desc.pixel_format), .RGBA8), image_desc.pixel_format);
    try testing.expectEqual(@as(i32, 1), image_desc.sample_count);

    const image = sokol_device.Image{ .id = 17 };
    const view_desc = sokol_device.offscreenColorAttachmentViewDesc(image);
    try testing.expectEqual(image, view_desc.color_attachment.image);

    const view = sokol_device.View{ .id = 23 };
    const pass = sokol_device.offscreenPassWithAction(sokol_device.loadPassAction(), view);
    try testing.expectEqual(view, pass.attachments.colors[0]);
}

test "stencil cover pass action clears color and stencil" {
    const action = sokol_device.stencilCoverPassAction(.{ .r = 0.4, .g = 0.3, .b = 0.2, .a = 1.0 });

    try testing.expectEqual(@as(@TypeOf(action.colors[0].load_action), .CLEAR), action.colors[0].load_action);
    try testing.expectEqual(@as(@TypeOf(action.colors[0].store_action), .STORE), action.colors[0].store_action);
    try testing.expectApproxEqAbs(@as(f32, 0.4), action.colors[0].clear_value.r, 0.001);
    try testing.expectEqual(@as(@TypeOf(action.stencil.load_action), .CLEAR), action.stencil.load_action);
    try testing.expectEqual(@as(@TypeOf(action.stencil.store_action), .STORE), action.stencil.store_action);
    try testing.expectEqual(@as(u8, 0), action.stencil.clear_value);
}

test "path buffer descriptors allocate stream vertex and index buffers" {
    const vertices = sokol_device.pathVertexBufferDesc(32);
    const indices = sokol_device.pathIndexBufferDesc(96);

    try testing.expectEqual(@as(usize, 32 * @sizeOf(path.Vertex)), vertices.size);
    try testing.expect(vertices.usage.vertex_buffer);
    try testing.expect(vertices.usage.stream_update);
    try testing.expect(!vertices.usage.immutable);
    try testing.expectEqual(@as(usize, 96 * @sizeOf(u16)), indices.size);
    try testing.expect(indices.usage.index_buffer);
    try testing.expect(indices.usage.stream_update);
    try testing.expect(!indices.usage.vertex_buffer);
}

test "path bindings carry vertex and index buffer offsets" {
    const vertex_buffer = sokol_device.Buffer{ .id = 11 };
    const index_buffer = sokol_device.Buffer{ .id = 12 };

    const vertex_only = sokol_device.pathVertexBindings(vertex_buffer, 64);
    try testing.expectEqual(vertex_buffer, vertex_only.vertex_buffers[0]);
    try testing.expectEqual(@as(i32, 64), vertex_only.vertex_buffer_offsets[0]);
    try testing.expectEqual(@as(u32, 0), vertex_only.index_buffer.id);

    const indexed = sokol_device.pathIndexedBindings(vertex_buffer, index_buffer, 128, 256);
    try testing.expectEqual(vertex_buffer, indexed.vertex_buffers[0]);
    try testing.expectEqual(index_buffer, indexed.index_buffer);
    try testing.expectEqual(@as(i32, 128), indexed.vertex_buffer_offsets[0]);
    try testing.expectEqual(@as(i32, 256), indexed.index_buffer_offset);
}

test "path texture descriptors and bindings use generated slots" {
    const image_desc = sokol_device.pathTextureImageDesc(16, 8);
    try testing.expectEqual(@as(i32, 16), image_desc.width);
    try testing.expectEqual(@as(i32, 8), image_desc.height);
    try testing.expect(image_desc.usage.stream_update);
    try testing.expectEqual(@as(@TypeOf(image_desc.pixel_format), .RGBA8), image_desc.pixel_format);

    const sampler_desc = sokol_device.pathTextureSamplerDesc();
    try testing.expectEqual(@as(@TypeOf(sampler_desc.min_filter), .LINEAR), sampler_desc.min_filter);
    try testing.expectEqual(@as(@TypeOf(sampler_desc.mag_filter), .LINEAR), sampler_desc.mag_filter);
    try testing.expectEqual(@as(@TypeOf(sampler_desc.wrap_u), .REPEAT), sampler_desc.wrap_u);
    try testing.expectEqual(@as(@TypeOf(sampler_desc.wrap_v), .REPEAT), sampler_desc.wrap_v);

    const vertex_buffer = sokol_device.Buffer{ .id = 11 };
    const index_buffer = sokol_device.Buffer{ .id = 12 };
    const view = sokol_device.View{ .id = 13 };
    const sampler = sokol_device.Sampler{ .id = 14 };
    const bindings = sokol_device.pathIndexedTextureBindings(vertex_buffer, index_buffer, 0, 0, view, sampler);
    try testing.expectEqual(view, bindings.views[sokol_device.path_image_view_slot]);
    try testing.expectEqual(sampler, bindings.samplers[sokol_device.path_image_sampler_slot]);
    try testing.expectEqual(index_buffer, bindings.index_buffer);
}

test "sparse compute descriptors use storage resources and generated slots" {
    const shader = sokol_device.Shader{ .id = 7 };
    const pipeline = sokol_device.sparseComputePipelineDesc(shader, "test_sparse_compute");
    try testing.expect(pipeline.compute);
    try testing.expectEqual(shader, pipeline.shader);

    const image_desc = sokol_device.sparseSurfaceImageDesc(32, 16);
    try testing.expect(image_desc.usage.storage_image);
    try testing.expectEqual(@as(i32, 32), image_desc.width);
    try testing.expectEqual(@as(i32, 16), image_desc.height);
    try testing.expectEqual(@as(@TypeOf(image_desc.pixel_format), .RGBA8), image_desc.pixel_format);

    const buffer_desc = sokol_device.storageBufferDesc(256, "test_sparse_buffer");
    try testing.expect(buffer_desc.usage.storage_buffer);
    try testing.expect(buffer_desc.usage.stream_update);
    try testing.expectEqual(@as(usize, 256), buffer_desc.size);

    const calls = sokol_device.View{ .id = 1 };
    const segments = sokol_device.View{ .id = 2 };
    const clips = sokol_device.View{ .id = 3 };
    const tasks = sokol_device.View{ .id = 4 };
    const clip_indices = sokol_device.View{ .id = 8 };
    const surface = sokol_device.View{ .id = 5 };
    const image = sokol_device.View{ .id = 6 };
    const sampler = sokol_device.Sampler{ .id = 7 };
    const clear_bindings = sokol_device.sparseClearBindings(surface);
    try testing.expectEqual(surface, clear_bindings.views[sokol_device.sparse_clear_surface_view_slot]);

    const fine_bindings = sokol_device.sparseFineBindings(calls, segments, clips, tasks, clip_indices, surface, image, sampler);
    try testing.expectEqual(calls, fine_bindings.views[sokol_device.sparse_calls_view_slot]);
    try testing.expectEqual(segments, fine_bindings.views[sokol_device.sparse_segments_view_slot]);
    try testing.expectEqual(clips, fine_bindings.views[sokol_device.sparse_clips_view_slot]);
    try testing.expectEqual(tasks, fine_bindings.views[sokol_device.sparse_tasks_view_slot]);
    try testing.expectEqual(clip_indices, fine_bindings.views[sokol_device.sparse_clip_indices_view_slot]);
    try testing.expectEqual(surface, fine_bindings.views[sokol_device.sparse_fine_surface_view_slot]);
    try testing.expectEqual(image, fine_bindings.views[sokol_device.sparse_image_view_slot]);
    try testing.expectEqual(sampler, fine_bindings.samplers[sokol_device.sparse_image_sampler_slot]);
}

test "sparse fine submit timing defaults to no successful draw" {
    const timing: sokol_device.SparseFineSubmitTiming = .{};

    try testing.expect(!timing.ok);
    try testing.expectEqual(sokol_device.SparseFineFallback.none, timing.fallback);
    try testing.expectEqual(@as(u64, 0), timing.total_ns);
    try testing.expectEqual(@as(usize, 0), timing.calls);
    try testing.expectEqual(@as(usize, 0), timing.tasks);
}

test "path pipeline descriptor uses path vertex layout" {
    const shader = sokol_device.Shader{ .id = 7 };
    const desc = sokol_device.pathPipelineDesc(shader, .cover);

    try testing.expectEqual(@as(usize, 16), @sizeOf(sokol_device.PathVsParams));
    try testing.expectEqual(@as(usize, 176), @sizeOf(sokol_device.PathFsParams));
    try testing.expectEqual(@as(usize, 0), sokol_device.path_vs_params_slot);
    try testing.expectEqual(@as(usize, 1), sokol_device.path_fs_params_slot);
    try testing.expectEqual(shader, desc.shader);
    try testing.expectEqual(@as(i32, @sizeOf(path.Vertex)), desc.layout.buffers[0].stride);
    try testing.expectEqual(@offsetOf(path.Vertex, "x"), desc.layout.attrs[sokol_device.path_position_attr].offset);
    try testing.expectEqual(@as(@TypeOf(desc.layout.attrs[0].format), .FLOAT2), desc.layout.attrs[sokol_device.path_position_attr].format);
    try testing.expectEqual(@offsetOf(path.Vertex, "u"), desc.layout.attrs[sokol_device.path_uv_attr].offset);
    try testing.expectEqual(@as(@TypeOf(desc.layout.attrs[0].format), .FLOAT2), desc.layout.attrs[sokol_device.path_uv_attr].format);
    try testing.expectEqual(@offsetOf(path.Vertex, "x"), desc.layout.attrs[sokol_device.path_cover_position_attr].offset);
    try testing.expectEqual(@offsetOf(path.Vertex, "u"), desc.layout.attrs[sokol_device.path_cover_uv_attr].offset);
    try testing.expectEqual(@as(@TypeOf(desc.face_winding), .CCW), desc.face_winding);
}

test "path vertex params clamp invalid view sizes" {
    const params = sokol_device.pathVsParams(0, -4);

    try testing.expectEqual(@as(f32, 1), params.view_size[0]);
    try testing.expectEqual(@as(f32, 1), params.view_size[1]);
}

test "stencil path pipelines configure nonzero and even odd stencil ops" {
    const shader = sokol_device.Shader{ .id = 7 };
    const nonzero = sokol_device.pathPipelineDesc(shader, .stencil_nonzero);
    const even_odd = sokol_device.pathPipelineDesc(shader, .stencil_even_odd);

    try testing.expectEqual(@as(@TypeOf(nonzero.primitive_type), .TRIANGLES), nonzero.primitive_type);
    try testing.expectEqual(@as(@TypeOf(nonzero.index_type), .UINT16), nonzero.index_type);
    try testing.expectEqual(@as(@TypeOf(nonzero.colors[0].write_mask), .RGBA), nonzero.colors[0].write_mask);
    try testing.expect(nonzero.colors[0].blend.enabled);
    try testing.expectEqual(@as(@TypeOf(nonzero.colors[0].blend.src_factor_rgb), .ZERO), nonzero.colors[0].blend.src_factor_rgb);
    try testing.expectEqual(@as(@TypeOf(nonzero.colors[0].blend.dst_factor_rgb), .ONE), nonzero.colors[0].blend.dst_factor_rgb);
    try testing.expect(nonzero.stencil.enabled);
    try testing.expectEqual(@as(@TypeOf(nonzero.stencil.front.compare), .ALWAYS), nonzero.stencil.front.compare);
    try testing.expectEqual(@as(@TypeOf(nonzero.stencil.front.pass_op), .INCR_WRAP), nonzero.stencil.front.pass_op);
    try testing.expectEqual(@as(@TypeOf(nonzero.stencil.back.pass_op), .DECR_WRAP), nonzero.stencil.back.pass_op);
    try testing.expectEqual(@as(u8, 0xff), nonzero.stencil.read_mask);
    try testing.expectEqual(@as(u8, 0xff), nonzero.stencil.write_mask);

    try testing.expectEqual(@as(@TypeOf(even_odd.index_type), .UINT16), even_odd.index_type);
    try testing.expectEqual(@as(@TypeOf(even_odd.colors[0].write_mask), .RGBA), even_odd.colors[0].write_mask);
    try testing.expect(even_odd.colors[0].blend.enabled);
    try testing.expect(even_odd.stencil.enabled);
    try testing.expectEqual(@as(@TypeOf(even_odd.stencil.front.pass_op), .INVERT), even_odd.stencil.front.pass_op);
    try testing.expectEqual(@as(@TypeOf(even_odd.stencil.back.pass_op), .INVERT), even_odd.stencil.back.pass_op);
}

test "cover path pipeline reads and clears stencil while blending color" {
    const shader = sokol_device.Shader{ .id = 7 };
    const desc = sokol_device.pathPipelineDesc(shader, .cover);

    try testing.expectEqual(@as(@TypeOf(desc.primitive_type), .TRIANGLE_STRIP), desc.primitive_type);
    try testing.expectEqual(@as(@TypeOf(desc.index_type), .DEFAULT), desc.index_type);
    try testing.expect(desc.stencil.enabled);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.front.compare), .NOT_EQUAL), desc.stencil.front.compare);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.front.pass_op), .ZERO), desc.stencil.front.pass_op);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.back.pass_op), .ZERO), desc.stencil.back.pass_op);
    try testing.expect(desc.colors[0].blend.enabled);
    try testing.expectEqual(@as(@TypeOf(desc.colors[0].blend.src_factor_rgb), .SRC_ALPHA), desc.colors[0].blend.src_factor_rgb);
    try testing.expectEqual(@as(@TypeOf(desc.colors[0].blend.dst_factor_rgb), .ONE_MINUS_SRC_ALPHA), desc.colors[0].blend.dst_factor_rgb);
    try testing.expectEqual(@as(@TypeOf(desc.colors[0].blend.src_factor_alpha), .ONE), desc.colors[0].blend.src_factor_alpha);
    try testing.expectEqual(@as(@TypeOf(desc.colors[0].blend.dst_factor_alpha), .ONE_MINUS_SRC_ALPHA), desc.colors[0].blend.dst_factor_alpha);
}

test "direct path pipelines blend without stencil" {
    const shader = sokol_device.Shader{ .id = 7 };
    const convex = sokol_device.pathPipelineDesc(shader, .convex);
    const fringe = sokol_device.pathPipelineDesc(shader, .fringe);
    const triangles = sokol_device.pathPipelineDesc(shader, .triangles);

    try testing.expectEqual(@as(@TypeOf(convex.primitive_type), .TRIANGLES), convex.primitive_type);
    try testing.expectEqual(@as(@TypeOf(convex.index_type), .UINT16), convex.index_type);
    try testing.expect(!convex.stencil.enabled);
    try testing.expect(convex.colors[0].blend.enabled);

    try testing.expectEqual(@as(@TypeOf(fringe.primitive_type), .TRIANGLE_STRIP), fringe.primitive_type);
    try testing.expectEqual(@as(@TypeOf(fringe.index_type), .DEFAULT), fringe.index_type);
    try testing.expect(!fringe.stencil.enabled);
    try testing.expect(fringe.colors[0].blend.enabled);

    try testing.expectEqual(@as(@TypeOf(triangles.primitive_type), .TRIANGLES), triangles.primitive_type);
    try testing.expectEqual(@as(@TypeOf(triangles.index_type), .DEFAULT), triangles.index_type);
    try testing.expect(!triangles.stencil.enabled);
    try testing.expect(triangles.colors[0].blend.enabled);
}

test "fringe stencil pipeline reads stencil without clearing it" {
    const shader = sokol_device.Shader{ .id = 7 };
    const desc = sokol_device.pathPipelineDesc(shader, .fringe_stencil);

    try testing.expectEqual(@as(@TypeOf(desc.primitive_type), .TRIANGLE_STRIP), desc.primitive_type);
    try testing.expectEqual(@as(@TypeOf(desc.index_type), .DEFAULT), desc.index_type);
    try testing.expect(desc.stencil.enabled);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.front.compare), .EQUAL), desc.stencil.front.compare);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.front.pass_op), .KEEP), desc.stencil.front.pass_op);
    try testing.expectEqual(@as(@TypeOf(desc.stencil.back.pass_op), .KEEP), desc.stencil.back.pass_op);
    try testing.expectEqual(@as(u8, 0xff), desc.stencil.read_mask);
    try testing.expectEqual(@as(u8, 0), desc.stencil.write_mask);
    try testing.expect(desc.colors[0].blend.enabled);
}

test "attached device records pixel viewport dimensions" {
    var device = sokol_device.Device.attach();
    device.resize(100.25, 50.0, 2.0);

    try testing.expectEqual(@as(i32, 201), device.width);
    try testing.expectEqual(@as(i32, 100), device.height);
    try testing.expectEqual(@as(f32, 2.0), device.dpr);
}
