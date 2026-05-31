//! Internal glyph handles and metrics for the atlas-backed text lane.

/// Logical glyph id. 0 is null and never a valid handle.
pub const GlyphId = enum(u32) {
    none = 0,
    _,
};

pub const GlyphMetrics = struct {
    width: u32 = 0,
    height: u32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    advance_x: f32 = 0,
    advance_y: f32 = 0,
};

pub const GlyphRecord = struct {
    id: GlyphId = .none,
    atlas_x: u32 = 0,
    atlas_y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    advance_x: f32 = 0,
    advance_y: f32 = 0,

    pub fn metrics(self: GlyphRecord) GlyphMetrics {
        return .{
            .width = self.width,
            .height = self.height,
            .offset_x = self.offset_x,
            .offset_y = self.offset_y,
            .advance_x = self.advance_x,
            .advance_y = self.advance_y,
        };
    }
};
