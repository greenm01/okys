//! Stroke outline: a flattened polyline -> backend-neutral closed outline
//! polygons. Stencil-cover can triangulate these; sparse-strip can analytic-cover
//! them.

const std = @import("std");
const Context = @import("../state/context.zig").Context;
const PathCache = @import("../state/path_cache.zig").PathCache;
const draw_state = @import("../state/draw_state.zig");
const LineCap = draw_state.LineCap;
const LineJoin = draw_state.LineJoin;
const path = @import("../types/path.zig");
const Point = path.Point;
const flatten = @import("flatten.zig");
const convex = @import("convex.zig");
const xforms = @import("transform.zig");

const Vec2 = struct { x: f32, y: f32 };

pub fn buildOutline(ctx: *Context) void {
    buildOutlineWithWidth(ctx, effectiveStrokeWidth(ctx));
}

pub fn buildOutlineWithWidth(ctx: *Context, stroke_width: f32) void {
    ctx.stroke_outline.clear();
    flatten.flatten(ctx);

    const half_width = stroke_width * 0.5;
    if (half_width <= 0) return;

    for (ctx.cache.paths.items) |src_path| {
        if (src_path.point_count < 2) continue;
        const pts = ctx.cache.points.items[src_path.point_start..][0..src_path.point_count];
        if (src_path.closed) {
            if (src_path.point_count < 3) continue;
            buildClosedPath(ctx, pts, half_width);
        } else {
            buildOpenPath(ctx, pts, half_width, ctx.state().line_cap, ctx.state().line_join);
        }
    }

    finishOutline(&ctx.stroke_outline, ctx.state().miter_limit);
}

pub fn effectiveStrokeWidth(ctx: *Context) f32 {
    const scale = xforms.averageScale(&ctx.state().xform);
    return @min(@max(ctx.state().stroke_width * scale, 0), 200);
}

fn buildClosedPath(ctx: *Context, pts: []const Point, w: f32) void {
    var left = std.ArrayList(Vec2).empty;
    defer left.deinit(ctx.gpa);
    var right = std.ArrayList(Vec2).empty;
    defer right.deinit(ctx.gpa);

    buildBoundary(ctx, &left, pts, w, 1, true, ctx.state().line_join);
    buildBoundary(ctx, &right, pts, w, -1, true, ctx.state().line_join);

    appendClosedPath(ctx, left.items, .ccw);
    std.mem.reverse(Vec2, right.items);
    appendClosedPath(ctx, right.items, .cw);
}

fn buildOpenPath(ctx: *Context, pts: []const Point, w: f32, cap: LineCap, join: LineJoin) void {
    var left = std.ArrayList(Vec2).empty;
    defer left.deinit(ctx.gpa);
    var right = std.ArrayList(Vec2).empty;
    defer right.deinit(ctx.gpa);

    buildBoundary(ctx, &left, pts, w, 1, false, join);
    buildBoundary(ctx, &right, pts, w, -1, false, join);
    if (left.items.len == 0 or right.items.len == 0) return;

    ctx.stroke_outline.addPath(ctx.gpa);
    const first = pts[0];
    const last = pts[pts.len - 1];
    const start_dir = directionBetween(first, pts[1]);
    const end_dir = directionBetween(pts[pts.len - 2], last);

    switch (cap) {
        .butt => {
            addCapPair(ctx, first, start_dir, w, 0, false);
        },
        .square => {
            addCapPair(ctx, first, start_dir, w, w, false);
        },
        .round => {
            addRoundStartCap(ctx, first, start_dir, w);
        },
    }

    for (left.items) |p| addOutlinePoint(ctx, p);

    switch (cap) {
        .butt => {
            addCapPair(ctx, last, end_dir, w, 0, true);
        },
        .square => {
            addCapPair(ctx, last, end_dir, w, w, true);
        },
        .round => {
            addRoundEndCap(ctx, last, end_dir, w);
        },
    }

    var i = right.items.len;
    while (i > 0) {
        i -= 1;
        addOutlinePoint(ctx, right.items[i]);
    }
    ctx.stroke_outline.closePath();
}

fn buildBoundary(ctx: *Context, out: *std.ArrayList(Vec2), pts: []const Point, w: f32, side: i32, closed: bool, join: LineJoin) void {
    for (pts, 0..) |p, i| {
        if (!closed and (i == 0 or i == pts.len - 1)) {
            out.append(ctx.gpa, offsetPoint(p, segmentNormal(endpointSegment(pts, i)), w, side)) catch {};
            continue;
        }

        const prev_i = if (i == 0) pts.len - 1 else i - 1;
        const prev = pts[prev_i];
        const prev_normal = segmentNormal(prev);
        const next_normal = segmentNormal(p);
        const outer = (p.flags.left and side > 0) or (!p.flags.left and side < 0);
        const needs_join = outer and p.flags.bevel;

        if (!needs_join) {
            out.append(ctx.gpa, offsetPoint(p, .{ .x = p.dmx, .y = p.dmy }, w, side)) catch {};
            continue;
        }

        switch (join) {
            .round => appendRoundJoin(ctx, out, p, prev_normal, next_normal, w, side),
            .miter, .bevel => {
                out.append(ctx.gpa, offsetPoint(p, prev_normal, w, side)) catch {};
                out.append(ctx.gpa, offsetPoint(p, next_normal, w, side)) catch {};
            },
        }
    }
}

fn appendRoundJoin(ctx: *Context, out: *std.ArrayList(Vec2), p: Point, prev_normal: Vec2, next_normal: Vec2, w: f32, side: i32) void {
    const start = offsetPoint(p, prev_normal, w, side);
    const end = offsetPoint(p, next_normal, w, side);
    out.append(ctx.gpa, start) catch {};

    const a0 = std.math.atan2(start.y - p.y, start.x - p.x);
    const a1 = std.math.atan2(end.y - p.y, end.x - p.x);
    var da = a1 - a0;
    while (da > std.math.pi) da -= std.math.pi * 2.0;
    while (da < -std.math.pi) da += std.math.pi * 2.0;

    const n = @max(@as(u32, 2), curveDivs(w, @abs(da), ctx.tess_tol));
    var i: u32 = 1;
    while (i < n) : (i += 1) {
        const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        const a = a0 + da * u;
        out.append(ctx.gpa, .{ .x = p.x + @cos(a) * w, .y = p.y + @sin(a) * w }) catch {};
    }
    out.append(ctx.gpa, end) catch {};
}

fn appendClosedPath(ctx: *Context, points: []const Vec2, winding: path.Winding) void {
    if (points.len < 3) return;
    ctx.stroke_outline.addPath(ctx.gpa);
    ctx.stroke_outline.pathWinding(winding);
    for (points) |p| addOutlinePoint(ctx, p);
    ctx.stroke_outline.closePath();
}

fn addCapPair(ctx: *Context, p: Point, dir: Vec2, w: f32, extend: f32, end: bool) void {
    const n = normalFromDir(dir);
    const shift = if (end) extend else -extend;
    const base = Vec2{ .x = p.x + dir.x * shift, .y = p.y + dir.y * shift };
    if (end) {
        addOutlinePoint(ctx, .{ .x = base.x + n.x * w, .y = base.y + n.y * w });
        addOutlinePoint(ctx, .{ .x = base.x - n.x * w, .y = base.y - n.y * w });
    } else {
        addOutlinePoint(ctx, .{ .x = base.x - n.x * w, .y = base.y - n.y * w });
        addOutlinePoint(ctx, .{ .x = base.x + n.x * w, .y = base.y + n.y * w });
    }
}

fn addRoundStartCap(ctx: *Context, p: Point, dir: Vec2, w: f32) void {
    const n = normalFromDir(dir);
    const ncap = curveDivs(w, std.math.pi, ctx.tess_tol);
    var i: u32 = 0;
    while (i < ncap) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ncap - 1)) * std.math.pi;
        const ax = @cos(a) * w;
        const ay = @sin(a) * w;
        addOutlinePoint(ctx, .{
            .x = p.x - n.x * ax - dir.x * ay,
            .y = p.y - n.y * ax - dir.y * ay,
        });
    }
}

fn addRoundEndCap(ctx: *Context, p: Point, dir: Vec2, w: f32) void {
    const n = normalFromDir(dir);
    const ncap = curveDivs(w, std.math.pi, ctx.tess_tol);
    var i: u32 = 0;
    while (i < ncap) : (i += 1) {
        const a = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ncap - 1)) * std.math.pi;
        const ax = @cos(a) * w;
        const ay = @sin(a) * w;
        addOutlinePoint(ctx, .{
            .x = p.x + n.x * ax + dir.x * ay,
            .y = p.y + n.y * ax + dir.y * ay,
        });
    }
}

fn addOutlinePoint(ctx: *Context, p: Vec2) void {
    ctx.stroke_outline.addPoint(ctx.gpa, p.x, p.y, .{ .corner = true }, ctx.dist_tol);
}

fn finishOutline(outline: *PathCache, miter_limit: f32) void {
    if (outline.paths.items.len == 0) {
        outline.bounds = .{ 0, 0, 0, 0 };
        return;
    }

    outline.bounds = .{ 1e6, 1e6, -1e6, -1e6 };
    for (outline.paths.items) |*outline_path| {
        if (outline_path.point_count == 0) continue;
        const pts = outline.points.items[outline_path.point_start..][0..outline_path.point_count];
        for (pts, 0..) |*p0, i| {
            outline.bounds[0] = @min(outline.bounds[0], p0.x);
            outline.bounds[1] = @min(outline.bounds[1], p0.y);
            outline.bounds[2] = @max(outline.bounds[2], p0.x);
            outline.bounds[3] = @max(outline.bounds[3], p0.y);
            const p1 = pts[(i + 1) % pts.len];
            p0.dx = p1.x - p0.x;
            p0.dy = p1.y - p0.y;
            p0.len = normalize(&p0.dx, &p0.dy);
        }
        outline_path.closed = true;
        calculateJoins(outline_path, pts, miter_limit);
    }
}

fn calculateJoins(active_path: *path.PathRange, pts: []Point, miter_limit: f32) void {
    if (pts.len == 0) return;

    for (pts, 0..) |*p1, i| {
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

        p1.flags = .{ .corner = true };
        if (cross(p0.dx, p0.dy, p1.dx, p1.dy) > 0) {
            p1.flags.left = true;
        }
        if ((dmr2 * 1.01 * 1.01) < 1.0) {
            p1.flags.inner_bevel = true;
        }
        if ((dmr2 * miter_limit * miter_limit) < 1.0) {
            p1.flags.bevel = true;
        }
    }

    active_path.convex = active_path.closed and convex.isConvex(pts);
}

fn endpointSegment(pts: []const Point, i: usize) Point {
    if (i == 0) return pointSegment(pts[0], pts[1]);
    return pointSegment(pts[pts.len - 2], pts[pts.len - 1]);
}

fn pointSegment(a: Point, b: Point) Point {
    var dx = b.x - a.x;
    var dy = b.y - a.y;
    _ = normalize(&dx, &dy);
    return .{ .dx = dx, .dy = dy };
}

fn directionBetween(a: Point, b: Point) Vec2 {
    var dx = b.x - a.x;
    var dy = b.y - a.y;
    _ = normalize(&dx, &dy);
    return .{ .x = dx, .y = dy };
}

fn segmentNormal(p: Point) Vec2 {
    return .{ .x = p.dy, .y = -p.dx };
}

fn normalFromDir(dir: Vec2) Vec2 {
    return .{ .x = dir.y, .y = -dir.x };
}

fn offsetPoint(p: Point, normal: Vec2, w: f32, side: i32) Vec2 {
    const s: f32 = if (side > 0) 1 else -1;
    return .{ .x = p.x + normal.x * w * s, .y = p.y + normal.y * w * s };
}

fn cross(dx0: f32, dy0: f32, dx1: f32, dy1: f32) f32 {
    return dx1 * dy0 - dx0 * dy1;
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

fn curveDivs(r: f32, arc: f32, tol: f32) u32 {
    const radius = @max(r, 0.001);
    const da = std.math.acos(radius / (radius + tol)) * 2;
    return @max(2, @as(u32, @intFromFloat(@ceil(arc / da))));
}
