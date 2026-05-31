//! Scalar fine stage for the first sparse-strip proof.

const std = @import("std");
const color = @import("../../types/color.zig");
const image = @import("../../types/image.zig");
const encode = @import("encode.zig");
const strip = @import("strip.zig");
const xforms = @import("../transform.zig");

pub const Texture = struct {
    id: image.ImageId,
    width: u32,
    height: u32,
    format: image.TexFormat,
    pixels: []const u8,
};

pub const Profile = struct {
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
    fill_ops: usize = 0,
    alpha_fill_ops: usize = 0,
    fill_pixels: usize = 0,
    alpha_fill_pixels: usize = 0,

    pub fn reset(self: *Profile) void {
        self.* = .{};
    }
};

const ColorF = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

const SolidPaint = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const Rect = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
};

const CompositeResult = struct {
    touched: bool = false,
    opaque_write: bool = false,
};

pub fn build(
    gpa: std.mem.Allocator,
    fill_rule: strip.FillRule,
    viewport_width: f32,
    viewport_height: f32,
    calls: []const encode.EncodedCall,
    segments: []const encode.Segment,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    strip_segment_indices: []const u32,
    textures: []const Texture,
    strips: *std.ArrayList(strip.Strip),
    alphas: *std.ArrayList(u8),
    surface: *std.ArrayList(u8),
    profile: ?*Profile,
) !void {
    if (profile) |p| p.reset();
    _ = strip_segment_indices;
    alphas.clearRetainingCapacity();
    const width = pixelExtent(viewport_width);
    const height = pixelExtent(viewport_height);

    const clear_start = profileStart(profile);
    try surface.resize(gpa, @as(usize, width) * @as(usize, height) * 4);
    @memset(surface.items, 0);
    if (profile) |p| p.clear_ns += elapsedSince(clear_start);

    var boundary_tiles = BoundarySet.init(gpa);
    defer boundary_tiles.deinit();

    const boundary_index_start = profileStart(profile);
    try boundary_tiles.ensureTotalCapacity(@intCast(strips.items.len));
    for (strips.items) |s| {
        try boundary_tiles.put(boundaryKey(s.call_index, strip.tileCoord(@floatFromInt(s.x)), strip.tileCoord(@floatFromInt(s.y))), {});
    }
    if (profile) |p| p.boundary_index_ns += elapsedSince(boundary_index_start);

    for (calls, 0..) |call, call_index| {
        const call_fill_rule = fillRuleForCall(fill_rule, call.kind);
        const solid = solidPaint(call);
        if (solid) |sp| {
            if (rectForCall(call, segments)) |rect| {
                try renderSolidRectFast(
                    gpa,
                    rect,
                    sp,
                    @intCast(call_index),
                    strips,
                    alphas,
                    width,
                    height,
                    surface.items,
                    profile,
                );
                continue;
            }
        }

        for (strips.items) |*s| {
            if (s.call_index != call_index) continue;
            try renderBoundaryStrip(
                gpa,
                call,
                call_fill_rule,
                textures,
                segments,
                clips,
                call_clip_indices,
                alphas,
                s,
                width,
                height,
                surface.items,
                solid,
                profile,
            );
        }
        renderSolidInterior(
            call,
            @intCast(call_index),
            call_fill_rule,
            textures,
            segments,
            clips,
            call_clip_indices,
            &boundary_tiles,
            width,
            height,
            surface.items,
            solid,
            profile,
        );
    }
}

const BoundarySet = std.AutoHashMap(u64, void);

fn renderBoundaryStrip(
    gpa: std.mem.Allocator,
    call: encode.EncodedCall,
    fill_rule: strip.FillRule,
    textures: []const Texture,
    segments: []const encode.Segment,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    alphas: *std.ArrayList(u8),
    s: *strip.Strip,
    width: u32,
    height: u32,
    surface: []u8,
    solid: ?SolidPaint,
    profile: ?*Profile,
) !void {
    const start = alphas.items.len;

    const alpha_start = profileStart(profile);
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            const alpha = pixelCoverageForCall(
                fill_rule,
                s.x + local_x,
                s.y + local_y,
                call.segments,
                segments,
            );
            try alphas.append(gpa, applyClipAlpha(alpha, call, clips, call_clip_indices, segments, s.x + local_x, s.y + local_y));
        }
    }
    if (profile) |p| {
        p.boundary_alpha_ns += elapsedSince(alpha_start);
        p.boundary_tiles += 1;
        p.boundary_pixels += strip.tile_area;
    }

    var touched: usize = 0;
    const composite_start = profileStart(profile);
    local_y = 0;
    var alpha_index = start;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            const alpha = alphas.items[alpha_index];
            if (solid) |sp| {
                const result = compositeSolidAlphaFillPixel(sp, alpha, s.x + local_x, s.y + local_y, width, height, surface);
                if (result.touched) touched += 1;
                if (result.opaque_write) {
                    if (profile) |p| p.opaque_write_pixels += 1;
                }
            } else {
                if (compositePaint(
                    call,
                    textures,
                    alpha,
                    s.x + local_x,
                    s.y + local_y,
                    width,
                    height,
                    surface,
                )) {
                    touched += 1;
                }
            }
            alpha_index += 1;
        }
    }
    if (profile) |p| {
        p.boundary_composite_ns += elapsedSince(composite_start);
        p.composite_pixels += touched;
        recordAlphaFill(p, touched);
        if (solid != null) p.solid_fast_pixels += touched;
    }
    s.alpha = .{ .start = @intCast(start), .count = strip.tile_area };
}

fn renderSolidInterior(
    call: encode.EncodedCall,
    call_index: u32,
    fill_rule: strip.FillRule,
    textures: []const Texture,
    segments: []const encode.Segment,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    boundary_tiles: *const BoundarySet,
    width: u32,
    height: u32,
    surface: []u8,
    solid: ?SolidPaint,
    profile: ?*Profile,
) void {
    if (width == 0 or height == 0) return;
    const bounds = callBounds(call, segments);
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3]) return;

    const max_tile_x = strip.tileCoord(@as(f32, @floatFromInt(width)) - 0.001);
    const max_tile_y = strip.tileCoord(@as(f32, @floatFromInt(height)) - 0.001);
    var tile_y = std.math.clamp(strip.tileCoord(bounds[1]), 0, max_tile_y);
    const tile_y_end = std.math.clamp(strip.tileCoord(bounds[3] - 0.001), 0, max_tile_y);
    const tile_size_f: f32 = @floatFromInt(strip.tile_size);
    var scan_start = profileStart(profile);

    while (tile_y <= tile_y_end) : (tile_y += 1) {
        var tile_x = std.math.clamp(strip.tileCoord(bounds[0]), 0, max_tile_x);
        const tile_x_end = std.math.clamp(strip.tileCoord(bounds[2] - 0.001), 0, max_tile_x);
        while (tile_x <= tile_x_end) : (tile_x += 1) {
            if (boundary_tiles.contains(boundaryKey(call_index, tile_x, tile_y))) continue;
            const sample_x = @as(f32, @floatFromInt(tile_x)) * tile_size_f + 0.5;
            const sample_y = @as(f32, @floatFromInt(tile_y)) * tile_size_f + 0.5;
            if (coverageAtForCall(fill_rule, sample_x, sample_y, call.segments, segments) == 0) continue;
            if (profile) |p| p.solid_scan_ns += elapsedSince(scan_start);

            const composite_start = profileStart(profile);
            const result = if (call.clips.count > 0)
                compositeClippedTile(call, textures, clips, call_clip_indices, segments, solid, strip.tileOrigin(@intCast(tile_x)), strip.tileOrigin(@intCast(tile_y)), width, height, surface)
            else if (solid) |sp|
                compositeSolidTile(sp, strip.tileOrigin(@intCast(tile_x)), strip.tileOrigin(@intCast(tile_y)), width, height, surface)
            else
                compositeGenericTile(call, textures, strip.tileOrigin(@intCast(tile_x)), strip.tileOrigin(@intCast(tile_y)), width, height, surface);
            if (profile) |p| {
                p.solid_composite_ns += elapsedSince(composite_start);
                p.solid_tiles += 1;
                p.solid_pixels += result.touched;
                p.composite_pixels += result.touched;
                p.opaque_write_pixels += result.opaque_writes;
                recordFill(p, result.touched);
                if (solid != null) p.solid_fast_pixels += result.touched;
                scan_start = profileStart(profile);
            }
        }
    }
    if (profile) |p| p.solid_scan_ns += elapsedSince(scan_start);
}

fn renderSolidRectFast(
    gpa: std.mem.Allocator,
    rect: Rect,
    solid: SolidPaint,
    call_index: u32,
    strips: *std.ArrayList(strip.Strip),
    alphas: *std.ArrayList(u8),
    width: u32,
    height: u32,
    surface: []u8,
    profile: ?*Profile,
) !void {
    const alpha_start = profileStart(profile);
    for (strips.items) |*s| {
        if (s.call_index != call_index) continue;
        const start = alphas.items.len;
        try appendRectTileAlpha(gpa, rect, s.x, s.y, alphas);
        s.alpha = .{ .start = @intCast(start), .count = strip.tile_area };
        if (profile) |p| {
            p.boundary_tiles += 1;
            p.boundary_pixels += strip.tile_area;
        }
    }
    if (profile) |p| p.boundary_alpha_ns += elapsedSince(alpha_start);

    var touched: usize = 0;
    var fill_pixels: usize = 0;
    var alpha_fill_pixels: usize = 0;
    var opaque_writes: usize = 0;
    const composite_start = profileStart(profile);
    const x_start = clampPixelStart(rect.x0, width);
    const y_start = clampPixelStart(rect.y0, height);
    const x_end = clampPixelEnd(rect.x1, width);
    const y_end = clampPixelEnd(rect.y1, height);
    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x = x_start;
        const y_alpha = coverage1D(@floatFromInt(y), rect.y0, rect.y1);
        while (x < x_end) : (x += 1) {
            const alpha = normToU8(coverage1D(@floatFromInt(x), rect.x0, rect.x1) * y_alpha);
            const result = if (alpha == 255)
                compositeSolidFillPixel(solid, @intCast(x), @intCast(y), width, height, surface)
            else
                compositeSolidAlphaFillPixel(solid, alpha, @intCast(x), @intCast(y), width, height, surface);
            if (result.touched) touched += 1;
            if (result.touched and alpha == 255) fill_pixels += 1;
            if (result.touched and alpha != 255) alpha_fill_pixels += 1;
            if (result.opaque_write) opaque_writes += 1;
        }
    }

    if (profile) |p| {
        p.solid_composite_ns += elapsedSince(composite_start);
        p.solid_pixels += touched;
        p.composite_pixels += touched;
        p.solid_fast_pixels += touched;
        p.opaque_write_pixels += opaque_writes;
        p.rect_fast_calls += 1;
        p.rect_fast_pixels += touched;
        recordFill(p, fill_pixels);
        if (alpha_fill_pixels > 0) recordAlphaFill(p, alpha_fill_pixels);
    }
}

const TileCompositeResult = struct {
    touched: usize = 0,
    opaque_writes: usize = 0,
};

fn compositeSolidTile(
    solid: SolidPaint,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) TileCompositeResult {
    var result: TileCompositeResult = .{};
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            const pixel = compositeSolidFillPixel(solid, x + local_x, y + local_y, width, height, surface);
            if (pixel.touched) result.touched += 1;
            if (pixel.opaque_write) result.opaque_writes += 1;
        }
    }
    return result;
}

fn recordFill(profile: *Profile, pixels: usize) void {
    if (pixels == 0) return;
    profile.fill_ops += 1;
    profile.fill_pixels += pixels;
}

fn recordAlphaFill(profile: *Profile, pixels: usize) void {
    if (pixels == 0) return;
    profile.alpha_fill_ops += 1;
    profile.alpha_fill_pixels += pixels;
}

fn compositeGenericTile(
    call: encode.EncodedCall,
    textures: []const Texture,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) TileCompositeResult {
    var result: TileCompositeResult = .{};
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            if (compositePaint(call, textures, 255, x + local_x, y + local_y, width, height, surface)) {
                result.touched += 1;
            }
        }
    }
    return result;
}

fn compositeClippedTile(
    call: encode.EncodedCall,
    textures: []const Texture,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    segments: []const encode.Segment,
    solid: ?SolidPaint,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) TileCompositeResult {
    var result: TileCompositeResult = .{};
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            const px = x + local_x;
            const py = y + local_y;
            const alpha = clipAlpha(call, clips, call_clip_indices, segments, px, py);
            if (solid) |sp| {
                const pixel = compositeSolidAlphaFillPixel(sp, alpha, px, py, width, height, surface);
                if (pixel.touched) result.touched += 1;
                if (pixel.opaque_write) result.opaque_writes += 1;
            } else if (compositePaint(call, textures, alpha, px, py, width, height, surface)) {
                result.touched += 1;
            }
        }
    }
    return result;
}

fn appendRectTileAlpha(gpa: std.mem.Allocator, rect: Rect, tile_x: u16, tile_y: u16, alphas: *std.ArrayList(u8)) !void {
    var local_y: u16 = 0;
    while (local_y < strip.tile_size) : (local_y += 1) {
        const y_alpha = coverage1D(@floatFromInt(tile_y + local_y), rect.y0, rect.y1);
        var local_x: u16 = 0;
        while (local_x < strip.tile_size) : (local_x += 1) {
            const x_alpha = coverage1D(@floatFromInt(tile_x + local_x), rect.x0, rect.x1);
            try alphas.append(gpa, normToU8(x_alpha * y_alpha));
        }
    }
}

fn boundaryKey(call_index: u32, tile_x: i32, tile_y: i32) u64 {
    return (@as(u64, call_index) << 42) |
        (@as(u64, @intCast(tile_y)) << 21) |
        @as(u64, @intCast(tile_x));
}

pub fn coverageAt(
    fill_rule: strip.FillRule,
    px: f32,
    py: f32,
    segment_indices: []const u32,
    segments: []const encode.Segment,
) u8 {
    var winding: i32 = 0;
    for (segment_indices) |segment_index| {
        winding += crossingWinding(px, py, segments[segment_index]);
    }
    return if (filled(fill_rule, winding)) 255 else 0;
}

pub fn pixelCoverage(
    fill_rule: strip.FillRule,
    x: u16,
    y: u16,
    range: strip.Range,
    strip_segment_indices: []const u32,
    segments: []const encode.Segment,
) u8 {
    var area: f32 = 0;
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (strip_segment_indices[start..][0..count]) |segment_index| {
        area += segmentArea(px, py, segments[segment_index]);
    }
    return areaToAlpha(fill_rule, area);
}

fn pixelCoverageForCall(
    fill_rule: strip.FillRule,
    x: u16,
    y: u16,
    range: strip.Range,
    segments: []const encode.Segment,
) u8 {
    var area: f32 = 0;
    const px: f32 = @floatFromInt(x);
    const py: f32 = @floatFromInt(y);
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (segments[start..][0..count]) |seg| {
        area += segmentArea(px, py, seg);
    }
    return areaToAlpha(fill_rule, area);
}

fn applyClipAlpha(
    alpha: u8,
    call: encode.EncodedCall,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    segments: []const encode.Segment,
    x: u16,
    y: u16,
) u8 {
    if (alpha == 0 or call.clips.count == 0) return alpha;
    const clip_alpha = clipAlpha(call, clips, call_clip_indices, segments, x, y);
    return normToU8(u8ToNorm(alpha) * u8ToNorm(clip_alpha));
}

fn clipAlpha(
    call: encode.EncodedCall,
    clips: []const encode.ClipRecord,
    call_clip_indices: []const u32,
    segments: []const encode.Segment,
    x: u16,
    y: u16,
) u8 {
    var mask: f32 = 1;
    const start: usize = @intCast(call.clips.start);
    const count: usize = @intCast(call.clips.count);
    for (call_clip_indices[start..][0..count]) |clip_index| {
        if (clip_index >= clips.len) return 0;
        const clip = clips[clip_index];
        if (clip.segments.count == 0) return 0;
        mask *= u8ToNorm(pixelCoverageForCall(clip.rule, x, y, clip.segments, segments));
        if (mask <= 0) return 0;
    }
    return normToU8(mask);
}

fn coverageAtForCall(
    fill_rule: strip.FillRule,
    px: f32,
    py: f32,
    range: strip.Range,
    segments: []const encode.Segment,
) u8 {
    var winding: i32 = 0;
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (segments[start..][0..count]) |seg| {
        winding += crossingWinding(px, py, seg);
    }
    return if (filled(fill_rule, winding)) 255 else 0;
}

fn windingAt(
    px: f32,
    py: f32,
    range: strip.Range,
    strip_segment_indices: []const u32,
    segments: []const encode.Segment,
) i32 {
    var winding: i32 = 0;
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    for (strip_segment_indices[start..][0..count]) |segment_index| {
        winding += crossingWinding(px, py, segments[segment_index]);
    }
    return winding;
}

fn crossingWinding(px: f32, py: f32, seg: encode.Segment) i32 {
    if (seg.y0 <= py and seg.y1 > py) {
        const x = intersectX(py, seg);
        if (x > px) return 1;
    } else if (seg.y1 <= py and seg.y0 > py) {
        const x = intersectX(py, seg);
        if (x > px) return -1;
    }
    return 0;
}

fn intersectX(py: f32, seg: encode.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return seg.x0;
    const t = (py - seg.y0) / dy;
    return seg.x0 + t * (seg.x1 - seg.x0);
}

fn filled(fill_rule: strip.FillRule, winding: i32) bool {
    return switch (fill_rule) {
        .nonzero => winding != 0,
        .even_odd => @mod(winding, 2) != 0,
    };
}

fn fillRuleForCall(default_rule: strip.FillRule, kind: strip.CallKind) strip.FillRule {
    return switch (kind) {
        .fill => default_rule,
        .stroke, .triangles => .nonzero,
    };
}

fn callBounds(call: encode.EncodedCall, segments: []const encode.Segment) [4]f32 {
    if (call.bounds[0] < call.bounds[2] and call.bounds[1] < call.bounds[3]) {
        return call.bounds;
    }

    var bounds = [4]f32{ 1e6, 1e6, -1e6, -1e6 };
    const start: usize = @intCast(call.segments.start);
    const count: usize = @intCast(call.segments.count);
    for (segments[start..][0..count]) |seg| {
        bounds[0] = @min(bounds[0], @min(seg.x0, seg.x1));
        bounds[1] = @min(bounds[1], @min(seg.y0, seg.y1));
        bounds[2] = @max(bounds[2], @max(seg.x0, seg.x1));
        bounds[3] = @max(bounds[3], @max(seg.y0, seg.y1));
    }
    return bounds;
}

fn segmentArea(px: f32, py: f32, seg: encode.Segment) f32 {
    const dy = seg.y1 - seg.y0;
    if (dy == 0) return 0;

    const y0 = @max(@min(seg.y0, seg.y1), py);
    const y1 = @min(@max(seg.y0, seg.y1), py + 1);
    if (y0 >= y1) return 0;

    const slope = (seg.x1 - seg.x0) / dy;
    const intercept = seg.x0 - slope * seg.y0 - px;
    const sign: f32 = if (dy > 0) 1 else -1;
    return sign * integrateClampedLinear(slope, intercept, y0, y1);
}

fn integrateClampedLinear(slope: f32, intercept: f32, y0: f32, y1: f32) f32 {
    if (slope == 0) return (y1 - y0) * std.math.clamp(intercept, 0, 1);

    var stops = [_]f32{ y0, y1, 0, 0 };
    var count: usize = 2;
    addStop(&stops, &count, (0 - intercept) / slope, y0, y1);
    addStop(&stops, &count, (1 - intercept) / slope, y0, y1);
    std.mem.sort(f32, stops[0..count], {}, lessThanF32);

    var area: f32 = 0;
    var i: usize = 0;
    while (i + 1 < count) : (i += 1) {
        const a = stops[i];
        const b = stops[i + 1];
        if (a == b) continue;

        const mid = (a + b) * 0.5;
        const mid_value = slope * mid + intercept;
        if (mid_value <= 0) continue;
        if (mid_value >= 1) {
            area += b - a;
            continue;
        }

        const av = slope * a + intercept;
        const bv = slope * b + intercept;
        area += (av + bv) * 0.5 * (b - a);
    }

    return std.math.clamp(area, 0, y1 - y0);
}

fn addStop(stops: *[4]f32, count: *usize, value: f32, min: f32, max: f32) void {
    if (value <= min or value >= max) return;
    stops[count.*] = value;
    count.* += 1;
}

fn lessThanF32(_: void, a: f32, b: f32) bool {
    return a < b;
}

fn areaToAlpha(fill_rule: strip.FillRule, area: f32) u8 {
    const coverage = switch (fill_rule) {
        .nonzero => @min(@abs(area), 1),
        .even_odd => blk: {
            const folded = area - 2 * @floor(area * 0.5 + 0.5);
            break :blk @min(@abs(folded), 1);
        },
    };
    return normToU8(coverage);
}

fn solidPaint(call: encode.EncodedCall) ?SolidPaint {
    if (call.paint.image != 0 or !scissorDisabled(&call.scissor)) return null;
    if (!sameColor(call.paint.inner_color, call.paint.outer_color)) return null;
    const c = call.paint.inner_color;
    return .{
        .r = c.r * c.a,
        .g = c.g * c.a,
        .b = c.b * c.a,
        .a = c.a,
    };
}

fn sameColor(a: color.Color, b: color.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn scissorDisabled(scissor: *const color.Scissor) bool {
    return scissor.extent[0] < 0 or scissor.extent[1] < 0;
}

fn rectForCall(call: encode.EncodedCall, segments: []const encode.Segment) ?Rect {
    if (call.clips.count > 0) return null;
    if (call.kind != .fill or !call.convex or call.segments.count != 4) return null;
    const bounds = callBounds(call, segments);
    if (bounds[0] >= bounds[2] or bounds[1] >= bounds[3]) return null;

    const start: usize = @intCast(call.segments.start);
    var horizontal: usize = 0;
    var vertical: usize = 0;
    for (segments[start..][0..4]) |seg| {
        if (seg.y0 == seg.y1) {
            if (!atRectY(seg.y0, bounds) or @min(seg.x0, seg.x1) != bounds[0] or @max(seg.x0, seg.x1) != bounds[2]) return null;
            horizontal += 1;
        } else if (seg.x0 == seg.x1) {
            if (!atRectX(seg.x0, bounds) or @min(seg.y0, seg.y1) != bounds[1] or @max(seg.y0, seg.y1) != bounds[3]) return null;
            vertical += 1;
        } else {
            return null;
        }
    }
    if (horizontal != 2 or vertical != 2) return null;
    return .{ .x0 = bounds[0], .y0 = bounds[1], .x1 = bounds[2], .y1 = bounds[3] };
}

fn atRectX(x: f32, bounds: [4]f32) bool {
    return x == bounds[0] or x == bounds[2];
}

fn atRectY(y: f32, bounds: [4]f32) bool {
    return y == bounds[1] or y == bounds[3];
}

fn compositeSolidFillPixel(
    solid: SolidPaint,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) CompositeResult {
    return compositeSolidPixel(solid, 255, x, y, width, height, surface);
}

fn compositeSolidAlphaFillPixel(
    solid: SolidPaint,
    coverage_alpha: u8,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) CompositeResult {
    return compositeSolidPixel(solid, coverage_alpha, x, y, width, height, surface);
}

fn compositeSolidPixel(
    solid: SolidPaint,
    coverage_alpha: u8,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) CompositeResult {
    if (coverage_alpha == 0) return .{};
    if (x >= width or y >= height) return .{};

    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    if (coverage_alpha == 255 and solid.a >= 1) {
        surface[index + 0] = normToU8(solid.r);
        surface[index + 1] = normToU8(solid.g);
        surface[index + 2] = normToU8(solid.b);
        surface[index + 3] = 255;
        return .{ .touched = true, .opaque_write = true };
    }

    const mask = u8ToNorm(coverage_alpha);
    const src_a = solid.a * mask;
    const src_r = solid.r * mask;
    const src_g = solid.g * mask;
    const src_b = solid.b * mask;

    const dst_r = u8ToNorm(surface[index + 0]);
    const dst_g = u8ToNorm(surface[index + 1]);
    const dst_b = u8ToNorm(surface[index + 2]);
    const dst_a = u8ToNorm(surface[index + 3]);
    const inv_a = 1 - src_a;

    surface[index + 0] = normToU8(src_r + dst_r * inv_a);
    surface[index + 1] = normToU8(src_g + dst_g * inv_a);
    surface[index + 2] = normToU8(src_b + dst_b * inv_a);
    surface[index + 3] = normToU8(src_a + dst_a * inv_a);
    return .{ .touched = true };
}

fn compositePaint(
    call: encode.EncodedCall,
    textures: []const Texture,
    coverage_alpha: u8,
    x: u16,
    y: u16,
    width: u32,
    height: u32,
    surface: []u8,
) bool {
    if (coverage_alpha == 0) return false;
    if (x >= width or y >= height) return false;

    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const mask = u8ToNorm(coverage_alpha) * scissorMask(&call.scissor, px, py);
    if (mask <= 0) return false;

    const c = resolvePaint(call, textures, px, py);
    const src_a = c.a * mask;
    const src_r = c.r * mask;
    const src_g = c.g * mask;
    const src_b = c.b * mask;

    const index = (@as(usize, y) * @as(usize, width) + x) * 4;
    const dst_r = u8ToNorm(surface[index + 0]);
    const dst_g = u8ToNorm(surface[index + 1]);
    const dst_b = u8ToNorm(surface[index + 2]);
    const dst_a = u8ToNorm(surface[index + 3]);
    const inv_a = 1 - src_a;

    surface[index + 0] = normToU8(src_r + dst_r * inv_a);
    surface[index + 1] = normToU8(src_g + dst_g * inv_a);
    surface[index + 2] = normToU8(src_b + dst_b * inv_a);
    surface[index + 3] = normToU8(src_a + dst_a * inv_a);
    return true;
}

fn resolvePaint(call: encode.EncodedCall, textures: []const Texture, px: f32, py: f32) ColorF {
    const paint = call.paint;
    if (paint.image > 0) {
        if (findTexture(textures, @enumFromInt(@as(u32, @intCast(paint.image))))) |texture| {
            return sampleImagePattern(&paint, texture, px, py);
        }
        return .{};
    }

    const inv = xforms.inverse(&paint.xform) orelse xforms.identity();
    const pt = xforms.point(&inv, px, py);
    const feather = @max(paint.feather, 0.0001);
    const d = std.math.clamp((sdroundrect(pt, paint.extent, paint.radius) + feather * 0.5) / feather, 0, 1);
    return mixPremul(paint.inner_color, paint.outer_color, d);
}

fn clampPixelStart(value: f32, extent: u32) u32 {
    if (extent == 0 or value <= 0) return 0;
    const floored = @floor(value);
    if (floored >= @as(f32, @floatFromInt(extent))) return extent;
    return @intFromFloat(floored);
}

fn clampPixelEnd(value: f32, extent: u32) u32 {
    if (extent == 0 or value <= 0) return 0;
    const ceiled = @ceil(value);
    if (ceiled >= @as(f32, @floatFromInt(extent))) return extent;
    return @intFromFloat(ceiled);
}

fn coverage1D(pixel: f32, lo: f32, hi: f32) f32 {
    return std.math.clamp(@min(hi, pixel + 1) - @max(lo, pixel), 0, 1);
}

fn sampleImagePattern(paint: *const color.Paint, texture: *const Texture, px: f32, py: f32) ColorF {
    if (texture.format != .rgba8 or texture.width == 0 or texture.height == 0 or texture.pixels.len < @as(usize, texture.width) * @as(usize, texture.height) * 4) {
        return .{};
    }

    const inv = xforms.inverse(&paint.xform) orelse xforms.identity();
    const pt = xforms.point(&inv, px, py);
    const sample = sampleWrappedLinear(texture, pt[0], pt[1], paint.extent);
    const alpha = sample.a * paint.inner_color.a;
    return .{
        .r = sample.r * alpha,
        .g = sample.g * alpha,
        .b = sample.b * alpha,
        .a = alpha,
    };
}

fn sampleWrappedLinear(texture: *const Texture, x: f32, y: f32, extent: [2]f32) ColorF {
    const tx = wrappedTexelCoord(x, extent[0], texture.width);
    const ty = wrappedTexelCoord(y, extent[1], texture.height);
    const c00 = texel(texture, tx.i0, ty.i0);
    const c10 = texel(texture, tx.i1, ty.i0);
    const c01 = texel(texture, tx.i0, ty.i1);
    const c11 = texel(texture, tx.i1, ty.i1);
    return mixColor(mixColor(c00, c10, tx.t), mixColor(c01, c11, tx.t), ty.t);
}

fn scissorMask(scissor: *const color.Scissor, px: f32, py: f32) f32 {
    if (scissor.extent[0] < 0 or scissor.extent[1] < 0) return 1;

    const inv = xforms.inverse(&scissor.xform) orelse return 0;
    const pt = xforms.point(&inv, px, py);
    var sx = @abs(pt[0]) - scissor.extent[0];
    var sy = @abs(pt[1]) - scissor.extent[1];
    const scale_x = @sqrt(scissor.xform[0] * scissor.xform[0] + scissor.xform[2] * scissor.xform[2]);
    const scale_y = @sqrt(scissor.xform[1] * scissor.xform[1] + scissor.xform[3] * scissor.xform[3]);
    sx = 0.5 - sx * scale_x;
    sy = 0.5 - sy * scale_y;
    return std.math.clamp(sx, 0, 1) * std.math.clamp(sy, 0, 1);
}

fn findTexture(textures: []const Texture, id: image.ImageId) ?*const Texture {
    for (textures) |*texture| {
        if (texture.id == id) return texture;
    }
    return null;
}

const WrappedTexelCoord = struct {
    i0: u32,
    i1: u32,
    t: f32,
};

fn wrappedTexelCoord(value: f32, extent: f32, size: u32) WrappedTexelCoord {
    if (size == 0) return .{ .i0 = 0, .i1 = 0, .t = 0 };
    const local_extent = if (@abs(extent) > 0.0001) @abs(extent) else @as(f32, @floatFromInt(size));
    const scaled = value / local_extent * @as(f32, @floatFromInt(size)) - 0.5;
    const base = @floor(scaled);
    const base_index: i32 = @intFromFloat(base);
    return .{
        .i0 = wrapIndex(base_index, size),
        .i1 = wrapIndex(base_index + 1, size),
        .t = scaled - base,
    };
}

fn wrapIndex(index: i32, size: u32) u32 {
    const size_i32: i32 = @intCast(size);
    return @intCast(@mod(index, size_i32));
}

fn texel(texture: *const Texture, x: u32, y: u32) ColorF {
    const index = (@as(usize, y) * @as(usize, texture.width) + x) * 4;
    return .{
        .r = u8ToNorm(texture.pixels[index + 0]),
        .g = u8ToNorm(texture.pixels[index + 1]),
        .b = u8ToNorm(texture.pixels[index + 2]),
        .a = u8ToNorm(texture.pixels[index + 3]),
    };
}

fn mixColor(a: ColorF, b: ColorF, t: f32) ColorF {
    const inv = 1 - t;
    return .{
        .r = a.r * inv + b.r * t,
        .g = a.g * inv + b.g * t,
        .b = a.b * inv + b.b * t,
        .a = a.a * inv + b.a * t,
    };
}

fn sdroundrect(pt: [2]f32, ext: [2]f32, rad: f32) f32 {
    const ext2 = [2]f32{ ext[0] - rad, ext[1] - rad };
    const dx = @abs(pt[0]) - ext2[0];
    const dy = @abs(pt[1]) - ext2[1];
    return @min(@max(dx, dy), 0) + @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0)) - rad;
}

fn mixPremul(inner: color.Color, outer: color.Color, t: f32) ColorF {
    const inv = 1 - t;
    return .{
        .r = inner.r * inner.a * inv + outer.r * outer.a * t,
        .g = inner.g * inner.a * inv + outer.g * outer.a * t,
        .b = inner.b * inner.a * inv + outer.b * outer.a * t,
        .a = inner.a * inv + outer.a * t,
    };
}

fn pixelExtent(value: f32) u32 {
    if (value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

fn u8ToNorm(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn normToU8(value: f32) u8 {
    const clamped = std.math.clamp(value, 0, 1);
    return @intFromFloat(@floor(clamped * 255 + 0.5));
}

fn profileStart(profile: ?*Profile) u64 {
    if (profile == null) return 0;
    return nowNs();
}

fn elapsedSince(start: u64) u64 {
    return nowNs() - start;
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
