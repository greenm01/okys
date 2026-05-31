//! The render interface. Fill paths cross as flattened polylines; strokes cross
//! as shared outline polygons. Both backends implement this vtable; the
//! front-end never knows which one is live.

const color = @import("../types/color.zig");
const Paint = color.Paint;
const Scissor = color.Scissor;
const path = @import("../types/path.zig");
const ClipRule = path.ClipRule;
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
    create_texture: *const fn (ctx: *anyopaque, id: ImageId, w: u32, h: u32, fmt: TexFormat, data: ?[]const u8) bool,
    update_texture: *const fn (ctx: *anyopaque, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void,
    delete_texture: *const fn (ctx: *anyopaque, id: ImageId) void,
    texture_size: *const fn (ctx: *anyopaque, id: ImageId) ?[2]u32,
    viewport: *const fn (ctx: *anyopaque, width: f32, height: f32, dpr: f32) void,
    flush: *const fn (ctx: *anyopaque) void,
    deinit: *const fn (ctx: *anyopaque) void,

    // draw — paths cross here before backend-specific tessellation or coverage.
    fill: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, bounds: [4]f32, paths: []const PathRange, points: []const Point) void,
    stroke: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, width: f32, paths: []const PathRange, points: []const Point) void,
    triangles: *const fn (ctx: *anyopaque, paint: *const Paint, scissor: *const Scissor, verts: []const Vertex) void,
    push_clip_path: *const fn (ctx: *anyopaque, rule: ClipRule, bounds: [4]f32, paths: []const PathRange, points: []const Point) void,
    pop_clip_path: *const fn (ctx: *anyopaque) void,
};
