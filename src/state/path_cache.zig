//! The flattened-path cache: SoA points plus the path ranges that index them.
//! Filled by systems/flatten.zig and handed across the render interface. Empty
//! until flattening is implemented.

const std = @import("std");
const path = @import("../types/path.zig");
const Point = path.Point;
const PathRange = path.PathRange;

pub const PathCache = struct {
    points: std.ArrayList(Point) = .empty,
    paths: std.ArrayList(PathRange) = .empty,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },

    pub fn deinit(self: *PathCache, gpa: std.mem.Allocator) void {
        self.points.deinit(gpa);
        self.paths.deinit(gpa);
    }

    pub fn clear(self: *PathCache) void {
        self.points.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.bounds = .{ 0, 0, 0, 0 };
    }

    pub fn lastPath(self: *PathCache) ?*PathRange {
        if (self.paths.items.len == 0) return null;
        return &self.paths.items[self.paths.items.len - 1];
    }

    pub fn addPath(self: *PathCache, gpa: std.mem.Allocator) void {
        self.paths.append(gpa, .{
            .point_start = @intCast(self.points.items.len),
            .point_count = 0,
            .closed = false,
            .convex = false,
            .winding = .ccw,
        }) catch {};
    }

    pub fn lastPoint(self: *PathCache) ?*Point {
        if (self.points.items.len == 0) return null;
        return &self.points.items[self.points.items.len - 1];
    }

    pub fn addPoint(self: *PathCache, gpa: std.mem.Allocator, x: f32, y: f32, flags: path.PointFlags, dist_tol: f32) void {
        const active_path = self.lastPath() orelse return;
        if (active_path.point_count > 0) {
            if (self.lastPoint()) |pt| {
                if (ptEquals(pt.x, pt.y, x, y, dist_tol)) {
                    pt.flags.corner = pt.flags.corner or flags.corner;
                    pt.flags.left = pt.flags.left or flags.left;
                    pt.flags.bevel = pt.flags.bevel or flags.bevel;
                    pt.flags.inner_bevel = pt.flags.inner_bevel or flags.inner_bevel;
                    return;
                }
            }
        }

        self.points.append(gpa, .{
            .x = x,
            .y = y,
            .flags = flags,
        }) catch return;
        self.paths.items[self.paths.items.len - 1].point_count += 1;
    }

    pub fn closePath(self: *PathCache) void {
        if (self.lastPath()) |active_path| active_path.closed = true;
    }

    pub fn pathWinding(self: *PathCache, winding: path.Winding) void {
        if (self.lastPath()) |active_path| active_path.winding = winding;
    }
};

fn ptEquals(x1: f32, y1: f32, x2: f32, y2: f32, tol: f32) bool {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return dx * dx + dy * dy < tol * tol;
}
