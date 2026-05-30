//! Sparse-strip backend CPU proof: encode, bin, coarse strips, scalar fine coverage.

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

pub const encode = @import("encode.zig");
pub const bin = @import("bin.zig");
pub const coarse = @import("coarse.zig");
pub const fine = @import("fine.zig");
pub const strip = @import("strip.zig");

pub const EncodedCall = encode.EncodedCall;
pub const Segment = encode.Segment;
pub const Strip = strip.Strip;
pub const TileRef = strip.TileRef;
pub const FillRule = strip.FillRule;

pub const Backend = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList(EncodedCall) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    tiles: std.ArrayList(TileRef) = .empty,
    strips: std.ArrayList(Strip) = .empty,
    strip_segment_indices: std.ArrayList(u32) = .empty,
    alphas: std.ArrayList(u8) = .empty,
    surface: std.ArrayList(u8) = .empty,
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
        self.segments.deinit(gpa);
        self.tiles.deinit(gpa);
        self.strips.deinit(gpa);
        self.strip_segment_indices.deinit(gpa);
        self.alphas.deinit(gpa);
        self.surface.deinit(gpa);
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
        _ = self.build();
        self.flush_count += 1;
        self.clearQueued();
    }

    pub fn build(self: *Backend) bool {
        bin.build(self.gpa, self.viewport_width, self.viewport_height, self.calls.items, self.segments.items, &self.tiles) catch return false;
        coarse.build(self.gpa, self.tiles.items, &self.strips, &self.strip_segment_indices) catch return false;
        fine.build(
            self.gpa,
            self.fill_rule,
            self.viewport_width,
            self.viewport_height,
            self.calls.items,
            self.segments.items,
            self.strip_segment_indices.items,
            &self.strips,
            &self.alphas,
            &self.surface,
        ) catch return false;
        return true;
    }

    pub fn clearQueued(self: *Backend) void {
        self.calls.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.tiles.clearRetainingCapacity();
        self.strips.clearRetainingCapacity();
        self.strip_segment_indices.clearRetainingCapacity();
        self.alphas.clearRetainingCapacity();
    }

    fn queuePath(self: *Backend, kind: strip.CallKind, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, width: f32, paths: []const PathRange, points: []const Point) void {
        const call_index: u32 = @intCast(self.calls.items.len);
        const range = encode.appendPathSegments(&self.segments, self.gpa, call_index, paths, points) catch return;
        if (range.count == 0) return;
        self.calls.append(self.gpa, .{
            .kind = kind,
            .paint = paint.*,
            .scissor = scissor.*,
            .bounds = bounds,
            .width = width,
            .segments = range,
            .convex = singleConvexPath(paths, points.len),
        }) catch {
            self.segments.shrinkRetainingCapacity(@intCast(range.start));
        };
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
    from(ctx).queuePath(.fill, paint, scissor, bounds, 0, paths, points);
}

fn stroke(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void {
    from(ctx).queuePath(.stroke, paint, scissor, .{ 0, 0, 0, 0 }, width, paths, points);
}

fn triangles(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
    const self = from(ctx);
    if (verts.len < 3) return;
    const call_index: u32 = @intCast(self.calls.items.len);
    const range = encode.appendTriangleSegments(&self.segments, self.gpa, call_index, verts) catch return;
    if (range.count == 0) return;
    self.calls.append(self.gpa, .{
        .kind = .triangles,
        .paint = paint.*,
        .scissor = scissor.*,
        .segments = range,
    }) catch {
        self.segments.shrinkRetainingCapacity(@intCast(range.start));
    };
}

fn singleConvexPath(paths: []const PathRange, point_len: usize) bool {
    var valid: usize = 0;
    var convex = false;
    for (paths) |p| {
        if (!p.closed or p.point_count < 3) continue;
        if (@as(usize, p.point_start) + @as(usize, p.point_count) > point_len) continue;
        valid += 1;
        convex = p.convex;
    }
    return valid == 1 and convex;
}
