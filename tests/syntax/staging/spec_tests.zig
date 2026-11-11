const std = @import("std");
const ast = @import("ast");
const syntax = @import("syntax");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

const prefix = "page Example\n  stages i { ";
const suffix = " }\n  let current = i\nend\n";

fn stageSource(allocator: std.mem.Allocator, entries: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, entries, suffix });
}

fn expectValues(module: ast.Module, expected: []const i32) !void {
    try testing.expectEqual(expected.len, module.pages.items.len);
    for (module.pages.items, expected, 0..) |page, value, index| {
        try testing.expectEqual(index, page.stage_index.?);
        try testing.expectEqualStrings("Example", page.source_name.?);
        try testing.expectEqual(@as(f32, @floatFromInt(value)), page.statements.items[0].kind.let_binding.expr.number);
        try testing.expectEqual(@as(f32, @floatFromInt(value)), page.stages.?.value(index));
        try testing.expect(page.stages.?.stageName(index) == null);
        const name = try std.fmt.allocPrint(testing.allocator, "Example / {d}", .{value});
        defer testing.allocator.free(name);
        try testing.expectEqualStrings(name, page.name);
        try testing.expectEqual(index, module.top_level_items.items[index].page);
    }
}

fn expectEntries(entries: []const u8, expected: []const i32) !void {
    errdefer std.debug.print("\nStage entries: {s}\n", .{entries});
    const source = try stageSource(testing.allocator, entries);
    defer testing.allocator.free(source);
    var module = try syntax.parse(testing.allocator, source);
    defer module.deinit(testing.allocator);
    try expectValues(module, expected);
    var recovered = try syntax.parseRecovering(testing.allocator, source);
    defer recovered.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), recovered.holes.diagnostics.len);
    try expectValues(recovered.module, expected);
}

fn expectFailure(source: []const u8, expected: anyerror) !syntax.ParseDiagnostic {
    var failure: syntax.ParseFailure = .{};
    if (syntax.parseWithSourceNameAndFailure(testing.allocator, source, "stages.ss", &failure)) |parsed| {
        var module = parsed;
        defer module.deinit(testing.allocator);
        return error.ExpectedStageError;
    } else |err| {
        errdefer std.debug.print("\nStage source: {s}\nActual diagnostic: {any}\n", .{ source, failure.diagnostic });
        try testing.expectEqual(expected, err);
        const diagnostic = failure.diagnostic orelse return error.MissingStageDiagnostic;
        try testing.expectEqual(expected, diagnostic.err);
        try testing.expect(diagnostic.span.start <= diagnostic.span.end);
        try testing.expect(diagnostic.span.end <= source.len);
        try testing.expect(diagnostic.expected != null);
        return diagnostic;
    }
}

test "integer stages: exhaustive small ranges match repeated addition" {
    var checks: usize = 0;
    for (0..9) |first_index| for (0..9) |last_index| for (0..11) |step_index| {
        const first = @as(i32, @intCast(first_index)) - 4;
        const last = @as(i32, @intCast(last_index)) - 4;
        const step = @as(i32, @intCast(step_index)) - 5;
        const entries = try std.fmt.allocPrint(testing.allocator, "{d}:{d}:{d}", .{ first, step, last });
        defer testing.allocator.free(entries);
        if (step == 0 or (first < last and step < 0) or (first > last and step > 0)) {
            const source = try stageSource(testing.allocator, entries);
            defer testing.allocator.free(source);
            _ = try expectFailure(source, error.InvalidStageRange);
        } else {
            var expected = std.ArrayList(i32).empty;
            defer expected.deinit(testing.allocator);
            var current = first;
            while (if (step > 0) current <= last else current >= last) : (current += step) {
                try expected.append(testing.allocator, current);
            }
            try expectEntries(entries, expected.items);
        }
        checks += 1;
    };
    try testing.expectEqual(@as(usize, 891), checks);
}

test "integer stages: singleton ranges, signed zero, decimal spelling, and exact-number boundaries" {
    const cases = [_]struct { entries: []const u8, values: []const i32 }{
        .{ .entries = "0", .values = &.{0} },
        .{ .entries = "-0", .values = &.{0} },
        .{ .entries = "000001", .values = &.{1} },
        .{ .entries = "-000002:000002:000004", .values = &.{ -2, 0, 2, 4 } },
        .{ .entries = "-0:0", .values = &.{0} },
        .{ .entries = "0:-1:-0", .values = &.{0} },
        .{ .entries = "-5:12:-1", .values = &.{-5} },
        .{ .entries = "5:-12:1", .values = &.{5} },
        .{ .entries = "-7:2:-2", .values = &.{ -7, -5, -3 } },
        .{ .entries = "-2:-2:-7", .values = &.{ -2, -4, -6 } },
        .{ .entries = "16777214:16777216", .values = &.{ 16777214, 16777215, 16777216 } },
        .{ .entries = "-16777216:-16777214", .values = &.{ -16777216, -16777215, -16777214 } },
        .{ .entries = "16777216:-1:16777214", .values = &.{ 16777216, 16777215, 16777214 } },
        .{ .entries = "-16777214:-1:-16777216", .values = &.{ -16777214, -16777215, -16777216 } },
        .{ .entries = "16777214:3:16777216", .values = &.{16777214} },
        .{ .entries = "-16777214:-3:-16777216", .values = &.{-16777214} },
        .{ .entries = "16777215:16777216:16777216", .values = &.{16777215} },
        .{ .entries = "-16777215:-16777216:-16777216", .values = &.{-16777215} },
        .{ .entries = "-16777216:16777215:16777216", .values = &.{ -16777216, -1, 16777214 } },
        .{ .entries = "16777216:-16777215:-16777216", .values = &.{ 16777216, 1, -16777214 } },
    };
    for (cases) |case| try expectEntries(case.entries, case.values);
}

test "integer stages: whitespace and comments separate tokens without changing their values" {
    const separators = [_][]const u8{ "", " ", "\t", "\n", "\r\n", " ;; Boundary\n", "\n\n  ;; Boundary\n\t" };
    for (separators) |before| for (separators) |after| {
        const entries = try std.fmt.allocPrint(testing.allocator, "{s}-3{s}:{s}2{s}:{s}4{s} 8{s}", .{ before, before, after, before, after, before, after });
        defer testing.allocator.free(entries);
        try expectEntries(entries, &.{ -3, -1, 1, 3, 8 });
    };
    try expectEntries("1;; End of first entry\n3:2:7;; End of range\n9", &.{ 1, 3, 5, 7, 9 });
    try expectEntries("1:;; Step follows\n2:;; End follows\n5", &.{ 1, 3, 5 });
    try expectEntries("\r\n;; Only a comment before the first entry\r\n-2:0\r\n;; Final comment\r\n", &.{ -2, -1, 0 });
}

test "integer stages: all pairs of range segments preserve order or diagnose their intersection" {
    const Segment = struct { text: []const u8, values: []const i32 };
    const segments = [_]Segment{
        .{ .text = "-3", .values = &.{-3} },
        .{ .text = "-1:1", .values = &.{ -1, 0, 1 } },
        .{ .text = "1:-1:-1", .values = &.{ 1, 0, -1 } },
        .{ .text = "0:2:4", .values = &.{ 0, 2, 4 } },
        .{ .text = "1:2:5", .values = &.{ 1, 3, 5 } },
        .{ .text = "5:-2:1", .values = &.{ 5, 3, 1 } },
        .{ .text = "-3:2:3", .values = &.{ -3, -1, 1, 3 } },
        .{ .text = "2:10:5", .values = &.{2} },
        .{ .text = "5:-10:2", .values = &.{5} },
        .{ .text = "7:9", .values = &.{ 7, 8, 9 } },
        .{ .text = "-0", .values = &.{0} },
        .{ .text = "0001", .values = &.{1} },
    };
    for (segments) |first| for (segments) |second| {
        const entries = try std.fmt.allocPrint(testing.allocator, "{s}\n;; Next segment\n{s}", .{ first.text, second.text });
        defer testing.allocator.free(entries);
        var duplicate = false;
        for (first.values) |left| for (second.values) |right| {
            if (left == right) duplicate = true;
        };
        if (duplicate) {
            const source = try stageSource(testing.allocator, entries);
            defer testing.allocator.free(source);
            const diagnostic = try expectFailure(source, error.DuplicateStageValue);
            try testing.expectEqual(prefix.len + first.text.len + "\n;; Next segment\n".len, diagnostic.span.start);
            try testing.expectEqualStrings(second.text, source[diagnostic.span.start..diagnostic.span.end]);
        } else {
            const expected = try std.mem.concat(testing.allocator, i32, &.{ first.values, second.values });
            defer testing.allocator.free(expected);
            try expectEntries(entries, expected);
        }
    };
    try expectEntries("-4 -2:2:2 3 9:-2:5 20:21", &.{ -4, -2, 0, 2, 3, 9, 7, 5, 20, 21 });
}

test "integer stages: unsupported numeric spellings and malformed range operands are rejected" {
    const invalid = [_][]const u8{
        "1.0",                            "-0.0",                            "1e3",          "1E+3",          "0x10",         "0b11",          "1_000",      "1foo",        "1-2",        "1+2",
        "1,2",                            "1;2",                             "1/2",          "1//2",          "1#2",          "1@2",           "1..3",       "1..=3",       "1...3",      "1::3",
        "1:::3",                          "1:2:3:4",                         "1:",           "1:2:",          "1:-",          "1:-:3",         "1:2:-",      "1:+2:3",      "1:--2:3",    "1:2.0:3",
        "1:2:3.0",                        "1:2:3e0",                         "1:2:0x10",     "1:(2):3",       "1:step:3",     "1:2:last",      "-",          "--1",         "- 1",        "-\n1",
        "-;; Split sign\n1",              "-Infinity",                       "1:NaN:3",      "1:1:Infinity",  "16777217",     "-16777217",     "2147483647", "-2147483648", "2147483648", "-2147483649",
        "999999999999999999999999999999", "-999999999999999999999999999999", "1:16777217:3", "1:-16777217:0", "1:1:16777217", "-16777217:1:0",
    };
    for (invalid) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        _ = try expectFailure(source, error.InvalidStageInteger);
    }
    for ([_][]const u8{ "0:0:0", "0:-0:0", "1:0:2", "2:0:1", "1:-2:9", "9:2:1", "1:-1", "-1:2:-3" }) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        _ = try expectFailure(source, error.InvalidStageRange);
    }
}

test "integer stages: symbolic and numeric domains cannot be mixed in either order" {
    const cases = [_][]const u8{
        "first 1",                        "first -1",                     "first 1:3", "first 3:-1:1", "1 second", "-1 second",
        "1:3 second",                     "3:-1:1 second",                "1 _next",   "1 true",       "1 NaN",    "1 Infinity",
        "first\n;; Number follows\n-2:0", "1:2:5\n;; Name follows\nlast",
    };
    for (cases) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        _ = try expectFailure(source, error.MixedStageEntries);
    }
    for ([_][]const u8{ "first", "NaN Infinity", "first2 _next stage_3" }) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        var module = try syntax.parse(testing.allocator, source);
        defer module.deinit(testing.allocator);
        try testing.expect(module.pages.items[0].stages.?.stageName(0) != null);
    }
    for ([_][]const u8{ "", " \t\r\n", ";; No entries\n" }) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        _ = try expectFailure(source, error.EmptyStages);
    }
}

test "integer stages: every possible byte between digits is either valid syntax or a source error" {
    for (0..256) |byte_value| {
        const byte: u8 = @intCast(byte_value);
        const entries = [_]u8{ '1', byte, '2' };
        const source = try stageSource(testing.allocator, &entries);
        defer testing.allocator.free(source);
        errdefer std.debug.print("\nByte between integer digits: 0x{x}\n", .{byte});
        if (std.ascii.isDigit(byte)) {
            try expectEntries(&entries, &.{102 + 10 * @as(i32, byte - '0')});
        } else if (byte == ':' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            try expectEntries(&entries, &.{ 1, 2 });
        } else {
            var failure: syntax.ParseFailure = .{};
            if (syntax.parseWithSourceNameAndFailure(testing.allocator, source, "bytes.ss", &failure)) |parsed| {
                var module = parsed;
                defer module.deinit(testing.allocator);
                return error.ExpectedStageError;
            } else |err| {
                const diagnostic = failure.diagnostic orelse return error.MissingStageDiagnostic;
                try testing.expectEqual(err, diagnostic.err);
                try testing.expect(diagnostic.expected != null);
                try testing.expect(diagnostic.span.start <= diagnostic.span.end);
                try testing.expect(diagnostic.span.end <= source.len);
            }
            var budget: Budget = .{};
            var recovered = try syntax.parseRecoveringWithOptions(testing.allocator, source, "bytes.ss", .{
                .expansion = .{ .expand_stages = false },
                .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
            });
            defer recovered.deinit(testing.allocator);
            try testing.expect(recovered.holes.diagnostics.len > 0);
            for (recovered.holes.diagnostics) |diagnostic| {
                try testing.expect(diagnostic.span.start <= diagnostic.span.end);
                try testing.expect(diagnostic.span.end <= source.len);
            }
        }
    }
}

test "integer stages: invalid ranges and repeated values identify the offending source span" {
    const cases = [_]struct { entries: []const u8, err: anyerror, start: usize, token: []const u8 }{
        .{ .entries = "1:0:3", .err = error.InvalidStageRange, .start = 2, .token = "0" },
        .{ .entries = "1:-0:3", .err = error.InvalidStageRange, .start = 2, .token = "-0" },
        .{ .entries = "1:-2:9", .err = error.InvalidStageRange, .start = 0, .token = "1:-2:9" },
        .{ .entries = "1:16777217:9", .err = error.InvalidStageInteger, .start = 2, .token = "16777217" },
        .{ .entries = "1:2:16777217", .err = error.InvalidStageInteger, .start = 4, .token = "16777217" },
        .{ .entries = "0 -0", .err = error.DuplicateStageValue, .start = 2, .token = "-0" },
        .{ .entries = "1 001", .err = error.DuplicateStageValue, .start = 2, .token = "001" },
        .{ .entries = "1:3 3:-1:1", .err = error.DuplicateStageValue, .start = 4, .token = "3:-1:1" },
        .{ .entries = "1:2:5 2:3:8", .err = error.DuplicateStageValue, .start = 6, .token = "2:3:8" },
        .{ .entries = "-16777216 16777216 -16777216", .err = error.DuplicateStageValue, .start = 19, .token = "-16777216" },
    };
    for (cases) |case| {
        const source = try stageSource(testing.allocator, case.entries);
        defer testing.allocator.free(source);
        const diagnostic = try expectFailure(source, case.err);
        try testing.expectEqual(prefix.len + case.start, diagnostic.span.start);
        try testing.expectEqualStrings(case.token, source[diagnostic.span.start..diagnostic.span.end]);
    }
}

const Budget = struct {
    remaining: usize = 2000,

    fn canceled(context: *const anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(@constCast(context)));
        if (self.remaining == 0) return true;
        self.remaining -= 1;
        return false;
    }
};

test "integer stages: every truncated prefix terminates and recovering diagnostics stay within source" {
    const sources = [_][]const u8{
        "page Example\n  stages i { -3:2:3 7 }\n  let current = i\nend\n",
        "page Example\r\n  stages i { 1:;; Step\r\n2:;; End\r\n5\r\n }\r\nend\r\n",
        "page Example\n  stages i { first second }\n  let current = i\nend\n",
    };
    for (sources) |source| for (0..source.len + 1) |length| {
        const truncated = source[0..length];
        errdefer std.debug.print("\nTruncated source: {s}\n", .{truncated});
        var failure: syntax.ParseFailure = .{};
        if (syntax.parseWithSourceNameAndFailure(testing.allocator, truncated, "prefix.ss", &failure)) |parsed| {
            var module = parsed;
            module.deinit(testing.allocator);
        } else |_| {
            const diagnostic = failure.diagnostic orelse return error.MissingStageDiagnostic;
            try testing.expect(diagnostic.span.start <= diagnostic.span.end);
            try testing.expect(diagnostic.span.end <= length);
        }
        var budget: Budget = .{};
        var recovered = try syntax.parseRecoveringWithOptions(testing.allocator, truncated, "prefix.ss", .{
            .expansion = .{ .expand_stages = false },
            .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
        });
        defer recovered.deinit(testing.allocator);
        for (recovered.holes.diagnostics) |diagnostic| {
            try testing.expect(diagnostic.span.start <= diagnostic.span.end);
            try testing.expect(diagnostic.span.end <= length);
        }
    };
}

test "integer stages: recovering parser retains later statements and pages after a malformed declaration" {
    for ([_][]const u8{ "1::3", "1:0:3", "1:step:3", "1.5", "1 first", "first 1", "1:2:" }) |entries| {
        const source = try std.fmt.allocPrint(testing.allocator, "page Broken\nstages i {{ {s} }}\nlet after = 42\nend\npage Next\nlet value = 99\nend\n", .{entries});
        defer testing.allocator.free(source);
        var budget: Budget = .{};
        var recovered = try syntax.parseRecoveringWithOptions(testing.allocator, source, "recover.ss", .{
            .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
        });
        defer recovered.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), recovered.holes.diagnostics.len);
        try testing.expectEqual(@as(usize, 2), recovered.module.pages.items.len);
        const broken = recovered.module.pages.items[0];
        try testing.expect(broken.stages == null);
        const after = broken.statements.items[broken.statements.items.len - 1].kind.let_binding;
        try testing.expectEqualStrings("after", after.name);
        try testing.expectEqual(@as(f32, 42), after.expr.number);
        try testing.expectEqualStrings("Next", recovered.module.pages.items[1].name);
        try testing.expectEqual(@as(f32, 99), recovered.module.pages.items[1].statements.items[0].kind.let_binding.expr.number);
    }
}

test "integer stages: the full exact integer interval stays compact until expansion is requested" {
    const source = try stageSource(testing.allocator, "-16777216:16777216");
    defer testing.allocator.free(source);
    var module = try syntax.parseWithOptions(testing.allocator, source, "compact.ss", .{ .expansion = .{ .expand_stages = false } });
    defer module.deinit(testing.allocator);
    var copy = try module.clone(testing.allocator);
    defer copy.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), copy.pages.items.len);
    const stages = copy.pages.items[0].stages.?;
    try testing.expectEqual(@as(usize, 1), stages.entries.numbers.items.len);
    try testing.expectEqual(@as(usize, 33554433), stages.count());
    for ([_]usize{ 0, 1, 16777215, 16777216, 16777217, 33554431, 33554432 }, [_]i32{ -16777216, -16777215, -1, 0, 1, 16777215, 16777216 }) |index, value| {
        try testing.expectEqual(@as(f32, @floatFromInt(value)), stages.value(index));
    }
}

test "integer stages: cancellation interrupts large expansion and duplicate scans without consuming the source" {
    for ([_][]const u8{ "-16777216:16777216", "-16777216:16777216 0" }) |entries| {
        const source = try stageSource(testing.allocator, entries);
        defer testing.allocator.free(source);
        var parsed = try syntax.parseSurface(testing.allocator, source);
        defer parsed.deinit(testing.allocator);
        for ([_]usize{ 0, 1, 16, 100 }) |limit| {
            var budget = Budget{ .remaining = limit };
            try testing.expectError(error.Canceled, syntax.desugar(testing.allocator, &parsed, .{
                .cancellation = .{ .context = &budget, .is_canceled = Budget.canceled },
            }));
        }
        var retained = try syntax.desugar(testing.allocator, &parsed, .{ .expand_stages = false });
        defer retained.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), retained.pages.items.len);
        try testing.expectEqual(@as(usize, 33554433) + @intFromBool(std.mem.endsWith(u8, entries, " 0")), retained.pages.items[0].stages.?.count());
    }
}

fn malformedAllocation(allocator: std.mem.Allocator, source: []const u8, expected: anyerror, recovering: bool) !void {
    if (recovering) {
        var recovered = try syntax.parseRecovering(allocator, source);
        defer recovered.deinit(allocator);
        try testing.expectEqual(@as(usize, 1), recovered.holes.diagnostics.len);
    } else {
        var module = syntax.parse(allocator, source) catch |err| {
            if (err == error.OutOfMemory) return err;
            try testing.expectEqual(expected, err);
            return;
        };
        defer module.deinit(allocator);
        return error.ExpectedStageError;
    }
}

test "integer stages: allocation failures clean up malformed declarations and repeated range values" {
    const cases = [_]struct { entries: []const u8, err: anyerror, recovering: bool = false }{
        .{ .entries = "1:2:5 7 9:0:12", .err = error.InvalidStageRange },
        .{ .entries = "1:2:5 7 9:step:12", .err = error.InvalidStageInteger },
        .{ .entries = "1:2:5 7 final", .err = error.MixedStageEntries },
        .{ .entries = "1:2:5 7 3:2:9", .err = error.DuplicateStageValue },
        .{ .entries = "1:2:5 7 9:0:12", .err = error.InvalidStageRange, .recovering = true },
    };
    for (cases) |case| {
        const source = try stageSource(testing.allocator, case.entries);
        defer testing.allocator.free(source);
        try allocation_testing.checkAllAllocationFailures(testing.allocator, malformedAllocation, .{ source, case.err, case.recovering });
    }
}
