//! Path command tags. The front-end records the imperative API call stream as
//! a flat buffer of these (see state/commands.zig). Matches the original C
//! NanoVG command set — no `clip`; clipping is scissor-only (spec §4).

pub const Command = enum(u8) {
    move_to = 0,
    line_to = 1,
    bezier_to = 2,
    close = 3,
    winding = 4,
};
