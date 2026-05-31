//! Flattening: command stream -> SoA points + path ranges, with adaptive
//! bezier/arc subdivision and join metadata. Shared by both backends. The
//! algorithmic reference is NanoVG's nvg__flattenPaths / nvg__tesselateBezier.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const PathCache = @import("../state/path_cache.zig").PathCache;
const LineJoin = @import("../state/draw_state.zig").LineJoin;
const Command = @import("../types/command.zig").Command;
const path = @import("../types/path.zig");
const Point = path.Point;
const PointFlags = path.PointFlags;
const Winding = path.Winding;
const convex = @import("convex.zig");

pub fn flatten(ctx: *Context) void {
    const cache = &ctx.cache;
    if (cache.paths.items.len > 0) return;

    parseCommands(ctx);
    finishPaths(ctx);
}

fn parseCommands(ctx: *Context) void {
    const data = ctx.commands.data.items;
    var i: usize = 0;
    while (i < data.len) {
        const command = commandFromValue(data[i]) orelse {
            ctx.recordDiagnostic(.malformed_command_stream);
            break;
        };
        switch (command) {
            .move_to => {
                if (i + 2 >= data.len) {
                    ctx.recordDiagnostic(.malformed_command_stream);
                    break;
                }
                ctx.cache.addPath(ctx.gpa);
                ctx.cache.addPoint(ctx.gpa, data[i + 1], data[i + 2], .{ .corner = true }, ctx.dist_tol);
                i += 3;
            },
            .line_to => {
                if (i + 2 >= data.len) {
                    ctx.recordDiagnostic(.malformed_command_stream);
                    break;
                }
                ctx.cache.addPoint(ctx.gpa, data[i + 1], data[i + 2], .{ .corner = true }, ctx.dist_tol);
                i += 3;
            },
            .bezier_to => {
                if (i + 6 >= data.len) {
                    ctx.recordDiagnostic(.malformed_command_stream);
                    break;
                }
                if (ctx.cache.lastPoint()) |last| {
                    tesselateBezier(
                        ctx,
                        last.x,
                        last.y,
                        data[i + 1],
                        data[i + 2],
                        data[i + 3],
                        data[i + 4],
                        data[i + 5],
                        data[i + 6],
                        0,
                        .{ .corner = true },
                    );
                }
                i += 7;
            },
            .close => {
                ctx.cache.closePath();
                i += 1;
            },
            .winding => {
                if (i + 1 >= data.len) {
                    ctx.recordDiagnostic(.malformed_command_stream);
                    break;
                }
                ctx.cache.pathWinding(windingFromValue(data[i + 1]));
                i += 2;
            },
        }
    }
}

fn finishPaths(ctx: *Context) void {
    const cache = &ctx.cache;
    if (cache.paths.items.len == 0) {
        cache.bounds = .{ 0, 0, 0, 0 };
        return;
    }

    cache.bounds = .{ 1e6, 1e6, -1e6, -1e6 };

    for (cache.paths.items) |*active_path| {
        if (active_path.point_count == 0) continue;

        var pts = pointsForPath(cache.points.items, active_path);
        const last = &pts[pts.len - 1];
        if (pts.len > 1 and ptEquals(last.x, last.y, pts[0].x, pts[0].y, ctx.dist_tol)) {
            active_path.point_count -= 1;
            if (active_path.point_count == 0) continue;
            pts = pointsForPath(cache.points.items, active_path);
            active_path.closed = true;
        }

        if (active_path.point_count > 2) {
            const area = polyArea(pts);
            if ((active_path.winding == .ccw and area < 0) or
                (active_path.winding == .cw and area > 0))
            {
                std.mem.reverse(Point, pts);
            }
        }

        calculateSegmentsAndBounds(cache, active_path, pts);
        calculateJoins(active_path, pts, ctx.state().line_join, ctx.state().miter_limit);
        active_path.convex = active_path.closed and convex.isConvex(pts);
    }

    if (cache.bounds[0] > cache.bounds[2] or cache.bounds[1] > cache.bounds[3]) {
        cache.bounds = .{ 0, 0, 0, 0 };
    }
}

fn tesselateBezier(ctx: *Context, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, x4: f32, y4: f32, level: u8, flags: PointFlags) void {
    if (level > 10) return;

    const x12 = (x1 + x2) * 0.5;
    const y12 = (y1 + y2) * 0.5;
    const x23 = (x2 + x3) * 0.5;
    const y23 = (y2 + y3) * 0.5;
    const x34 = (x3 + x4) * 0.5;
    const y34 = (y3 + y4) * 0.5;
    const x123 = (x12 + x23) * 0.5;
    const y123 = (y12 + y23) * 0.5;

    const dx = x4 - x1;
    const dy = y4 - y1;
    const d2 = @abs((x2 - x4) * dy - (y2 - y4) * dx);
    const d3 = @abs((x3 - x4) * dy - (y3 - y4) * dx);

    if ((d2 + d3) * (d2 + d3) < ctx.tess_tol * (dx * dx + dy * dy)) {
        ctx.cache.addPoint(ctx.gpa, x4, y4, flags, ctx.dist_tol);
        return;
    }

    const x234 = (x23 + x34) * 0.5;
    const y234 = (y23 + y34) * 0.5;
    const x1234 = (x123 + x234) * 0.5;
    const y1234 = (y123 + y234) * 0.5;

    tesselateBezier(ctx, x1, y1, x12, y12, x123, y123, x1234, y1234, level + 1, .{});
    tesselateBezier(ctx, x1234, y1234, x234, y234, x34, y34, x4, y4, level + 1, flags);
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

        const inner_limit = 1.01;
        if ((dmr2 * inner_limit * inner_limit) < 1.0) {
            p1.flags.inner_bevel = true;
        }

        if (p1.flags.corner) {
            if ((dmr2 * miter_limit * miter_limit) < 1.0 or line_join == .bevel or line_join == .round) {
                p1.flags.bevel = true;
            }
        }
    }
}

fn pointsForPath(points: []Point, active_path: *const path.PathRange) []Point {
    const start: usize = @intCast(active_path.point_start);
    const count: usize = @intCast(active_path.point_count);
    return points[start..][0..count];
}

fn commandFromValue(value: f32) ?Command {
    if (!std.math.isFinite(value)) return null;
    if (value != @trunc(value) or value < 0 or value > 4) return null;
    const tag: u8 = @intFromFloat(value);
    return switch (tag) {
        0 => .move_to,
        1 => .line_to,
        2 => .bezier_to,
        3 => .close,
        4 => .winding,
        else => null,
    };
}

fn windingFromValue(value: f32) Winding {
    return switch (@as(i32, @intFromFloat(value))) {
        2 => .cw,
        else => .ccw,
    };
}

fn ptEquals(x1: f32, y1: f32, x2: f32, y2: f32, tol: f32) bool {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return dx * dx + dy * dy < tol * tol;
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

fn triangleArea2(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
    const abx = bx - ax;
    const aby = by - ay;
    const acx = cx - ax;
    const acy = cy - ay;
    return acx * aby - abx * acy;
}

fn polyArea(pts: []const Point) f32 {
    var area: f32 = 0;
    var i: usize = 2;
    while (i < pts.len) : (i += 1) {
        const p0 = pts[0];
        const p1 = pts[i - 1];
        const p2 = pts[i];
        area += triangleArea2(p0.x, p0.y, p1.x, p1.y, p2.x, p2.y);
    }
    return area * 0.5;
}
