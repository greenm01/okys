//! Internal reusable draw-list value. It records render-interface events into
//! owned storage and can replay them into any backend.

const std = @import("std");
const frame_capture = @import("frame_capture.zig");
const RenderInterface = @import("interface.zig").RenderInterface;

pub const DrawList = struct {
    frame: frame_capture.CapturedFrame,

    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{ .frame = frame_capture.CapturedFrame.init(gpa) };
    }

    pub fn deinit(self: *DrawList) void {
        self.frame.deinit();
    }

    pub fn clear(self: *DrawList) void {
        self.frame.clear();
    }

    pub fn interface(self: *DrawList) RenderInterface {
        return self.frame.interface();
    }

    pub fn replay(self: *const DrawList, target: RenderInterface) void {
        self.frame.replay(target);
    }

    pub fn eventCount(self: *const DrawList) usize {
        return self.frame.events.items.len;
    }

    pub fn isEmpty(self: *const DrawList) bool {
        return self.eventCount() == 0;
    }
};
