const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");

const app = sokol.app;
const glue = sokol.glue;

const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const Context = okys.state.context.Context;
const Backend = okys.systems.backend_stencil.Backend;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;
const sokol_device = okys.render.sokol_device;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

var device: sokol_device.Device = .{};
var ctx: ?*Context = null;
var backend: ?*Backend = null;
var checker_image: ImageId = .none;

pub fn main() void {
    app.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 960,
        .height = 640,
        .high_dpi = true,
        .window_title = "Okys stencil-cover demo",
    });
}

fn init() callconv(.c) void {
    device = sokol_device.Device.initOwned(.{ .environment = glue.environment() });

    const c = Context.create(std.heap.c_allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES) catch {
        app.requestQuit();
        return;
    };
    const b = Backend.createWithFlags(std.heap.c_allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES) catch {
        c.destroy();
        app.requestQuit();
        return;
    };
    b.fill_rule = .even_odd;
    c.installBackend(b.interface());

    ctx = c;
    backend = b;
    checker_image = createCheckerImage(c);
}

fn frame() callconv(.c) void {
    const c = ctx orelse return;
    const b = backend orelse return;
    const width = app.widthf();
    const height = app.heightf();
    const dpr = app.dpiScale();

    device.resize(width, height, dpr);
    frame_ops.beginFrame(c, width, height, dpr);
    drawScene(c, checker_image);

    const pass = sokol_device.swapchainPassWithAction(
        sokol_device.stencilCoverPassAction(.{ .r = 0.08, .g = 0.09, .b = 0.10, .a = 1.0 }),
        glue.swapchain(),
    );
    _ = b.submitToDevice(&device, pass);
    b.clearQueued();
    sokol_device.Device.commit();
}

fn cleanup() callconv(.c) void {
    if (ctx) |c| {
        c.destroy();
        ctx = null;
        backend = null;
    }
    device.deinit();
}

fn createCheckerImage(c: *Context) ImageId {
    const pixels = [_]u8{
        255, 255, 255, 255, 40,  80,  160, 255,
        40,  80,  160, 255, 255, 255, 255, 255,
    };
    return image_ops.createImageRGBA(c, 2, 2, &pixels);
}

fn drawScene(c: *Context, image_id: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.14, 0.15, 0.16, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, c.width, c.height);
    render_ops.fill(c);

    paint_ops.fillColor(c, color.rgbaf(0.20, 0.58, 0.86, 1.0));
    path_ops.beginPath(c);
    path_ops.roundedRect(c, 48, 48, 190, 110, 18);
    render_ops.fill(c);

    paint_ops.fillPaint(c, paint_ops.linearGradient(
        c,
        280,
        52,
        520,
        160,
        color.rgbaf(1.0, 0.72, 0.20, 1.0),
        color.rgbaf(0.82, 0.18, 0.46, 1.0),
    ));
    path_ops.beginPath(c);
    path_ops.moveTo(c, 292, 150);
    path_ops.bezierTo(c, 330, 36, 480, 36, 525, 145);
    path_ops.lineTo(c, 426, 204);
    path_ops.closePath(c);
    render_ops.fill(c);

    paint_ops.fillColor(c, color.rgbaf(0.64, 0.86, 0.35, 0.92));
    path_ops.beginPath(c);
    path_ops.rect(c, 580, 54, 210, 140);
    path_ops.rect(c, 636, 88, 100, 72);
    render_ops.fill(c);

    if (image_id != .none) {
        paint_ops.fillPaint(c, paint_ops.imagePattern(c, 58, 238, 96, 96, 0.2, @intCast(@intFromEnum(image_id)), 0.9));
        path_ops.beginPath(c);
        path_ops.roundedRect(c, 48, 228, 180, 120, 16);
        render_ops.fill(c);
    }

    state_ops.save(c);
    state_ops.scissor(c, 282, 230, 250, 120);
    paint_ops.fillPaint(c, paint_ops.boxGradient(
        c,
        270,
        220,
        270,
        140,
        28,
        38,
        color.rgbaf(0.94, 0.94, 0.98, 1.0),
        color.rgbaf(0.16, 0.40, 0.70, 0.85),
    ));
    path_ops.beginPath(c);
    path_ops.circle(c, 338, 286, 74);
    path_ops.circle(c, 476, 286, 74);
    render_ops.fill(c);
    state_ops.restore(c);

    paint_ops.strokeColor(c, color.rgbaf(0.94, 0.94, 0.90, 1.0));
    state_ops.strokeWidth(c, 10);
    state_ops.lineJoin(c, .round);
    state_ops.lineCap(c, .round);
    path_ops.beginPath(c);
    path_ops.moveTo(c, 590, 265);
    path_ops.lineTo(c, 660, 225);
    path_ops.lineTo(c, 735, 310);
    path_ops.bezierTo(c, 780, 360, 850, 250, 890, 318);
    render_ops.stroke(c);

    paint_ops.strokeColor(c, color.rgbaf(0.95, 0.30, 0.22, 0.75));
    state_ops.strokeWidth(c, 0.55);
    state_ops.lineCap(c, .square);
    path_ops.beginPath(c);
    path_ops.moveTo(c, 58, 410);
    path_ops.lineTo(c, 900, 414);
    render_ops.stroke(c);
    path_ops.beginPath(c);
    path_ops.moveTo(c, 58, 418);
    path_ops.lineTo(c, 900, 422);
    render_ops.stroke(c);
}
