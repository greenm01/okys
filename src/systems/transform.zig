//! 2D affine transform helpers. NanoVG/PostScript layout: [a b c d e f].

const Transform = @import("../types/color.zig").Transform;

pub fn identity() Transform {
    return .{ 1, 0, 0, 1, 0, 0 };
}

pub fn translate(tx: f32, ty: f32) Transform {
    return .{ 1, 0, 0, 1, tx, ty };
}

pub fn scale(sx: f32, sy: f32) Transform {
    return .{ sx, 0, 0, sy, 0, 0 };
}

pub fn rotate(a: f32) Transform {
    const cs = @cos(a);
    const sn = @sin(a);
    return .{ cs, sn, -sn, cs, 0, 0 };
}

pub fn skewX(a: f32) Transform {
    return .{ 1, 0, @tan(a), 1, 0, 0 };
}

pub fn skewY(a: f32) Transform {
    return .{ 1, @tan(a), 0, 1, 0, 0 };
}

pub fn multiply(t: *Transform, s: *const Transform) void {
    const t0 = t[0] * s[0] + t[1] * s[2];
    const t2 = t[2] * s[0] + t[3] * s[2];
    const t4 = t[4] * s[0] + t[5] * s[2] + s[4];
    t[1] = t[0] * s[1] + t[1] * s[3];
    t[3] = t[2] * s[1] + t[3] * s[3];
    t[5] = t[4] * s[1] + t[5] * s[3] + s[5];
    t[0] = t0;
    t[2] = t2;
    t[4] = t4;
}

pub fn premultiply(t: *Transform, s: *const Transform) void {
    var s2 = s.*;
    multiply(&s2, t);
    t.* = s2;
}

pub fn inverse(t: *const Transform) ?Transform {
    const det = @as(f64, t[0]) * @as(f64, t[3]) - @as(f64, t[2]) * @as(f64, t[1]);
    if (det > -1e-6 and det < 1e-6) return null;

    const invdet = 1.0 / det;
    return .{
        @floatCast(@as(f64, t[3]) * invdet),
        @floatCast(-@as(f64, t[1]) * invdet),
        @floatCast(-@as(f64, t[2]) * invdet),
        @floatCast(@as(f64, t[0]) * invdet),
        @floatCast((@as(f64, t[2]) * @as(f64, t[5]) - @as(f64, t[3]) * @as(f64, t[4])) * invdet),
        @floatCast((@as(f64, t[1]) * @as(f64, t[4]) - @as(f64, t[0]) * @as(f64, t[5])) * invdet),
    };
}

pub fn averageScale(t: *const Transform) f32 {
    const sx = @sqrt(t[0] * t[0] + t[2] * t[2]);
    const sy = @sqrt(t[1] * t[1] + t[3] * t[3]);
    return (sx + sy) * 0.5;
}

pub fn point(t: *const Transform, x: f32, y: f32) [2]f32 {
    return .{
        x * t[0] + y * t[2] + t[4],
        x * t[1] + y * t[3] + t[5],
    };
}
