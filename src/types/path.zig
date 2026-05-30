//! Flattened-geometry types: the SoA-friendly Point, the PathRange that indexes
//! into the point buffer, and the GPU-ready Vertex. Produced by
//! systems/flatten.zig; consumed across the render interface. See
//! AGENTS/okys/architecture.md.

const std = @import("std");

pub const PointFlags = packed struct(u8) {
    corner: bool = false,
    left: bool = false,
    bevel: bool = false,
    inner_bevel: bool = false,
    _pad: u4 = 0,
};

/// A flattened path point with the join metadata stroke expansion needs.
/// Mirrors NanoVG's NVGpoint.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
    len: f32 = 0,
    dmx: f32 = 0,
    dmy: f32 = 0,
    flags: PointFlags = .{},
};

pub const Winding = enum(i32) {
    ccw = 1,
    cw = 2,
};

/// One subpath: a contiguous range in the shared point buffer plus the flags a
/// backend needs to rasterize it.
pub const PathRange = struct {
    point_start: u32 = 0,
    point_count: u32 = 0,
    closed: bool = false,
    convex: bool = false,
    winding: Winding = .ccw,
};

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
};

comptime {
    std.debug.assert(@sizeOf(PointFlags) == 1);
    std.debug.assert(@sizeOf(Vertex) == 16);
}
