//! The draw state pushed and popped by save/restore. One State sits on the
//! stack at all times; the top is the live state. Passive data.

const color = @import("../types/color.zig");
const Paint = color.Paint;
const Transform = color.Transform;
const Scissor = color.Scissor;

pub const LineCap = enum(u8) { butt, round, square };
pub const LineJoin = enum(u8) { miter, round, bevel };
pub const max_line_dashes = 16;

pub const State = struct {
    fill: Paint,
    stroke: Paint,
    stroke_width: f32,
    miter_limit: f32,
    line_cap: LineCap,
    line_join: LineJoin,
    line_dash: [max_line_dashes]f32,
    line_dash_count: u8,
    line_dash_offset: f32,
    alpha: f32,
    xform: Transform,
    scissor: Scissor,

    pub fn default() State {
        return .{
            .fill = color.solid(color.rgbaf(1, 1, 1, 1)),
            .stroke = color.solid(color.rgbaf(0, 0, 0, 1)),
            .stroke_width = 1.0,
            .miter_limit = 10.0,
            .line_cap = .butt,
            .line_join = .miter,
            .line_dash = @splat(0),
            .line_dash_count = 0,
            .line_dash_offset = 0,
            .alpha = 1.0,
            .xform = .{ 1, 0, 0, 1, 0, 0 },
            // extent[0] < 0 -> no scissor
            .scissor = .{ .xform = .{ 0, 0, 0, 0, 0, 0 }, .extent = .{ -1, -1 } },
        };
    }
};
