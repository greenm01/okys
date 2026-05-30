//! The convexity test. Both backends take a cheaper path for convex fills, so
//! the front-end has to tell them.

const Point = @import("../types/path.zig").Point;

pub fn isConvex(points: []const Point) bool {
    if (points.len < 3) return false;

    var turn_sign: i8 = 0;
    for (points, 0..) |p1, i| {
        const p0 = points[(i + points.len - 1) % points.len];
        const p2 = points[(i + 1) % points.len];
        const dx0 = p1.x - p0.x;
        const dy0 = p1.y - p0.y;
        const dx1 = p2.x - p1.x;
        const dy1 = p2.y - p1.y;
        const area = cross(dx0, dy0, dx1, dy1);
        if (@abs(area) <= 1e-6) continue;
        const sign: i8 = if (area > 0) 1 else -1;
        if (turn_sign == 0) {
            turn_sign = sign;
        } else if (turn_sign != sign) {
            return false;
        }
    }

    return turn_sign != 0;
}

fn cross(dx0: f32, dy0: f32, dx1: f32, dy1: f32) f32 {
    return dx1 * dy0 - dx0 * dy1;
}
