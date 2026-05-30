//! The texture table — the one long-lived entity store. Dense list, monotonic
//! ids, 0 reserved as null. CRUD only; it knows nothing about backends or
//! paints. See AGENTS/okys/dod.md, "Storage".

const std = @import("std");
const image = @import("../types/image.zig");
const ImageId = image.ImageId;
const Texture = image.Texture;

pub const Textures = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Texture) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Textures {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Textures) void {
        self.list.deinit(self.gpa);
    }

    pub fn get(self: *Textures, id: ImageId) ?*Texture {
        for (self.list.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    // create/update/delete arrive with the backend (Milestone 1); they will
    // allocate the GPU resource and return the issued ImageId.
};
