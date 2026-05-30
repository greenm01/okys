//! Internal backend selection. The public C ABI still exposes only creation
//! flags; this module resolves those flags to the backend Okys should request.

pub const BackendKind = enum(u8) {
    stencil_cover,
    sparse_strip,
};

const OKY_SPARSE_STRIP: u32 = 1 << 2;

pub fn fromCreateFlags(flags: u32) BackendKind {
    if ((flags & OKY_SPARSE_STRIP) != 0) return .sparse_strip;
    return .stencil_cover;
}
