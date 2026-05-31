//! Internal Zig root module. The public surface is the C ABI in include/okys.h,
//! exported from c_api.zig. This module exists so the test build compiles every
//! file in the tree and runs each one's comptime layout assertions.

pub const types = struct {
    pub const color = @import("types/color.zig");
    pub const command = @import("types/command.zig");
    pub const path = @import("types/path.zig");
    pub const image = @import("types/image.zig");
};

pub const state = struct {
    pub const arena = @import("state/arena.zig");
    pub const commands = @import("state/commands.zig");
    pub const path_cache = @import("state/path_cache.zig");
    pub const draw_state = @import("state/draw_state.zig");
    pub const frame_profile = @import("state/frame_profile.zig");
    pub const textures = @import("state/textures.zig");
    pub const context = @import("state/context.zig");
};

pub const ops = struct {
    pub const frame = @import("ops/frame_ops.zig");
    pub const path = @import("ops/path_ops.zig");
    pub const paint = @import("ops/paint_ops.zig");
    pub const render = @import("ops/render_ops.zig");
    pub const state = @import("ops/state_ops.zig");
    pub const image = @import("ops/image_ops.zig");
};

pub const systems = struct {
    pub const transform = @import("systems/transform.zig");
    pub const flatten = @import("systems/flatten.zig");
    pub const stroke = @import("systems/stroke.zig");
    pub const convex = @import("systems/convex.zig");
    pub const backend_stencil = @import("systems/backend_stencil/backend.zig");
    pub const backend_sparse_strip = @import("systems/backend_sparse_strip/backend.zig");
};

pub const render = struct {
    pub const backend_selection = @import("render/backend_selection.zig");
    pub const frame_capture = @import("render/frame_capture.zig");
    pub const interface = @import("render/interface.zig");
    pub const sokol_device = @import("render/sokol_device.zig");
};

pub const c_api = @import("c_api.zig");
