const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;
const allocation_testing = @import("allocation_testing");

test "core value text spec: placement references round trip exact node identifiers" {
    for ([_]core.NodeId{ 0, 1, 16777217, std.math.maxInt(core.NodeId) }) |id| {
        const original = core.Value{ .object = id };
        try testing.expect(core.value_text.propertyStringNeedsFree(original));
        const text = try core.value_text.propertyString(testing.allocator, original);
        defer testing.allocator.free(text);
        var parsed = try core.value_text.parsePropertyValue(testing.allocator, text);
        defer core.value_text.deinitParsedPropertyValue(testing.allocator, &parsed);
        try testing.expectEqual(id, parsed.object);
        var typed = try core.value_text.typedPropertyValue(testing.allocator, text, ast.Type.placement);
        defer core.value_text.deinitParsedPropertyValue(testing.allocator, &typed);
        try testing.expectEqual(id, typed.object);
    }
    for ([_][]const u8{ "-1", "1.5", "4294967296", "null", "\"1\"" }) |invalid| {
        const text = try std.fmt.allocPrint(testing.allocator, "{{\"kind\":\"object\",\"value\":{s}}}", .{invalid});
        defer testing.allocator.free(text);
        try testing.expectError(error.InvalidValueTag, core.value_text.parsePropertyValue(testing.allocator, text));
    }
}

const tagged_style_json =
    \\{"kind":"record","type":{"kind":"record","name":"TextStyle"},"fields":[{"name":"font","explicit":true,"value":{"kind":"record","type":{"kind":"record","name":"FontFace"},"fields":[{"name":"family","explicit":true,"value":{"kind":"string","value":"Helvetica"}},{"name":"weight","explicit":true,"value":{"kind":"enum","type":"FontWeight","case":"bold"}}]}},{"name":"line_height","explicit":false,"value":{"kind":"number","value":28}},{"name":"enabled","explicit":true,"value":{"kind":"bool","value":true}}]}
;

test "core value text spec: tagged property value deinit frees duplicated names and strings" {
    var value = try core.value_text.parsePropertyValue(testing.allocator, tagged_style_json);
    defer core.value_text.deinitParsedPropertyValue(testing.allocator, &value);

    try testing.expectEqualStrings("TextStyle", value.record.ty.class_name.?);
    const font = value.record.field("font").?.record;
    try testing.expectEqualStrings("FontFace", font.ty.class_name.?);
    try testing.expectEqualStrings("Helvetica", font.field("family").?.string);
    const weight = font.field("weight").?.enum_case;
    try testing.expectEqualStrings("FontWeight", weight.enum_name);
    try testing.expectEqualStrings("bold", weight.case_name);
}

test "core value text spec: class record defaults stay alive for the document state" {
    var state = try initDocumentStateWithTaggedRecordDefault();
    defer state.deinit();

    const document = state.getNode(state.graph.document_id).?;
    var first_family: ?[]const u8 = null;
    for (0..16) |_| {
        var slot = (try core.fields.get(testing.allocator, &state, document, "style")).?;
        try testing.expect(!slot.owned);
        try testing.expect(!slot.owns_tagged_text);
        try testing.expectEqualStrings("TextStyle", slot.value.record.ty.class_name.?);
        const font = slot.value.record.field("font").?.record;
        const family = font.field("family").?.string;
        try testing.expectEqualStrings("Helvetica", family);
        if (first_family) |first| try testing.expectEqual(first.ptr, family.ptr) else first_family = family;
        slot.deinit(testing.allocator);
    }

    try testing.expectEqualStrings(
        "Helvetica",
        core.fields.read(testing.allocator, &state, document, "style", &.{ "font", "family" }, .text).?,
    );
}

const ConcurrentDefaultReads = struct {
    state: *core.DocumentState,
    document: *const core.Node,
    ready: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    const thread_count = 8;
    const field_count = 32;

    fn run(self: *ConcurrentDefaultReads, thread_index: usize) void {
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (self.ready.load(.seq_cst) != thread_count) std.atomic.spinLoopHint();

        for (0..32) |iteration| {
            for (0..field_count) |offset| {
                var key_buffer: [32]u8 = undefined;
                const field_index = (thread_index + offset + iteration) % field_count;
                const key = std.fmt.bufPrint(&key_buffer, "style_{d}", .{field_index}) catch {
                    self.failed.store(true, .seq_cst);
                    return;
                };
                const family = core.fields.read(
                    testing.allocator,
                    self.state,
                    self.document,
                    key,
                    &.{ "font", "family" },
                    .text,
                ) orelse {
                    self.failed.store(true, .seq_cst);
                    return;
                };
                if (!std.mem.eql(u8, family, "Helvetica")) {
                    self.failed.store(true, .seq_cst);
                    return;
                }
            }
        }
    }
};

test "core value text spec: class record defaults are safe under parallel rendering" {
    var state = try initDocumentStateWithTaggedRecordDefault();
    defer state.deinit();

    var work = ConcurrentDefaultReads{
        .state = &state,
        .document = state.getNode(state.graph.document_id).?,
    };
    var threads: [ConcurrentDefaultReads.thread_count]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    while (started < threads.len) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, ConcurrentDefaultReads.run, .{ &work, started });
    }
    for (threads) |thread| thread.join();
    try testing.expect(!work.failed.load(.seq_cst));
}

fn initDocumentStateWithTaggedRecordDefault() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "value-text-defaults.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);

    var program = ast.Module.init();
    errdefer program.deinit(allocator);

    try program.records.append(allocator, .{
        .name = try allocator.dupe(u8, "PageSettings"),
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.records.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "style"),
        .value_type = ast.Type.recordType("TextStyle"),
        .default_property_value = try allocator.dupe(u8, tagged_style_json),
        .span = zeroSpan(),
    });
    for (0..ConcurrentDefaultReads.field_count) |index| {
        try program.records.items[0].fields.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "style_{d}", .{index}),
            .value_type = ast.Type.recordType("TextStyle"),
            .default_property_value = try allocator.dupe(u8, tagged_style_json),
            .span = zeroSpan(),
        });
    }

    var state = try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Module.init();
    errdefer state.deinit();
    try state.modules.order.append(allocator, state.modules.project_id);
    state.declaration_index.settings_module_id = state.modules.project_id;
    return state;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}

fn exerciseAppliedRecordTypes(allocator: std.mem.Allocator) !void {
    const Type = ast.Type;
    var optional = try Type.optional(allocator, Type.recordType("Inner").inModule(7));
    defer optional.deinit(allocator);
    var action = try Type.functionType(allocator, &.{optional}, .{ .kind = .void });
    defer action.deinit(allocator);
    var placed = try Type.placedOf(allocator, Type.recordType("Item").inModule(3));
    defer placed.deinit(allocator);
    var selected = try Type.selectionOf(allocator, placed);
    defer selected.deinit(allocator);
    var record = core.RecordValue.init(try Type.recordType("Box").inModule(2).withArguments(allocator, &.{ action, selected, Type.placement }));
    defer record.deinit(allocator);
    try record.fields.append(allocator, .{ .name = "count", .value = .{ .number = 3 } });
    var copy = try record.clone(allocator);
    defer copy.deinit(allocator);
    try testing.expect(Type.eql(record.ty, copy.ty));
    try testing.expect(record.ty.arguments.ptr != copy.ty.arguments.ptr);
    copy.ty.mutableArguments()[0].fn_params[0].optional_child.?.nominal_module_id = 8;
    try testing.expect(!Type.eql(record.ty, copy.ty));
    const encoded = try core.value_text.propertyString(allocator, .{ .record = record });
    defer allocator.free(encoded);
    var decoded = try core.value_text.typedPropertyValue(allocator, encoded, record.ty);
    defer core.value_text.deinitParsedPropertyValue(allocator, &decoded);
    try testing.expect(Type.eql(record.ty, decoded.record.ty));
    try testing.expectEqualStrings("Inner", decoded.record.ty.arguments[0].fn_params[0].optional_child.?.class_name.?);
    try testing.expectEqual(@as(?u32, 7), decoded.record.ty.arguments[0].fn_params[0].optional_child.?.nominal_module_id);
    if (core.value_text.typedPropertyValue(allocator, encoded, copy.ty)) |value| {
        var unexpected = value;
        defer core.value_text.deinitParsedPropertyValue(allocator, &unexpected);
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => try testing.expectEqual(error.InvalidValueTag, err),
    }
}

test "core value text spec: record values preserve complete type arguments through cloning and serialization" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseAppliedRecordTypes, .{});
}

test "core value text spec: malformed serialized record types are rejected" {
    for ([_][]const u8{
        "{\"kind\":\"number\"}",
        "{\"kind\":\"record\"}",
        "{\"kind\":\"record\",\"name\":\"\"}",
        "{\"kind\":\"object\"}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"object\",\"name\":\"Text\",\"module\":1}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"object\",\"name\":3}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"module\":-1}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"optional\"}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"function\",\"parameters\":[]}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"parameter\"}]}",
        "{\"kind\":\"unresolved\",\"name\":\"Box\"}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"unresolved\",\"name\":\"T\"}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"number\",\"arguments\":[]}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"placed\"}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"placed\",\"arguments\":[{\"kind\":\"number\"},{\"kind\":\"string\"}]}]}",
        "{\"kind\":\"record\",\"name\":\"Box\",\"arguments\":[{\"kind\":\"placement\",\"arguments\":[]}]}",
    }) |ty| {
        const source = try std.fmt.allocPrint(testing.allocator, "{{\"kind\":\"record\",\"type\":{s},\"fields\":[]}}", .{ty});
        defer testing.allocator.free(source);
        try testing.expectError(error.InvalidValueTag, core.value_text.parsePropertyValue(testing.allocator, source));
    }
}

test "core value text spec: unresolved names cannot be decoded or serialized as value types" {
    const Type = ast.Type;
    const name = Type.unresolvedNameAt("Missing", .{ .start = 0, .end = 7 });
    try testing.expectError(error.InvalidValueTag, core.value_text.typedPropertyValue(testing.allocator, "value", name));
    var optional = try Type.optional(testing.allocator, name);
    defer optional.deinit(testing.allocator);
    try testing.expectError(error.InvalidValueTag, core.value_text.typedPropertyValue(testing.allocator, "none", optional));
    var record = core.RecordValue.init(try Type.recordType("Box").inModule(0).withArguments(testing.allocator, &.{name}));
    defer record.deinit(testing.allocator);
    try testing.expectError(error.InvalidValueTag, core.value_text.propertyString(testing.allocator, .{ .record = record }));
}
