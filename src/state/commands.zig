//! The flat command buffer. The imperative path-building API appends tagged
//! floats here; systems/flatten.zig reads them back. This is the command stream
//! that is the per-frame model (AGENTS/okys/dod.md).

const std = @import("std");
const Command = @import("../types/command.zig").Command;

pub const CommandBuffer = struct {
    data: std.ArrayList(f32) = .empty,

    pub fn deinit(self: *CommandBuffer, gpa: std.mem.Allocator) void {
        self.data.deinit(gpa);
    }

    pub fn clear(self: *CommandBuffer) void {
        self.data.clearRetainingCapacity();
    }

    pub fn tag(self: *CommandBuffer, gpa: std.mem.Allocator, c: Command) void {
        self.data.append(gpa, @floatFromInt(@intFromEnum(c))) catch {};
    }

    pub fn float(self: *CommandBuffer, gpa: std.mem.Allocator, v: f32) void {
        self.data.append(gpa, v) catch {};
    }
};
