//! Paint verbs. Set the live state's fill/stroke paint. Gradients and image
//! patterns (extent/radius/feather/image) aren't implemented yet.

const Context = @import("../state/context.zig").Context;
const color = @import("../types/color.zig");
const Color = color.Color;

pub fn fillColor(ctx: *Context, c: Color) void {
    ctx.state().fill = color.solid(c);
}

pub fn strokeColor(ctx: *Context, c: Color) void {
    ctx.state().stroke = color.solid(c);
}
