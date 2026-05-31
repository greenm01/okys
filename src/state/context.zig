//! Context — the internal model. Owns the command stream, the state stack, the
//! per-frame arena, the path cache, and the texture table, plus the live render
//! backend (none yet). The C ABI sees this only as an opaque `OKYcontext`.

const std = @import("std");
const draw_state = @import("draw_state.zig");
const State = draw_state.State;
const CommandBuffer = @import("commands.zig").CommandBuffer;
const PathCache = @import("path_cache.zig").PathCache;
const FrameArena = @import("arena.zig").FrameArena;
const FrameProfile = @import("frame_profile.zig").FrameProfile;
const Textures = @import("textures.zig").Textures;
const RenderInterface = @import("../render/interface.zig").RenderInterface;
const backend_selection = @import("../render/backend_selection.zig");
const BackendKind = backend_selection.BackendKind;

pub const Context = struct {
    gpa: std.mem.Allocator,
    flags: u32,
    backend_kind: BackendKind,

    commands: CommandBuffer = .{},
    command_x: f32 = 0,
    command_y: f32 = 0,
    states: std.ArrayList(State) = .empty,
    cache: PathCache = .{},
    stroke_outline: PathCache = .{},
    frame_arena: FrameArena,
    frame_profile: FrameProfile = .{},
    textures: Textures,
    backend: ?RenderInterface = null,

    width: f32 = 0,
    height: f32 = 0,
    device_pixel_ratio: f32 = 1,
    tess_tol: f32 = 0.25,
    dist_tol: f32 = 0.01,

    pub fn create(gpa: std.mem.Allocator, flags: u32) !*Context {
        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .flags = flags,
            .backend_kind = backend_selection.fromCreateFlags(flags),
            .frame_arena = FrameArena.init(gpa),
            .textures = Textures.init(gpa),
        };
        // One default state always sits on the stack.
        try self.states.append(gpa, State.default());
        return self;
    }

    pub fn destroy(self: *Context) void {
        const gpa = self.gpa;
        self.clearBackend();
        self.commands.deinit(gpa);
        self.states.deinit(gpa);
        self.cache.deinit(gpa);
        self.stroke_outline.deinit(gpa);
        self.frame_arena.deinit();
        self.textures.deinit();
        gpa.destroy(self);
    }

    /// The live (top-of-stack) draw state.
    pub fn state(self: *Context) *State {
        return &self.states.items[self.states.items.len - 1];
    }

    pub fn installBackend(self: *Context, backend: RenderInterface) void {
        self.clearBackend();
        self.backend = backend;
    }

    pub fn clearBackend(self: *Context) void {
        if (self.backend) |b| {
            b.deinit(b.ctx);
            self.backend = null;
        }
    }
};
