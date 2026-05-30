//! The render interface. Flattened polylines, paint, and scissor cross here;
//! never expanded meshes. Both backends implement this vtable; the front-end
//! never knows which one is live.

const color = @import("../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const path = @import("../types/path.zig");
const Point = path.Point;
const PathRange = path.PathRange;
const Vertex = path.Vertex;
const image = @import("../types/image.zig");
const ImageId = image.ImageId;
const TexFormat = image.TexFormat;

pub const RenderInterface = struct {
    /// Backend-owned state; passed back to every callback.
    ctx: *anyopaque,

    // device + textures
    create_texture: *const fn (ctx: *anyopaque, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) ImageId,
    update_texture: *const fn (ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void,
    delete_texture: *const fn (ctx: *anyopaque, id: ImageId) void,
    viewport: *const fn (ctx: *anyopaque, width: f32, height: f32, dpr: f32) void,
    flush: *const fn (ctx: *anyopaque) void,
    deinit: *const fn (ctx: *anyopaque) void,

    // draw — flattened polylines cross here, not meshes
    fill: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void,
    stroke: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void,
    triangles: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void,
};
