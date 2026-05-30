//! State-stack verbs. save/restore push and pop; reset rewrites the top.

const Context = @import("../state/context.zig").Context;
const State = @import("../state/draw_state.zig").State;

pub fn save(ctx: *Context) void {
    const top = ctx.state().*;
    ctx.states.append(ctx.gpa, top) catch {};
}

pub fn restore(ctx: *Context) void {
    // Always keep one state on the stack.
    if (ctx.states.items.len <= 1) return;
    _ = ctx.states.pop();
}

pub fn reset(ctx: *Context) void {
    ctx.state().* = State.default();
}
