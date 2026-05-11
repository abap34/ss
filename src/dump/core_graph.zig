const std = @import("std");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const json = @import("utils").json;

const SemanticEnv = semantic_env.SemanticEnv;

pub fn writeNodesField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);

    var nodes = try root.arrayField("nodes");
    for (ir.nodes.items) |node| {
        if (node.kind == .object and !node.attached) continue;
        try writeNode(allocator, &nodes, ir, &sema, node);
    }
    try nodes.end();
}

fn writeNode(allocator: std.mem.Allocator, nodes: *json.Array, ir: *core.Ir, sema: anytype, node: core.Node) !void {
    const render = core.render_policy.resolveWithEnv(ir, &node, sema);
    const should_parse_blocks = core.markdown.shouldParseBlocksNode(ir, &node) and node.content != null;
    const should_parse_inline = core.markdown.shouldParseInlineNode(ir, &node) and node.content != null and !should_parse_blocks;

    var markdown_doc_storage = core.markdown.MarkdownDocument.init(allocator);
    defer markdown_doc_storage.deinit();
    var inline_layout_storage: core.markdown.TextLayout = .{};
    defer if (should_parse_inline) inline_layout_storage.deinit(allocator);
    if (should_parse_blocks) {
        markdown_doc_storage = try core.markdown.parseMarkdownDocumentForNode(
            allocator,
            ir,
            &node,
            node.content.?,
        );
    }
    if (should_parse_inline) {
        inline_layout_storage = try core.markdown.parseTextLayoutForNode(
            allocator,
            ir,
            &node,
            node.content.?,
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
    try writeProperties(&item, node.properties.items);
    var render_env = try core.render_env.resolveForNode(allocator, ir, &node);
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

fn writeProperties(object: *json.Object, properties: anytype) !void {
    var props = try object.objectField("properties");
    for (properties) |property| {
        try props.stringField(property.key, property.value);
    }
    try props.end();
}

fn writeRenderEnv(object: *json.Object, env: core.render_env.Resolved) !void {
    var root = try object.objectField("render_env");
    var math = try root.objectField("math");
    var latex = try math.objectField("latex");
    var packages = try latex.arrayField("packages");
    for (env.math_latex_packages.items) |package| try packages.stringItem(package);
    try packages.end();
    try latex.end();
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
        .paragraph => {
            try writeInlineLines(&item, "lines", block.paragraph.?.lines.items);
        },
        .code_block => {
            try item.optionalStringField("language", block.language);
            try writeInlineLines(&item, "lines", block.paragraph.?.lines.items);
        },
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
    try text.stringField("font", text_spec.font);
    try text.stringField("bold_font", text_spec.bold_font);
    try text.stringField("italic_font", text_spec.italic_font);
    try text.stringField("code_font", text_spec.code_font);
    try text.floatField("font_size", text_spec.font_size, "{d:.1}");
    try text.floatField("line_height", text_spec.line_height, "{d:.1}");
    try writeColor(&text, "color", text_spec.color);
    try writeColor(&text, "link_color", text_spec.link_color);
    try text.floatField("link_underline_width", text_spec.link_underline_width, "{d:.1}");
    try text.floatField("link_underline_offset", text_spec.link_underline_offset, "{d:.1}");
    try text.floatField("inline_math_height_factor", text_spec.inline_math_height_factor, "{d:.4}");
    try text.floatField("inline_math_spacing", text_spec.inline_math_spacing, "{d:.4}");
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
    try text.intField("cjk_bold_passes", text_spec.cjk_bold_passes);
    try text.floatField("cjk_bold_dx", text_spec.cjk_bold_dx, "{d:.4}");
    try text.boolField("wrap", text_spec.wrap);
    try text.end();
}

fn writeOptionalMathPaint(object: *json.Object, maybe_math: ?core.render_policy.MathPaint) !void {
    const math_spec = maybe_math orelse {
        try object.nullField("math");
        return;
    };

    var math = try object.objectField("math");
    try math.floatField("block_line_height", math_spec.block_line_height, "{d:.1}");
    try math.floatField("block_min_height", math_spec.block_min_height, "{d:.1}");
    try math.floatField("block_vertical_padding", math_spec.block_vertical_padding, "{d:.1}");
    try math.floatField("scale", math_spec.scale, "{d:.4}");
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
