//! Internal frame capture backend. It records render-interface events as owned
//! data so tests and later benchmarks can replay the same frame into any backend.

const std = @import("std");
const color = @import("../types/color.zig");
const image = @import("../types/image.zig");
const path = @import("../types/path.zig");
const RenderInterface = @import("interface.zig").RenderInterface;

const Paint = color.Paint;
const Scissor = color.Scissor;
const ImageId = image.ImageId;
const TexFormat = image.TexFormat;
const PathRange = path.PathRange;
const Point = path.Point;
const Vertex = path.Vertex;

pub const EventKind = enum {
    create_texture,
    update_texture,
    delete_texture,
    viewport,
    flush,
    fill,
    stroke,
    triangles,
};

pub const Range = struct {
    start: u32 = 0,
    count: u32 = 0,
};

pub const Event = struct {
    kind: EventKind,
    image_id: ImageId = .none,
    tex_format: TexFormat = .rgba8,
    tex_x: u32 = 0,
    tex_y: u32 = 0,
    tex_width: u32 = 0,
    tex_height: u32 = 0,
    byte_range: Range = .{},
    view_width: f32 = 0,
    view_height: f32 = 0,
    view_dpr: f32 = 1,
    paint: Paint = undefined,
    scissor: Scissor = undefined,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    stroke_width: f32 = 0,
    path_range: Range = .{},
    point_range: Range = .{},
    vertex_range: Range = .{},
};

pub const CapturedFrame = struct {
    gpa: std.mem.Allocator,
    events: std.ArrayList(Event) = .empty,
    paths: std.ArrayList(PathRange) = .empty,
    points: std.ArrayList(Point) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) CapturedFrame {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *CapturedFrame) void {
        self.events.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.points.deinit(self.gpa);
        self.vertices.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
    }

    pub fn clear(self: *CapturedFrame) void {
        self.events.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
    }

    pub fn interface(self: *CapturedFrame) RenderInterface {
        return .{
            .ctx = self,
            .create_texture = createTexture,
            .update_texture = updateTexture,
            .delete_texture = deleteTexture,
            .texture_size = textureSize,
            .viewport = viewport,
            .flush = flush,
            .deinit = backendDeinit,
            .fill = fill,
            .stroke = stroke,
            .triangles = triangles,
        };
    }

    pub fn replay(self: *const CapturedFrame, target: RenderInterface) void {
        for (self.events.items) |event| {
            switch (event.kind) {
                .create_texture => {
                    const data = bytesFor(self, event.byte_range);
                    _ = target.create_texture(
                        target.ctx,
                        event.image_id,
                        event.tex_width,
                        event.tex_height,
                        event.tex_format,
                        if (data.len > 0) data else null,
                    );
                },
                .update_texture => target.update_texture(
                    target.ctx,
                    event.image_id,
                    event.tex_x,
                    event.tex_y,
                    event.tex_width,
                    event.tex_height,
                    bytesFor(self, event.byte_range),
                ),
                .delete_texture => target.delete_texture(target.ctx, event.image_id),
                .viewport => target.viewport(target.ctx, event.view_width, event.view_height, event.view_dpr),
                .flush => target.flush(target.ctx),
                .fill => target.fill(
                    target.ctx,
                    &event.paint,
                    &event.scissor,
                    event.bounds,
                    pathsFor(self, event.path_range),
                    pointsFor(self, event.point_range),
                ),
                .stroke => target.stroke(
                    target.ctx,
                    &event.paint,
                    &event.scissor,
                    event.stroke_width,
                    pathsFor(self, event.path_range),
                    pointsFor(self, event.point_range),
                ),
                .triangles => target.triangles(
                    target.ctx,
                    &event.paint,
                    &event.scissor,
                    verticesFor(self, event.vertex_range),
                ),
            }
        }
    }

    fn appendBytes(self: *CapturedFrame, data: []const u8) !Range {
        const start = self.bytes.items.len;
        try self.bytes.appendSlice(self.gpa, data);
        return .{ .start = @intCast(start), .count = @intCast(data.len) };
    }

    fn appendPaths(self: *CapturedFrame, paths: []const PathRange) !Range {
        const start = self.paths.items.len;
        try self.paths.appendSlice(self.gpa, paths);
        return .{ .start = @intCast(start), .count = @intCast(paths.len) };
    }

    fn appendPoints(self: *CapturedFrame, points: []const Point) !Range {
        const start = self.points.items.len;
        try self.points.appendSlice(self.gpa, points);
        return .{ .start = @intCast(start), .count = @intCast(points.len) };
    }

    fn appendVertices(self: *CapturedFrame, vertices: []const Vertex) !Range {
        const start = self.vertices.items.len;
        try self.vertices.appendSlice(self.gpa, vertices);
        return .{ .start = @intCast(start), .count = @intCast(vertices.len) };
    }
};

fn from(ctx: *anyopaque) *CapturedFrame {
    return @ptrCast(@alignCast(ctx));
}

fn createTexture(ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool {
    const self = from(ctx);
    const byte_range = if (data) |bytes| self.appendBytes(bytes) catch return false else Range{};
    self.events.append(self.gpa, .{
        .kind = .create_texture,
        .image_id = id,
        .tex_format = fmt,
        .tex_width = w,
        .tex_height = h,
        .byte_range = byte_range,
    }) catch return false;
    return true;
}

fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
    const self = from(ctx);
    const byte_range = self.appendBytes(data) catch return;
    self.events.append(self.gpa, .{
        .kind = .update_texture,
        .image_id = id,
        .tex_x = x,
        .tex_y = y,
        .tex_width = w,
        .tex_height = h,
        .byte_range = byte_range,
    }) catch {};
}

fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
    const self = from(ctx);
    self.events.append(self.gpa, .{ .kind = .delete_texture, .image_id = id }) catch {};
}

fn textureSize(ctx: *anyopaque, id: ImageId) ?[2]u32 {
    const self = from(ctx);
    var result: ?[2]u32 = null;
    for (self.events.items) |event| {
        if (event.image_id != id) continue;
        switch (event.kind) {
            .create_texture => result = .{ event.tex_width, event.tex_height },
            .delete_texture => result = null,
            else => {},
        }
    }
    return result;
}

fn viewport(ctx: *anyopaque, width: f32, height: f32, dpr: f32) void {
    const self = from(ctx);
    self.events.append(self.gpa, .{
        .kind = .viewport,
        .view_width = width,
        .view_height = height,
        .view_dpr = dpr,
    }) catch {};
}

fn flush(ctx: *anyopaque) void {
    const self = from(ctx);
    self.events.append(self.gpa, .{ .kind = .flush }) catch {};
}

fn backendDeinit(ctx: *anyopaque) void {
    _ = ctx;
}

fn fill(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
    const self = from(ctx);
    const path_range = self.appendPaths(paths) catch return;
    const point_range = self.appendPoints(points) catch return;
    self.events.append(self.gpa, .{
        .kind = .fill,
        .paint = paint.*,
        .scissor = scissor.*,
        .bounds = bounds,
        .path_range = path_range,
        .point_range = point_range,
    }) catch {};
}

fn stroke(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void {
    const self = from(ctx);
    const path_range = self.appendPaths(paths) catch return;
    const point_range = self.appendPoints(points) catch return;
    self.events.append(self.gpa, .{
        .kind = .stroke,
        .paint = paint.*,
        .scissor = scissor.*,
        .stroke_width = width,
        .path_range = path_range,
        .point_range = point_range,
    }) catch {};
}

fn triangles(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
    const self = from(ctx);
    const vertex_range = self.appendVertices(verts) catch return;
    self.events.append(self.gpa, .{
        .kind = .triangles,
        .paint = paint.*,
        .scissor = scissor.*,
        .vertex_range = vertex_range,
    }) catch {};
}

fn bytesFor(frame: *const CapturedFrame, range: Range) []const u8 {
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    return frame.bytes.items[start..][0..count];
}

fn pathsFor(frame: *const CapturedFrame, range: Range) []const PathRange {
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    return frame.paths.items[start..][0..count];
}

fn pointsFor(frame: *const CapturedFrame, range: Range) []const Point {
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    return frame.points.items[start..][0..count];
}

fn verticesFor(frame: *const CapturedFrame, range: Range) []const Vertex {
    const start: usize = @intCast(range.start);
    const count: usize = @intCast(range.count);
    return frame.vertices.items[start..][0..count];
}
