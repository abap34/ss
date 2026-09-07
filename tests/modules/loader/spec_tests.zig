const std = @import("std");
const compiler = @import("compiler");

const testing = std.testing;

test "module loader spec: module transfer preserves ownership on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, transferModuleOwnership, .{});
}

fn transferModuleOwnership(allocator: std.mem.Allocator) !void {
    var graph = compiler.module_loader.ModuleGraph{
        .allocator = allocator,
        .modules = .empty,
        .module_order = .empty,
        .project_implicit_import_ids = .empty,
        .project_import_ids = .empty,
    };
    defer graph.deinit();
    var destination = std.ArrayList(compiler.core.SourceModule).empty;
    defer {
        for (destination.items) |*module| module.deinit(allocator);
        destination.deinit(allocator);
    }

    try appendOwnedModule(allocator, &destination, 0);
    for (1..17) |id| try appendOwnedModule(allocator, &graph.modules, @intCast(id));

    graph.moveModulesTo(&destination) catch |err| {
        try testing.expectEqual(@as(usize, 1), destination.items.len);
        try testing.expectEqual(@as(usize, 16), graph.modules.items.len);
        for (graph.modules.items, 1..) |module, id| {
            try testing.expectEqual(@as(compiler.core.SourceModuleId, @intCast(id)), module.id);
        }
        return err;
    };
    try testing.expectEqual(@as(usize, 0), graph.modules.items.len);
    try testing.expectEqual(@as(usize, 17), destination.items.len);
    for (destination.items, 0..) |module, id| {
        try testing.expectEqual(@as(compiler.core.SourceModuleId, @intCast(id)), module.id);
        try testing.expectEqualStrings("// owned source\n", module.source);
    }
    try graph.moveModulesTo(&destination);
    try testing.expectEqual(@as(usize, 17), destination.items.len);
}

fn appendOwnedModule(allocator: std.mem.Allocator, modules: *std.ArrayList(compiler.core.SourceModule), id: compiler.core.SourceModuleId) !void {
    const spec = try std.fmt.allocPrint(allocator, "module-{d}", .{id});
    errdefer allocator.free(spec);
    const source = try allocator.dupe(u8, "// owned source\n");
    errdefer allocator.free(source);
    const line_index = try @import("utils").source.LineIndex.init(allocator, source);
    errdefer line_index.deinit(allocator);
    try modules.append(allocator, .{
        .id = id,
        .kind = .library,
        .spec = spec,
        .path = null,
        .source = source,
        .line_index = line_index,
        .syntax = .init(),
        .implicit_import_ids = .empty,
        .resolved_import_ids = .empty,
    });
}

test "module loader spec: source overlays preserve lookup allocation failures" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var overlay = compiler.module_loader.SourceOverlay.init(failing.allocator());
    defer overlay.deinit();

    try testing.expectError(error.OutOfMemory, overlay.get("slide.ss"));
}

test "module loader spec: diagnostics free partial allocations" {
    var completed = false;
    for (0..16) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var diagnostics = compiler.module_loader.LoadDiagnostics.init(failing.allocator());
        defer diagnostics.deinit();
        diagnostics.add(
            "dependency.ss",
            "invalid source",
            .@"error",
            "ParseFailed",
            "ParseFailed: invalid source",
            null,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try testing.expectEqual(@as(usize, 1), diagnostics.items.items.len);
        completed = true;
        break;
    }
    try testing.expect(completed);
}

test "module loader spec: import failure spans preserve allocation failures" {
    const source = "import \"allocation-test-module\" as dependency\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "span-allocation-test.ss");
    defer program.deinit(testing.allocator);
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("allocation-test-module.ss", "");
    var diagnostics = compiler.module_loader.LoadDiagnostics.init(testing.allocator);
    defer diagnostics.deinit();
    try diagnostics.add(
        "allocation-test-module.ss",
        "",
        .@"error",
        "ParseFailed",
        "ParseFailed: invalid source",
        null,
    );

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, compiler.module_loader.importFailureSpan(
        failing.allocator(),
        testing.io,
        ".",
        &program,
        &overlay,
        &diagnostics,
    ));
}

test "module loader spec: source parse failures use the diagnostic error" {
    const source = "import \"invalid-module\" as dependency\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "parse-failure-test.ss");
    defer program.deinit(testing.allocator);
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("stdlib/core/invalid-module.ss", "@");
    var diagnostics = compiler.module_loader.LoadDiagnostics.init(testing.allocator);
    defer diagnostics.deinit();

    try testing.expectError(error.DiagnosticsFailed, compiler.module_loader.loadGraphWithOptions(
        testing.allocator,
        testing.io,
        "stdlib/core",
        program,
        .{
            .overlay = &overlay,
            .diagnostics = &diagnostics,
            .print_diagnostics = false,
        },
    ));
    try testing.expect(diagnostics.items.items.len != 0);
}

test "module loader spec: graph failures clean previously loaded modules" {
    const source = "import \"missing-cleanup-test-module\" as dependency\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "graph-cleanup-test.ss");
    defer program.deinit(testing.allocator);

    try testing.expectError(
        error.UnknownImport,
        compiler.module_loader.loadGraph(testing.allocator, testing.io, ".", program),
    );
}

test "module loader spec: stdlib resolution frees partial allocations" {
    const source = "import std:core/prelude as core\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "stdlib-allocation-test.ss");
    defer program.deinit(testing.allocator);

    var completed = false;
    for (0..16) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var report = compiler.module_loader.findUnknownImportReport(
            failing.allocator(),
            testing.io,
            ".",
            program,
            null,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer if (report) |*value| value.deinit(failing.allocator());
        try testing.expect(report == null);
        completed = true;
        break;
    }
    try testing.expect(completed);
}

test "module loader spec: explicit resolution frees partial allocations" {
    const source = "import \"allocation-test-module\" as dependency\n";
    var program = try compiler.syntax.parseWithSourceName(testing.allocator, source, "explicit-allocation-test.ss");
    defer program.deinit(testing.allocator);
    var overlay = compiler.module_loader.SourceOverlay.init(testing.allocator);
    defer overlay.deinit();
    try overlay.put("allocation-test-module.ss", "");

    var completed = false;
    for (0..16) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var report = compiler.module_loader.findUnknownImportReport(
            failing.allocator(),
            testing.io,
            ".",
            program,
            &overlay,
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        defer if (report) |*value| value.deinit(failing.allocator());
        try testing.expect(report == null);
        completed = true;
        break;
    }
    try testing.expect(completed);
}
