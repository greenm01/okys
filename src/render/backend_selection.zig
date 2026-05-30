//! Internal backend selection. The public C ABI still exposes only creation
//! flags; this module resolves those flags to the backend Okys should request.

pub const BackendKind = enum(u8) {
    plan_a,
    plan_b,
};

pub fn fromCreateFlags(flags: u32) BackendKind {
    _ = flags;
    return .plan_a;
}
