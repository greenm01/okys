const std = @import("std");
const okys = @import("okys");
const tiger_data = @import("tiger_data.zig");

const color = okys.types.color;
pub const CapturedFrame = okys.render.frame_capture.CapturedFrame;
pub const Context = okys.state.context.Context;
pub const ImageId = okys.types.image.ImageId;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

pub const oky_antialias: u32 = 1 << 0;
pub const oky_stencil_strokes: u32 = 1 << 1;
pub const scene_width: f32 = 960;
pub const scene_height: f32 = 640;
pub const tiger_min_x: f32 = 17.0;
pub const tiger_min_y: f32 = 53.0;
pub const tiger_max_x: f32 = 562.0;
pub const tiger_max_y: f32 = 613.0;
pub const tiger_margin: f32 = 32.0;
pub const tiger_visible_width = tiger_max_x - tiger_min_x;
pub const tiger_visible_height = tiger_max_y - tiger_min_y;
pub const tiger_source_center_x = (tiger_min_x + tiger_max_x) * 0.5;
pub const tiger_source_center_y = tiger_data.height - (tiger_min_y + tiger_max_y) * 0.5;
pub const tiger_nose_source_x: f32 = 145.0;
pub const tiger_nose_source_y: f32 = 315.0;

const checker_size = 16;
const checker_square = 4;

pub const SceneDraw = *const fn (*Context, ImageId) void;

pub const TigerPlacement = struct {
    center_x: f32,
    center_y: f32,
    scale: f32,
    angle: f32 = 0,
    pivot_x: f32 = tiger_source_center_x,
    pivot_y: f32 = tiger_source_center_y,
};

pub const SceneSpec = struct {
    name: []const u8,
    draw: SceneDraw,
};

pub const specs = [_]SceneSpec{
    .{ .name = "mixed_demo", .draw = drawMixedScene },
    .{ .name = "rounded_rect_grid", .draw = drawRoundedGridScene },
    .{ .name = "arcs_icons", .draw = drawArcsIconsScene },
    .{ .name = "nested_scissors", .draw = drawScissorScene },
};

pub const tiger_specs = [_]SceneSpec{
    .{ .name = "ghostscript_tiger", .draw = drawTigerScene },
};

pub fn captureScene(gpa: std.mem.Allocator, draw: SceneDraw) !CapturedFrame {
    var frame = CapturedFrame.init(gpa);
    errdefer frame.deinit();

    const ctx = try Context.create(gpa, oky_antialias | oky_stencil_strokes);
    defer ctx.destroy();
    ctx.installBackend(frame.interface());

    frame_ops.beginFrame(ctx, scene_width, scene_height, 1);
    const image_id = createCheckerImage(ctx);
    draw(ctx, image_id);
    frame_ops.cancelFrame(ctx);
    return frame;
}

pub fn createCheckerImage(c: *Context) ImageId {
    var pixels: [checker_size * checker_size * 4]u8 = undefined;
    var y: usize = 0;
    while (y < checker_size) : (y += 1) {
        var x: usize = 0;
        while (x < checker_size) : (x += 1) {
            const dark = ((x / checker_square) + (y / checker_square)) % 2 == 0;
            const index = (y * checker_size + x) * 4;
            if (dark) {
                pixels[index + 0] = 40;
                pixels[index + 1] = 80;
                pixels[index + 2] = 160;
            } else {
                pixels[index + 0] = 255;
                pixels[index + 1] = 255;
                pixels[index + 2] = 255;
            }
            pixels[index + 3] = 255;
        }
    }
    return image_ops.createImageRGBA(c, checker_size, checker_size, &pixels);
}

pub fn drawMixedScene(c: *Context, image_id: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.14, 0.15, 0.16, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, scene_width, scene_height);
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

pub fn drawRoundedGridScene(c: *Context, image_id: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.12, 0.13, 0.14, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, scene_width, scene_height);
    render_ops.fill(c);

    var row: usize = 0;
    while (row < 9) : (row += 1) {
        var col: usize = 0;
        while (col < 12) : (col += 1) {
            const x = 28 + f32FromInt(col) * 76;
            const y = 28 + f32FromInt(row) * 66;
            const shade = 0.18 + f32FromInt((row + col) % 5) * 0.035;
            paint_ops.fillColor(c, color.rgbaf(shade, 0.30 + shade, 0.42 + shade, 0.95));
            path_ops.beginPath(c);
            path_ops.roundedRect(c, x, y, 58, 42, 9 + f32FromInt((row + col) % 4));
            render_ops.fill(c);
        }
    }

    if (image_id != .none) {
        paint_ops.fillPaint(c, paint_ops.imagePattern(c, 650, 80, 120, 120, 0.4, @intCast(@intFromEnum(image_id)), 0.55));
        path_ops.beginPath(c);
        path_ops.roundedRect(c, 632, 68, 220, 148, 24);
        render_ops.fill(c);
    }
}

pub fn drawArcsIconsScene(c: *Context, _: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.11, 0.12, 0.13, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, scene_width, scene_height);
    render_ops.fill(c);

    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const col = i % 10;
        const row = i / 10;
        const cx = 64 + f32FromInt(col) * 88;
        const cy = 58 + f32FromInt(row) * 68;
        const r = 18 + f32FromInt(i % 5);

        paint_ops.fillColor(c, color.rgbaf(0.20 + f32FromInt(i % 3) * 0.08, 0.56, 0.70, 0.85));
        path_ops.beginPath(c);
        path_ops.circle(c, cx, cy, r);
        path_ops.circle(c, cx, cy, r * 0.45);
        render_ops.fill(c);

        paint_ops.strokeColor(c, color.rgbaf(0.94, 0.90, 0.76, 0.9));
        state_ops.strokeWidth(c, 3 + f32FromInt(i % 4));
        state_ops.lineCap(c, .round);
        path_ops.beginPath(c);
        path_ops.arc(c, cx, cy, r + 8, 0.2, std.math.pi * (1.1 + f32FromInt(i % 4) * 0.1), .cw);
        render_ops.stroke(c);
    }
}

pub fn drawScissorScene(c: *Context, image_id: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.13, 0.14, 0.15, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, scene_width, scene_height);
    render_ops.fill(c);

    var i: usize = 0;
    while (i < 24) : (i += 1) {
        const x = 36 + f32FromInt(i % 6) * 150;
        const y = 34 + f32FromInt(i / 6) * 138;

        state_ops.save(c);
        state_ops.scissor(c, x, y, 116, 104);
        state_ops.intersectScissor(c, x + 14, y + 12, 84, 76);

        if (image_id != .none and i % 3 == 0) {
            paint_ops.fillPaint(c, paint_ops.imagePattern(c, x - 10, y - 10, 72, 72, 0.1 * f32FromInt(i % 5), @intCast(@intFromEnum(image_id)), 0.8));
        } else {
            paint_ops.fillPaint(c, paint_ops.linearGradient(
                c,
                x,
                y,
                x + 100,
                y + 90,
                color.rgbaf(0.85, 0.34, 0.38, 0.9),
                color.rgbaf(0.20, 0.46, 0.82, 0.9),
            ));
        }
        path_ops.beginPath(c);
        path_ops.roundedRect(c, x - 8, y - 4, 138, 112, 20);
        render_ops.fill(c);

        paint_ops.strokeColor(c, color.rgbaf(0.96, 0.94, 0.84, 0.78));
        state_ops.strokeWidth(c, 4);
        state_ops.lineJoin(c, .round);
        state_ops.lineCap(c, .round);
        path_ops.beginPath(c);
        path_ops.moveTo(c, x - 8, y + 80);
        path_ops.bezierTo(c, x + 28, y + 20, x + 78, y + 128, x + 132, y + 24);
        render_ops.stroke(c);
        state_ops.restore(c);
    }
}

pub fn drawTigerScene(c: *Context, _: ImageId) void {
    paint_ops.fillColor(c, color.rgbaf(0.0, 0.0, 0.50, 1.0));
    path_ops.beginPath(c);
    path_ops.rect(c, 0, 0, scene_width, scene_height);
    render_ops.fill(c);

    drawTiger(c, tigerDefaultPlacement());
}

pub fn tigerDefaultPlacement() TigerPlacement {
    return .{
        .center_x = tiger_tx + tiger_source_center_x * tiger_scale,
        .center_y = tiger_ty + tiger_source_center_y * tiger_scale,
        .scale = tiger_scale,
    };
}

pub fn tigerScaleForBox(width: f32, height: f32, margin: f32, rotating: bool) f32 {
    const available_w = @max(width - margin * 2.0, 1.0);
    const available_h = @max(height - margin * 2.0, 1.0);
    if (rotating) {
        const diagonal = @sqrt(tiger_visible_width * tiger_visible_width + tiger_visible_height * tiger_visible_height);
        return @min(available_w / diagonal, available_h / diagonal);
    }
    return @min(available_w / tiger_visible_width, available_h / tiger_visible_height);
}

pub fn tigerScaleForPivotBox(width: f32, height: f32, margin: f32, pivot_x: f32, pivot_y: f32) f32 {
    const available_w = @max(width - margin * 2.0, 1.0);
    const available_h = @max(height - margin * 2.0, 1.0);
    const radius = @max(
        distance(pivot_x, pivot_y, tiger_min_x, tiger_data.height - tiger_min_y),
        @max(
            distance(pivot_x, pivot_y, tiger_min_x, tiger_data.height - tiger_max_y),
            @max(
                distance(pivot_x, pivot_y, tiger_max_x, tiger_data.height - tiger_min_y),
                distance(pivot_x, pivot_y, tiger_max_x, tiger_data.height - tiger_max_y),
            ),
        ),
    );
    return @min(available_w, available_h) / @max(radius * 2.0, 1.0);
}

pub fn drawTiger(c: *Context, placement: TigerPlacement) void {
    var command_index: usize = 0;
    var point_index: usize = 0;
    while (command_index < tiger_data.commands.len) {
        const fill_mode = tiger_data.commands[command_index];
        command_index += 1;
        const stroke_mode = tiger_data.commands[command_index];
        command_index += 1;
        const cap_mode = tiger_data.commands[command_index];
        command_index += 1;
        const join_mode = tiger_data.commands[command_index];
        command_index += 1;

        const miter_limit = tiger_data.points[point_index];
        const stroke_width = tiger_data.points[point_index + 1];
        point_index += 2;

        const stroke_color = color.rgbaf(
            tiger_data.points[point_index + 0],
            tiger_data.points[point_index + 1],
            tiger_data.points[point_index + 2],
            1.0,
        );
        const fill_color = color.rgbaf(
            tiger_data.points[point_index + 3],
            tiger_data.points[point_index + 4],
            tiger_data.points[point_index + 5],
            1.0,
        );
        point_index += 6;

        const path_command_count: usize = @intFromFloat(tiger_data.points[point_index]);
        point_index += 1;

        path_ops.beginPath(c);
        var i: usize = 0;
        while (i < path_command_count) : (i += 1) {
            const path_command = tiger_data.commands[command_index];
            command_index += 1;
            switch (path_command) {
                'M' => {
                    const p = tigerPoint(placement, tiger_data.points[point_index], tiger_data.points[point_index + 1]);
                    path_ops.moveTo(c, p[0], p[1]);
                    point_index += 2;
                },
                'L' => {
                    const p = tigerPoint(placement, tiger_data.points[point_index], tiger_data.points[point_index + 1]);
                    path_ops.lineTo(c, p[0], p[1]);
                    point_index += 2;
                },
                'C' => {
                    const p0 = tigerPoint(placement, tiger_data.points[point_index + 0], tiger_data.points[point_index + 1]);
                    const p1 = tigerPoint(placement, tiger_data.points[point_index + 2], tiger_data.points[point_index + 3]);
                    const p2 = tigerPoint(placement, tiger_data.points[point_index + 4], tiger_data.points[point_index + 5]);
                    path_ops.bezierTo(
                        c,
                        p0[0],
                        p0[1],
                        p1[0],
                        p1[1],
                        p2[0],
                        p2[1],
                    );
                    point_index += 6;
                },
                'E' => path_ops.closePath(c),
                else => {},
            }
        }

        if (fill_mode == 'F') {
            paint_ops.fillColor(c, fill_color);
            render_ops.fill(c);
        }

        if (stroke_mode == 'S') {
            paint_ops.strokeColor(c, stroke_color);
            state_ops.strokeWidth(c, stroke_width * placement.scale);
            state_ops.miterLimit(c, miter_limit);
            state_ops.lineCap(c, tigerLineCap(cap_mode));
            state_ops.lineJoin(c, tigerLineJoin(join_mode));
            render_ops.stroke(c);
        }
    }
}

fn f32FromInt(value: usize) f32 {
    return @floatFromInt(value);
}

const tiger_scale = @min(
    (scene_width - tiger_margin * 2.0) / tiger_visible_width,
    (scene_height - tiger_margin * 2.0) / tiger_visible_height,
);
const tiger_tx = (scene_width - tiger_visible_width * tiger_scale) * 0.5 - tiger_min_x * tiger_scale;
const tiger_ty = (scene_height - tiger_visible_height * tiger_scale) * 0.5 - tiger_min_y * tiger_scale;

fn tigerPoint(placement: TigerPlacement, x: f32, y: f32) [2]f32 {
    const source_x = x;
    const source_y = tiger_data.height - y;
    const dx = source_x - placement.pivot_x;
    const dy = source_y - placement.pivot_y;
    const cs = @cos(placement.angle);
    const sn = @sin(placement.angle);
    return .{
        placement.center_x + (dx * cs - dy * sn) * placement.scale,
        placement.center_y + (dx * sn + dy * cs) * placement.scale,
    };
}

fn distance(x0: f32, y0: f32, x1: f32, y1: f32) f32 {
    const dx = x1 - x0;
    const dy = y1 - y0;
    return @sqrt(dx * dx + dy * dy);
}

fn tigerLineCap(mode: u8) okys.state.draw_state.LineCap {
    return switch (mode) {
        'R' => .round,
        'S' => .square,
        else => .butt,
    };
}

fn tigerLineJoin(mode: u8) okys.state.draw_state.LineJoin {
    return switch (mode) {
        'R' => .round,
        'B' => .bevel,
        else => .miter,
    };
}
