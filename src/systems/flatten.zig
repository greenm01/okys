//! Flattening: command stream -> SoA points + path ranges, with adaptive
//! bezier/arc subdivision and join metadata. Shared by both backends. The
//! algorithmic reference is NanoVG's nvg__flattenPaths / nvg__tesselateBezier.
//! Not implemented yet.

const Context = @import("../state/context.zig").Context;

pub fn flatten(ctx: *Context) void {
    _ = ctx;
}
