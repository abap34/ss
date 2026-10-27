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

fn recordState() !core.DocumentState {
    const allocator = testing.allocator;
    const text = try allocator.dupe(u8,
        \\type Inner { label: String = "default" }
        \\type Outer { inner: Inner = Inner { label = "override" } }
        \\type Container { outer: Outer = Outer { inner = Inner { label = "override" } } }
    );
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
    var state = try recordState();
    defer state.deinit();
    try state.rebuildDeclarationIndex();
    try allocation_testing.checkAllAllocationFailures(testing.allocator, materializeDefaults, .{&state});
}
