//! The flattened-path cache: SoA points plus the path ranges that index them.
//! Filled by systems/flatten.zig and handed across the render interface. Empty
//! until the flatten path lands (Milestone 1).

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
};
