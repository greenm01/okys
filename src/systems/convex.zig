//! The convexity test. Both backends take a cheaper path for convex fills, so
//! the front-end has to tell them. Not implemented yet.

const Point = @import("../types/path.zig").Point;

pub fn isConvex(points: []const Point) bool {
    _ = points;
    return false;
}
