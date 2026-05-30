//! Encode flattened paths into line segments for tile binning.

const std = @import("std");
const color = @import("../../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const path = @import("../../types/path.zig");
const PathRange = path.PathRange;
const Point = path.Point;
const Vertex = path.Vertex;
const strip = @import("strip.zig");

pub const EncodedCall = struct {
    kind: strip.CallKind,
    paint: Paint,
    scissor: Scissor,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    width: f32 = 0,
    segments: strip.Range = .{},
    convex: bool = false,
};

pub const Segment = extern struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    call_index: u32 = 0,
    path_index: u32 = 0,
    winding: i32 = 0,
    flags: u32 = 0,
};

pub fn appendPathSegments(
    segments: *std.ArrayList(Segment),
    gpa: std.mem.Allocator,
    call_index: u32,
    input_paths: []const PathRange,
    points: []const Point,
) !strip.Range {
    const start = segments.items.len;
    for (input_paths, 0..) |p, local_path_index| {
        if (!validPath(p, points.len)) continue;
        const pts = points[p.point_start..][0..p.point_count];
        for (pts, 0..) |a, i| {
            const b = pts[(i + 1) % pts.len];
            if (samePoint(a, b)) continue;
            try segments.append(gpa, .{
                .x0 = a.x,
                .y0 = a.y,
                .x1 = b.x,
                .y1 = b.y,
                .call_index = call_index,
                .path_index = @intCast(local_path_index),
                .winding = if (b.y < a.y) 1 else if (b.y > a.y) -1 else 0,
                .flags = @intFromBool(p.convex),
            });
        }
    }
    return .{ .start = @intCast(start), .count = @intCast(segments.items.len - start) };
}

pub fn appendTriangleSegments(
    segments: *std.ArrayList(Segment),
    gpa: std.mem.Allocator,
    call_index: u32,
    verts: []const Vertex,
) !strip.Range {
    const start = segments.items.len;
    var tri_start: usize = 0;
    while (tri_start + 2 < verts.len) : (tri_start += 3) {
        const tri = verts[tri_start..][0..3];
        for (0..3) |i| {
            const a = tri[i];
            const b = tri[(i + 1) % 3];
            if (a.x == b.x and a.y == b.y) continue;
            try segments.append(gpa, .{
                .x0 = a.x,
                .y0 = a.y,
                .x1 = b.x,
                .y1 = b.y,
                .call_index = call_index,
                .path_index = @intCast(tri_start / 3),
                .winding = if (b.y < a.y) 1 else if (b.y > a.y) -1 else 0,
            });
        }
    }
    return .{ .start = @intCast(start), .count = @intCast(segments.items.len - start) };
}

fn validPath(p: PathRange, point_len: usize) bool {
    return p.closed and p.point_count >= 3 and @as(usize, p.point_start) + @as(usize, p.point_count) <= point_len;
}

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

comptime {
    std.debug.assert(@sizeOf(Segment) == 32);
    std.debug.assert(@offsetOf(Segment, "x0") == 0);
    std.debug.assert(@offsetOf(Segment, "y0") == 4);
    std.debug.assert(@offsetOf(Segment, "x1") == 8);
    std.debug.assert(@offsetOf(Segment, "y1") == 12);
    std.debug.assert(@offsetOf(Segment, "call_index") == 16);
    std.debug.assert(@offsetOf(Segment, "path_index") == 20);
    std.debug.assert(@offsetOf(Segment, "winding") == 24);
    std.debug.assert(@offsetOf(Segment, "flags") == 28);
}
