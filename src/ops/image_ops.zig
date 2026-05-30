//! Image verbs. These will route to the backend's texture upload and the
//! texture table once a backend exists (Milestone 1). Stubbed for now.

const Context = @import("../state/context.zig").Context;
const ImageId = @import("../types/image.zig").ImageId;

pub fn createImage(ctx: *Context, w: u32, h: u32) ImageId {
    _ = ctx;
    _ = w;
    _ = h;
    return .none; // TODO (Milestone 1)
}

pub fn deleteImage(ctx: *Context, id: ImageId) void {
    _ = ctx;
    _ = id;
}
