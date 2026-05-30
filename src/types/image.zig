//! Image/texture identity and record. Textures are the one long-lived entity
//! table in okys; everything else is per-frame arena data. See
//! AGENTS/okys/dod.md, "Storage".

/// Logical texture id. 0 is null and never a valid handle.
pub const ImageId = enum(u32) {
    none = 0,
    _,
};

pub const TexFormat = enum(i32) {
    rgba8 = 0,
    a8 = 1,
};

/// A texture record. The GPU handle field arrives with the backend
/// (Milestone 1); for now this is identity plus dimensions.
pub const Texture = struct {
    id: ImageId,
    width: u32,
    height: u32,
    format: TexFormat,
};
