//! Internal backend selection. The public C ABI still exposes only creation
//! flags; this module resolves those flags to the backend Okys should request.

pub const BackendKind = enum(u8) {
    stencil_cover,
    sparse_strip,
};

pub fn fromCreateFlags(flags: u32) BackendKind {
    _ = flags;
    return .stencil_cover;
}
