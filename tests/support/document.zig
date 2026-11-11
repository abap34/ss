const std = @import("std");
const core = @import("core");
const ast = @import("ast");

/// Build renderer inputs directly for tests below the evaluator boundary.
pub const FixtureInput = enum { text, code, image, pdf, icon, latex, path_shape };

pub fn native(state: *core.DocumentState, page: core.NodeId, name: []const u8, kind: FixtureInput, content: []const u8) !core.NodeId {
    const native_kind: core.native_display.Kind = switch (kind) {
        .text, .code => .text,
        .image, .pdf, .icon, .latex => .image,
        .path_shape => return error.UnsupportedNativeFixture,
    };
    var input = core.Value{ .record = .init(ast.Type.recordType(if (native_kind == .text) "Text" else "Image")) };
    defer input.deinit(state.allocator);
    var source = core.Value{ .record = .init(ast.Type.recordType(if (native_kind == .text) "TextContent" else "ImageSource")) };
    defer source.deinit(state.allocator);
    const owned = try state.copyString(content);
    try state.setStringProvenance(owned, state.stringProvenance(content));
    try source.record.fields.append(state.allocator, .{ .name = "source", .value = .{ .string = owned } });
    try put(state.allocator, &source.record, "kind", .{ .enum_case = .{ .enum_name = if (native_kind == .text) "TextContentKind" else "ImageSourceKind", .case_name = if (kind == .image) "file" else @tagName(kind) } });
    if (native_kind == .image) {
        try put(state.allocator, &source.record, "pdf_page", .{ .number = 1 });
        try put(state.allocator, &source.record, "pdf_box", .{ .enum_case = .{ .enum_name = "PdfPageBox", .case_name = "crop" } });
        try put(state.allocator, &source.record, "min_height", .{ .number = 30 });
    }
    try input.record.fields.append(state.allocator, .{ .name = "style", .value = .{ .record = .init(ast.Type.recordType("BlockStyle")) } });
    if (kind == .code) {
        const style = &input.record.fields.items[input.record.fields.items.len - 1].value.record;
        const layout = try ensureRecord(state.allocator, style, "layout");
        try put(state.allocator, layout, "wrap", .{ .enum_case = .{ .enum_name = "WrapMode", .case_name = "off" } });
    }
    if (native_kind == .text or kind == .latex) {
        var config = core.Value{ .record = .init(ast.Type.recordType("LatexConfig")) };
        defer config.deinit(state.allocator);
        try put(state.allocator, &config.record, "engine", .{ .enum_case = .{ .enum_name = "LatexEngine", .case_name = "pdflatex" } });
        try put(state.allocator, &config.record, "preamble", .{ .string = "" });
        try put(state.allocator, &source.record, "config", config);
    }
    try put(state.allocator, &input.record, if (native_kind == .text) "content" else "source", source);
    const id = try state.registerPlacement(page, input, null);
    const node = state.getNode(id).?;
    node.name = try state.copyString(name);
    node.placement.?.display = .{ .native = native_kind };
    return id;
}

pub fn group(state: *core.DocumentState, page: core.NodeId, children: []const core.NodeId, origin: ?core.SourceOrigin) !core.NodeId {
    return state.adoptGroup(page, children, .overlay, 32, origin);
}

/// Mutate test input records before preparation, following the native contract.
/// Production placements expose immutable inputs and never use this helper.
pub fn setField(state: *core.DocumentState, id: core.NodeId, key: []const u8, value: core.Value) !void {
    const node = state.getNode(id) orelse return error.UnknownNode;
    const placement = if (node.placement) |*p| p else return setStoredField(state, id, key, value);
    if (placement.display != .native) return setStoredField(state, id, key, value);
    if (std.mem.eql(u8, key, "semantics")) return put(state.allocator, &placement.value.record, key, value);
    if (std.mem.eql(u8, key, "language")) {
        const content = try ensureRecord(state.allocator, &placement.value.record, "content");
        return put(state.allocator, content, key, value);
    }
    var style: *core.RecordValue = undefined;
    for (placement.value.record.fields.items) |*field| {
        if (std.mem.eql(u8, field.name, "style")) {
            style = &field.value.record;
            break;
        }
    } else return error.MissingStyle;
    if (placement.display.native == .text and std.mem.eql(u8, key, "code")) {
        const content = try ensureRecord(state.allocator, &placement.value.record, "content");
        const highlight = try ensureRecord(state.allocator, content, "highlight");
        return put(state.allocator, highlight, key, value);
    }
    if (placement.display.native == .image and std.mem.eql(u8, key, "latex")) {
        const source = try ensureRecord(state.allocator, &placement.value.record, "source");
        if (value.record.field("min_height")) |height| try put(state.allocator, source, "min_height", height);
        const asset = try ensureRecord(state.allocator, style, "asset");
        for ([_][]const u8{ "scale", "align" }) |field| if (value.record.field(field)) |property| try put(state.allocator, asset, field, property);
        return;
    }
    if (placement.display.native == .image and std.mem.eql(u8, key, "asset")) {
        const source = try ensureRecord(state.allocator, &placement.value.record, "source");
        for ([_][]const u8{ "pdf_page", "pdf_box" }) |field| if (value.record.field(field)) |property| try put(state.allocator, source, field, property);
    }
    return put(state.allocator, style, if (std.mem.eql(u8, key, "markdown_headings")) "headings" else key, value);
}

fn setStoredField(state: *core.DocumentState, id: core.NodeId, key: []const u8, value: core.Value) !void {
    for (state.getNode(id).?.fields.items) |*field| if (std.mem.eql(u8, field.key, key)) {
        const copy = try value.clone(state.allocator);
        field.value.deinit(state.allocator);
        field.value = copy;
        return;
    };
    try state.setNodeFieldValue(id, key, value);
}

pub fn setPath(state: *core.DocumentState, id: core.NodeId, root: []const u8, path: []const []const u8, value: core.Value) !void {
    var record = if (state.getNodeField(id, root)) |existing| try existing.clone(state.allocator) else core.Value{ .record = .init(ast.Type.recordType("Style")) };
    defer record.deinit(state.allocator);
    var target = &record.record;
    for (path[0 .. path.len - 1]) |key| target = try ensureRecord(state.allocator, target, key);
    try put(state.allocator, target, path[path.len - 1], value);
    try setField(state, id, root, record);
}

fn ensureRecord(allocator: std.mem.Allocator, record: *core.RecordValue, key: []const u8) !*core.RecordValue {
    for (record.fields.items) |*field| if (std.mem.eql(u8, field.name, key)) return &field.value.record;
    try record.fields.append(allocator, .{ .name = key, .value = .{ .record = .init(ast.Type.recordType("Style")) } });
    return &record.fields.items[record.fields.items.len - 1].value.record;
}

fn put(allocator: std.mem.Allocator, record: *core.RecordValue, key: []const u8, value: core.Value) !void {
    var copy = try value.clone(allocator);
    errdefer copy.deinit(allocator);
    for (record.fields.items) |*field| if (std.mem.eql(u8, field.name, key)) {
        field.value.deinit(allocator);
        field.value = copy;
        field.explicit = true;
        return;
    };
    try record.fields.append(allocator, .{ .name = key, .value = copy, .explicit = true });
}
