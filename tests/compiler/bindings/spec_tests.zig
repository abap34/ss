const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const Type = compiler.language.Type;
const testing = std.testing;

fn document(allocator: std.mem.Allocator, source: []const u8) !core.DocumentState {
    var text = try allocator.dupe(u8, source);
    defer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "binding-spec.ss");
    defer syntax.deinit(allocator);
    var index = try compiler.analysis.loadModuleIndex(allocator, testing.io, ".", syntax, .{});
    defer index.deinit();
    return compiler.analysis.buildDocumentState(allocator, "binding-spec.ss", ".", &text, &syntax, &index);
}

fn expectType(state: *const core.DocumentState, name: []const u8, scope: []const u8, expected: compiler.language.Type) !void {
    for (state.definitions.items) |definition| {
        if (definition.kind != .variable or !std.mem.eql(u8, definition.name, name)) continue;
        if (!std.mem.eql(u8, definition.scope_name orelse "", scope)) continue;
        const info = state.bindingTypeAt(definition.module_id, definition.span_start) orelse return error.MissingBindingType;
        try testing.expect(compiler.language.Type.eql(expected, info.ty));
        return;
    }
    return error.MissingBindingDefinition;
}

test "binding types: repeated names preserve function page and branch scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try document(allocator,
        \\fn count(value: Number) -> Number
        \\  let local = value
        \\  return local
        \\end
        \\fn label(value: String) -> String
        \\  let local = value
        \\  return local
        \\end
        \\page first
        \\  let local = count(1)
        \\  if true
        \\    let nested = label("a")
        \\  end
        \\end
        \\page second
        \\  let local = label("b")
        \\end
    );
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(allocator, &state);
    try expectType(&state, "value", "count", Type.number);
    try expectType(&state, "local", "count", Type.number);
    try expectType(&state, "value", "label", Type.string);
    try expectType(&state, "local", "label", Type.string);
    try expectType(&state, "local", "first", Type.number);
    try expectType(&state, "nested", "first", Type.string);
    try expectType(&state, "local", "second", Type.string);
}

test "binding types: body diagnostics preserve checked facts from other scopes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try document(allocator,
        \\fn broken() -> Number = "invalid"
        \\fn useful(value: String) -> String = value
        \\page first
        \\  let local = useful("body")
        \\end
    );
    defer state.deinit();
    try testing.expectError(error.DiagnosticsFailed, compiler.analysis.analyzeDocumentState(allocator, &state));
    try expectType(&state, "value", "useful", Type.string);
    try expectType(&state, "local", "first", Type.string);
}

test "binding types: snapshots use checked facts without reinferring expressions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = try document(allocator, "page first\n  let amount = 2\nend\n");
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(allocator, &state);

    // A snapshot consumes the recorded judgment. Changing the expression after
    // checking makes any accidental second inference observably different.
    const expression = &state.projectModuleMutable().syntax.pages.items[0].statements.items[0].kind.let_binding.expr;
    expression.* = .{ .boolean = true };
    var snapshot = try compiler.analysis.snapshot.AnalysisSnapshot.fromDocumentState(
        allocator,
        &state,
        state.declaration_index,
        compiler.analysis.diagnostics.DiagnosticBag.init(allocator),
        null,
        .{},
    );
    defer snapshot.deinit();
    for (snapshot.variable_bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "amount")) continue;
        try testing.expectEqual(.number, binding.value_type.kind);
        try testing.expectEqualStrings("Number", binding.type_label);
        return;
    }
    return error.MissingBindingType;
}

test "binding types: same source offsets in imported modules remain distinct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sources = compiler.analysis.snapshot.SourceSet.init(allocator, testing.io);
    defer sources.deinit();
    try sources.put("binding-spec.ss", "import ./a as a\nimport ./b as b\npage main\nend\n");
    try sources.put("a.ss", "fn identity() -> Number\n  let shared = 1\n  return shared\nend\n");
    try sources.put("b.ss", "fn identity() -> String\n  let shared = \"a\"\n  return shared\nend\n");
    var snapshot = try compiler.analysis.snapshot.build(allocator, &sources, "binding-spec.ss", ".", .{});
    defer snapshot.deinit();
    errdefer for (snapshot.diagnostics.items.items) |diagnostic| std.debug.print("{s}: {s}\n", .{ diagnostic.code, diagnostic.message });
    try testing.expect(!snapshot.diagnostics.hasErrors());
    var number_module: ?core.SourceModuleId = null;
    var string_module: ?core.SourceModuleId = null;
    var first_offset: ?usize = null;
    for (snapshot.variable_bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "shared")) continue;
        if (first_offset) |offset| try testing.expectEqual(offset, binding.span_start) else first_offset = binding.span_start;
        switch (binding.value_type.kind) {
            .number => number_module = binding.module_id,
            .string => string_module = binding.module_id,
            else => return error.UnexpectedBindingType,
        }
    }
    try testing.expect(number_module != null);
    try testing.expect(string_module != null);
    try testing.expect(number_module.? != string_module.?);
}
