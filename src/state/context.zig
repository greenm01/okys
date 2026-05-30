//! Context — the internal model. Owns the command stream, the state stack, the
//! per-frame arena, the path cache, and the texture table, plus the live render
//! backend (none yet). The C ABI sees this only as an opaque `OKYcontext`.

const std = @import("std");
const draw_state = @import("draw_state.zig");
const State = draw_state.State;
const CommandBuffer = @import("commands.zig").CommandBuffer;
const PathCache = @import("path_cache.zig").PathCache;
const FrameArena = @import("arena.zig").FrameArena;
const Textures = @import("textures.zig").Textures;
const RenderInterface = @import("../render/interface.zig").RenderInterface;

pub const Context = struct {
    gpa: std.mem.Allocator,
    flags: u32,

    commands: CommandBuffer = .{},
    command_x: f32 = 0,
    command_y: f32 = 0,
    states: std.ArrayList(State) = .empty,
    cache: PathCache = .{},
    frame_arena: FrameArena,
    textures: Textures,
    backend: ?RenderInterface = null,

    width: f32 = 0,
    height: f32 = 0,
    device_pixel_ratio: f32 = 1,

    pub fn create(gpa: std.mem.Allocator, flags: u32) !*Context {
        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .flags = flags,
            .frame_arena = FrameArena.init(gpa),
            .textures = Textures.init(gpa),
        };
        // One default state always sits on the stack.
        try self.states.append(gpa, State.default());
        return self;
    }

    pub fn destroy(self: *Context) void {
        const gpa = self.gpa;
        self.commands.deinit(gpa);
        self.states.deinit(gpa);
        self.cache.deinit(gpa);
        self.frame_arena.deinit();
        self.textures.deinit();
        gpa.destroy(self);
    }

    /// The live (top-of-stack) draw state.
    pub fn state(self: *Context) *State {
        return &self.states.items[self.states.items.len - 1];
    }
};

// ===== production code above =====

const testing = std.testing;

test "create installs one default state and destroy frees it" {
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();
    try testing.expectEqual(@as(usize, 1), ctx.states.items.len);
    try testing.expectEqual(@as(f32, 1.0), ctx.state().alpha);
}
