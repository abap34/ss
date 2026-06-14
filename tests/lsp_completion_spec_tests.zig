const std = @import("std");
const compiler = @import("compiler");
const completion = compiler.completion;

const testing = std.testing;

test "analysis completion: access context detects dot and module qualifiers" {
    const dot_source = "page main\n  title.text";
    const dot = completion.accessBeforeOffset(dot_source, dot_source.len) orelse return error.ExpectedDotAccess;
    try std.testing.expectEqual(completion.AccessSeparator.dot, dot.separator);
    try std.testing.expectEqualStrings("title", dot.receiver);
    try std.testing.expectEqual(std.mem.indexOfScalar(u8, dot_source, '.').?, dot.separator_offset);

    const module_source = "default::h";
    const module = completion.accessBeforeOffset(module_source, module_source.len) orelse return error.ExpectedModuleAccess;
    try std.testing.expectEqual(completion.AccessSeparator.double_colon, module.separator);
    try std.testing.expectEqualStrings("default", module.receiver);
    try std.testing.expectEqual(std.mem.indexOf(u8, module_source, "::").?, module.separator_offset);

    const dot_with_space_source = "page main\n  title. ";
    const dot_with_space = completion.accessBeforeOffset(dot_with_space_source, dot_with_space_source.len) orelse return error.ExpectedDotAccess;
    try std.testing.expectEqual(completion.AccessSeparator.dot, dot_with_space.separator);
    try std.testing.expectEqualStrings("title", dot_with_space.receiver);

    const module_with_space_source = "default:: ";
    const module_with_space = completion.accessBeforeOffset(module_with_space_source, module_with_space_source.len) orelse return error.ExpectedModuleAccess;
    try std.testing.expectEqual(completion.AccessSeparator.double_colon, module_with_space.separator);
    try std.testing.expectEqualStrings("default", module_with_space.receiver);

    try std.testing.expect(completion.accessBeforeOffset("title.text ", "title.text ".len) == null);
    try std.testing.expect(completion.accessBeforeOffset("title", 5) == null);
}

test "analysis completion: dot module and normal positions keep candidate kinds separate" {
    var case = try CompletionCase.init(
        \\import std:themes/default
        \\import std:themes/default as *
        \\
        \\page title
        \\  let t = default::h1("body")
        \\  t.text_size = 20
        \\end
        \\
    );
    defer case.deinit();

    {
        var result = try case.completeAfter("t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text_size");
        try expectHas(result, "content");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "Align");
        try expectMissing(result, "String");
    }

    {
        var result = try case.completeAfter("default::");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "h1");
        try expectHas(result, "h1!");
        try expectMissing(result, "page");
        try expectMissing(result, "add");
        try expectMissing(result, "text_size");
        try expectMissing(result, "String");
        try expectMissing(result, "Align");
    }

    {
        var result = try case.completeAfter("page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "page");
        try expectHas(result, "h1!");
        try expectHas(result, "String");
        try expectHas(result, "Object");
        try expectHas(result, "Selection");
        try expectHas(result, "Align");
        try expectHas(result, "Text");
        try expectMissing(result, "text_size");
    }
}

test "analysis completion: normal position follows import visibility" {
    var case = try CompletionCase.init(
        \\import std:themes/default as theme
        \\
        \\page title
        \\
        \\end
        \\
    );
    defer case.deinit();

    var result = try case.completeAfter("page title\n");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    try expectHas(result, "page");
    try expectMissing(result, "h1");
    try expectMissing(result, "h1!");
    try expectMissing(result, "text_size");
}

test "analysis completion: normal positions include builtin and source type names" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\type SourceOnly = alpha | beta
        \\type SourceCard = object {
        \\}
        \\
        \\fn keep(value: ) -> SourceOnly
        \\  return value
        \\end
        \\
    ;

    var result = try case.completeSourceAfter(request_source, "value: ");
    defer result.deinit(case.allocator);
    try expectUnique(result);
    try expectHas(result, "String");
    try expectHas(result, "Object");
    try expectHas(result, "Selection");
    try expectHas(result, "SourceOnly");
    try expectHas(result, "SourceCard");
    try expectMissing(result, "text_size");
}

test "analysis completion: source fallback sees same-scope bindings before and after cursor" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  let t = h2! "before"
        \\  let alias = t
        \\  let later = h2! "after"
        \\  alias.text_size = 1
        \\  later.text_size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\page title
        \\  alias.
        \\  let t = h2! "before"
        \\  let alias = t
        \\  later.
        \\  let later = h2! "after"
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "alias.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text_size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "later.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text_size");
        try expectMissing(result, "page");
    }
}

test "analysis completion: fn paired function and const result annotations drive property targets" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\fn make_plain() -> Object
        \\  return h2!("plain")
        \\end
        \\
        \\fn/! make_paired(content: String) -> Object
        \\  return h2!(content)
        \\end
        \\
        \\const make_const: Object = h2!("const")
        \\
        \\page title
        \\  let a = make_plain()
        \\  a.text_size = 1
        \\  let b = make_paired! "paired"
        \\  b.text_size = 1
        \\  let c = make_const
        \\  c.text_size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\fn make_plain() -> Object
        \\  return h2!("plain")
        \\end
        \\
        \\fn/! make_paired(content: String) -> Object
        \\  return h2!(content)
        \\end
        \\
        \\const make_const: Object = h2!("const")
        \\
        \\page title
        \\  let a = make_plain()
        \\  a.
        \\  let b = make_paired! "paired"
        \\  b.
        \\  let c = make_const
        \\  c.
        \\end
        \\
    ;

    inline for (.{ "a.", "b.", "c." }) |needle| {
        var result = try case.completeSourceAfter(request_source, needle);
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text_size");
        try expectMissing(result, "page");
    }
}

test "analysis completion: chevron blocks and comments do not create fake bindings or scopes" {
    var case = try CompletionCase.init(
        \\import std:themes/default as *
        \\
        \\page title
        \\  # let fake_comment = h2! "comment"
        \\  let t = h2! <<
        \\let fake_block = h2! "block"
        \\end
        \\>>
        \\  t.text_size = 1
        \\end
        \\
    );
    defer case.deinit();

    const request_source =
        \\import std:themes/default as *
        \\
        \\page title
        \\  # let fake_comment = h2! "comment"
        \\  let t = h2! <<
        \\let fake_block = h2! "block"
        \\end
        \\>>
        \\  t.
        \\end
        \\
    ;

    {
        var result = try case.completeSourceAfter(request_source, "t.");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectHas(result, "text_size");
        try expectMissing(result, "page");
    }

    {
        var result = try case.completeSourceAfter(request_source, "page title\n");
        defer result.deinit(case.allocator);
        try expectUnique(result);
        try expectMissing(result, "fake_comment");
        try expectMissing(result, "fake_block");
        try expectMissing(result, "text_size");
    }
}

const CompletionCase = struct {
    arena: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    index: completion.Index,

    fn init(source: []const u8) !CompletionCase {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        errdefer testing.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
        try std.Io.Dir.cwd().createDirPath(testing.io, root);
        const path = try std.fs.path.join(allocator, &.{ root, "case.ss" });
        const owned_source = try allocator.dupe(u8, source);
        const index = try buildIndex(allocator, path, source);
        return .{
            .arena = arena,
            .allocator = allocator,
            .path = path,
            .source = owned_source,
            .index = index,
        };
    }

    fn deinit(self: *CompletionCase) void {
        _ = self.index;
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn completeAfter(self: *CompletionCase, needle: []const u8) !completion.Result {
        return self.completeSourceAfter(self.source, needle);
    }

    fn completeSourceAfter(self: *CompletionCase, source: []const u8, needle: []const u8) !completion.Result {
        const offset = offsetAfter(source, needle);
        return completion.complete(self.allocator, &self.index, .{
            .doc_path = self.path,
            .source = source,
            .offset = offset,
        });
    }
};

fn buildIndex(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !completion.Index {
    const asset_base_dir = std.fs.path.dirname(path) orelse ".";
    var source_buf = try allocator.dupe(u8, source);
    var program = try compiler.syntax.parseWithSourceName(allocator, source_buf, path);
    var program_index = try compiler.typecheck.loadProgramIndex(allocator, testing.io, asset_base_dir, program);
    defer program_index.deinit();

    var ir = try compiler.typecheck.buildIrWithOptions(allocator, path, asset_base_dir, &source_buf, &program, &program_index, .{
        .allow_diagnostics = true,
    });
    defer ir.deinit();

    compiler.typecheck.typecheckProgram(allocator, &ir) catch {};
    return completion.Index.fromIr(allocator, &ir);
}

fn offsetAfter(source: []const u8, needle: []const u8) usize {
    const start = std.mem.indexOf(u8, source, needle) orelse @panic("needle not found");
    return start + needle.len;
}

fn expectHas(result: completion.Result, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return;
    }
    return error.ExpectedCompletionMissing;
}

fn expectMissing(result: completion.Result, label: []const u8) !void {
    for (result.items) |item| {
        if (std.mem.eql(u8, item.label, label)) return error.UnexpectedCompletionPresent;
    }
}

fn expectUnique(result: completion.Result) !void {
    var seen = std.StringHashMap(void).init(testing.allocator);
    defer seen.deinit();
    for (result.items) |item| {
        if (seen.contains(item.label)) return error.DuplicateCompletionLabel;
        try seen.put(item.label, {});
    }
}
