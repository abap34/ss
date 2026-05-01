const std = @import("std");
const model = @import("model.zig");
const render_policy = @import("render_policy.zig");
const markdown = @import("markdown.zig");

const Allocator = model.Allocator;
const Constraint = model.Constraint;
const Diagnostic = model.Diagnostic;

pub fn dumpToString(engine: anytype, allocator: Allocator) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);
    try text.appendSlice(allocator, "Document graph\n");

    for (engine.page_order.items) |page_id| {
        const page = engine.getNode(page_id) orelse continue;
        try appendFmt(allocator, &text, "\nPage {d}: {s}\n", .{ page.page_index.?, page.name });
        const children = engine.contains.get(page_id) orelse continue;
        for (children.items) |child_id| {
            const child = engine.getNode(child_id) orelse continue;
            try appendFmt(
                allocator,
                &text,
                "  - #{d} {s} kind={s} role={s}",
                .{
                    child.id,
                    child.name,
                    @tagName(child.kind),
                    child.role orelse "none",
                },
            );
            if (child.derived_from) |from_id| {
                try appendFmt(allocator, &text, " derived_from=#{d}", .{from_id});
            }
            if (child.origin) |origin| {
                try appendFmt(allocator, &text, " origin={s}", .{origin});
            }
            if (child.payload_kind) |payload_kind| {
                try appendFmt(allocator, &text, " payload={s}", .{@tagName(payload_kind)});
            }
            if (child.content) |content| {
                try appendFmt(allocator, &text, " content=\"{s}\"", .{content});
            }
            if (child.properties.items.len > 0) {
                try text.appendSlice(allocator, " props={");
                for (child.properties.items, 0..) |property, index| {
                    if (index != 0) try text.appendSlice(allocator, ", ");
                    try appendFmt(allocator, &text, "{s}={s}", .{ property.key, property.value });
                }
                try text.appendSlice(allocator, "}");
            }
            try appendFmt(
                allocator,
                &text,
                " frame=({d:.1}, {d:.1}, {d:.1}, {d:.1})\n",
                .{ child.frame.x, child.frame.y, child.frame.width, child.frame.height },
            );
        }
    }

    if (engine.constraints.items.len > 0) {
        try text.appendSlice(allocator, "\nConstraints\n");
        for (engine.constraints.items) |constraint| {
            const line = try formatConstraint(allocator, constraint);
            try appendFmt(allocator, &text, "{s}\n", .{line});
        }
    }

    if (engine.diagnostics.items.len > 0) {
        try text.appendSlice(allocator, "\nDiagnostics\n");
        for (engine.diagnostics.items) |diagnostic| {
            const line = try formatDiagnostic(allocator, diagnostic);
            try appendFmt(allocator, &text, "{s}\n", .{line});
        }
    }

    return text.toOwnedSlice(allocator);
}

pub fn dumpJsonToString(engine: anytype, allocator: Allocator) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);

    try text.appendSlice(allocator, "{\n");
    try text.appendSlice(allocator, "  \"stage\": \"finalized_semantic_graph\",\n");
    try text.appendSlice(allocator, "  \"document_id\": ");
    try appendJsonInt(allocator, &text, engine.document_id);
    try text.appendSlice(allocator, ",\n");
    try text.appendSlice(allocator, "  \"page_order\": [");
    for (engine.page_order.items, 0..) |page_id, index| {
        if (index != 0) try text.appendSlice(allocator, ", ");
        try appendJsonInt(allocator, &text, page_id);
    }
    try text.appendSlice(allocator, "],\n");

    try text.appendSlice(allocator, "  \"nodes\": [\n");
    var visible_index: usize = 0;
    for (engine.nodes.items) |node| {
        if ((node.kind == .object or node.kind == .derived) and !node.attached) continue;
        if (visible_index != 0) try text.appendSlice(allocator, ",\n");
        visible_index += 1;
        const render = render_policy.resolve(engine, &node);
        const should_parse_blocks = markdown.shouldParseBlocks(
            node.role,
            if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
        ) and node.content != null;
        const should_parse_inline = markdown.shouldParseInline(
            node.role,
            if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
        ) and node.content != null and !should_parse_blocks;
        var markdown_doc_storage = markdown.MarkdownDocument.init(allocator);
        defer markdown_doc_storage.deinit();
        var inline_layout_storage: markdown.TextLayout = .{};
        defer if (should_parse_inline) inline_layout_storage.deinit(allocator);
        if (should_parse_blocks) {
            markdown_doc_storage = try markdown.parseMarkdownDocument(
                allocator,
                node.role,
                if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
                node.content.?,
            );
        }
        if (should_parse_inline) {
            inline_layout_storage = try markdown.parseTextLayout(
                allocator,
                node.role,
                if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
                node.content.?,
            );
        }
        try text.appendSlice(allocator, "    {");
        try appendJsonFieldInt(allocator, &text, "id", node.id, true);
        try appendJsonFieldString(allocator, &text, "kind", @tagName(node.kind), true);
        try appendJsonFieldString(allocator, &text, "name", node.name, true);
        try appendJsonFieldOptionalString(allocator, &text, "role", node.role, true);
        try appendJsonFieldOptionalEnumTag(allocator, &text, "object_kind", node.object_kind, true);
        try appendJsonFieldOptionalEnumTag(allocator, &text, "payload_kind", node.payload_kind, true);
        try appendJsonFieldOptionalString(allocator, &text, "content", node.content, true);
        if (should_parse_blocks) {
            try appendJsonFieldMarkdownBlocks(allocator, &text, "blocks", markdown_doc_storage, true);
        } else {
            try appendJsonFieldNull(allocator, &text, "blocks", true);
        }
        if (should_parse_inline) {
            try appendJsonFieldInlineLines(allocator, &text, "inline_lines", inline_layout_storage, true);
        } else {
            try appendJsonFieldNull(allocator, &text, "inline_lines", true);
        }
        try appendJsonFieldProperties(allocator, &text, "properties", node.properties.items, true);
        try appendJsonFieldOptionalInt(allocator, &text, "page_index", node.page_index, true);
        try appendJsonFieldOptionalInt(allocator, &text, "derived_from", node.derived_from, true);
        try appendJsonFieldOptionalString(allocator, &text, "origin", node.origin, true);
        try appendJsonFieldFloat(allocator, &text, "x", node.frame.x, true);
        try appendJsonFieldFloat(allocator, &text, "y", node.frame.y, true);
        try appendJsonFieldFloat(allocator, &text, "width", node.frame.width, true);
        try appendJsonFieldFloat(allocator, &text, "height", node.frame.height, true);
        try appendJsonFieldRender(allocator, &text, "render", render, false);
        try text.appendSlice(allocator, "}");
    }
    try text.appendSlice(allocator, "\n  ],\n");

    try text.appendSlice(allocator, "  \"contains\": [\n");
    var contain_index: usize = 0;
    var it = engine.contains.iterator();
    while (it.next()) |entry| {
        if (contain_index != 0) try text.appendSlice(allocator, ",\n");
        contain_index += 1;
        try text.appendSlice(allocator, "    {");
        try appendJsonFieldInt(allocator, &text, "parent", entry.key_ptr.*, true);
        try text.appendSlice(allocator, "\"children\": [");
        for (entry.value_ptr.items, 0..) |child_id, child_index| {
            if (child_index != 0) try text.appendSlice(allocator, ", ");
            try appendJsonInt(allocator, &text, child_id);
        }
        try text.appendSlice(allocator, "]}");
    }
    try text.appendSlice(allocator, "\n  ],\n");

    try text.appendSlice(allocator, "  \"constraints\": [\n");
    for (engine.constraints.items, 0..) |constraint, index| {
        if (index != 0) try text.appendSlice(allocator, ",\n");
        try text.appendSlice(allocator, "    {");
        try appendJsonFieldInt(allocator, &text, "target_node", constraint.target_node, true);
        try appendJsonFieldString(allocator, &text, "target_anchor", @tagName(constraint.target_anchor), true);
        switch (constraint.source) {
            .page => |anchor| {
                try appendJsonFieldString(allocator, &text, "source_kind", "page", true);
                try appendJsonFieldString(allocator, &text, "source_anchor", @tagName(anchor), true);
                try appendJsonFieldNull(allocator, &text, "source_node", true);
            },
            .node => |source| {
                try appendJsonFieldString(allocator, &text, "source_kind", "node", true);
                try appendJsonFieldString(allocator, &text, "source_anchor", @tagName(source.anchor), true);
                try appendJsonFieldInt(allocator, &text, "source_node", source.node_id, true);
            },
        }
        try appendJsonFieldFloat(allocator, &text, "offset", constraint.offset, false);
        try text.appendSlice(allocator, "}");
    }
    try text.appendSlice(allocator, "\n  ],\n");

    try text.appendSlice(allocator, "  \"diagnostics\": [\n");
    for (engine.diagnostics.items, 0..) |diagnostic, index| {
        if (index != 0) try text.appendSlice(allocator, ",\n");
        try text.appendSlice(allocator, "    {");
        try appendJsonFieldString(allocator, &text, "phase", @tagName(diagnostic.phase), true);
        try appendJsonFieldString(allocator, &text, "severity", @tagName(diagnostic.severity), true);
        try appendJsonFieldOptionalInt(allocator, &text, "page_id", diagnostic.page_id, true);
        try appendJsonFieldOptionalInt(allocator, &text, "node_id", diagnostic.node_id, true);
        try appendJsonFieldOptionalString(allocator, &text, "origin", diagnostic.origin, true);
        switch (diagnostic.data) {
            .user_report => |data| {
                try appendJsonFieldString(allocator, &text, "code", "user_report", true);
                try appendJsonFieldString(allocator, &text, "message", data.message, false);
            },
            .asset_not_found => |data| {
                try appendJsonFieldString(allocator, &text, "code", "asset_not_found", true);
                try appendJsonFieldString(allocator, &text, "requested_path", data.requested_path, true);
                try appendJsonFieldString(allocator, &text, "resolved_path", data.resolved_path, true);
                try appendJsonFieldOptionalEnumTag(allocator, &text, "payload_kind", data.payload_kind, false);
            },
            .asset_invalid => |data| {
                try appendJsonFieldString(allocator, &text, "code", "asset_invalid", true);
                try appendJsonFieldString(allocator, &text, "reason", data.reason, true);
                try appendJsonFieldOptionalEnumTag(allocator, &text, "payload_kind", data.payload_kind, false);
            },
            .type_mismatch => |data| {
                try appendJsonFieldString(allocator, &text, "code", @tagName(data.code), true);
                try appendJsonFieldString(allocator, &text, "expected", @tagName(data.expected), true);
                try appendJsonFieldString(allocator, &text, "actual", @tagName(data.actual), false);
            },
            .recursive_function => |data| {
                try appendJsonFieldString(allocator, &text, "code", "RecursiveFunction", true);
                try appendJsonFieldString(allocator, &text, "function_name", data.function_name, false);
            },
            .unresolved_frame => |data| {
                try appendJsonFieldString(allocator, &text, "code", "unresolved_frame", true);
                try appendJsonFieldBool(allocator, &text, "missing_horizontal", data.missing_horizontal, true);
                try appendJsonFieldBool(allocator, &text, "missing_vertical", data.missing_vertical, false);
            },
            .page_overflow => |data| {
                try appendJsonFieldString(allocator, &text, "code", "page_overflow", true);
                try appendJsonFieldFloat(allocator, &text, "overflow_left", data.overflow_left, true);
                try appendJsonFieldFloat(allocator, &text, "overflow_right", data.overflow_right, true);
                try appendJsonFieldFloat(allocator, &text, "overflow_top", data.overflow_top, true);
                try appendJsonFieldFloat(allocator, &text, "overflow_bottom", data.overflow_bottom, false);
            },
        }
        try text.appendSlice(allocator, "}");
    }
    try text.appendSlice(allocator, "\n  ]\n");
    try text.appendSlice(allocator, "}\n");

    return text.toOwnedSlice(allocator);
}

pub fn formatConstraint(allocator: Allocator, constraint: Constraint) ![]const u8 {
    const source_text = switch (constraint.source) {
        .page => |anchor| try std.fmt.allocPrint(allocator, "page.{s}", .{@tagName(anchor)}),
        .node => |source| try std.fmt.allocPrint(allocator, "#{d}.{s}", .{ source.node_id, @tagName(source.anchor) }),
    };
    return std.fmt.allocPrint(
        allocator,
        "  - #{d}.{s} = {s} {s} {d:.1}",
        .{
            constraint.target_node,
            @tagName(constraint.target_anchor),
            source_text,
            if (constraint.offset < 0) "-" else "+",
            @abs(constraint.offset),
        },
    );
}

pub fn formatDiagnostic(allocator: Allocator, diagnostic: Diagnostic) ![]const u8 {
    const page_text = if (diagnostic.page_id) |page_id|
        try std.fmt.allocPrint(allocator, " page=#{d}", .{page_id})
    else
        "";
    const node_text = if (diagnostic.node_id) |node_id|
        try std.fmt.allocPrint(allocator, " node=#{d}", .{node_id})
    else
        "";

    return switch (diagnostic.data) {
        .user_report => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} UserReport {s}",
            .{ @tagName(diagnostic.phase), @tagName(diagnostic.severity), page_text, node_text, data.message },
        ),
        .asset_not_found => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} asset_not_found requested={s} resolved={s}",
            .{ @tagName(diagnostic.phase), @tagName(diagnostic.severity), page_text, node_text, data.requested_path, data.resolved_path },
        ),
        .asset_invalid => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} asset_invalid {s}",
            .{ @tagName(diagnostic.phase), @tagName(diagnostic.severity), page_text, node_text, data.reason },
        ),
        .type_mismatch => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} {s} expected={s} actual={s}",
            .{ @tagName(diagnostic.phase), @tagName(diagnostic.severity), page_text, node_text, @tagName(data.code), @tagName(data.expected), @tagName(data.actual) },
        ),
        .recursive_function => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} RecursiveFunction function={s}",
            .{ @tagName(diagnostic.phase), @tagName(diagnostic.severity), page_text, node_text, data.function_name },
        ),
        .unresolved_frame => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} unresolved_frame missing_horizontal={s} missing_vertical={s}",
            .{
                @tagName(diagnostic.phase),
                @tagName(diagnostic.severity),
                page_text,
                node_text,
                if (data.missing_horizontal) "true" else "false",
                if (data.missing_vertical) "true" else "false",
            },
        ),
        .page_overflow => |data| std.fmt.allocPrint(
            allocator,
            "  - [{s}/{s}]{s}{s} page_overflow left={d:.1} right={d:.1} top={d:.1} bottom={d:.1}",
            .{
                @tagName(diagnostic.phase),
                @tagName(diagnostic.severity),
                page_text,
                node_text,
                data.overflow_left,
                data.overflow_right,
                data.overflow_top,
                data.overflow_bottom,
            },
        ),
    };
}

fn appendFmt(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try buffer.appendSlice(allocator, text);
}

fn appendJsonFieldPrefix(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8) !void {
    try appendJsonString(allocator, buffer, key);
    try buffer.appendSlice(allocator, ": ");
}

fn appendJsonTrailingComma(allocator: Allocator, buffer: *std.ArrayList(u8), trailing_comma: bool) !void {
    if (trailing_comma) try buffer.appendSlice(allocator, ", ");
}

fn appendJsonObjectFieldStart(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.append(allocator, '{');
}

fn appendJsonFieldString(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8, value: []const u8, trailing_comma: bool) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try appendJsonString(allocator, buffer, value);
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldInt(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8, value: anytype, trailing_comma: bool) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try appendJsonInt(allocator, buffer, value);
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldFloat(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8, value: f32, trailing_comma: bool) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try appendFmt(allocator, buffer, "{d:.1}", .{value});
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldNull(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8, trailing_comma: bool) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.appendSlice(allocator, "null");
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldBool(allocator: Allocator, buffer: *std.ArrayList(u8), key: []const u8, value: bool, trailing_comma: bool) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.appendSlice(allocator, if (value) "true" else "false");
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldOptionalString(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: ?[]const u8,
    trailing_comma: bool,
) !void {
    if (value) |text| {
        try appendJsonFieldString(allocator, buffer, key, text, trailing_comma);
    } else {
        try appendJsonFieldNull(allocator, buffer, key, trailing_comma);
    }
}

fn appendJsonFieldOptionalInt(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
    trailing_comma: bool,
) !void {
    if (value) |number| {
        try appendJsonFieldInt(allocator, buffer, key, number, trailing_comma);
    } else {
        try appendJsonFieldNull(allocator, buffer, key, trailing_comma);
    }
}

fn appendJsonFieldOptionalEnumTag(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    value: anytype,
    trailing_comma: bool,
) !void {
    if (value) |tagged| {
        try appendJsonFieldString(allocator, buffer, key, @tagName(tagged), trailing_comma);
    } else {
        try appendJsonFieldNull(allocator, buffer, key, trailing_comma);
    }
}

fn appendJsonFieldProperties(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    properties: []const model.Property,
    trailing_comma: bool,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, key);
    for (properties, 0..) |property, index| {
        if (index != 0) try buffer.appendSlice(allocator, ", ");
        try appendJsonFieldPrefix(allocator, buffer, property.key);
        try appendJsonString(allocator, buffer, property.value);
    }
    try buffer.append(allocator, '}');
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldInlineLines(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    layout: markdown.TextLayout,
    trailing_comma: bool,
) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.append(allocator, '[');
    for (layout.lines.items, 0..) |line, line_index| {
        if (line_index != 0) try buffer.appendSlice(allocator, ", ");
        try buffer.appendSlice(allocator, "[");
        for (line.runs.items, 0..) |run, run_index| {
            if (run_index != 0) try buffer.appendSlice(allocator, ", ");
            try buffer.appendSlice(allocator, "{");
            try appendJsonFieldString(allocator, buffer, "kind", @tagName(run.kind), true);
            try appendJsonFieldString(allocator, buffer, "text", run.text, run.url != null or run.icon != null);
            if (run.url) |url| {
                try appendJsonFieldString(allocator, buffer, "url", url, run.icon != null);
            }
            if (run.icon) |icon| {
                try appendJsonFieldString(allocator, buffer, "icon", icon, false);
            }
            try buffer.appendSlice(allocator, "}");
        }
        try buffer.appendSlice(allocator, "]");
    }
    try buffer.append(allocator, ']');
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldMarkdownBlocks(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    doc: markdown.MarkdownDocument,
    trailing_comma: bool,
) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try appendJsonMarkdownBlocks(allocator, buffer, doc.blocks.items);
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonMarkdownBlocks(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    blocks: []const *markdown.Block,
) !void {
    try buffer.append(allocator, '[');
    for (blocks, 0..) |block, index| {
        if (index != 0) try buffer.appendSlice(allocator, ", ");
        try buffer.append(allocator, '{');
        try appendJsonFieldString(allocator, buffer, "kind", @tagName(block.kind), true);
        switch (block.kind) {
            .paragraph => {
                const paragraph = block.paragraph.?;
                try appendJsonFieldInlineLinesFromLines(allocator, buffer, "lines", paragraph.lines.items, false);
            },
            .code_block => {
                const paragraph = block.paragraph.?;
                try appendJsonFieldOptionalString(allocator, buffer, "language", block.language, true);
                try appendJsonFieldInlineLinesFromLines(allocator, buffer, "lines", paragraph.lines.items, false);
            },
            .bullet_list, .ordered_list => {
                const list = block.list.?;
                try appendJsonFieldInt(allocator, buffer, "start", list.start, true);
                try appendJsonFieldPrefix(allocator, buffer, "items");
                try buffer.append(allocator, '[');
                for (list.items.items, 0..) |item, item_index| {
                    if (item_index != 0) try buffer.appendSlice(allocator, ", ");
                    try buffer.append(allocator, '{');
                    try appendJsonFieldPrefix(allocator, buffer, "blocks");
                    try appendJsonMarkdownBlocks(allocator, buffer, item.blocks.items);
                    try buffer.append(allocator, '}');
                }
                try buffer.append(allocator, ']');
            },
        }
        try buffer.append(allocator, '}');
    }
    try buffer.append(allocator, ']');
}

fn appendJsonFieldInlineLinesFromLines(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    lines: []const markdown.Line,
    trailing_comma: bool,
) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.append(allocator, '[');
    for (lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.appendSlice(allocator, ", ");
        try buffer.appendSlice(allocator, "[");
        for (line.runs.items, 0..) |run, run_index| {
            if (run_index != 0) try buffer.appendSlice(allocator, ", ");
            try buffer.appendSlice(allocator, "{");
            try appendJsonFieldString(allocator, buffer, "kind", @tagName(run.kind), true);
            try appendJsonFieldString(allocator, buffer, "text", run.text, run.url != null or run.icon != null);
            if (run.url) |url| {
                try appendJsonFieldString(allocator, buffer, "url", url, run.icon != null);
            }
            if (run.icon) |icon| {
                try appendJsonFieldString(allocator, buffer, "icon", icon, false);
            }
            try buffer.appendSlice(allocator, "}");
        }
        try buffer.appendSlice(allocator, "]");
    }
    try buffer.append(allocator, ']');
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonRenderTextSpec(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    text_spec: render_policy.TextPaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "text");
    try appendJsonFieldString(allocator, buffer, "font", text_spec.font, true);
    try appendJsonFieldString(allocator, buffer, "bold_font", text_spec.bold_font, true);
    try appendJsonFieldString(allocator, buffer, "italic_font", text_spec.italic_font, true);
    try appendJsonFieldString(allocator, buffer, "code_font", text_spec.code_font, true);
    try appendJsonFieldFloat(allocator, buffer, "font_size", text_spec.font_size, true);
    try appendJsonFieldFloat(allocator, buffer, "line_height", text_spec.line_height, true);
    try appendJsonFieldColor(allocator, buffer, "color", text_spec.color, true);
    try appendJsonFieldColor(allocator, buffer, "link_color", text_spec.link_color, true);
    try appendJsonFieldFloat(allocator, buffer, "link_underline_width", text_spec.link_underline_width, true);
    try appendJsonFieldFloat(allocator, buffer, "link_underline_offset", text_spec.link_underline_offset, true);
    try appendJsonFieldFloat(allocator, buffer, "inline_math_height_factor", text_spec.inline_math_height_factor, true);
    try appendJsonFieldFloat(allocator, buffer, "inline_math_spacing", text_spec.inline_math_spacing, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_block_gap", text_spec.markdown_block_gap, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_list_indent", text_spec.markdown_list_indent, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_font_size", text_spec.markdown_code_font_size, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_line_height", text_spec.markdown_code_line_height, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_pad_x", text_spec.markdown_code_pad_x, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_pad_y", text_spec.markdown_code_pad_y, true);
    try appendJsonFieldOptionalColor(allocator, buffer, "markdown_code_fill", text_spec.markdown_code_fill, true);
    try appendJsonFieldOptionalColor(allocator, buffer, "markdown_code_stroke", text_spec.markdown_code_stroke, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_line_width", text_spec.markdown_code_line_width, true);
    try appendJsonFieldFloat(allocator, buffer, "markdown_code_radius", text_spec.markdown_code_radius, true);
    try appendJsonFieldInt(allocator, buffer, "cjk_bold_passes", text_spec.cjk_bold_passes, true);
    try appendJsonFieldFloat(allocator, buffer, "cjk_bold_dx", text_spec.cjk_bold_dx, true);
    try appendJsonFieldBool(allocator, buffer, "wrap", text_spec.wrap, false);
    try buffer.appendSlice(allocator, "}, ");
}

fn appendJsonRenderMathSpec(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    math_spec: render_policy.MathPaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "math");
    try appendJsonFieldFloat(allocator, buffer, "block_line_height", math_spec.block_line_height, true);
    try appendJsonFieldFloat(allocator, buffer, "block_min_height", math_spec.block_min_height, true);
    try appendJsonFieldFloat(allocator, buffer, "block_vertical_padding", math_spec.block_vertical_padding, false);
    try buffer.appendSlice(allocator, "}, ");
}

fn appendJsonRenderCodeSpec(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    code_spec: render_policy.CodePaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "code");
    try appendJsonFieldOptionalString(allocator, buffer, "language", code_spec.language, true);
    try appendJsonFieldColor(allocator, buffer, "plain_color", code_spec.plain, true);
    try appendJsonFieldColor(allocator, buffer, "keyword_color", code_spec.keyword, true);
    try appendJsonFieldColor(allocator, buffer, "comment_color", code_spec.comment, true);
    try appendJsonFieldColor(allocator, buffer, "string_color", code_spec.string, false);
    try buffer.appendSlice(allocator, "}, ");
}

fn appendJsonRenderChrome(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    chrome: render_policy.ChromePaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "chrome");
    try appendJsonFieldOptionalColor(allocator, buffer, "fill", chrome.fill, true);
    try appendJsonFieldOptionalColor(allocator, buffer, "stroke", chrome.stroke, true);
    try appendJsonFieldFloat(allocator, buffer, "line_width", chrome.line_width, true);
    try appendJsonFieldFloat(allocator, buffer, "radius", chrome.radius, false);
    try buffer.appendSlice(allocator, "}, ");
}

fn appendJsonRenderUnderline(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    underline: render_policy.UnderlinePaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "underline");
    try appendJsonFieldOptionalColor(allocator, buffer, "color", underline.color, true);
    try appendJsonFieldFloat(allocator, buffer, "width", underline.width, true);
    try appendJsonFieldFloat(allocator, buffer, "offset", underline.offset, false);
    try buffer.appendSlice(allocator, "}, ");
}

fn appendJsonRenderRule(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    rule: render_policy.RulePaint,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, "rule");
    try appendJsonFieldOptionalColor(allocator, buffer, "stroke", rule.stroke, true);
    try appendJsonFieldFloat(allocator, buffer, "line_width", rule.line_width, true);
    try appendJsonFieldOptionalDash(allocator, buffer, "dash", rule.dash, false);
    try buffer.append(allocator, '}');
}

fn appendJsonFieldRender(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    render: render_policy.ResolvedRender,
    trailing_comma: bool,
) !void {
    try appendJsonObjectFieldStart(allocator, buffer, key);
    try appendJsonFieldString(allocator, buffer, "kind", @tagName(render.kind), true);
    if (render.text) |text_spec| {
        try appendJsonRenderTextSpec(allocator, buffer, text_spec);
    } else {
        try appendJsonFieldNull(allocator, buffer, "text", true);
    }
    if (render.math) |math_spec| {
        try appendJsonRenderMathSpec(allocator, buffer, math_spec);
    } else {
        try appendJsonFieldNull(allocator, buffer, "math", true);
    }
    if (render.code) |code_spec| {
        try appendJsonRenderCodeSpec(allocator, buffer, code_spec);
    } else {
        try appendJsonFieldNull(allocator, buffer, "code", true);
    }
    try appendJsonRenderChrome(allocator, buffer, render.chrome);
    try appendJsonRenderUnderline(allocator, buffer, render.underline);
    try appendJsonRenderRule(allocator, buffer, render.rule);
    try buffer.append(allocator, '}');
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonInt(allocator: Allocator, buffer: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    try buffer.appendSlice(allocator, text);
}

fn appendJsonFieldColor(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    color: render_policy.Color,
    trailing_comma: bool,
) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    try buffer.append(allocator, '[');
    try appendJsonFloatValue(allocator, buffer, color.r);
    try buffer.appendSlice(allocator, ", ");
    try appendJsonFloatValue(allocator, buffer, color.g);
    try buffer.appendSlice(allocator, ", ");
    try appendJsonFloatValue(allocator, buffer, color.b);
    try buffer.append(allocator, ']');
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFieldOptionalColor(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    color: ?render_policy.Color,
    trailing_comma: bool,
) !void {
    if (color) |value| {
        try appendJsonFieldColor(allocator, buffer, key, value, trailing_comma);
    } else {
        try appendJsonFieldNull(allocator, buffer, key, trailing_comma);
    }
}

fn appendJsonFieldOptionalDash(
    allocator: Allocator,
    buffer: *std.ArrayList(u8),
    key: []const u8,
    dash: ?render_policy.Dash,
    trailing_comma: bool,
) !void {
    try appendJsonFieldPrefix(allocator, buffer, key);
    if (dash) |value| {
        try buffer.append(allocator, '[');
        try appendJsonFloatValue(allocator, buffer, value.on);
        try buffer.appendSlice(allocator, ", ");
        try appendJsonFloatValue(allocator, buffer, value.off);
        try buffer.append(allocator, ']');
    } else {
        try buffer.appendSlice(allocator, "null");
    }
    try appendJsonTrailingComma(allocator, buffer, trailing_comma);
}

fn appendJsonFloatValue(allocator: Allocator, buffer: *std.ArrayList(u8), value: f32) !void {
    const text = try std.fmt.allocPrint(allocator, "{d:.4}", .{value});
    try buffer.appendSlice(allocator, text);
}

fn appendJsonString(allocator: Allocator, buffer: *std.ArrayList(u8), value: []const u8) !void {
    try buffer.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => try buffer.appendSlice(allocator, "\\r"),
            '\t' => try buffer.appendSlice(allocator, "\\t"),
            else => try buffer.append(allocator, ch),
        }
    }
    try buffer.append(allocator, '"');
}
