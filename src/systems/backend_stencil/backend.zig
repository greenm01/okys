//! Stencil-cover backend: the proven fallback. This module owns the fallback
//! batching shape: queued calls, copied vertices, and texture callbacks. GPU
//! pass execution lands after the queue is proven.

const std = @import("std");
const color = @import("../../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const image = @import("../../types/image.zig");
const ImageId = image.ImageId;
const TexFormat = image.TexFormat;
const Texture = image.Texture;
const path = @import("../../types/path.zig");
const PathRange = path.PathRange;
const Point = path.Point;
const Vertex = path.Vertex;
const RenderInterface = @import("../../render/interface.zig").RenderInterface;
pub const draw_plan = @import("draw_plan.zig");
pub const replay = @import("replay.zig");

pub const max_vertices = draw_plan.max_vertices;
pub const max_indices = draw_plan.max_indices;

pub const CallType = draw_plan.CallType;
pub const DrawOp = draw_plan.DrawOp;
pub const DrawOpKind = draw_plan.DrawOpKind;
pub const FillRule = draw_plan.FillRule;
pub const PaintUniform = draw_plan.PaintUniform;
pub const Primitive = draw_plan.Primitive;
pub const Range = draw_plan.Range;
pub const StencilMode = draw_plan.StencilMode;
pub const QueuedPath = draw_plan.QueuedPath;
pub const Call = draw_plan.Call;
pub const StencilDraw = @import("../../render/sokol_device.zig").StencilDraw;
pub const CoverDraw = @import("../../render/sokol_device.zig").CoverDraw;
pub const PathFsParams = @import("../../render/sokol_device.zig").PathFsParams;

pub const Backend = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    paths: std.ArrayList(QueuedPath) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u16) = .empty,
    uniforms: std.ArrayList(PaintUniform) = .empty,
    draw_ops: std.ArrayList(DrawOp) = .empty,
    stencil_draws: std.ArrayList(StencilDraw) = .empty,
    cover_draws: std.ArrayList(CoverDraw) = .empty,
    frag_params: std.ArrayList(PathFsParams) = .empty,
    textures: std.AutoArrayHashMapUnmanaged(ImageId, Texture) = .empty,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_dpr: f32 = 1,
    fill_rule: FillRule = .nonzero,
    flush_count: usize = 0,

    pub fn create(gpa: std.mem.Allocator) !*Backend {
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Backend) void {
        const gpa = self.gpa;
        self.calls.deinit(gpa);
        self.paths.deinit(gpa);
        self.vertices.deinit(gpa);
        self.indices.deinit(gpa);
        self.uniforms.deinit(gpa);
        self.draw_ops.deinit(gpa);
        self.stencil_draws.deinit(gpa);
        self.cover_draws.deinit(gpa);
        self.frag_params.deinit(gpa);
        self.textures.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn interface(self: *Backend) RenderInterface {
        return .{
            .ctx = self,
            .create_texture = createTexture,
            .update_texture = updateTexture,
            .delete_texture = deleteTexture,
            .texture_size = textureSize,
            .viewport = viewport,
            .flush = renderFlush,
            .deinit = deinit,
            .fill = fill,
            .stroke = stroke,
            .triangles = triangles,
        };
    }

    pub fn flush(self: *Backend) void {
        _ = self.buildStencilPass();
        self.flush_count += 1;
        self.calls.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.uniforms.clearRetainingCapacity();
        self.draw_ops.clearRetainingCapacity();
        self.stencil_draws.clearRetainingCapacity();
        self.cover_draws.clearRetainingCapacity();
        self.frag_params.clearRetainingCapacity();
    }

    pub fn buildDrawPlan(self: *Backend) bool {
        draw_plan.build(
            self.gpa,
            self.calls.items,
            self.paths.items,
            self.fill_rule,
            &self.uniforms,
            &self.indices,
            &self.draw_ops,
        ) catch return false;
        return true;
    }

    pub fn buildStencilPass(self: *Backend) bool {
        if (!self.buildDrawPlan()) return false;
        replay.build(
            self.gpa,
            self.draw_ops.items,
            self.uniforms.items,
            &self.stencil_draws,
            &self.cover_draws,
            &self.frag_params,
        ) catch return false;
        return true;
    }

    fn queueFill(self: *Backend, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, input_paths: []const PathRange, points: []const Point) void {
        var valid_path_count: usize = 0;
        var vertex_count: usize = 0;
        var single_convex = false;

        for (input_paths) |p| {
            if (!validFillPath(p, points.len)) continue;
            valid_path_count += 1;
            vertex_count += p.point_count;
            single_convex = p.convex;
        }
        if (valid_path_count == 0) return;

        const call_type: CallType = if (valid_path_count == 1 and single_convex) .fill_convex else .fill;
        const cover_count: usize = if (call_type == .fill) 4 else 0;
        const total_vertices = vertex_count + cover_count;
        if (!self.ensureRoom(valid_path_count, total_vertices)) return;

        const call_path_start = self.paths.items.len;
        const call_vertex_start = self.vertices.items.len;
        var cover: Range = .{};

        if (cover_count > 0) {
            cover = .{ .start = @intCast(self.vertices.items.len), .count = 4 };
            self.appendCoverQuad(bounds);
        }

        for (input_paths) |p| {
            if (!validFillPath(p, points.len)) continue;

            const start = self.vertices.items.len;
            const path_points = points[p.point_start..][0..p.point_count];
            for (path_points) |pt| {
                self.vertices.appendAssumeCapacity(vertexFromPoint(pt));
            }
            self.paths.appendAssumeCapacity(.{
                .vertices = .{ .start = @intCast(start), .count = p.point_count },
                .winding = p.winding,
                .closed = p.closed,
                .convex = p.convex,
            });
        }

        self.calls.appendAssumeCapacity(.{
            .call_type = call_type,
            .paint = paint.*,
            .scissor = scissor.*,
            .bounds = bounds,
            .paths = .{ .start = @intCast(call_path_start), .count = @intCast(valid_path_count) },
            .vertices = .{ .start = @intCast(call_vertex_start), .count = @intCast(total_vertices) },
            .cover = cover,
        });
    }

    fn queueStroke(self: *Backend, paint: *const Paint, scissor: *const Scissor, width: f32, input_paths: []const PathRange, points: []const Point) void {
        var valid_path_count: usize = 0;
        var vertex_count: usize = 0;
        for (input_paths) |p| {
            if (!validStrokePath(p, points.len)) continue;
            valid_path_count += 1;
            vertex_count += p.point_count;
        }
        if (valid_path_count == 0) return;
        if (!self.ensureRoom(valid_path_count, vertex_count)) return;

        const call_path_start = self.paths.items.len;
        const call_vertex_start = self.vertices.items.len;
        for (input_paths) |p| {
            if (!validStrokePath(p, points.len)) continue;

            const start = self.vertices.items.len;
            const path_points = points[p.point_start..][0..p.point_count];
            for (path_points) |pt| {
                self.vertices.appendAssumeCapacity(vertexFromPoint(pt));
            }
            self.paths.appendAssumeCapacity(.{
                .vertices = .{ .start = @intCast(start), .count = p.point_count },
                .winding = p.winding,
                .closed = p.closed,
                .convex = p.convex,
            });
        }

        self.calls.appendAssumeCapacity(.{
            .call_type = .stroke,
            .paint = paint.*,
            .scissor = scissor.*,
            .width = width,
            .paths = .{ .start = @intCast(call_path_start), .count = @intCast(valid_path_count) },
            .vertices = .{ .start = @intCast(call_vertex_start), .count = @intCast(vertex_count) },
        });
    }

    fn queueTriangles(self: *Backend, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
        if (verts.len == 0) return;
        if (!self.ensureRoom(0, verts.len)) return;

        const start = self.vertices.items.len;
        self.vertices.appendSliceAssumeCapacity(verts);
        self.calls.appendAssumeCapacity(.{
            .call_type = .triangles,
            .paint = paint.*,
            .scissor = scissor.*,
            .vertices = .{ .start = @intCast(start), .count = @intCast(verts.len) },
        });
    }

    fn ensureRoom(self: *Backend, path_count: usize, vertex_count: usize) bool {
        if (vertex_count > max_vertices) return false;
        if (self.vertices.items.len + vertex_count > max_vertices) {
            self.flush();
        }
        self.calls.ensureUnusedCapacity(self.gpa, 1) catch return false;
        self.paths.ensureUnusedCapacity(self.gpa, path_count) catch return false;
        self.vertices.ensureUnusedCapacity(self.gpa, vertex_count) catch return false;
        return true;
    }

    fn appendCoverQuad(self: *Backend, bounds: [4]f32) void {
        self.vertices.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[3], .u = 0.5, .v = 1.0 });
        self.vertices.appendAssumeCapacity(.{ .x = bounds[2], .y = bounds[1], .u = 0.5, .v = 1.0 });
        self.vertices.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[3], .u = 0.5, .v = 1.0 });
        self.vertices.appendAssumeCapacity(.{ .x = bounds[0], .y = bounds[1], .u = 0.5, .v = 1.0 });
    }
};

fn from(ctx: *anyopaque) *Backend {
    return @ptrCast(@alignCast(ctx));
}

fn createTexture(ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool {
    _ = data;
    const self = from(ctx);
    self.textures.put(self.gpa, id, .{
        .id = id,
        .width = w,
        .height = h,
        .format = fmt,
    }) catch return false;
    return true;
}

fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
    _ = ctx;
    _ = id;
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = data;
}

fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
    _ = from(ctx).textures.swapRemove(id);
}

fn textureSize(ctx: *anyopaque, id: ImageId) ?[2]u32 {
    const texture = from(ctx).textures.get(id) orelse return null;
    return .{ texture.width, texture.height };
}

fn viewport(ctx: *anyopaque, width: f32, height: f32, dpr: f32) void {
    const self = from(ctx);
    self.viewport_width = width;
    self.viewport_height = height;
    self.viewport_dpr = if (dpr > 0) dpr else 1;
}

fn renderFlush(ctx: *anyopaque) void {
    from(ctx).flush();
}

fn deinit(ctx: *anyopaque) void {
    from(ctx).destroy();
}

fn fill(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
    from(ctx).queueFill(paint, scissor, bounds, paths, points);
}

fn stroke(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void {
    from(ctx).queueStroke(paint, scissor, width, paths, points);
}

fn triangles(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
    from(ctx).queueTriangles(paint, scissor, verts);
}

fn validFillPath(p: PathRange, point_len: usize) bool {
    return p.point_count >= 3 and pathInBounds(p, point_len);
}

fn validStrokePath(p: PathRange, point_len: usize) bool {
    return p.point_count >= 2 and pathInBounds(p, point_len);
}

fn pathInBounds(p: PathRange, point_len: usize) bool {
    return @as(usize, p.point_start) + @as(usize, p.point_count) <= point_len;
}

fn vertexFromPoint(p: Point) Vertex {
    return .{ .x = p.x, .y = p.y, .u = 0.5, .v = 1.0 };
}
