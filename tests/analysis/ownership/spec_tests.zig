const std = @import("std");
const compiler = @import("compiler");
const allocation_testing = @import("allocation_testing");
const testing = std.testing;
const core = compiler.core;

const Environment = compiler.analysis_env.ValueEnv([]const u8);

fn exerciseEnvironment(allocator: std.mem.Allocator) !void {
    const input = try allocator.dupe(u8, "original");
    defer allocator.free(input);
    var env = Environment.init(allocator);
    defer env.deinit();
    try env.bind("first", input);
    try env.bind("second", input);
    try env.bind("first", env.lookup("first").?);
    var copied = try env.clone();
    defer copied.deinit();
    try env.bind("first", "replacement");
    try testing.expectEqualStrings("replacement", env.lookup("first").?);
    try testing.expectEqualStrings("original", copied.lookup("first").?);
    try testing.expect(copied.lookup("first").?.ptr == input.ptr);
    try testing.expect(env.lookup("second").?.ptr == input.ptr);
}

test "analysis environments own binding maps and borrow immutable values at every allocation failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseEnvironment, .{});
}

fn parsedState(source: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    const text = try allocator.dupe(u8, source);
    errdefer allocator.free(text);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, text, "ownership.ss");
    errdefer syntax.deinit(allocator);
    const path = try allocator.dupe(u8, "ownership.ss");
    errdefer allocator.free(path);
    const base = try allocator.dupe(u8, ".");
    errdefer allocator.free(base);
    return core.DocumentState.init(allocator, base, path, text, syntax);
}

fn materializeDefaults(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    // Only generated defaults use the failing allocator; syntax and declarations
    // belong to the surrounding fixture and remain valid for the next attempt.
    defer for (state.projectSyntax().records.items) |*record| {
        for (record.fields.items) |*field| {
            if (field.default_property_value) |value| allocator.free(value);
            field.default_property_value = null;
        }
    };
    const sema = compiler.semantic_env.SemanticEnv.init(state, state.declaration_index, &state.functions);
    try compiler.analysis_semantics.resolveEnumCaseExpressionsAndDefaults(allocator, state, &sema);
    const value = state.projectSyntax().records.items[2].fields.items[0].default_property_value.?;
    try testing.expect(std.mem.indexOf(u8, value, "override") != null);
}

test "nested record defaults have one owner at every allocation failure" {
    var state = try parsedState(
        \\type Inner { label: String = "default" }
        \\type Outer { inner: Inner = Inner { label = "override" } }
        \\type Container { outer: Outer = Outer { inner = Inner { label = "override" } } }
    );
    defer state.deinit();
    try state.rebuildDeclarationIndex();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, materializeDefaults, .{&state});
}

fn checkCallableFacts(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    try compiler.analysis.checkFunctionDefinitions(allocator, state, &state.functions);
}

fn callableState() !core.DocumentState {
    var state = try parsedState(
        \\type Handler { run: Number -> Number }
        \\type Settings { first: Handler second: Handler }
        \\fn inc(value: Number) -> Number = value + 1
        \\fn twice(value: Number) -> Number = value * 2
        \\const seed: Settings = Settings { first = Handler { run = inc } second = Handler { run = twice } }
        \\fn choose(first: Settings, second: Settings, flag: Bool) -> Settings
        \\  if flag
        \\    return first
        \\  else
        \\    return second
        \\  end
        \\end
        \\fn capture(settings: Settings) -> Number -> Number = (value: Number) |-> settings.first.run(value)
        \\fn invoke() -> Number
        \\  let updated = seed with { first.run = seed.second.run }
        \\  let joined = choose(seed, updated, false)
        \\  let saved = capture(joined)
        \\  return saved(3) + seed.first.run(3)
        \\end
        \\document
        \\  let result = invoke()
        \\end
    );
    errdefer state.deinit();
    try state.modules.order.append(testing.allocator, 0);
    const sema = compiler.semantic_env.SemanticEnv.init(&state, state.declaration_index, &state.functions);
    try compiler.analysis_semantics.resolveTypeReferences(testing.allocator, &state, &sema);
    try state.rebuildDeclarationIndex();
    for (state.projectSyntax().functions.items) |function| {
        try state.functions.put(core.functionDeclarationKey(0, function), function);
    }
    for (state.projectSyntax().constants.items) |constant| {
        try state.constants.declarations.put(core.constKey(0, constant.name), constant);
    }
    return state;
}

test "shared callable facts release pass storage at every allocation failure" {
    var state = try callableState();
    defer state.deinit();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, checkCallableFacts, .{&state});
}

const CancelCallAnalysis = struct {
    checks: usize = 0,
    limit: usize,

    fn canceled(context: *const anyopaque) bool {
        const self: *CancelCallAnalysis = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.limit;
    }
};

test "canceled callable analysis releases shared snapshots and can be repeated" {
    var state = try callableState();
    defer state.deinit();
    for ([_]usize{ 1, 8, 24 }) |limit| {
        var cancellation = CancelCallAnalysis{ .limit = limit };
        state.runtime.analysis_cancellation = .{ .context = &cancellation, .is_canceled = CancelCallAnalysis.canceled };
        defer state.runtime.analysis_cancellation = null;
        try testing.expectError(error.Canceled, checkCallableFacts(testing.allocator, &state));
        try testing.expect(cancellation.checks >= limit);
        state.runtime.analysis_cancellation = null;
        try checkCallableFacts(testing.allocator, &state);
    }
}
