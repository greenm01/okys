//! Stroke dashing above the render interface. It consumes the shared flattened
//! path cache and emits open visible dash fragments into a second PathCache.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const PathCache = @import("../state/path_cache.zig").PathCache;
const draw_state = @import("../state/draw_state.zig");
const LineJoin = draw_state.LineJoin;
const path = @import("../types/path.zig");
const Point = path.Point;
const PointFlags = path.PointFlags;
const flatten = @import("flatten.zig");
const xforms = @import("transform.zig");

const epsilon: f32 = 1e-5;

const DashCursor = struct {
    index: usize = 0,
    on: bool = true,
    remaining: f32 = 0,
    count: usize = 0,
    logical_count: usize = 0,
    pattern: [draw_state.max_line_dashes]f32 = @splat(0),

    fn lengthAt(self: DashCursor, index: usize) f32 {
        return self.pattern[index % self.count];
    }

    fn advance(self: *DashCursor) void {
        self.index = (self.index + 1) % self.logical_count;
        self.on = (self.index % 2) == 0;
        self.remaining = self.lengthAt(self.index);
    }
};

pub fn active(ctx: *const Context) bool {
    return ctx.states.items[ctx.states.items.len - 1].line_dash_count > 0;
}

pub fn build(ctx: *Context) bool {
    ctx.dash_cache.clear();
    flatten.flatten(ctx);

    const scale = xforms.averageScale(&ctx.state().xform);
    const cursor_template = initialCursor(ctx, scale) orelse return false;

    for (ctx.cache.paths.items) |src_path| {
        if (src_path.point_count < 2) continue;
        const pts = ctx.cache.points.items[src_path.point_start..][0..src_path.point_count];
        var cursor = cursor_template;
        dashPath(ctx, &ctx.dash_cache, pts, src_path.closed, &cursor);
    }

    finishDashCache(ctx, &ctx.dash_cache);
    return ctx.dash_cache.paths.items.len > 0 and ctx.dash_cache.points.items.len > 0;
}

fn initialCursor(ctx: *const Context, scale: f32) ?DashCursor {
    const state = ctx.states.items[ctx.states.items.len - 1];
    const count = @as(usize, state.line_dash_count);
    if (count == 0 or scale <= epsilon) return null;

    var cursor: DashCursor = .{
        .count = count,
        .logical_count = if (count % 2 == 0) count else count * 2,
    };

    var total: f32 = 0;
    for (state.line_dash[0..count], 0..) |value, i| {
        const scaled = value * scale;
        if (!std.math.isFinite(scaled) or scaled <= epsilon) return null;
        cursor.pattern[i] = scaled;
    }
    for (0..cursor.logical_count) |i| total += cursor.lengthAt(i);
    if (total <= epsilon) return null;

    var offset = positiveMod(state.line_dash_offset * scale, total);
    cursor.index = 0;
    cursor.on = true;
    cursor.remaining = cursor.lengthAt(0);
    while (offset > epsilon) {
        if (offset < cursor.remaining) {
            cursor.remaining -= offset;
            break;
        }
        offset -= cursor.remaining;
        cursor.advance();
    }
    return cursor;
}

fn dashPath(ctx: *Context, out: *PathCache, pts: []const Point, closed: bool, cursor: *DashCursor) void {
    const segment_count = if (closed) pts.len else pts.len - 1;
    var visible_open = false;

    for (0..segment_count) |segment_i| {
        const next_i = (segment_i + 1) % pts.len;
        const a = pts[segment_i];
        const b = pts[next_i];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= epsilon) continue;

        const inv_len = 1.0 / len;
        var consumed: f32 = 0;
        while (consumed < len - epsilon) {
            if (cursor.remaining <= epsilon) {
                cursor.advance();
                continue;
            }

            const segment_remaining = len - consumed;
            const step = @min(segment_remaining, cursor.remaining);
            if (step <= epsilon) break;

            const start = pointAt(a, dx, dy, inv_len, consumed);
            const end = pointAt(a, dx, dy, inv_len, consumed + step);
            const ends_segment = step >= segment_remaining - epsilon;
            const ends_dash = step >= cursor.remaining - epsilon;

            if (cursor.on) {
                if (!visible_open) {
                    out.addPath(ctx.gpa);
                    addDashPoint(ctx, out, start, .{ .corner = true });
                    visible_open = true;
                }
                const flags = if (ends_segment and !ends_dash) b.flags else PointFlags{ .corner = true };
                addDashPoint(ctx, out, end, flags);
            }

            consumed += step;
            cursor.remaining -= step;
            if (ends_dash) {
                const was_on = cursor.on;
                cursor.advance();
                if (was_on) visible_open = false;
            }
        }
    }
}

fn pointAt(a: Point, dx: f32, dy: f32, inv_len: f32, distance: f32) Point {
    const t = distance * inv_len;
    return .{
        .x = a.x + dx * t,
        .y = a.y + dy * t,
        .flags = .{ .corner = true },
    };
}

fn addDashPoint(ctx: *Context, out: *PathCache, p: Point, flags: PointFlags) void {
    out.addPoint(ctx.gpa, p.x, p.y, flags, ctx.dist_tol);
}

fn finishDashCache(ctx: *Context, cache: *PathCache) void {
    if (cache.paths.items.len == 0) {
        cache.bounds = .{ 0, 0, 0, 0 };
        return;
    }

    cache.bounds = .{ 1e6, 1e6, -1e6, -1e6 };
    for (cache.paths.items) |*active_path| {
        if (active_path.point_count == 0) continue;
        const pts = pointsForPath(cache.points.items, active_path);
        calculateSegmentsAndBounds(cache, active_path, pts);
        calculateJoins(active_path, pts, ctx.state().line_join, ctx.state().miter_limit);
    }

    if (cache.bounds[0] > cache.bounds[2] or cache.bounds[1] > cache.bounds[3]) {
        cache.bounds = .{ 0, 0, 0, 0 };
    }
}

fn calculateSegmentsAndBounds(cache: *PathCache, active_path: *path.PathRange, pts: []Point) void {
    if (pts.len == 0) return;

    const segment_count = if (active_path.closed) pts.len else pts.len -| 1;
    if (segment_count == 0) {
        cache.bounds[0] = @min(cache.bounds[0], pts[0].x);
        cache.bounds[1] = @min(cache.bounds[1], pts[0].y);
        cache.bounds[2] = @max(cache.bounds[2], pts[0].x);
        cache.bounds[3] = @max(cache.bounds[3], pts[0].y);
        return;
    }

    for (pts, 0..) |*p0, i| {
        cache.bounds[0] = @min(cache.bounds[0], p0.x);
        cache.bounds[1] = @min(cache.bounds[1], p0.y);
        cache.bounds[2] = @max(cache.bounds[2], p0.x);
        cache.bounds[3] = @max(cache.bounds[3], p0.y);

        if (!active_path.closed and i == pts.len - 1) {
            p0.dx = 0;
            p0.dy = 0;
            p0.len = 0;
            continue;
        }

        const p1 = pts[(i + 1) % pts.len];
        p0.dx = p1.x - p0.x;
        p0.dy = p1.y - p0.y;
        p0.len = normalize(&p0.dx, &p0.dy);
    }
}

fn calculateJoins(active_path: *path.PathRange, pts: []Point, line_join: LineJoin, miter_limit: f32) void {
    if (pts.len == 0) return;

    for (pts, 0..) |*p1, i| {
        if (!active_path.closed and (i == 0 or i == pts.len - 1)) {
            p1.dmx = 0;
            p1.dmy = 0;
            p1.flags = .{ .corner = p1.flags.corner };
            continue;
        }

        const prev_i = if (i == 0) pts.len - 1 else i - 1;
        const p0 = pts[prev_i];
        const dlx0 = p0.dy;
        const dly0 = -p0.dx;
        const dlx1 = p1.dy;
        const dly1 = -p1.dx;

        p1.dmx = (dlx0 + dlx1) * 0.5;
        p1.dmy = (dly0 + dly1) * 0.5;
        const dmr2 = p1.dmx * p1.dmx + p1.dmy * p1.dmy;
        if (dmr2 > 0.000001) {
            const s = @min(1.0 / dmr2, 600.0);
            p1.dmx *= s;
            p1.dmy *= s;
        }

        p1.flags = .{ .corner = p1.flags.corner };
        if (cross(p0.dx, p0.dy, p1.dx, p1.dy) > 0) {
            p1.flags.left = true;
        }
        if ((dmr2 * 1.01 * 1.01) < 1.0) {
            p1.flags.inner_bevel = true;
        }
        if (p1.flags.corner and ((dmr2 * miter_limit * miter_limit) < 1.0 or line_join == .bevel or line_join == .round)) {
            p1.flags.bevel = true;
        }
    }
}

fn pointsForPath(points: []Point, active_path: *const path.PathRange) []Point {
    const start: usize = @intCast(active_path.point_start);
    const count: usize = @intCast(active_path.point_count);
    return points[start..][0..count];
}

fn positiveMod(value: f32, modulus: f32) f32 {
    if (modulus <= epsilon) return 0;
    var result = @mod(value, modulus);
    if (result < 0) result += modulus;
    return result;
}

fn normalize(x: *f32, y: *f32) f32 {
    const d = @sqrt(x.* * x.* + y.* * y.*);
    if (d > 1e-6) {
        const id = 1.0 / d;
        x.* *= id;
        y.* *= id;
    }
    return d;
}

fn cross(dx0: f32, dy0: f32, dx1: f32, dy1: f32) f32 {
    return dx1 * dy0 - dx0 * dy1;
}
