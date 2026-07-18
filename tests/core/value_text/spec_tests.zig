const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;

const tagged_style_json =
    \\{"kind":"record","type":"TextStyle","fields":[{"name":"font","explicit":true,"value":{"kind":"record","type":"FontFace","fields":[{"name":"family","explicit":true,"value":{"kind":"string","value":"Helvetica"}},{"name":"weight","explicit":true,"value":{"kind":"enum","type":"FontWeight","case":"bold"}}]}},{"name":"line_height","explicit":false,"value":{"kind":"number","value":28}},{"name":"enabled","explicit":true,"value":{"kind":"bool","value":true}}]}
;

test "core value text spec: tagged property value deinit frees duplicated names and strings" {
    var value = try core.value_text.parsePropertyValue(testing.allocator, tagged_style_json);
    defer core.value_text.deinitParsedPropertyValue(testing.allocator, &value);

    try testing.expectEqualStrings("TextStyle", value.record.type_name);
    const font = value.record.field("font").?.record;
    try testing.expectEqualStrings("FontFace", font.type_name);
    try testing.expectEqualStrings("Helvetica", font.field("family").?.string);
    const weight = font.field("weight").?.enum_case;
    try testing.expectEqualStrings("FontWeight", weight.enum_name);
    try testing.expectEqualStrings("bold", weight.case_name);
}

test "core value text spec: class record defaults stay alive for the document state" {
    var state = try initDocumentStateWithTaggedRecordDefault();
    defer state.deinit();

    const document = state.getNode(state.document_id).?;
    var first_family: ?[]const u8 = null;
    for (0..16) |_| {
        var slot = (try core.fields.get(testing.allocator, &state, document, "style")).?;
        try testing.expect(!slot.owned);
        try testing.expect(!slot.owns_tagged_text);
        try testing.expectEqualStrings("TextStyle", slot.value.record.type_name);
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
        .document = state.getNode(state.document_id).?,
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

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "style"),
        .value_type = ast.Type.recordType("TextStyle"),
        .default_property_value = try allocator.dupe(u8, tagged_style_json),
        .span = zeroSpan(),
    });
    for (0..ConcurrentDefaultReads.field_count) |index| {
        try program.objects.items[0].fields.append(allocator, .{
            .name = try std.fmt.allocPrint(allocator, "style_{d}", .{index}),
            .value_type = ast.Type.recordType("TextStyle"),
            .default_property_value = try allocator.dupe(u8, tagged_style_json),
            .span = zeroSpan(),
        });
    }

    var state = try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Module.init();
    errdefer state.deinit();
    try state.module_order.append(allocator, state.project_module_id);
    return state;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}
