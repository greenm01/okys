//! Color, Paint, Transform, Scissor — passive POD that crosses the C ABI and
//! the render interface. Layout is asserted at comptime as a corruption
//! tripwire.

const std = @import("std");

/// RGBA, components in 0..1. ABI-compatible with C `OKYcolor` (a 16-byte,
/// four-float aggregate). The C side is a union exposing both `.rgba[i]` and
/// `.r/.g/.b/.a`; the Zig side is the struct view — same layout, same SysV
/// register classification, so it crosses the boundary by value cleanly.
pub const Color = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
};

/// 2D affine transform, NanoVG/PostScript layout: [a b c d e f].
pub const Transform = [6]f32;

/// Rectangular scissor with its own transform. Internal; crosses the render
/// interface, not the C ABI. extent[0] < 0 means "no scissor".
pub const Scissor = extern struct {
    xform: Transform,
    extent: [2]f32,
};

/// Paint descriptor. Mirrors C `OKYpaint`. `image` is 0 (none) or an image id.
pub const Paint = extern struct {
    xform: Transform,
    extent: [2]f32,
    radius: f32,
    feather: f32,
    inner_color: Color,
    outer_color: Color,
    image: i32,
};

comptime {
    std.debug.assert(@sizeOf(Color) == 16);
    std.debug.assert(@alignOf(Color) == 4);
    std.debug.assert(@sizeOf(Paint) == 76);
    std.debug.assert(@offsetOf(Paint, "inner_color") == 40);
    std.debug.assert(@offsetOf(Paint, "outer_color") == 56);
    std.debug.assert(@offsetOf(Paint, "image") == 72);
}

pub fn rgbaf(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return rgbaf(
        @as(f32, @floatFromInt(r)) / 255.0,
        @as(f32, @floatFromInt(g)) / 255.0,
        @as(f32, @floatFromInt(b)) / 255.0,
        @as(f32, @floatFromInt(a)) / 255.0,
    );
}

/// A flat solid-color paint with an identity transform.
pub fn solid(c: Color) Paint {
    return .{
        .xform = .{ 1, 0, 0, 1, 0, 0 },
        .extent = .{ 0, 0 },
        .radius = 0,
        .feather = 1,
        .inner_color = c,
        .outer_color = c,
        .image = 0,
    };
}
