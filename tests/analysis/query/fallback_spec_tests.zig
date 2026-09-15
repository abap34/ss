const std = @import("std");
const analysis = @import("analysis");
const utils = @import("utils");
const testing = std.testing;
const api = analysis.snapshot;
const query_types = analysis.query.types;
const limits = analysis.query.fallback.Limits;
const clock_context: u8 = 0;
const options = query_types.QueryOptions{ .budget_ms = 0, .clock = .{ .context = &clock_context, .now_ns = frozenNow } };

fn frozenNow(_: *const anyopaque) i128 {
    return 0;
}

fn emptySnapshot() api.AnalysisSnapshot {
    return .{ .allocator = testing.allocator, .diagnostics = analysis.diagnostics.DiagnosticBag.init(testing.allocator) };
}

fn after(source: []const u8, needle: []const u8) usize {
    return (std.mem.lastIndexOf(u8, source, needle) orelse unreachable) + needle.len;
}

fn candidate(result: query_types.CompletionResult, name: []const u8) !query_types.CompletionCandidate {
    for (result.items) |item| if (std.mem.eql(u8, item.label, name)) return item;
    return error.ExpectedCandidate;
}

test "fallback analysis: malformed current source produces new results without a syntax tree" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = "fn broken(\npage main\n  let count: Number = missing(\n  let next = count +\nend\n";
    const req = query_types.SourceRequest{ .path = "fallback.ss", .source = source, .offset = after(source, "next = co") };
    var allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var completion = try api.completeAt(allocator.allocator(), &snapshot, req, options);
    defer completion.deinit(allocator.allocator());
    try testing.expect(completion.is_incomplete);
    try testing.expectEqualStrings("Number", (try candidate(completion, "count")).detail.?);
    _ = try candidate(completion, "next");

    var hover = (try api.hoverAt(testing.allocator, &snapshot, req, options)) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expectEqualStrings("```ss\n(count: Number)\n```", hover.markdown);
    const definitions = try api.definitionAt(testing.allocator, &snapshot, req, options);
    defer testing.allocator.free(definitions);
    try testing.expectEqual(@as(usize, 1), definitions.len);
    try testing.expectEqual(@as(usize, 2), definitions[0].line);
    try testing.expectEqual(@as(usize, 6), definitions[0].character);
    try testing.expectEqual(@as(usize, 11), definitions[0].end_character);
}

test "fallback analysis: literals give shallow types and arbitrary expressions give Any" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = "page main\nlet count = 1\nlet label = \"Text\"\nlet result = count + unknown\ncount\nlabel\nresult\nend\n";
    for ([_][2][]const u8{ .{ "count\n", "(count: Number)" }, .{ "label\n", "(label: String)" }, .{ "result\n", "(result: Any)" } }) |item| {
        var hover = (try api.hoverAt(testing.allocator, &snapshot, .{ .path = "literal.ss", .source = source, .offset = after(source, item[0]) - 2 }, options)) orelse return error.ExpectedHover;
        defer hover.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, hover.markdown, item[1]) != null);
    }
}

test "fallback analysis: ambiguous declarations give Any and candidate definition locations" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = "page first\nlet value = 1\nend\npage second\nlet value = \"Text\"\nvalue\nend\n";
    const req = query_types.SourceRequest{ .path = "ambiguous.ss", .source = source, .offset = after(source, "value\n") - 2 };
    var hover = (try api.hoverAt(testing.allocator, &snapshot, req, options)) orelse return error.ExpectedHover;
    defer hover.deinit(testing.allocator);
    try testing.expectEqualStrings("```ss\n(value: Any)\n```", hover.markdown);
    const targets = try api.definitionAt(testing.allocator, &snapshot, req, options);
    defer testing.allocator.free(targets);
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqual(@as(usize, 4), targets[0].line);
    try testing.expectEqual(@as(usize, 1), targets[1].line);
}

test "fallback analysis: an unknown receiver admits known fields without type resolution" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    var fields = [_]api.RecordFieldFact{
        .{ .name = @constCast("size"), .record_name = @constCast("Style"), .type_label = @constCast("Number"), .module_id = 0 },
        .{ .name = @constCast("color"), .record_name = @constCast("ColorStyle"), .type_label = @constCast("Color"), .module_id = 0 },
    };
    snapshot.record_fields = &fields;
    defer snapshot.record_fields = &.{};
    const source = "page main\nlet item = unknown(\nitem.\nend\n";
    var completion = try api.completeAt(testing.allocator, &snapshot, .{ .path = "member.ss", .source = source, .offset = after(source, "item.") }, options);
    defer completion.deinit(testing.allocator);
    try testing.expectEqual(.property, (try candidate(completion, "size")).kind);
    try testing.expectEqual(.property, (try candidate(completion, "color")).kind);
    for (completion.items) |item| try testing.expect(item.kind == .property);
}

test "fallback analysis: comments and strings do not introduce declarations or hover targets" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = "page main\n;; let hidden = 1\nlet label = \"let secret = 2\"\nlabel\nend\n";
    for ([_][]const u8{ "hidden", "secret", ";; let " }) |needle| {
        const req = query_types.SourceRequest{ .path = "text.ss", .source = source, .offset = after(source, needle) };
        var completion = try api.completeAt(testing.allocator, &snapshot, req, options);
        defer completion.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), completion.items.len);
        var hover = try api.hoverAt(testing.allocator, &snapshot, req, options);
        defer if (hover) |*value| value.deinit(testing.allocator);
        try testing.expect(hover == null);
        const definitions = try api.definitionAt(testing.allocator, &snapshot, req, options);
        defer testing.allocator.free(definitions);
        try testing.expectEqual(@as(usize, 0), definitions.len);
    }
}

test "fallback analysis: large files retain nearby names and current positions" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = ("let repeated = 0\n" ** 5000) ++ "let nearby: Number = unknown(\nlet copy = nearby\n";
    const index = try utils.source.LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    const req = query_types.SourceRequest{ .path = "large.ss", .source = source, .offset = after(source, "copy = near"), .line_index = index };
    var completion = try api.completeAt(testing.allocator, &snapshot, req, options);
    defer completion.deinit(testing.allocator);
    _ = try candidate(completion, "nearby");
    try testing.expect(completion.items.len <= limits.names);
    const targets = try api.definitionAt(testing.allocator, &snapshot, req, options);
    defer testing.allocator.free(targets);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(@as(usize, 5000), targets[0].line);
    try testing.expectEqual(@as(usize, 4), targets[0].character);
}

test "fallback analysis: definition positions use UTF-16 and reject a stale line index" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    const source = "let text = \"\u{1f600}\" let value = 1\nvalue\n";
    const index = try utils.source.LineIndex.init(testing.allocator, source);
    defer index.deinit(testing.allocator);
    const stale = try utils.source.LineIndex.init(testing.allocator, "\n" ++ source);
    defer stale.deinit(testing.allocator);
    for ([_]?utils.source.LineIndex{ null, index, stale }) |line_index| {
        const targets = try api.definitionAt(testing.allocator, &snapshot, .{
            .path = "unicode.ss",
            .source = source,
            .offset = after(source, "value\n") - 2,
            .line_index = line_index,
        }, options);
        defer testing.allocator.free(targets);
        try testing.expectEqual(@as(usize, 1), targets.len);
        try testing.expectEqual(@as(usize, 0), targets[0].line);
        try testing.expectEqual(@as(usize, 20), targets[0].character);
        try testing.expectEqual(@as(usize, 0), targets[0].end_line);
        try testing.expectEqual(@as(usize, 25), targets[0].end_character);
    }
}

test "fallback analysis: its own deadline stops scanning snapshot facts" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    var fields = [_]api.RecordFieldFact{.{
        .name = @constCast("size"),
        .record_name = @constCast("Style"),
        .type_label = @constCast("Number"),
        .module_id = 0,
    }} ** 128;
    fields[fields.len - 1].name = @constCast("last_field");
    snapshot.record_fields = &fields;
    defer snapshot.record_fields = &.{};
    const req = query_types.SourceRequest{ .path = "deadline.ss", .source = "item.", .offset = 5 };
    var full = try api.completeAt(testing.allocator, &snapshot, req, options);
    defer full.deinit(testing.allocator);
    _ = try candidate(full, "last_field");

    const AdvancingClock = struct {
        calls: usize = 0,

        fn now(context: *const anyopaque) i128 {
            const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
            self.calls += 1;
            return @as(i128, @intCast(self.calls)) * std.time.ns_per_ms;
        }
    };
    var clock = AdvancingClock{};
    var timed_options = options;
    timed_options.clock = .{ .context = &clock, .now_ns = AdvancingClock.now };
    var timed = try api.completeAt(testing.allocator, &snapshot, req, timed_options);
    defer timed.deinit(testing.allocator);
    try testing.expect(timed.is_incomplete);
    _ = try candidate(timed, "content");
    for (timed.items) |item| try testing.expect(!std.mem.eql(u8, item.label, "last_field"));
    try testing.expect(clock.calls < 16);
}

test "fallback analysis: cancellation prevents the replacement analysis" {
    var snapshot = emptySnapshot();
    defer snapshot.deinit();
    var canceled_options = options;
    canceled_options.cancellation = .{ .context = &clock_context, .is_canceled = alwaysCanceled };
    const source = "let value = 1\nvalue\n";
    const req = query_types.SourceRequest{ .path = "cancel.ss", .source = source, .offset = after(source, "value\n") - 2 };
    var completion = try api.completeAt(testing.allocator, &snapshot, req, canceled_options);
    defer completion.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), completion.items.len);
    var hover = try api.hoverAt(testing.allocator, &snapshot, req, canceled_options);
    defer if (hover) |*value| value.deinit(testing.allocator);
    try testing.expect(hover == null);
    const targets = try api.definitionAt(testing.allocator, &snapshot, req, canceled_options);
    defer testing.allocator.free(targets);
    try testing.expectEqual(@as(usize, 0), targets.len);
}

fn alwaysCanceled(_: *const anyopaque) bool {
    return true;
}
