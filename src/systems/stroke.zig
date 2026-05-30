//! Stroke outline: a flattened polyline -> its offset outline, with joins,
//! caps, and miter handling. Shared geometry: Plan A triangulates the outline
//! with a fringe; Plan B will analytic-cover it. Not implemented yet.

const Context = @import("../state/context.zig").Context;

pub fn buildOutline(ctx: *Context) void {
    _ = ctx;
}
