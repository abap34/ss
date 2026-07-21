const std = @import("std");
const core = @import("core");

const json = @import("utils").json;

pub fn writeNodesField(allocator: std.mem.Allocator, root: *json.Object, state: *core.DocumentState) !void {
    var nodes = try root.arrayField("nodes");
    for (state.nodes.items) |node| {
        if (node.kind == .object and !node.attached) continue;
        try writeNode(allocator, &nodes, state, node);
    }
    try nodes.end();
}

fn writeNode(allocator: std.mem.Allocator, nodes: *json.Array, state: *core.DocumentState, node: core.Node) !void {
    const render = core.render_policy.resolve(state, &node);
    const display_content = core.nodeDisplayContent(&node);
    const has_display_content = display_content.len != 0 or node.content != null or node.display_content != null;
    const should_parse_blocks = core.markdown.shouldParseBlocksNode(state, &node) and has_display_content;
    const should_parse_inline = core.markdown.shouldParseInlineNode(state, &node) and has_display_content and !should_parse_blocks;

    var markdown_doc_storage = core.markdown.MarkdownDocument.init(allocator);
    defer markdown_doc_storage.deinit();
    var inline_layout_storage: core.markdown.TextLayout = .{};
    defer if (should_parse_inline) inline_layout_storage.deinit(allocator);
    if (should_parse_blocks) {
        markdown_doc_storage = try core.markdown.parseMarkdownDocumentForNode(
            allocator,
            state,
            &node,
            display_content,
        );
    }
    if (should_parse_inline) {
        inline_layout_storage = try core.markdown.parseTextLayoutForNode(
            allocator,
            state,
            &node,
            display_content,
        );
    }

    var item = try nodes.objectItem();
    try item.intField("id", node.id);
    try item.enumTagField("kind", node.kind);
    try item.stringField("name", node.name);
    try item.optionalStringField("role", node.role);
    try item.optionalEnumTagField("object_kind", node.object_kind);
    try item.optionalEnumTagField("payload_kind", node.payload_kind);
    try item.optionalStringField("content", node.content);
    if (node.display_content != null) {
        try item.stringField("display_content", display_content);
    }
    if (should_parse_blocks) {
        try writeMarkdownBlocks(&item, "blocks", markdown_doc_storage.blocks.items);
    } else {
        try item.nullField("blocks");
    }
    if (should_parse_inline) {
        try writeInlineLines(&item, "inline_lines", inline_layout_storage.lines.items);
    } else {
        try item.nullField("inline_lines");
    }
    try writeFields(allocator, &item, node.fields.items);
    var render_env = try core.render_env.resolveForNode(allocator, state, &node);
    defer render_env.deinit(allocator);
    try writeRenderEnv(&item, render_env);
    try item.optionalIntField("page_index", node.page_index);
    try item.optionalStringField("origin", node.origin);
    try item.floatField("x", node.frame.x, "{d:.1}");
    try item.floatField("y", node.frame.y, "{d:.1}");
    try item.floatField("width", node.frame.width, "{d:.1}");
    try item.floatField("height", node.frame.height, "{d:.1}");
    try writeRender(&item, render);
    try item.end();
}

fn writeFields(allocator: std.mem.Allocator, object: *json.Object, fields: anytype) !void {
    var out = try object.objectField("fields");
    for (fields) |field| {
        const text = try core.value_text.propertyString(allocator, field.value);
        defer if (core.value_text.propertyStringNeedsFree(field.value)) allocator.free(text);
        try out.stringField(field.key, text);
    }
    try out.end();
}

fn writeRenderEnv(object: *json.Object, env: core.render_env.Resolved) !void {
    var root = try object.objectField("render_env");
    var math = try root.objectField("math");
    var tex = try math.objectField("tex");
    try tex.enumTagField("engine", env.tex_engine);
    var preamble = try tex.arrayField("preamble");
    for (env.tex_preamble.items) |entry| {
        var item = try preamble.objectItem();
        try item.enumTagField("source", entry.source);
        try item.stringField("value", entry.value);
        try item.end();
    }
    try preamble.end();
    try tex.end();
    try math.end();
    try root.end();
}

fn writeInlineLines(object: *json.Object, key: []const u8, lines: []const core.markdown.Line) !void {
    var outer = try object.arrayField(key);
    for (lines) |line| {
        var line_array = try outer.arrayItem();
        for (line.runs.items) |run| {
            var run_item = try line_array.objectItem();
            try run_item.enumTagField("kind", run.kind);
            try run_item.stringField("text", run.text);
            if (run.strikethrough) try run_item.boolField("strikethrough", true);
            if (run.underline) try run_item.boolField("underline", true);
            try run_item.optionalStringField("url", run.url);
            try run_item.optionalStringField("icon", run.icon);
            try run_item.end();
        }
        try line_array.end();
    }
    try outer.end();
}

fn writeMarkdownBlocks(object: *json.Object, key: []const u8, blocks: []const *core.markdown.Block) anyerror!void {
    var outer = try object.arrayField(key);
    for (blocks) |block| {
        try writeMarkdownBlock(&outer, block);
    }
    try outer.end();
}

fn writeMarkdownBlock(blocks: *json.Array, block: *const core.markdown.Block) anyerror!void {
    var item = try blocks.objectItem();
    try item.enumTagField("kind", block.kind);
    switch (block.kind) {
        .paragraph, .heading => {
            if (block.heading_level) |level| try item.intField("level", level);
            try writeInlineLines(&item, "lines", block.paragraph.?.lines.items);
        },
        .code_block => {
            try item.optionalStringField("language", block.language);
            try writeInlineLines(&item, "lines", block.paragraph.?.lines.items);
        },
        .block_quote => try writeMarkdownBlocks(&item, "blocks", block.quote.?.blocks.items),
        .bullet_list, .ordered_list => {
            try item.intField("start", block.list.?.start);
            var items = try item.arrayField("items");
            for (block.list.?.items.items) |list_item| {
                var list_json = try items.objectItem();
                try writeMarkdownBlocks(&list_json, "blocks", list_item.blocks.items);
                try list_json.end();
            }
            try items.end();
        },
        .table => {
            try item.intField("columns", block.table.?.columns);
            var rows = try item.arrayField("rows");
            for (block.table.?.rows.items) |row| {
                var row_json = try rows.objectItem();
                try row_json.boolField("header", row.header);
                var cells = try row_json.arrayField("cells");
                for (row.cells.items) |cell| {
                    var cell_json = try cells.objectItem();
                    try cell_json.enumTagField("align", cell.alignment);
                    try writeInlineLines(&cell_json, "lines", cell.lines.items);
                    try cell_json.end();
                }
                try cells.end();
                try row_json.end();
            }
            try rows.end();
        },
    }
    try item.end();
}

fn writeRender(object: *json.Object, render: core.render_policy.ResolvedRender) !void {
    var render_object = try object.objectField("render");
    try render_object.enumTagField("kind", render.kind);
    try writeOptionalTextPaint(&render_object, render.text);
    try writeOptionalMathPaint(&render_object, render.math);
    try writeOptionalCodePaint(&render_object, render.code);
    try writeChromePaint(&render_object, render.chrome);
    try writeUnderlinePaint(&render_object, render.underline);
    try writeRulePaint(&render_object, render.rule);
    try render_object.end();
}

fn writeOptionalTextPaint(object: *json.Object, maybe_text: ?core.render_policy.TextPaint) !void {
    const text_spec = maybe_text orelse {
        try object.nullField("text");
        return;
    };

    var text = try object.objectField("text");
    try writeInlineTextPaint(&text, text_spec);
    try writeMarkdownQuotePaint(&text, text_spec.markdown_quote);
    var headings = try text.objectField("markdown_headings");
    const names = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };
    for (names, text_spec.markdown_headings) |name, heading| {
        try writeOptionalMarkdownHeadingPaint(&headings, name, heading);
    }
    try headings.end();
    try text.floatField("markdown_block_gap", text_spec.markdown_block_gap, "{d:.4}");
    try text.floatField("markdown_list_inset", text_spec.markdown_list_inset, "{d:.4}");
    try text.floatField("markdown_list_indent", text_spec.markdown_list_indent, "{d:.4}");
    try text.floatField("markdown_code_font_size", text_spec.markdown_code_font_size, "{d:.1}");
    try text.floatField("markdown_code_line_height", text_spec.markdown_code_line_height, "{d:.1}");
    try text.floatField("markdown_code_pad_x", text_spec.markdown_code_pad_x, "{d:.1}");
    try text.floatField("markdown_code_pad_y", text_spec.markdown_code_pad_y, "{d:.1}");
    try writeOptionalColor(&text, "markdown_code_fill", text_spec.markdown_code_fill);
    try writeOptionalColor(&text, "markdown_code_stroke", text_spec.markdown_code_stroke);
    try text.floatField("markdown_code_line_width", text_spec.markdown_code_line_width, "{d:.1}");
    try text.floatField("markdown_code_radius", text_spec.markdown_code_radius, "{d:.1}");
    try writeOptionalColor(&text, "markdown_code_plain_color", text_spec.markdown_code_plain_color);
    try writeOptionalColor(&text, "markdown_code_keyword_color", text_spec.markdown_code_keyword_color);
    try writeOptionalColor(&text, "markdown_code_function_color", text_spec.markdown_code_function_color);
    try writeOptionalColor(&text, "markdown_code_type_color", text_spec.markdown_code_type_color);
    try writeOptionalColor(&text, "markdown_code_constant_color", text_spec.markdown_code_constant_color);
    try writeOptionalColor(&text, "markdown_code_number_color", text_spec.markdown_code_number_color);
    try writeOptionalColor(&text, "markdown_code_variable_color", text_spec.markdown_code_variable_color);
    try writeOptionalColor(&text, "markdown_code_operator_color", text_spec.markdown_code_operator_color);
    try writeOptionalColor(&text, "markdown_code_comment_color", text_spec.markdown_code_comment_color);
    try writeOptionalColor(&text, "markdown_code_string_color", text_spec.markdown_code_string_color);
    try text.floatField("markdown_table_cell_pad_x", text_spec.markdown_table_cell_pad_x, "{d:.1}");
    try text.floatField("markdown_table_cell_pad_y", text_spec.markdown_table_cell_pad_y, "{d:.1}");
    try writeOptionalColor(&text, "markdown_table_border", text_spec.markdown_table_border);
    try text.floatField("markdown_table_line_width", text_spec.markdown_table_line_width, "{d:.1}");
    try writeOptionalColor(&text, "markdown_table_header_fill", text_spec.markdown_table_header_fill);
    try writeOptionalColor(&text, "markdown_table_alt_row_fill", text_spec.markdown_table_alt_row_fill);
    try text.boolField("wrap", text_spec.wrap);
    try text.end();
}

fn writeMarkdownQuotePaint(object: *json.Object, quote: core.render_policy.MarkdownQuotePaint) !void {
    var value = try object.objectField("markdown_quote");
    try writeOptionalColor(&value, "color", quote.color);
    try value.floatField("inset", quote.inset, "{d:.1}");
    try value.floatField("pad_x", quote.pad_x, "{d:.1}");
    try value.floatField("pad_y", quote.pad_y, "{d:.1}");
    try writeOptionalColor(&value, "fill", quote.fill);
    try value.floatField("radius", quote.radius, "{d:.1}");
    try writeOptionalColor(&value, "bar_color", quote.bar_color);
    try value.floatField("bar_width", quote.bar_width, "{d:.1}");
    if (quote.bar_dash) |dash| {
        try value.floatField("bar_dash_on", dash.on, "{d:.1}");
        try value.floatField("bar_dash_off", dash.off, "{d:.1}");
    } else {
        try value.nullField("bar_dash_on");
        try value.nullField("bar_dash_off");
    }
    try value.end();
}

fn writeInlineTextPaint(object: *json.Object, spec: anytype) !void {
    try writeFontFace(object, "font", spec.font);
    try writeFontFace(object, "bold_font", spec.bold_font);
    try writeFontFace(object, "italic_font", spec.italic_font);
    try writeFontFace(object, "code_font", spec.code_font);
    try object.floatField("font_size", spec.font_size, "{d:.1}");
    try object.floatField("line_height", spec.line_height, "{d:.1}");
    try writeColor(object, "color", spec.color);
    try writeColor(object, "link_color", spec.link_color);
    try writeOptionalColor(object, "markdown_bold_color", spec.markdown_bold_color);
    try writeMarkdownUnderlinePaint(object, spec.markdown_underline);
    try object.floatField("inline_math_height_factor", spec.inline_math_height_factor, "{d:.4}");
    try object.floatField("inline_math_spacing", spec.inline_math_spacing, "{d:.4}");
    try object.floatField("display_math_height_factor", spec.display_math_height_factor, "{d:.4}");
    try object.enumTagField("math_align", spec.math_align);
    try object.floatField("emoji_spacing", spec.emoji_spacing, "{d:.4}");
}

fn writeMarkdownUnderlinePaint(object: *json.Object, spec: core.render_policy.MarkdownUnderlinePaint) !void {
    var underline = try object.objectField("markdown_underline");
    try writeOptionalColor(&underline, "color", spec.color);
    try underline.floatField("opacity", spec.opacity, "{d:.4}");
    try underline.optionalFloatField("width", spec.width, "{d:.4}");
    try underline.floatField("offset", spec.offset, "{d:.4}");
    if (spec.dash) |dash| {
        var dash_array = try underline.arrayField("dash");
        try dash_array.floatItem(dash.on, "{d:.4}");
        try dash_array.floatItem(dash.off, "{d:.4}");
        try dash_array.end();
    } else {
        try underline.nullField("dash");
    }
    try underline.end();
}

fn writeOptionalMarkdownHeadingPaint(
    object: *json.Object,
    key: []const u8,
    maybe_heading: ?core.render_policy.MarkdownHeadingPaint,
) !void {
    const heading_spec = maybe_heading orelse {
        try object.nullField(key);
        return;
    };

    var heading = try object.objectField(key);
    try writeInlineTextPaint(&heading, heading_spec);
    try heading.end();
}

fn writeFontFace(object: *json.Object, key: []const u8, face: core.font.Face) !void {
    var font = try object.objectField(key);
    try font.stringField("family", face.family);
    try font.intField("weight", face.weight);
    try font.stringField("style", core.font.styleName(face.style));
    try font.stringField("stretch", core.font.stretchName(face.stretch));
    try font.end();
}

fn writeOptionalMathPaint(object: *json.Object, maybe_math: ?core.render_policy.MathPaint) !void {
    const math_spec = maybe_math orelse {
        try object.nullField("math");
        return;
    };

    var math = try object.objectField("math");
    try math.floatField("min_height", math_spec.min_height, "{d:.1}");
    try math.floatField("raw_tex_width_ratio", math_spec.raw_tex_width_ratio, "{d:.4}");
    try math.floatField("scale", math_spec.scale, "{d:.4}");
    try math.enumTagField("align", math_spec.horizontal_align);
    try math.end();
}

fn writeOptionalCodePaint(object: *json.Object, maybe_code: ?core.render_policy.CodePaint) !void {
    const code_spec = maybe_code orelse {
        try object.nullField("code");
        return;
    };

    var code = try object.objectField("code");
    try code.optionalStringField("language", code_spec.language);
    try writeColor(&code, "plain_color", code_spec.plain);
    try writeColor(&code, "keyword_color", code_spec.keyword);
    try writeColor(&code, "function_color", code_spec.function);
    try writeColor(&code, "type_color", code_spec.type);
    try writeColor(&code, "constant_color", code_spec.constant);
    try writeColor(&code, "number_color", code_spec.number);
    try writeColor(&code, "variable_color", code_spec.variable);
    try writeColor(&code, "operator_color", code_spec.operator);
    try writeColor(&code, "comment_color", code_spec.comment);
    try writeColor(&code, "string_color", code_spec.string);
    try code.end();
}

fn writeChromePaint(object: *json.Object, chrome_spec: core.render_policy.ChromePaint) !void {
    var chrome = try object.objectField("chrome");
    try writeOptionalColor(&chrome, "fill", chrome_spec.fill);
    try writeOptionalColor(&chrome, "stroke", chrome_spec.stroke);
    try chrome.floatField("line_width", chrome_spec.line_width, "{d:.1}");
    try chrome.floatField("radius", chrome_spec.radius, "{d:.1}");
    try chrome.floatField("pad_x", chrome_spec.pad_x, "{d:.1}");
    try chrome.floatField("pad_y", chrome_spec.pad_y, "{d:.1}");
    try chrome.end();
}

fn writeUnderlinePaint(object: *json.Object, underline_spec: core.render_policy.UnderlinePaint) !void {
    var underline = try object.objectField("underline");
    try writeOptionalColor(&underline, "color", underline_spec.color);
    try underline.floatField("width", underline_spec.width, "{d:.1}");
    try underline.floatField("offset", underline_spec.offset, "{d:.1}");
    try underline.end();
}

fn writeRulePaint(object: *json.Object, rule_spec: core.render_policy.RulePaint) !void {
    var rule = try object.objectField("rule");
    try writeOptionalColor(&rule, "stroke", rule_spec.stroke);
    try rule.floatField("line_width", rule_spec.line_width, "{d:.1}");
    if (rule_spec.dash) |dash| {
        var dash_array = try rule.arrayField("dash");
        try dash_array.floatItem(dash.on, "{d:.4}");
        try dash_array.floatItem(dash.off, "{d:.4}");
        try dash_array.end();
    } else {
        try rule.nullField("dash");
    }
    try rule.end();
}

fn writeColor(object: *json.Object, key: []const u8, color: core.render_policy.Color) !void {
    var array = try object.arrayField(key);
    try array.floatItem(color.r, "{d:.4}");
    try array.floatItem(color.g, "{d:.4}");
    try array.floatItem(color.b, "{d:.4}");
    try array.end();
}

fn writeOptionalColor(object: *json.Object, key: []const u8, color: ?core.render_policy.Color) !void {
    if (color) |value| {
        try writeColor(object, key, value);
    } else {
        try object.nullField(key);
    }
}
