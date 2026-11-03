const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const testing = std.testing;

fn emptyState() !core.DocumentState {
    const base = try testing.allocator.dupe(u8, ".");
    errdefer testing.allocator.free(base);
    const path = try testing.allocator.dupe(u8, "workspace.ss");
    errdefer testing.allocator.free(path);
    const source = try testing.allocator.dupe(u8, "");
    errdefer testing.allocator.free(source);
    return core.DocumentState.init(testing.allocator, base, path, source, ast.Module.init());
}

test "layout workspace diagnostics release messages when origin cloning fails" {
    for ([_]core.DiagnosticSeverity{ .warning, .@"error" }) |severity| {
        var state = try emptyState();
        defer state.deinit();
        const page = try state.addPage("Page");
        state.getNode(page).?.origin = core.SourceOrigin.at("origin.ss", .{ .start = 1, .end = 4 });
        var workspace = try core.layout.Workspace.init(testing.allocator, &state, .{ .page_id = page });
        defer workspace.deinit();
        const data: core.Diagnostic.Data = .{
            .user_report = .{ .code = "Example", .message = try testing.allocator.dupe(u8, "owned before origin cloning") },
        };
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
        workspace.allocator = failing.allocator();
        defer workspace.allocator = testing.allocator;
        const result = if (severity == .warning)
            workspace.addLayoutWarning(page, page, data)
        else
            workspace.addLayoutError(page, page, data);
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), workspace.diagnostics.entries.items.len);
        try testing.expectEqual(@as(usize, 0), state.diagnostics.entries.items.len);
    }
}
