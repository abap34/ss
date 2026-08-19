const std = @import("std");
const compiler = @import("compiler");

const testing = std.testing;

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
