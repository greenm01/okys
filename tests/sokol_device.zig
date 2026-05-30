const std = @import("std");
const testing = std.testing;

const okys = @import("okys");
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

test "attached device records pixel viewport dimensions" {
    var device = sokol_device.Device.attach();
    device.resize(100.25, 50.0, 2.0);

    try testing.expectEqual(@as(i32, 201), device.width);
    try testing.expectEqual(@as(i32, 100), device.height);
    try testing.expectEqual(@as(f32, 2.0), device.dpr);
}
