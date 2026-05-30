const okys = @import("okys");

const Paint = okys.types.color.Paint;
const Scissor = okys.types.color.Scissor;
const ImageId = okys.types.image.ImageId;
const TexFormat = okys.types.image.TexFormat;
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

pub const MockBackend = struct {
    viewport_calls: usize = 0,
    flush_calls: usize = 0,
    deinit_calls: usize = 0,
    fill_calls: usize = 0,
    stroke_calls: usize = 0,
    triangles_calls: usize = 0,
    create_texture_calls: usize = 0,
    update_texture_calls: usize = 0,
    delete_texture_calls: usize = 0,

    viewport_width: f32 = 0,
    viewport_height: f32 = 0,
    viewport_dpr: f32 = 0,
    last_fill: DrawCall = .{},
    last_stroke: DrawCall = .{},

    pub fn interface(self: *MockBackend) RenderInterface {
        return .{
            .ctx = self,
            .create_texture = createTexture,
            .update_texture = updateTexture,
            .delete_texture = deleteTexture,
            .viewport = viewport,
            .flush = flush,
            .deinit = deinit,
            .fill = fill,
            .stroke = stroke,
            .triangles = triangles,
        };
    }

    fn from(ctx: *anyopaque) *MockBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn createTexture(ctx: *anyopaque, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) ImageId {
        _ = w;
        _ = h;
        _ = fmt;
        _ = data;
        const self = from(ctx);
        self.create_texture_calls += 1;
        return @enumFromInt(self.create_texture_calls);
    }

    fn updateTexture(ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
        _ = id;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = data;
        from(ctx).update_texture_calls += 1;
    }

    fn deleteTexture(ctx: *anyopaque, id: ImageId) void {
        _ = id;
        from(ctx).delete_texture_calls += 1;
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
        _ = paint;
        _ = scissor;
        _ = verts;
        from(ctx).triangles_calls += 1;
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
