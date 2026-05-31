//! Optional per-frame frontend profiling. Disabled by default so normal drawing
//! does not pay timing overhead.

const std = @import("std");
const path = @import("../types/path.zig");
const PathRange = path.PathRange;

pub const FrameProfile = struct {
    enabled: bool = false,
    stroke_outline_ns: u64 = 0,
    stroke_outline_builds: usize = 0,
    stroke_calls: usize = 0,
    stroke_source_paths: usize = 0,
    stroke_source_points: usize = 0,
    stroke_source_open_paths: usize = 0,
    stroke_source_closed_paths: usize = 0,
    stroke_outline_paths: usize = 0,
    stroke_outline_points: usize = 0,
    max_stroke_outline_expansion_pct: usize = 0,

    pub fn resetFrame(self: *FrameProfile) void {
        const keep_enabled = self.enabled;
        self.* = .{ .enabled = keep_enabled };
    }

    pub fn recordStrokeOutline(
        self: *FrameProfile,
        ns: u64,
        source_paths: []const PathRange,
        source_points: usize,
        outline_paths: usize,
        outline_points: usize,
    ) void {
        if (!self.enabled) return;

        self.stroke_outline_ns += ns;
        self.stroke_outline_builds += 1;
        self.stroke_source_paths += source_paths.len;
        self.stroke_source_points += source_points;
        self.stroke_outline_paths += outline_paths;
        self.stroke_outline_points += outline_points;

        for (source_paths) |source_path| {
            if (source_path.closed) {
                self.stroke_source_closed_paths += 1;
            } else {
                self.stroke_source_open_paths += 1;
            }
        }

        if (source_points > 0) {
            const expansion_pct = outline_points * 100 / source_points;
            self.max_stroke_outline_expansion_pct = @max(self.max_stroke_outline_expansion_pct, expansion_pct);
        }
    }

    pub fn recordStrokeCall(self: *FrameProfile) void {
        if (!self.enabled) return;
        self.stroke_calls += 1;
    }
};

pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
