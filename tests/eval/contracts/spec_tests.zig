const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const Type = ast.Type;
const contracts = @import("value_contracts");
const testing = std.testing;

test "runtime contracts: nominal values retain all applied type arguments" {
    const allocator = testing.allocator;
    var number_box = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{Type.number});
    defer number_box.deinit(allocator);
    var string_box = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{Type.string});
    defer string_box.deinit(allocator);
    var nested = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{number_box});
    defer nested.deinit(allocator);
    var other_nested = try Type.recordType("Box").inModule(1).withArguments(allocator, &.{string_box});
    defer other_nested.deinit(allocator);
    var optional = try Type.optional(allocator, nested);
    defer optional.deinit(allocator);
    var other_optional = try Type.optional(allocator, other_nested);
    defer other_optional.deinit(allocator);
    var value = core.Value{ .record = .init(try nested.clone(allocator)) };
    defer value.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const state_allocator = arena.allocator();
    var state = try core.DocumentState.init(
        state_allocator,
        try state_allocator.dupe(u8, "."),
        try state_allocator.dupe(u8, "contracts.ss"),
        try state_allocator.dupe(u8, ""),
        ast.Module.init(),
    );
    defer state.deinit();
    try testing.expect(contracts.valueConformsToType(&state, value, nested));
    try testing.expect(contracts.valueConformsToType(&state, value, optional));
    try testing.expect(!contracts.valueConformsToType(&state, value, other_nested));
    try testing.expect(!contracts.valueConformsToType(&state, value, other_optional));
    try testing.expect(!contracts.valueConformsToType(&state, value, number_box));
    try testing.expect(!contracts.valueConformsToType(&state, value, Type.recordType("Box").inModule(1)));
    try testing.expect(!contracts.valueConformsToType(&state, value, nested.inModule(2)));
}
