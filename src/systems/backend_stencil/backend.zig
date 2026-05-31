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
const ClipRule = path.ClipRule;
const PathRange = path.PathRange;
const Point = path.Point;
const Vertex = path.Vertex;
const RenderInterface = @import("../../render/interface.zig").RenderInterface;
const sokol_device = @import("../../render/sokol_device.zig");
pub const draw_plan = @import("draw_plan.zig");
pub const replay = @import("replay.zig");

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;

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
pub const Device = sokol_device.Device;
pub const Pass = sokol_device.Pass;
pub const PathDraw = sokol_device.PathDraw;
pub const StencilDraw = sokol_device.StencilDraw;
pub const CoverDraw = sokol_device.CoverDraw;
pub const PathFsParams = sokol_device.PathFsParams;

const StencilTexture = struct {
    texture: Texture,
    pixels: std.ArrayList(u8) = .empty,
    generation: u64 = 1,

    fn deinit(self: *StencilTexture, gpa: std.mem.Allocator) void {
        self.pixels.deinit(gpa);
    }

    fn view(self: *const StencilTexture) sokol_device.PathTexture {
        return .{
            .id = @intFromEnum(self.texture.id),
            .width = self.texture.width,
            .height = self.texture.height,
            .format = self.texture.format,
            .pixels = self.pixels.items,
            .generation = self.generation,
        };
    }

    fn markChanged(self: *StencilTexture) void {
        self.generation = if (self.generation == std.math.maxInt(u64)) 1 else self.generation + 1;
    }
};

pub const Backend = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(Call) = .empty,
    paths: std.ArrayList(QueuedPath) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u16) = .empty,
    uniforms: std.ArrayList(PaintUniform) = .empty,
    draw_ops: std.ArrayList(DrawOp) = .empty,
    path_draws: std.ArrayList(PathDraw) = .empty,
    stencil_draws: std.ArrayList(StencilDraw) = .empty,
    cover_draws: std.ArrayList(CoverDraw) = .empty,
    frag_params: std.ArrayList(PathFsParams) = .empty,
    textures: std.AutoArrayHashMapUnmanaged(ImageId, StencilTexture) = .empty,
    texture_views: std.ArrayList(sokol_device.PathTexture) = .empty,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_dpr: f32 = 1,
    fill_rule: FillRule = .nonzero,
    antialias: bool = false,
    stencil_strokes: bool = false,
    flush_count: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    clip_push_count: usize = 0,
    clip_pop_count: usize = 0,
    last_clip_rule: ClipRule = .nonzero,
    last_clip_bounds: [4]f32 = .{ 0, 0, 0, 0 },
    last_clip_path_count: usize = 0,
    last_clip_point_count: usize = 0,

    pub fn create(gpa: std.mem.Allocator) !*Backend {
        return createWithFlags(gpa, 0);
    }

    pub fn createWithFlags(gpa: std.mem.Allocator, flags: u32) !*Backend {
        const self = try gpa.create(Backend);
        self.* = .{
            .gpa = gpa,
            .antialias = (flags & OKY_ANTIALIAS) != 0,
            .stencil_strokes = (flags & OKY_STENCIL_STROKES) != 0,
        };
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
        self.path_draws.deinit(gpa);
        self.stencil_draws.deinit(gpa);
        self.cover_draws.deinit(gpa);
        self.frag_params.deinit(gpa);
        for (self.textures.values()) |*texture| {
            texture.deinit(gpa);
        }
        self.textures.deinit(gpa);
        self.texture_views.deinit(gpa);
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
            .push_clip_path = pushClipPath,
            .pop_clip_path = popClipPath,
        };
    }

    pub fn flush(self: *Backend) void {
        _ = self.buildStencilPass();
        self.flush_count += 1;
        self.clearQueued();
    }

    pub fn submitToDevice(self: *Backend, device: *Device, pass: Pass) bool {
        if (!self.buildStencilPass()) return false;
        self.rebuildTextureViews() catch return false;
        device.drawPathPassWithTextures(
            pass,
            self.vertices.items,
            self.indices.items,
            self.path_draws.items,
            self.frag_params.items,
            self.texture_views.items,
            self.viewport_width,
            self.viewport_height,
        );
        return true;
    }

    pub fn clearQueued(self: *Backend) void {
        self.calls.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.uniforms.clearRetainingCapacity();
        self.draw_ops.clearRetainingCapacity();
        self.path_draws.clearRetainingCapacity();
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
            &self.path_draws,
            &self.stencil_draws,
            &self.cover_draws,
            &self.frag_params,
        ) catch return false;
        return true;
    }

    fn rebuildTextureViews(self: *Backend) !void {
        self.texture_views.clearRetainingCapacity();
        try self.texture_views.ensureTotalCapacity(self.gpa, self.textures.count());
        for (self.textures.values()) |*texture| {
            self.texture_views.appendAssumeCapacity(texture.view());
        }
    }

    fn queueFill(self: *Backend, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, input_paths: []const PathRange, points: []const Point) void {
        var valid_path_count: usize = 0;
        var vertex_count: usize = 0;
        var single_convex = false;
        const fringe_width = self.fringeWidth();

        for (input_paths) |p| {
            if (!validFillPath(p, points.len)) continue;
            valid_path_count += 1;
            vertex_count += self.fillVertexCount(p.point_count);
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
            self.appendFillVertices(path_points, fringe_width);
            const fill_count = self.vertices.items.len - start;
            var fringe: Range = .{};
            if (self.antialias) {
                const fringe_start = self.vertices.items.len;
                self.appendFillFringe(path_points, fringe_width);
                fringe = .{
                    .start = @intCast(fringe_start),
                    .count = @intCast(self.vertices.items.len - fringe_start),
                };
            }
            self.paths.appendAssumeCapacity(.{
                .vertices = .{ .start = @intCast(start), .count = @intCast(fill_count) },
                .fringe = fringe,
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
            .antialias = self.antialias,
        });
    }

    fn queueStroke(self: *Backend, paint: *const Paint, scissor: *const Scissor, width: f32, input_paths: []const PathRange, points: []const Point) void {
        var valid_path_count: usize = 0;
        var vertex_count: usize = 0;
        var single_convex = false;
        var bounds = Bounds.empty();
        const fringe_width = self.fringeWidth();

        for (input_paths) |p| {
            if (!validStrokePath(p, points.len)) continue;
            valid_path_count += 1;
            vertex_count += self.fillVertexCount(p.point_count);
            single_convex = p.convex;
            bounds.includePath(points[p.point_start..][0..p.point_count]);
        }
        if (valid_path_count == 0) return;

        const direct_convex = valid_path_count == 1 and single_convex and !self.stencil_strokes;
        const call_type: CallType = if (direct_convex) .stroke_convex else .stroke;
        const cover_count: usize = if (call_type == .stroke) 4 else 0;
        const total_vertices = vertex_count + cover_count;
        if (!self.ensureRoom(valid_path_count, total_vertices)) return;

        const call_path_start = self.paths.items.len;
        const call_vertex_start = self.vertices.items.len;
        var cover: Range = .{};

        if (cover_count > 0) {
            cover = .{ .start = @intCast(self.vertices.items.len), .count = 4 };
            self.appendCoverQuad(bounds.expanded(fringe_width));
        }

        for (input_paths) |p| {
            if (!validStrokePath(p, points.len)) continue;

            const start = self.vertices.items.len;
            const path_points = points[p.point_start..][0..p.point_count];
            self.appendFillVertices(path_points, fringe_width);
            const stroke_count = self.vertices.items.len - start;
            var fringe: Range = .{};
            if (self.antialias) {
                const fringe_start = self.vertices.items.len;
                self.appendFillFringe(path_points, fringe_width);
                fringe = .{
                    .start = @intCast(fringe_start),
                    .count = @intCast(self.vertices.items.len - fringe_start),
                };
            }
            self.paths.appendAssumeCapacity(.{
                .vertices = .{ .start = @intCast(start), .count = @intCast(stroke_count) },
                .fringe = fringe,
                .winding = p.winding,
                .closed = p.closed,
                .convex = p.convex,
            });
        }

        self.calls.appendAssumeCapacity(.{
            .call_type = call_type,
            .paint = paint.*,
            .scissor = scissor.*,
            .width = width,
            .bounds = bounds.expanded(fringe_width),
            .paths = .{ .start = @intCast(call_path_start), .count = @intCast(valid_path_count) },
            .vertices = .{ .start = @intCast(call_vertex_start), .count = @intCast(total_vertices) },
            .cover = cover,
            .antialias = self.antialias,
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

    fn fillVertexCount(self: *const Backend, point_count: u32) usize {
        var count: usize = point_count;
        if (self.antialias) {
            count += @as(usize, point_count) * 2 + 2;
        }
        return count;
    }

    fn fringeWidth(self: *const Backend) f32 {
        return 1.0 / if (self.viewport_dpr > 0) self.viewport_dpr else 1.0;
    }

    fn appendFillVertices(self: *Backend, pts: []const Point, fringe_width: f32) void {
        if (!self.antialias) {
            for (pts) |pt| {
                self.vertices.appendAssumeCapacity(vertexFromPoint(pt));
            }
            return;
        }

        const woff = fringe_width * 0.5;
        for (pts) |pt| {
            self.vertices.appendAssumeCapacity(.{
                .x = pt.x + pt.dmx * woff,
                .y = pt.y + pt.dmy * woff,
                .u = 0.5,
                .v = 1.0,
            });
        }
    }

    fn appendFillFringe(self: *Backend, pts: []const Point, fringe_width: f32) void {
        const woff = fringe_width * 0.5;
        for (pts) |pt| {
            appendFringePair(self, pt, woff);
        }
        appendFringePair(self, pts[0], woff);
    }

    fn appendFringePair(self: *Backend, pt: Point, woff: f32) void {
        self.vertices.appendAssumeCapacity(.{
            .x = pt.x + pt.dmx * woff,
            .y = pt.y + pt.dmy * woff,
            .u = 0.5,
            .v = 1.0,
        });
        self.vertices.appendAssumeCapacity(.{
            .x = pt.x - pt.dmx * woff,
            .y = pt.y - pt.dmy * woff,
            .u = 0.0,
            .v = 1.0,
        });
    }
};

fn from(ctx: *anyopaque) *Backend {
    return @ptrCast(@alignCast(ctx));
}

fn createTexture(ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool {
    const self = from(ctx);
    var texture: StencilTexture = .{
        .texture = .{
            .id = id,
            .width = w,
            .height = h,
            .format = fmt,
        },
    };
    const len = byteLen(w, h, fmt) orelse return false;
    if (data) |bytes| {
        if (bytes.len != len) return false;
        texture.pixels.appendSlice(self.gpa, bytes) catch return false;
    } else {
        texture.pixels.resize(self.gpa, len) catch return false;
        @memset(texture.pixels.items, 0);
    }
    errdefer texture.deinit(self.gpa);
    self.textures.put(self.gpa, id, texture) catch return false;
    return true;
}

fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
    const self = from(ctx);
    const texture = self.textures.getPtr(id) orelse return;
    const bpp = bytesPerPixel(texture.texture.format) orelse return;
    if (w == 0 or h == 0) return;
    if (x + w > texture.texture.width or y + h > texture.texture.height) return;
    const row_bytes: usize = @as(usize, w) * bpp;
    if (data.len != row_bytes * @as(usize, h)) return;

    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src = @as(usize, row) * row_bytes;
        const dst = (@as(usize, y + row) * @as(usize, texture.texture.width) + x) * bpp;
        @memcpy(texture.pixels.items[dst..][0..row_bytes], data[src..][0..row_bytes]);
    }
    texture.markChanged();
}

fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
    const self = from(ctx);
    if (self.textures.fetchSwapRemove(id)) |entry| {
        var texture = entry.value;
        texture.deinit(self.gpa);
    }
}

fn textureSize(ctx: *anyopaque, id: ImageId) ?[2]u32 {
    const texture = from(ctx).textures.get(id) orelse return null;
    return .{ texture.texture.width, texture.texture.height };
}

fn byteLen(w: u32, h: u32, fmt: TexFormat) ?usize {
    const bpp = bytesPerPixel(fmt) orelse return null;
    return @as(usize, w) * @as(usize, h) * bpp;
}

fn bytesPerPixel(fmt: TexFormat) ?usize {
    return switch (fmt) {
        .rgba8 => 4,
        .a8 => 1,
    };
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

fn pushClipPath(ctx: *anyopaque, rule: ClipRule, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
    const self = from(ctx);
    self.clip_push_count += 1;
    self.clip_depth += 1;
    self.max_clip_depth = @max(self.max_clip_depth, self.clip_depth);
    self.last_clip_rule = rule;
    self.last_clip_bounds = bounds;
    self.last_clip_path_count = paths.len;
    self.last_clip_point_count = points.len;
}

fn popClipPath(ctx: *anyopaque) void {
    const self = from(ctx);
    self.clip_pop_count += 1;
    self.clip_depth -|= 1;
}

fn validFillPath(p: PathRange, point_len: usize) bool {
    return p.point_count >= 3 and pathInBounds(p, point_len);
}

fn validStrokePath(p: PathRange, point_len: usize) bool {
    return p.point_count >= 3 and pathInBounds(p, point_len);
}

fn pathInBounds(p: PathRange, point_len: usize) bool {
    return @as(usize, p.point_start) + @as(usize, p.point_count) <= point_len;
}

fn vertexFromPoint(p: Point) Vertex {
    return .{ .x = p.x, .y = p.y, .u = 0.5, .v = 1.0 };
}

const Bounds = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    fn empty() Bounds {
        return .{
            .min_x = 1e6,
            .min_y = 1e6,
            .max_x = -1e6,
            .max_y = -1e6,
        };
    }

    fn includePath(self: *Bounds, pts: []const Point) void {
        for (pts) |pt| {
            self.min_x = @min(self.min_x, pt.x);
            self.min_y = @min(self.min_y, pt.y);
            self.max_x = @max(self.max_x, pt.x);
            self.max_y = @max(self.max_y, pt.y);
        }
    }

    fn expanded(self: Bounds, amount: f32) [4]f32 {
        if (self.min_x > self.max_x or self.min_y > self.max_y) return .{ 0, 0, 0, 0 };
        return .{
            self.min_x - amount,
            self.min_y - amount,
            self.max_x + amount,
            self.max_y + amount,
        };
    }
};
