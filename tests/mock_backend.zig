const okys = @import("okys");

const Paint = okys.types.color.Paint;
const Scissor = okys.types.color.Scissor;
const ImageId = okys.types.image.ImageId;
const TexFormat = okys.types.image.TexFormat;
const ClipRule = okys.types.path.ClipRule;
const Point = okys.types.path.Point;
const PathRange = okys.types.path.PathRange;
const Vertex = okys.types.path.Vertex;
const RenderInterface = okys.render.interface.RenderInterface;

pub const DrawCall = struct {
    paint: Paint = undefined,
    scissor: Scissor = undefined,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    width: f32 = 0,
    path_count: usize = 0,
    point_count: usize = 0,
    paths_ptr: usize = 0,
    points_ptr: usize = 0,
};

pub const TriangleCall = struct {
    paint: Paint = undefined,
    scissor: Scissor = undefined,
    vertex_count: usize = 0,
    verts_ptr: usize = 0,
    first_vertex: Vertex = .{ .x = 0, .y = 0, .u = 0, .v = 0 },
};

pub const ClipCall = struct {
    rule: ClipRule = .nonzero,
    bounds: [4]f32 = .{ 0, 0, 0, 0 },
    path_count: usize = 0,
    point_count: usize = 0,
    paths_ptr: usize = 0,
    points_ptr: usize = 0,
};

pub const MockBackend = struct {
    viewport_calls: usize = 0,
    flush_calls: usize = 0,
    deinit_calls: usize = 0,
    fill_calls: usize = 0,
    stroke_calls: usize = 0,
    triangles_calls: usize = 0,
    push_clip_path_calls: usize = 0,
    pop_clip_path_calls: usize = 0,
    clip_depth: usize = 0,
    max_clip_depth: usize = 0,
    create_texture_calls: usize = 0,
    update_texture_calls: usize = 0,
    delete_texture_calls: usize = 0,
    texture_size_calls: usize = 0,
    fail_create_texture: bool = false,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_dpr: f32 = 0,
    last_texture_id: ImageId = .none,
    last_texture_width: u32 = 0,
    last_texture_height: u32 = 0,
    last_texture_format: TexFormat = .rgba8,
    last_texture_data_len: usize = 0,
    last_update_id: ImageId = .none,
    last_update_width: u32 = 0,
    last_update_height: u32 = 0,
    last_update_data_len: usize = 0,
    last_deleted_id: ImageId = .none,
    last_fill: DrawCall = .{},
    last_stroke: DrawCall = .{},
    last_triangles: TriangleCall = .{},
    last_clip: ClipCall = .{},

    pub fn interface(self: *MockBackend) RenderInterface {
        return .{
            .ctx = self,
            .create_texture = createTexture,
            .update_texture = updateTexture,
            .delete_texture = deleteTexture,
            .texture_size = textureSize,
            .viewport = viewport,
            .flush = flush,
            .deinit = deinit,
            .fill = fill,
            .stroke = stroke,
            .triangles = triangles,
            .push_clip_path = pushClipPath,
            .pop_clip_path = popClipPath,
        };
    }

    fn from(ctx: *anyopaque) *MockBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn createTexture(ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool {
        const self = from(ctx);
        self.create_texture_calls += 1;
        self.last_texture_id = id;
        self.last_texture_width = w;
        self.last_texture_height = h;
        self.last_texture_format = fmt;
        self.last_texture_data_len = if (data) |bytes| bytes.len else 0;
        return !self.fail_create_texture;
    }

    fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
        _ = x;
        _ = y;
        const self = from(ctx);
        self.update_texture_calls += 1;
        self.last_update_id = id;
        self.last_update_width = w;
        self.last_update_height = h;
        self.last_update_data_len = data.len;
    }

    fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
        const self = from(ctx);
        self.delete_texture_calls += 1;
        self.last_deleted_id = id;
    }

    fn textureSize(ctx: *anyopaque, id: ImageId) ?[2]u32 {
        const self = from(ctx);
        self.texture_size_calls += 1;
        if (self.last_texture_id != id) return null;
        return .{ self.last_texture_width, self.last_texture_height };
    }

    fn viewport(ctx: *anyopaque, width: f32, height: f32, dpr: f32) void {
        const self = from(ctx);
        self.viewport_calls += 1;
        self.viewport_width = width;
        self.viewport_height = height;
        self.viewport_dpr = dpr;
    }

    fn flush(ctx: *anyopaque) void {
        from(ctx).flush_calls += 1;
    }

    fn deinit(ctx: *anyopaque) void {
        from(ctx).deinit_calls += 1;
    }

    fn fill(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
        const self = from(ctx);
        self.fill_calls += 1;
        self.last_fill = drawCall(paint, scissor, bounds, 0, paths, points);
    }

    fn stroke(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void {
        const self = from(ctx);
        self.stroke_calls += 1;
        self.last_stroke = drawCall(paint, scissor, .{ 0, 0, 0, 0 }, width, paths, points);
    }

    fn triangles(ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void {
        const self = from(ctx);
        self.triangles_calls += 1;
        self.last_triangles = .{
            .paint = paint.*,
            .scissor = scissor.*,
            .vertex_count = verts.len,
            .verts_ptr = if (verts.len > 0) @intFromPtr(verts.ptr) else 0,
            .first_vertex = if (verts.len > 0) verts[0] else .{ .x = 0, .y = 0, .u = 0, .v = 0 },
        };
    }

    fn pushClipPath(ctx: *anyopaque, rule: ClipRule, bounds: [4]f32, paths: []const PathRange, points: []const Point) void {
        const self = from(ctx);
        self.push_clip_path_calls += 1;
        self.clip_depth += 1;
        self.max_clip_depth = @max(self.max_clip_depth, self.clip_depth);
        self.last_clip = clipCall(rule, bounds, paths, points);
    }

    fn popClipPath(ctx: *anyopaque) void {
        const self = from(ctx);
        self.pop_clip_path_calls += 1;
        self.clip_depth -|= 1;
    }
};

fn drawCall(paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, width: f32, paths: []const PathRange, points: []const Point) DrawCall {
    return .{
        .paint = paint.*,
        .scissor = scissor.*,
        .bounds = bounds,
        .width = width,
        .path_count = paths.len,
        .point_count = points.len,
        .paths_ptr = if (paths.len > 0) @intFromPtr(paths.ptr) else 0,
        .points_ptr = if (points.len > 0) @intFromPtr(points.ptr) else 0,
    };
}

fn clipCall(rule: ClipRule, bounds: [4]f32, paths: []const PathRange, points: []const Point) ClipCall {
    return .{
        .rule = rule,
        .bounds = bounds,
        .path_count = paths.len,
        .point_count = points.len,
        .paths_ptr = if (paths.len > 0) @intFromPtr(paths.ptr) else 0,
        .points_ptr = if (points.len > 0) @intFromPtr(points.ptr) else 0,
    };
}
