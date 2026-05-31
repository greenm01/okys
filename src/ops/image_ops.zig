//! Image verbs. These route to the backend's texture upload and the texture
//! table. Allocation is allowed here; images are long-lived resources.

const Context = @import("../state/context.zig").Context;
const image = @import("../types/image.zig");
const ImageId = image.ImageId;
const TexFormat = image.TexFormat;

pub fn createImageRGBA(ctx: *Context, w: u32, h: u32, data: ?[]const u8) ImageId {
    if (w == 0 or h == 0) {
        ctx.recordDiagnostic(.invalid_image_data);
        return .none;
    }
    if (data) |bytes| {
        if (bytes.len != byteLen(w, h, .rgba8)) {
            ctx.recordDiagnostic(.invalid_image_data);
            return .none;
        }
    }

    const backend = ctx.backend orelse return .none;
    const id = ctx.textures.create(w, h, .rgba8) catch return .none;
    if (!backend.create_texture(backend.ctx, id, w, h, .rgba8, data)) {
        _ = ctx.textures.remove(id);
        return .none;
    }
    return id;
}

pub fn updateImage(ctx: *Context, id: ImageId, data: []const u8) void {
    const texture = ctx.textures.get(id) orelse {
        ctx.recordDiagnostic(.invalid_image_id);
        return;
    };
    if (data.len != byteLen(texture.width, texture.height, texture.format)) {
        ctx.recordDiagnostic(.invalid_image_data);
        return;
    }

    const backend = ctx.backend orelse return;
    backend.update_texture(backend.ctx, id, 0, 0, texture.width, texture.height, data);
}

pub fn updateImageRect(ctx: *Context, id: ImageId, x: u32, y: u32, w: u32, h: u32, data: []const u8) void {
    const texture = ctx.textures.get(id) orelse {
        ctx.recordDiagnostic(.invalid_image_id);
        return;
    };
    if (w == 0 or h == 0) {
        ctx.recordDiagnostic(.out_of_range_image_rect);
        return;
    }
    if (x >= texture.width or y >= texture.height) {
        ctx.recordDiagnostic(.out_of_range_image_rect);
        return;
    }
    if (w > texture.width - x or h > texture.height - y) {
        ctx.recordDiagnostic(.out_of_range_image_rect);
        return;
    }
    if (data.len != byteLen(w, h, texture.format)) {
        ctx.recordDiagnostic(.invalid_image_data);
        return;
    }

    const backend = ctx.backend orelse return;
    backend.update_texture(backend.ctx, id, x, y, w, h, data);
}

pub fn imageSize(ctx: *Context, id: ImageId) ?[2]u32 {
    const table_size = ctx.textures.size(id) orelse return null;
    if (ctx.backend) |backend| {
        if (backend.texture_size(backend.ctx, id)) |size| return size;
    }
    return table_size;
}

pub fn deleteImage(ctx: *Context, id: ImageId) void {
    if (id == .none) return;
    if (ctx.textures.get(id) == null) {
        ctx.recordDiagnostic(.invalid_image_id);
        return;
    }

    if (ctx.backend) |backend| {
        backend.delete_texture(backend.ctx, id);
    }
    _ = ctx.textures.remove(id);
}

fn byteLen(w: u32, h: u32, format: TexFormat) usize {
    const pixels: usize = @as(usize, w) * @as(usize, h);
    return switch (format) {
        .rgba8 => pixels * 4,
        .a8 => pixels,
    };
}
