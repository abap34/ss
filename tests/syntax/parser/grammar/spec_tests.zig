const std = @import("std");
const syntax = @import("syntax");
const testing = std.testing;

const document_path = "tests/fixtures/syntax/grammar/examples.md";
const Outcome = enum { accept, reject };
const Context = enum { expression, module };

fn checkExample(outcome: Outcome, context: Context, expected_error: ?[]const u8, example: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = switch (context) {
        .expression => try std.fmt.allocPrint(allocator, "page Grammar\nlet value = {s}\nend\n", .{example}),
        .module => example,
    };
    var failure: syntax.ParseFailure = .{};
    if (syntax.parseWithSourceNameAndFailure(allocator, source, document_path, &failure)) |parsed| {
        var module = parsed;
        defer module.deinit(allocator);
        if (outcome == .reject) return error.ExpectedParseError;
    } else |err| {
        if (outcome == .accept) {
            std.debug.print("\nUnexpected parse failure: {s}, diagnostic: {any}\n", .{ @errorName(err), failure.diagnostic });
            return err;
        }
        try testing.expectEqualStrings(expected_error.?, @errorName(err));
        const diagnostic = failure.diagnostic orelse return error.MissingParseDiagnostic;
        try testing.expectEqual(err, diagnostic.err);
        return;
    }

    var recovered = try syntax.parseRecoveringWithSourceName(allocator, source, document_path);
    defer recovered.deinit(allocator);
    if (recovered.holes.diagnostics.len != 0) {
        for (recovered.holes.diagnostics) |diagnostic| {
            std.debug.print("\nUnexpected recovery diagnostic: {any}\n", .{diagnostic});
        }
    }
    try testing.expectEqual(@as(usize, 0), recovered.holes.diagnostics.len);
}

test "syntax grammar: documented examples match strict and recovering parsers" {
    const document = try std.Io.Dir.cwd().readFileAlloc(testing.io, document_path, testing.allocator, .limited(1024 * 1024));
    defer testing.allocator.free(document);
    const marker = "<!-- syntax:";
    var cursor: usize = 0;
    var accepted: usize = 0;
    var rejected: usize = 0;
    while (std.mem.indexOfPos(u8, document, cursor, marker)) |start| {
        const line = 1 + std.mem.count(u8, document[0..start], "\n");
        errdefer std.debug.print("\nGrammar example failed at {s}:{d}\n", .{ document_path, line });
        const header_end = std.mem.indexOfPos(u8, document, start, " -->\n") orelse return error.UnclosedExampleMarker;
        var words = std.mem.tokenizeAny(u8, document[start + marker.len .. header_end], " \t");
        const outcome = std.meta.stringToEnum(Outcome, words.next() orelse return error.MissingOutcome) orelse return error.InvalidOutcome;
        const context = std.meta.stringToEnum(Context, words.next() orelse return error.MissingContext) orelse return error.InvalidContext;
        const expected_error = words.next();
        try testing.expectEqual(outcome == .reject, expected_error != null);
        try testing.expect(words.next() == null);
        const fence_start = header_end + " -->\n".len;
        if (!std.mem.startsWith(u8, document[fence_start..], "```ss\n")) return error.MissingExampleFence;
        const code_start = fence_start + "```ss\n".len;
        const code_end = std.mem.indexOfPos(u8, document, code_start, "\n```\n") orelse return error.UnclosedExampleFence;
        const example = document[code_start .. code_end + 1];
        errdefer std.debug.print("\nExample source:\n{s}\n", .{example});
        try checkExample(outcome, context, expected_error, example);
        switch (outcome) {
            .accept => accepted += 1,
            .reject => rejected += 1,
        }
        cursor = code_end + "\n```\n".len;
    }
    try testing.expect(accepted > 0);
    try testing.expect(rejected > 0);
    try testing.expectEqual(std.mem.count(u8, document, "```ss\n"), accepted + rejected);
}

test "syntax grammar: empty updates and coalescing have the documented AST" {
    const source =
        \\page Grammar
        \\let empty = style with {}
        \\let right = a ?? b + c
        \\let left = a + b ?? c
        \\end
    ;
    for ([_]bool{ false, true }) |recovering| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const module = if (recovering) blk: {
            const result = try syntax.parseRecovering(arena.allocator(), source);
            try testing.expectEqual(@as(usize, 0), result.holes.diagnostics.len);
            break :blk result.module;
        } else try syntax.parse(arena.allocator(), source);
        const statements = module.pages.items[0].statements.items;
        try testing.expectEqual(@as(usize, 3), statements.len);
        const empty = statements[0].kind.let_binding.expr.record_update;
        try testing.expectEqualStrings("style", empty.target.ident.name);
        try testing.expectEqual(@as(usize, 0), empty.fields.items.len);
        const right = statements[1].kind.let_binding.expr.coalesce;
        try testing.expectEqualStrings("a", right.target.ident.name);
        try testing.expectEqualStrings("add", right.fallback.call.callee.name);
        try testing.expectEqualStrings("b", right.fallback.call.args.items[0].ident.name);
        try testing.expectEqualStrings("c", right.fallback.call.args.items[1].ident.name);
        const left = statements[2].kind.let_binding.expr.call;
        try testing.expectEqualStrings("add", left.callee.name);
        try testing.expectEqualStrings("a", left.args.items[0].ident.name);
        try testing.expectEqualStrings("b", left.args.items[1].coalesce.target.ident.name);
        try testing.expectEqualStrings("c", left.args.items[1].coalesce.fallback.ident.name);
    }
}
