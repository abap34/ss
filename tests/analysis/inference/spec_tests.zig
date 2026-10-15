const std = @import("std");
const analysis = @import("analysis");
const testing = std.testing;

test "inferred types and facts are released with successful and failed generations" {
    const prefix =
        \\record Payload { amount: Number? = none }
        \\fn identity(value: Number?) -> Number? = value
        \\fn choose(flag: Bool) -> Number -> Number
        \\  if flag
        \\    return (x: Number) |-> x + 1
        \\  else
        \\    return (x: Number) |-> x + 2
        \\  end
        \\end
        \\page sample
        \\  let callback = choose(true)
        \\  let named = identity
        \\  let data = Payload {}
        \\  let value = identity(data.amount)
        \\
    ;
    for (0..4) |generation| {
        for ([_]bool{ false, true }) |invalid| {
            for ([_]bool{ false, true }) |retain| {
                const source = try std.mem.concat(testing.allocator, u8, &.{ prefix, if (invalid) "let bad: Number = \"wrong\"\nend\n" else "end\n" });
                defer testing.allocator.free(source);
                var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
                defer sources.deinit();
                const path = "stdlib/core/inference-ownership-test.ss";
                try sources.put(path, source);
                var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{
                    .generation = generation,
                    .retain_layout_inputs = retain,
                });
                defer snapshot.deinit();
                try testing.expectEqual(invalid, snapshot.diagnostics.hasErrors());
                if (!invalid and retain) {
                    var inputs = snapshot.retained_layout_inputs.?;
                    snapshot.retained_layout_inputs = null;
                    var retained = analysis.snapshot.RetainedLayoutState{ .state = inputs.state };
                    defer retained.deinit();
                    defer inputs.graph.deinit();
                    const offset = std.mem.indexOf(u8, source, "let callback").? + "let ".len;
                    const info = retained.state.bindingTypeAt(0, offset).?;
                    try testing.expectEqual(.function, info.ty.kind);
                    try testing.expectEqual(.number, info.ty.fn_result.?.kind);
                    const buffer = try retained.state.inferenceAllocator().dupe(u8, "moved state");
                    try testing.expectEqualStrings("moved state", buffer);
                }
            }
        }
    }
}
