const std = @import("std");
const sokol = @import("sokol");
const okys = @import("okys");
const builtin = @import("builtin");

const sokol_device = okys.render.sokol_device;
const sg = sokol.gfx;

pub const Kind = enum {
    none,
    readback_wait,
    queue_fence,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .none => "none",
            .readback_wait => "readback_wait",
            .queue_fence => "queue_fence",
        };
    }
};

pub const Status = enum {
    ok,
    unsupported_backend,
    missing_handle,
    timeout,
    wait_failed,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .unsupported_backend => "unsupported_backend",
            .missing_handle => "missing_handle",
            .timeout => "timeout",
            .wait_failed => "wait_failed",
        };
    }
};

pub const Params = struct {
    device: *sokol_device.Device,
    allocator: std.mem.Allocator,
    target_width: u32,
    target_height: u32,
};

pub const Result = struct {
    kind: Kind,
    status: Status,
    ns: ?u64,

    pub fn supported(self: Result) bool {
        return self.status == .ok and self.ns != null;
    }
};

extern fn sg_wgpu_queue() ?*const anyopaque;
extern fn okys_wgpu_queue_fence_wait(queue: ?*const anyopaque, timeout_ns: u64) c_int;

const is_darwin = switch (builtin.target.os.tag) {
    .macos, .ios, .tvos, .watchos => true,
    else => false,
};

const MetalFence = if (is_darwin) struct {
    extern fn sg_mtl_command_queue() ?*const anyopaque;
    extern fn okys_metal_queue_fence_wait(queue: ?*const anyopaque) c_int;
} else struct {};

pub fn measure(params: Params) Result {
    return switch (sg.queryBackend()) {
        .GLCORE, .GLES3 => measureGlReadback(params),
        .METAL_IOS, .METAL_MACOS, .METAL_SIMULATOR => measureMetalQueueFence(),
        .WGPU => measureWebgpuQueueFence(),
        else => .{
            .kind = .none,
            .status = .unsupported_backend,
            .ns = null,
        },
    };
}

fn measureGlReadback(params: Params) Result {
    var pixel = [_]u8{0} ** 4;
    const start = nowNs();
    if (!params.device.readPixelsGL(
        params.allocator,
        0,
        params.target_width,
        params.target_height,
        0,
        0,
        1,
        1,
        4,
        &pixel,
    )) {
        return .{
            .kind = .readback_wait,
            .status = .wait_failed,
            .ns = null,
        };
    }
    return .{
        .kind = .readback_wait,
        .status = .ok,
        .ns = nowNs() - start,
    };
}

fn measureMetalQueueFence() Result {
    if (!is_darwin) {
        return .{
            .kind = .queue_fence,
            .status = .unsupported_backend,
            .ns = null,
        };
    }

    const queue = MetalFence.sg_mtl_command_queue() orelse {
        return .{
            .kind = .queue_fence,
            .status = .missing_handle,
            .ns = null,
        };
    };

    const start = nowNs();
    const rc = MetalFence.okys_metal_queue_fence_wait(queue);
    if (rc != 0) {
        return .{
            .kind = .queue_fence,
            .status = .wait_failed,
            .ns = null,
        };
    }

    return .{
        .kind = .queue_fence,
        .status = .ok,
        .ns = nowNs() - start,
    };
}

fn measureWebgpuQueueFence() Result {
    const queue = sg_wgpu_queue() orelse {
        return .{
            .kind = .queue_fence,
            .status = .missing_handle,
            .ns = null,
        };
    };

    const start = nowNs();
    const rc = okys_wgpu_queue_fence_wait(queue, 50 * std.time.ns_per_ms);
    return switch (rc) {
        0 => .{
            .kind = .queue_fence,
            .status = .ok,
            .ns = nowNs() - start,
        },
        -4 => .{
            .kind = .queue_fence,
            .status = .timeout,
            .ns = null,
        },
        -5 => .{
            .kind = .queue_fence,
            .status = .unsupported_backend,
            .ns = null,
        },
        else => .{
            .kind = .queue_fence,
            .status = .wait_failed,
            .ns = null,
        },
    };
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
