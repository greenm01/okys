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
    pub const textures = @import("state/textures.zig");
    pub const context = @import("state/context.zig");
};

pub const ops = struct {
    pub const frame = @import("ops/frame_ops.zig");
    pub const path = @import("ops/path_ops.zig");
    pub const paint = @import("ops/paint_ops.zig");
    pub const state = @import("ops/state_ops.zig");
    pub const image = @import("ops/image_ops.zig");
};

pub const systems = struct {
    pub const flatten = @import("systems/flatten.zig");
    pub const stroke = @import("systems/stroke.zig");
    pub const convex = @import("systems/convex.zig");
    pub const backend_a = @import("systems/backend_a/backend.zig");
    pub const backend_b = @import("systems/backend_b/backend.zig");
};

pub const render = struct {
    pub const interface = @import("render/interface.zig");
};

pub const c_api = @import("c_api.zig");

// Reference every module so the test build analyzes each file — running its
// comptime layout assertions and including its in-file `test` blocks.
test {
    _ = types.color;
    _ = types.command;
    _ = types.path;
    _ = types.image;
    _ = state.arena;
    _ = state.commands;
    _ = state.path_cache;
    _ = state.draw_state;
    _ = state.textures;
    _ = state.context;
    _ = ops.frame;
    _ = ops.path;
    _ = ops.paint;
    _ = ops.state;
    _ = ops.image;
    _ = systems.flatten;
    _ = systems.stroke;
    _ = systems.convex;
    _ = systems.backend_a;
    _ = systems.backend_b;
    _ = render.interface;
    _ = c_api;
}
