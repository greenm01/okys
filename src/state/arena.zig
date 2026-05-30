//! Per-frame scratch arena. Reset on beginFrame; never freed piecemeal. The
//! command stream, point cache, and encode scratch allocate from here once the
//! flatten/encode path is wired in.

const std = @import("std");

pub const FrameArena = struct {
    impl: std.heap.ArenaAllocator,

    pub fn init(child: std.mem.Allocator) FrameArena {
        return .{ .impl = std.heap.ArenaAllocator.init(child) };
    }

    pub fn deinit(self: *FrameArena) void {
        self.impl.deinit();
    }

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return self.impl.allocator();
    }

    /// Drop the frame's allocations but keep the backing capacity.
    pub fn reset(self: *FrameArena) void {
        _ = self.impl.reset(.retain_capacity);
    }
};
