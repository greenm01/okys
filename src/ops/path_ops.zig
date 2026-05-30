//! Path-building verbs. Each appends to the command stream; flattening happens
//! later, in systems/flatten.zig. Transform application on append arrives with
//! the flatten path (Milestone 1).

const Context = @import("../state/context.zig").Context;

pub fn beginPath(ctx: *Context) void {
    ctx.commands.clear();
    ctx.cache.clear();
}

pub fn moveTo(ctx: *Context, x: f32, y: f32) void {
    ctx.commands.tag(ctx.gpa, .move_to);
    ctx.commands.float(ctx.gpa, x);
    ctx.commands.float(ctx.gpa, y);
    ctx.command_x = x;
    ctx.command_y = y;
}

pub fn lineTo(ctx: *Context, x: f32, y: f32) void {
    ctx.commands.tag(ctx.gpa, .line_to);
    ctx.commands.float(ctx.gpa, x);
    ctx.commands.float(ctx.gpa, y);
    ctx.command_x = x;
    ctx.command_y = y;
}

pub fn bezierTo(ctx: *Context, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void {
    ctx.commands.tag(ctx.gpa, .bezier_to);
    ctx.commands.float(ctx.gpa, c1x);
    ctx.commands.float(ctx.gpa, c1y);
    ctx.commands.float(ctx.gpa, c2x);
    ctx.commands.float(ctx.gpa, c2y);
    ctx.commands.float(ctx.gpa, x);
    ctx.commands.float(ctx.gpa, y);
    ctx.command_x = x;
    ctx.command_y = y;
}

pub fn closePath(ctx: *Context) void {
    ctx.commands.tag(ctx.gpa, .close);
}

pub fn rect(ctx: *Context, x: f32, y: f32, w: f32, h: f32) void {
    moveTo(ctx, x, y);
    lineTo(ctx, x, y + h);
    lineTo(ctx, x + w, y + h);
    lineTo(ctx, x + w, y);
    closePath(ctx);
}
