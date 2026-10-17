const std = @import("std");
const analysis = @import("analysis");
const testing = std.testing;

test "inferred types and facts are released with successful and failed generations" {
    const prefix =
        \\type Payload { amount: Number? = none }
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
                const path = "stdlib/internal/inference-ownership-test.ss";
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

test "generic instances retain owned declarations across snapshot generations" {
    for ([_]bool{ false, true }) |invalid| {
        const source = if (invalid)
            "fn identity<T>(value: T) -> T = value + 1\npage main\nlet value = identity(\"Text\")\nend\n"
        else
            "fn identity<T>(value: T) -> T\nlet copy: T = value\nreturn copy\nend\npage main\nlet number = identity(3)\nlet text = identity(\"Text\")\nend\n";
        var sources = analysis.snapshot.SourceSet.init(testing.allocator, testing.io);
        defer sources.deinit();
        const path = "stdlib/internal/generic-ownership-test.ss";
        try sources.put(path, source);
        var snapshot = try analysis.snapshot.build(testing.allocator, &sources, path, ".", .{ .retain_layout_inputs = true });
        defer snapshot.deinit();
        try testing.expectEqual(invalid, snapshot.diagnostics.hasErrors());
        if (!invalid) {
            const state = &snapshot.retained_layout_inputs.?.state;
            try testing.expectEqual(@as(usize, 2), state.instantiations.entries.items.len);
            const parameter_offset = std.mem.indexOf(u8, source, "value: T").?;
            try testing.expectEqual(.parameter, state.bindingTypeAt(0, parameter_offset).?.ty.kind);
            const local_offset = std.mem.indexOf(u8, source, "copy: T").?;
            try testing.expectEqual(.parameter, state.bindingTypeAt(0, local_offset).?.ty.kind);
            const offset = std.mem.indexOf(u8, source, "let number").? + "let ".len;
            try testing.expectEqual(.number, state.bindingTypeAt(0, offset).?.ty.kind);
            const text_offset = std.mem.indexOf(u8, source, "let text").? + "let ".len;
            try testing.expectEqual(.string, state.bindingTypeAt(0, text_offset).?.ty.kind);
        }
    }
}
