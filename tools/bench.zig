const std = @import("std");
const okys = @import("okys");

const color = okys.types.color;
const ImageId = okys.types.image.ImageId;
const CapturedFrame = okys.render.frame_capture.CapturedFrame;
const Context = okys.state.context.Context;
const SparseBackend = okys.systems.backend_sparse_strip.Backend;
const StencilBackend = okys.systems.backend_stencil.Backend;
const SparseCall = okys.systems.backend_sparse_strip.EncodedCall;
const SparseProfile = okys.systems.backend_sparse_strip.Profile;
const SparseSegment = okys.systems.backend_sparse_strip.Segment;
const SparseStrip = okys.systems.backend_sparse_strip.Strip;
const SparseTile = okys.systems.backend_sparse_strip.TileRef;
const StencilCall = okys.systems.backend_stencil.Call;
const StencilDrawOp = okys.systems.backend_stencil.DrawOp;
const StencilPath = okys.systems.backend_stencil.QueuedPath;
const StencilUniform = okys.systems.backend_stencil.PaintUniform;
const Vertex = okys.types.path.Vertex;
const frame_ops = okys.ops.frame;
const image_ops = okys.ops.image;
const paint_ops = okys.ops.paint;
const path_ops = okys.ops.path;
const render_ops = okys.ops.render;
const state_ops = okys.ops.state;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

const warmup_iterations: usize = 5;
const measured_iterations: usize = 50;
const scene_width: f32 = 960;
const scene_height: f32 = 640;
const checker_size = 16;
const checker_square = 4;

const Scene = struct {
    name: []const u8,
    frame: *const CapturedFrame,
};

const Stats = struct {
    calls: usize = 0,
    segments: usize = 0,
    tiles: usize = 0,
    strips: usize = 0,
    vertices: usize = 0,
    indices: usize = 0,
    draw_ops: usize = 0,
    buffer_bytes: usize = 0,
};

const ProfileStats = struct {
    bin_ns: u64 = 0,
    coarse_ns: u64 = 0,
    texture_views_ns: u64 = 0,
    fine_ns: u64 = 0,
    clear_ns: u64 = 0,
    boundary_index_ns: u64 = 0,
    boundary_alpha_ns: u64 = 0,
    boundary_composite_ns: u64 = 0,
    solid_scan_ns: u64 = 0,
    solid_composite_ns: u64 = 0,
    boundary_tiles: usize = 0,
    solid_tiles: usize = 0,
    boundary_pixels: usize = 0,
    solid_pixels: usize = 0,
    composite_pixels: usize = 0,
    solid_fast_pixels: usize = 0,
    opaque_write_pixels: usize = 0,
    rect_fast_calls: usize = 0,
    rect_fast_pixels: usize = 0,
};

const Result = struct {
    replay_ns: u64,
    build_ns: u64,
    stats: Stats,
    profile: ProfileStats = .{},
};

pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var mixed = try captureScene(gpa, drawMixedScene);
    defer mixed.deinit();
    var rounded_grid = try captureScene(gpa, drawRoundedGridScene);
    defer rounded_grid.deinit();
    var arcs_icons = try captureScene(gpa, drawArcsIconsScene);
    defer arcs_icons.deinit();
    var scissors = try captureScene(gpa, drawScissorScene);
    defer scissors.deinit();

    const scenes = [_]Scene{
        .{ .name = "mixed_demo", .frame = &mixed },
        .{ .name = "rounded_rect_grid", .frame = &rounded_grid },
        .{ .name = "arcs_icons", .frame = &arcs_icons },
        .{ .name = "nested_scissors", .frame = &scissors },
    };

    printHeader();
    for (scenes) |scene| {
        const stencil = try benchStencil(gpa, scene.frame);
        printResult(scene.name, "stencil_cover", "cpu_build_only", stencil);

        const sparse = try benchSparse(gpa, scene.frame);
        printResult(scene.name, "sparse_strip", "cpu_raster_composite", sparse);
    }
}

fn captureScene(gpa: std.mem.Allocator, draw: *const fn (*Context, ImageId) void) !CapturedFrame {
    var frame = CapturedFrame.init(gpa);
    errdefer frame.deinit();

    const ctx = try Context.create(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();
    ctx.installBackend(frame.interface());

    frame_ops.beginFrame(ctx, scene_width, scene_height, 1);
    const image_id = createCheckerImage(ctx);
    draw(ctx, image_id);
    frame_ops.cancelFrame(ctx);
    return frame;
}

fn benchStencil(gpa: std.mem.Allocator, frame: *const CapturedFrame) !Result {
    var replay_total: u128 = 0;
    var build_total: u128 = 0;
    var stats: Stats = .{};

    var i: usize = 0;
    while (i < warmup_iterations + measured_iterations) : (i += 1) {
        const backend = try StencilBackend.createWithFlags(gpa, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
        defer backend.destroy();
        backend.fill_rule = .even_odd;

        const replay_start = nowNs();
        frame.replay(backend.interface());
        const replay_ns = nowNs() - replay_start;

        const build_start = nowNs();
        if (!backend.buildStencilPass()) return error.BenchmarkBuildFailed;
        const build_ns = nowNs() - build_start;

        if (i >= warmup_iterations) {
            replay_total += replay_ns;
            build_total += build_ns;
            stats = stencilStats(backend);
        }
    }

    return .{
        .replay_ns = average(replay_total),
        .build_ns = average(build_total),
        .stats = stats,
    };
}

fn benchSparse(gpa: std.mem.Allocator, frame: *const CapturedFrame) !Result {
    var replay_total: u128 = 0;
    var build_total: u128 = 0;
    var profile_total: ProfileStats = .{};
    var profile_last: ProfileStats = .{};
    var stats: Stats = .{};

    var i: usize = 0;
    while (i < warmup_iterations + measured_iterations) : (i += 1) {
        const backend = try SparseBackend.create(gpa);
        defer backend.destroy();
        backend.fill_rule = .even_odd;

        const replay_start = nowNs();
        frame.replay(backend.interface());
        const replay_ns = nowNs() - replay_start;

        var profile: SparseProfile = .{};
        const build_start = nowNs();
        if (!backend.buildProfiled(&profile)) return error.BenchmarkBuildFailed;
        const build_ns = nowNs() - build_start;

        if (i >= warmup_iterations) {
            replay_total += replay_ns;
            build_total += build_ns;
            const profile_stats = profileStats(profile);
            addProfileDurations(&profile_total, profile_stats);
            profile_last = profile_stats;
            stats = sparseStats(backend);
        }
    }

    return .{
        .replay_ns = average(replay_total),
        .build_ns = average(build_total),
        .stats = stats,
        .profile = averageProfile(profile_total, profile_last),
    };
}

fn average(total: u128) u64 {
    return @intCast(total / measured_iterations);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn stencilStats(backend: *const StencilBackend) Stats {
    var texture_bytes: usize = 0;
    for (backend.textures.values()) |texture| {
        texture_bytes += texture.pixels.items.len;
    }

    return .{
        .calls = backend.calls.items.len,
        .vertices = backend.vertices.items.len,
        .indices = backend.indices.items.len,
        .draw_ops = backend.draw_ops.items.len,
        .buffer_bytes = bytesOf(StencilCall, backend.calls.items.len) +
            bytesOf(StencilPath, backend.paths.items.len) +
            bytesOf(Vertex, backend.vertices.items.len) +
            bytesOf(u16, backend.indices.items.len) +
            bytesOf(StencilUniform, backend.uniforms.items.len) +
            bytesOf(StencilDrawOp, backend.draw_ops.items.len) +
            texture_bytes,
    };
}

fn sparseStats(backend: *const SparseBackend) Stats {
    var texture_bytes: usize = 0;
    for (backend.textures.values()) |texture| {
        texture_bytes += texture.pixels.items.len;
    }

    return .{
        .calls = backend.calls.items.len,
        .segments = backend.segments.items.len,
        .tiles = backend.tiles.items.len,
        .strips = backend.strips.items.len,
        .buffer_bytes = bytesOf(SparseCall, backend.calls.items.len) +
            bytesOf(SparseSegment, backend.segments.items.len) +
            bytesOf(SparseTile, backend.tiles.items.len) +
            bytesOf(SparseStrip, backend.strips.items.len) +
            bytesOf(u32, backend.strip_segment_indices.items.len) +
            backend.alphas.items.len +
            backend.surface.items.len +
            texture_bytes,
    };
}

fn profileStats(profile: SparseProfile) ProfileStats {
    return .{
        .bin_ns = profile.bin_ns,
        .coarse_ns = profile.coarse_ns,
        .texture_views_ns = profile.texture_views_ns,
        .fine_ns = profile.fine_ns,
        .clear_ns = profile.fine_profile.clear_ns,
        .boundary_index_ns = profile.fine_profile.boundary_index_ns,
        .boundary_alpha_ns = profile.fine_profile.boundary_alpha_ns,
        .boundary_composite_ns = profile.fine_profile.boundary_composite_ns,
        .solid_scan_ns = profile.fine_profile.solid_scan_ns,
        .solid_composite_ns = profile.fine_profile.solid_composite_ns,
        .boundary_tiles = profile.fine_profile.boundary_tiles,
        .solid_tiles = profile.fine_profile.solid_tiles,
        .boundary_pixels = profile.fine_profile.boundary_pixels,
        .solid_pixels = profile.fine_profile.solid_pixels,
        .composite_pixels = profile.fine_profile.composite_pixels,
        .solid_fast_pixels = profile.fine_profile.solid_fast_pixels,
        .opaque_write_pixels = profile.fine_profile.opaque_write_pixels,
        .rect_fast_calls = profile.fine_profile.rect_fast_calls,
        .rect_fast_pixels = profile.fine_profile.rect_fast_pixels,
    };
}

fn addProfileDurations(total: *ProfileStats, profile: ProfileStats) void {
    total.bin_ns += profile.bin_ns;
    total.coarse_ns += profile.coarse_ns;
    total.texture_views_ns += profile.texture_views_ns;
    total.fine_ns += profile.fine_ns;
    total.clear_ns += profile.clear_ns;
    total.boundary_index_ns += profile.boundary_index_ns;
    total.boundary_alpha_ns += profile.boundary_alpha_ns;
    total.boundary_composite_ns += profile.boundary_composite_ns;
    total.solid_scan_ns += profile.solid_scan_ns;
    total.solid_composite_ns += profile.solid_composite_ns;
}

fn averageProfile(total: ProfileStats, last: ProfileStats) ProfileStats {
    return .{
        .bin_ns = average(total.bin_ns),
        .coarse_ns = average(total.coarse_ns),
        .texture_views_ns = average(total.texture_views_ns),
        .fine_ns = average(total.fine_ns),
        .clear_ns = average(total.clear_ns),
        .boundary_index_ns = average(total.boundary_index_ns),
        .boundary_alpha_ns = average(total.boundary_alpha_ns),
        .boundary_composite_ns = average(total.boundary_composite_ns),
        .solid_scan_ns = average(total.solid_scan_ns),
        .solid_composite_ns = average(total.solid_composite_ns),
        .boundary_tiles = last.boundary_tiles,
        .solid_tiles = last.solid_tiles,
        .boundary_pixels = last.boundary_pixels,
        .solid_pixels = last.solid_pixels,
        .composite_pixels = last.composite_pixels,
        .solid_fast_pixels = last.solid_fast_pixels,
        .opaque_write_pixels = last.opaque_write_pixels,
        .rect_fast_calls = last.rect_fast_calls,
        .rect_fast_pixels = last.rect_fast_pixels,
    };
}

fn bytesOf(comptime T: type, count: usize) usize {
    return @sizeOf(T) * count;
}

fn printHeader() void {
    _ = std.c.printf("scene\tbackend\ttiming_scope\titerations\treplay_avg_ns\tbuild_avg_ns\ttotal_avg_ns\tcalls\tsegments\ttiles\tstrips\tvertices\tindices\tdraw_ops\tbuffer_bytes\tbin_ns\tcoarse_ns\ttexture_views_ns\tfine_ns\tclear_ns\tboundary_index_ns\tboundary_alpha_ns\tboundary_composite_ns\tsolid_scan_ns\tsolid_composite_ns\tboundary_tiles\tsolid_tiles\tboundary_pixels\tsolid_pixels\tcomposite_pixels\tsolid_fast_pixels\topaque_write_pixels\trect_fast_calls\trect_fast_pixels\n");
}

fn printResult(scene_name: []const u8, backend_name: []const u8, timing_scope: []const u8, result: Result) void {
    _ = std.c.printf(
        "%.*s\t%.*s\t%.*s\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\t%llu\n",
        @as(c_int, @intCast(scene_name.len)),
        cString(scene_name),
        @as(c_int, @intCast(backend_name.len)),
        cString(backend_name),
        @as(c_int, @intCast(timing_scope.len)),
        cString(timing_scope),
        u64ForPrint(measured_iterations),
        u64ForPrint(result.replay_ns),
        u64ForPrint(result.build_ns),
        u64ForPrint(result.replay_ns + result.build_ns),
        u64ForPrint(result.stats.calls),
        u64ForPrint(result.stats.segments),
        u64ForPrint(result.stats.tiles),
        u64ForPrint(result.stats.strips),
        u64ForPrint(result.stats.vertices),
        u64ForPrint(result.stats.indices),
        u64ForPrint(result.stats.draw_ops),
        u64ForPrint(result.stats.buffer_bytes),
        u64ForPrint(result.profile.bin_ns),
        u64ForPrint(result.profile.coarse_ns),
        u64ForPrint(result.profile.texture_views_ns),
        u64ForPrint(result.profile.fine_ns),
        u64ForPrint(result.profile.clear_ns),
        u64ForPrint(result.profile.boundary_index_ns),
        u64ForPrint(result.profile.boundary_alpha_ns),
        u64ForPrint(result.profile.boundary_composite_ns),
        u64ForPrint(result.profile.solid_scan_ns),
        u64ForPrint(result.profile.solid_composite_ns),
        u64ForPrint(result.profile.boundary_tiles),
        u64ForPrint(result.profile.solid_tiles),
        u64ForPrint(result.profile.boundary_pixels),
        u64ForPrint(result.profile.solid_pixels),
        u64ForPrint(result.profile.composite_pixels),
        u64ForPrint(result.profile.solid_fast_pixels),
        u64ForPrint(result.profile.opaque_write_pixels),
        u64ForPrint(result.profile.rect_fast_calls),
        u64ForPrint(result.profile.rect_fast_pixels),
    );
}

fn cString(value: []const u8) [*c]const u8 {
    return @ptrCast(value.ptr);
}

fn u64ForPrint(value: anytype) c_ulonglong {
    return @intCast(value);
}

fn createCheckerImage(c: *Context) ImageId {
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

fn drawMixedScene(c: *Context, image_id: ImageId) void {
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

fn drawRoundedGridScene(c: *Context, image_id: ImageId) void {
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

fn drawArcsIconsScene(c: *Context, _: ImageId) void {
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

fn drawScissorScene(c: *Context, image_id: ImageId) void {
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

fn f32FromInt(value: usize) f32 {
    return @floatFromInt(value);
}
