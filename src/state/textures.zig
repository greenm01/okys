//! The texture table — the one long-lived entity store. Dense list, monotonic
//! ids, 0 reserved as null. CRUD only; it knows nothing about backends or
//! paints.

const std = @import("std");
const image = @import("../types/image.zig");
const ImageId = image.ImageId;
const Texture = image.Texture;

pub const Textures = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Texture) = .empty,
    index_by_id: std.AutoArrayHashMapUnmanaged(ImageId, usize) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Textures {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Textures) void {
        self.index_by_id.deinit(self.gpa);
        self.list.deinit(self.gpa);
    }

    pub fn get(self: *Textures, id: ImageId) ?*Texture {
        const index = self.index_by_id.get(id) orelse return null;
        return &self.list.items[index];
    }

    pub fn getConst(self: *const Textures, id: ImageId) ?*const Texture {
        const index = self.index_by_id.get(id) orelse return null;
        return &self.list.items[index];
    }

    pub fn create(self: *Textures, width: u32, height: u32, format: image.TexFormat) !ImageId {
        if (width == 0 or height == 0) return .none;

        const id: ImageId = @enumFromInt(self.next_id);
        self.next_id += 1;
        const index = self.list.items.len;
        try self.list.append(self.gpa, .{
            .id = id,
            .width = width,
            .height = height,
            .format = format,
        });
        errdefer _ = self.list.pop();
        try self.index_by_id.put(self.gpa, id, index);
        return id;
    }

    pub fn remove(self: *Textures, id: ImageId) bool {
        if (id == .none) return false;

        const index = self.index_by_id.get(id) orelse return false;
        const last_index = self.list.items.len - 1;

        _ = self.index_by_id.swapRemove(id);
        if (index != last_index) {
            const moved = self.list.items[last_index];
            self.list.items[index] = moved;
            self.index_by_id.getPtr(moved.id).?.* = index;
        }
        _ = self.list.pop();
        return true;
    }

    pub fn size(self: *const Textures, id: ImageId) ?[2]u32 {
        const texture = self.getConst(id) orelse return null;
        return .{ texture.width, texture.height };
    }
};
