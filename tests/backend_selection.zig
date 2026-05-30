const testing = @import("std").testing;

const okys = @import("okys");
const mock_backend = @import("mock_backend.zig");

const Context = okys.state.context.Context;
const selection = okys.render.backend_selection;

const OKY_ANTIALIAS: u32 = 1 << 0;
const OKY_STENCIL_STROKES: u32 = 1 << 1;
const OKY_SPARSE_STRIP: u32 = 1 << 2;

test "create flags select requested backend kind" {
    try testing.expectEqual(selection.BackendKind.stencil_cover, selection.fromCreateFlags(0));
    try testing.expectEqual(selection.BackendKind.stencil_cover, selection.fromCreateFlags(OKY_ANTIALIAS));
    try testing.expectEqual(selection.BackendKind.stencil_cover, selection.fromCreateFlags(OKY_STENCIL_STROKES));
    try testing.expectEqual(selection.BackendKind.stencil_cover, selection.fromCreateFlags(OKY_ANTIALIAS | OKY_STENCIL_STROKES));
    try testing.expectEqual(selection.BackendKind.sparse_strip, selection.fromCreateFlags(OKY_SPARSE_STRIP));
    try testing.expectEqual(selection.BackendKind.sparse_strip, selection.fromCreateFlags(OKY_SPARSE_STRIP | OKY_ANTIALIAS));
}

test "context stores selected backend kind at creation" {
    const ctx = try Context.create(testing.allocator, OKY_ANTIALIAS | OKY_STENCIL_STROKES);
    defer ctx.destroy();

    try testing.expectEqual(selection.BackendKind.stencil_cover, ctx.backend_kind);

    const sparse_ctx = try Context.create(testing.allocator, OKY_SPARSE_STRIP);
    defer sparse_ctx.destroy();
    try testing.expectEqual(selection.BackendKind.sparse_strip, sparse_ctx.backend_kind);
}

test "context install and clear own backend lifecycle" {
    var first: mock_backend.MockBackend = .{};
    var second: mock_backend.MockBackend = .{};
    const ctx = try Context.create(testing.allocator, 0);
    defer ctx.destroy();

    ctx.installBackend(first.interface());
    try testing.expect(ctx.backend != null);
    try testing.expectEqual(@as(usize, 0), first.deinit_calls);

    ctx.installBackend(second.interface());
    try testing.expectEqual(@as(usize, 1), first.deinit_calls);
    try testing.expectEqual(@as(usize, 0), second.deinit_calls);

    ctx.clearBackend();
    try testing.expect(ctx.backend == null);
    try testing.expectEqual(@as(usize, 1), second.deinit_calls);
}
