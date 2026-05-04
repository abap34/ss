const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const registry = @import("parser/registry.zig");
const typecheck = @import("parser/typecheck.zig");
const property_schema = @import("property_schema.zig");
const json = @import("utils").json;

pub fn toOwnedString(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try json.Object.beginBuffer(allocator, &buffer);
    try root.intField("ir_version", 1);
    try root.stringField("stage", "finalized_ir");
    try root.stringField("project_path", ir.projectPath());
    try root.stringField("asset_base_dir", ir.asset_base_dir);

    var modules = try root.arrayField("modules");
    for (ir.modules.items) |module| try writeModule(allocator, &modules, module);
    try modules.end();

    var functions = try root.arrayField("functions");
    for (registry.primitiveDescriptors()) |descriptor| {
        if (ir.functions.contains(descriptor.name)) continue;
        try writePrimitiveFunction(allocator, &functions, descriptor);
    }
    var function_iterator = ir.functions.iterator();
    while (function_iterator.next()) |entry| {
        const metadata = ir.function_metadata.get(entry.key_ptr.*) orelse core.FunctionMetadata{ .module_id = ir.project_module_id };
        try writeUserFunction(allocator, &functions, ir, entry.key_ptr.*, entry.value_ptr.*, metadata);
    }
    try functions.end();

    var variables = try root.arrayField("variables");
    var variable_infos = try typecheck.collectVariableInfoFromProgram(allocator, &ir.functions, ir.projectProgram());
    defer variable_infos.deinit();
    var variable_iterator = variable_infos.iterator();
    while (variable_iterator.next()) |entry| {
        var item = try variables.objectItem();
        try item.stringField("name", entry.key_ptr.*);
        try item.enumTagField("type", entry.value_ptr.sort);
        try item.enumTagField("objectShape", entry.value_ptr.object_shape);
        try item.end();
    }
    try variables.end();

    var property_schemas_json = try root.arrayField("property_schemas");
    for (property_schema.propertySchemas()) |schema| {
        var item = try property_schemas_json.objectItem();
        try item.stringField("key", schema.key);
        try item.stringField("valueType", @tagName(schema.value_type));
        var allowed = try item.arrayField("allowedShapes");
        for (schema.allowed_shapes) |shape| try allowed.stringItem(property_schema.shapeLabel(shape));
        try allowed.end();
        try item.end();
    }
    try property_schemas_json.end();

    var definitions = try root.arrayField("definitions");
    var definition_iterator = ir.definitions.iterator();
    while (definition_iterator.next()) |entry| {
        var item = try definitions.objectItem();
        try item.stringField("name", entry.key_ptr.*);
        try item.enumTagField("kind", entry.value_ptr.kind);
        try item.intField("line", entry.value_ptr.line);
        try item.intField("column", entry.value_ptr.column);
        try item.intField("length", entry.value_ptr.length);
        try item.optionalStringField("file", entry.value_ptr.file);
        try item.end();
    }
    try definitions.end();

    var hints = try root.arrayField("hints");
    for (ir.hints.items) |hint| {
        var item = try hints.objectItem();
        try item.intField("line", hint.line);
        try item.intField("column", hint.column);
        try item.stringField("label", hint.label);
        try item.enumTagField("kind", hint.kind);
        try item.end();
    }
    try hints.end();

    try root.intField("document_id", ir.document_id);
    var page_order = try root.arrayField("page_order");
    for (ir.page_order.items) |page_id| try page_order.intItem(page_id);
    try page_order.end();

    var nodes = try root.arrayField("nodes");
    for (ir.nodes.items) |node| {
        if ((node.kind == .object or node.kind == .derived) and !node.attached) continue;
        try writeNode(allocator, &nodes, ir, node);
    }
    try nodes.end();

    var contains = try root.arrayField("contains");
    var contains_iterator = ir.contains.iterator();
    while (contains_iterator.next()) |entry| {
        var item = try contains.objectItem();
        try item.intField("parent", entry.key_ptr.*);
        var children = try item.arrayField("children");
        for (entry.value_ptr.items) |child_id| try children.intItem(child_id);
        try children.end();
        try item.end();
    }
    try contains.end();

    var constraints = try root.arrayField("constraints");
    for (ir.constraints.items) |constraint| {
        var item = try constraints.objectItem();
        try item.intField("target_node", constraint.target_node);
        try item.enumTagField("target_anchor", constraint.target_anchor);
        switch (constraint.source) {
            .page => |anchor| {
                try item.stringField("source_kind", "page");
                try item.enumTagField("source_anchor", anchor);
                try item.nullField("source_node");
            },
            .node => |source| {
                try item.stringField("source_kind", "node");
                try item.enumTagField("source_anchor", source.anchor);
                try item.intField("source_node", source.node_id);
            },
        }
        try item.floatField("offset", constraint.offset, "{d:.1}");
        try item.optionalStringField("origin", constraint.origin);
        try item.end();
    }
    try constraints.end();

    var diagnostics = try root.arrayField("diagnostics");
    for (ir.diagnostics.items) |diagnostic| {
        try writeDiagnostic(allocator, &diagnostics, diagnostic);
    }
    try diagnostics.end();

    try root.end();
    try json.appendNewline(&buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn writeModule(allocator: std.mem.Allocator, modules: *json.Array, module: core.SourceModule) !void {
    var item = try modules.objectItem();
    try item.intField("id", module.id);
    try item.enumTagField("kind", module.kind);
    try item.stringField("spec", module.spec);
    try item.optionalStringField("path", module.path);
    var imports = try item.arrayField("imports");
    for (module.program.imports.items, 0..) |import_decl, index| {
        var import_item = try imports.objectItem();
        try import_item.stringField("spec", import_decl.spec);
        try writeSpan(&import_item, import_decl.span);
        if (index < module.resolved_import_ids.items.len) {
            try import_item.intField("module_id", module.resolved_import_ids.items[index]);
        } else {
            try import_item.nullField("module_id");
        }
        try import_item.end();
    }
    try imports.end();
    try item.stringField("source", module.source);
    try writeProgram(allocator, &item, module.program);
    try item.end();
}

fn writeProgram(allocator: std.mem.Allocator, object: *json.Object, program: ast.Program) !void {
    var program_object = try object.objectField("program");

    var imports = try program_object.arrayField("imports");
    for (program.imports.items) |import_decl| {
        var item = try imports.objectItem();
        try item.stringField("spec", import_decl.spec);
        try writeSpan(&item, import_decl.span);
        try item.end();
    }
    try imports.end();

    var functions = try program_object.arrayField("functions");
    for (program.functions.items) |func| {
        var item = try functions.objectItem();
        try item.stringField("name", func.name);
        try item.enumTagField("kind", func.kind);
        try writeSpan(&item, func.span);
        try item.enumTagField("result_sort", func.result_sort);
        var params = try item.arrayField("params");
        for (func.params.items) |param| {
            var param_item = try params.objectItem();
            try param_item.stringField("name", param.name);
            try param_item.enumTagField("sort", param.sort);
            try param_item.end();
        }
        try params.end();
        var statements = try item.arrayField("statements");
        for (func.statements.items) |stmt| try writeStatement(allocator, &statements, stmt);
        try statements.end();
        try item.end();
    }
    try functions.end();

    var pages = try program_object.arrayField("pages");
    for (program.pages.items) |page| {
        var item = try pages.objectItem();
        try item.stringField("name", page.name);
        var statements = try item.arrayField("statements");
        for (page.statements.items) |stmt| try writeStatement(allocator, &statements, stmt);
        try statements.end();
        try item.end();
    }
    try pages.end();
    try program_object.end();
}

fn writeSpan(object: *json.Object, span: ast.Span) !void {
    var span_object = try object.objectField("span");
    try span_object.intField("start", span.start);
    try span_object.intField("end", span.end);
    try span_object.end();
}

fn writeStatement(allocator: std.mem.Allocator, statements: *json.Array, stmt: ast.Statement) !void {
    var item = try statements.objectItem();
    try writeSpan(&item, stmt.span);
    switch (stmt.kind) {
        .title => |text| {
            try item.stringField("kind", "title");
            try item.stringField("text", text);
        },
        .subtitle => |text| {
            try item.stringField("kind", "subtitle");
            try item.stringField("text", text);
        },
        .math => |text| {
            try item.stringField("kind", "math");
            try item.stringField("text", text);
        },
        .mathtex => |text| {
            try item.stringField("kind", "mathtex");
            try item.stringField("text", text);
        },
        .figure => |text| {
            try item.stringField("kind", "figure");
            try item.stringField("text", text);
        },
        .image => |text| {
            try item.stringField("kind", "image");
            try item.stringField("text", text);
        },
        .pdf_ref => |text| {
            try item.stringField("kind", "pdf_ref");
            try item.stringField("text", text);
        },
        .code => |text| {
            try item.stringField("kind", "code");
            try item.stringField("text", text);
        },
        .page_number => {
            try item.stringField("kind", "page_number");
        },
        .toc => {
            try item.stringField("kind", "toc");
        },
        .highlight => |text| {
            try item.stringField("kind", "highlight");
            try item.stringField("text", text);
        },
        .let_binding => |binding| {
            try item.stringField("kind", "let_binding");
            try item.stringField("name", binding.name);
            try writeExpr(allocator, &item, "expr", binding.expr);
        },
        .bind_binding => |binding| {
            try item.stringField("kind", "bind_binding");
            try item.stringField("name", binding.name);
            try writeExpr(allocator, &item, "expr", binding.expr);
        },
        .return_expr => |expr| {
            try item.stringField("kind", "return_expr");
            try writeExpr(allocator, &item, "expr", expr);
        },
        .expr_stmt => |expr| {
            try item.stringField("kind", "expr_stmt");
            try writeExpr(allocator, &item, "expr", expr);
        },
        .constrain => |decl| {
            try item.stringField("kind", "constrain");
            try writeAnchorRef(&item, "target", decl.target);
            try writeAnchorRef(&item, "source", decl.source);
            if (decl.offset) |expr| {
                try writeExpr(allocator, &item, "offset", expr);
            } else {
                try item.nullField("offset");
            }
        },
        .property_set => |property_set| {
            try item.stringField("kind", "property_set");
            try item.stringField("object_name", property_set.object_name);
            try item.stringField("property_name", property_set.property_name);
            try writeExpr(allocator, &item, "value", property_set.value);
        },
    }
    try item.end();
}

fn writeAnchorRef(object: *json.Object, key: []const u8, anchor_ref: ast.AnchorRef) !void {
    var item = try object.objectField(key);
    try item.stringField("kind", @tagName(anchor_ref.kind));
    try item.enumTagField("anchor", anchor_ref.anchor);
    try item.optionalStringField("node_name", anchor_ref.node_name);
    try item.end();
}

fn writeExpr(allocator: std.mem.Allocator, object: *json.Object, key: []const u8, expr: ast.Expr) !void {
    var item = try object.objectField(key);
    switch (expr) {
        .ident => |name| {
            try item.stringField("kind", "ident");
            try item.stringField("name", name);
        },
        .string => |text| {
            try item.stringField("kind", "string");
            try item.stringField("value", text);
        },
        .number => |value| {
            try item.stringField("kind", "number");
            try item.floatField("value", value, "{d:.4}");
        },
        .call => |call| {
            try item.stringField("kind", "call");
            try item.stringField("name", call.name);
            var args = try item.arrayField("args");
            for (call.args.items) |arg| {
                try writeExprItem(allocator, &args, arg);
            }
            try args.end();
        },
    }
    try item.end();
}

fn writeExprItem(allocator: std.mem.Allocator, items: *json.Array, expr: ast.Expr) !void {
    var item = try items.objectItem();
    switch (expr) {
        .ident => |name| {
            try item.stringField("kind", "ident");
            try item.stringField("name", name);
        },
        .string => |text| {
            try item.stringField("kind", "string");
            try item.stringField("value", text);
        },
        .number => |value| {
            try item.stringField("kind", "number");
            try item.floatField("value", value, "{d:.4}");
        },
        .call => |call| {
            try item.stringField("kind", "call");
            try item.stringField("name", call.name);
            var args = try item.arrayField("args");
            for (call.args.items) |arg| try writeExprItem(allocator, &args, arg);
            try args.end();
        },
    }
    try item.end();
}

fn writePrimitiveFunction(allocator: std.mem.Allocator, functions: *json.Array, descriptor: registry.PrimitiveDescriptor) !void {
    const signature = try typecheck.formatPrimitiveSignature(allocator, descriptor);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", descriptor.name);
    try item.stringField("signature", signature);
    try item.stringField("resultSort", typecheck.resultText(descriptor.result_sort));
    try item.stringField("source", "primitive");
    try item.stringField("summary", descriptor.summary);
    var params = try item.arrayField("params");
    for (descriptor.arg_names, 0..) |_, index| {
        const label = try typecheck.formatPrimitiveParam(allocator, descriptor, index);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    try params.end();
    try item.end();
}

fn writeUserFunction(
    allocator: std.mem.Allocator,
    functions: *json.Array,
    ir: *core.Ir,
    name: []const u8,
    func: ast.FunctionDecl,
    metadata: core.FunctionMetadata,
) !void {
    const signature = try typecheck.formatUserSignature(allocator, name, func);
    defer allocator.free(signature);

    var item = try functions.objectItem();
    try item.stringField("name", name);
    try item.enumTagField("kind", func.kind);
    try item.stringField("signature", signature);
    try item.enumTagField("resultSort", func.result_sort);
    if (ir.moduleById(metadata.module_id)) |module| {
        try item.enumTagField("source", module.kind);
        try item.intField("moduleId", module.id);
        try item.stringField("moduleSpec", module.spec);
        try item.optionalStringField("file", module.path);
    } else {
        try item.stringField("source", "unknown");
        try item.intField("moduleId", metadata.module_id);
        try item.nullField("file");
    }
    try item.stringField("summary", "");
    var params = try item.arrayField("params");
    for (func.params.items) |param| {
        const label = try typecheck.formatUserParam(allocator, param);
        defer allocator.free(label);
        try params.stringItem(label);
    }
    try params.end();
    try item.end();
}

fn writeNode(allocator: std.mem.Allocator, nodes: *json.Array, ir: *core.Ir, node: core.Node) !void {
    const render = core.render_policy.resolve(ir, &node);
    const should_parse_blocks = core.markdown.shouldParseBlocks(
        node.role,
        if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
    ) and node.content != null;
    const should_parse_inline = core.markdown.shouldParseInline(
        node.role,
        if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
    ) and node.content != null and !should_parse_blocks;

    var markdown_doc_storage = core.markdown.MarkdownDocument.init(allocator);
    defer markdown_doc_storage.deinit();
    var inline_layout_storage: core.markdown.TextLayout = .{};
    defer if (should_parse_inline) inline_layout_storage.deinit(allocator);
    if (should_parse_blocks) {
        markdown_doc_storage = try core.markdown.parseMarkdownDocument(
            allocator,
            node.role,
            if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
            node.content.?,
        );
    }
    if (should_parse_inline) {
        inline_layout_storage = try core.markdown.parseTextLayout(
            allocator,
            node.role,
            if (node.payload_kind) |payload_kind| @tagName(payload_kind) else null,
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
    try item.optionalIntField("page_index", node.page_index);
    try item.optionalIntField("derived_from", node.derived_from);
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
    if (render.text) |text_spec| {
        var text = try render_object.objectField("text");
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
    } else {
        try render_object.nullField("text");
    }
    if (render.math) |math_spec| {
        var math = try render_object.objectField("math");
        try math.floatField("block_line_height", math_spec.block_line_height, "{d:.1}");
        try math.floatField("block_min_height", math_spec.block_min_height, "{d:.1}");
        try math.floatField("block_vertical_padding", math_spec.block_vertical_padding, "{d:.1}");
        try math.floatField("scale", math_spec.scale, "{d:.4}");
        try math.end();
    } else {
        try render_object.nullField("math");
    }
    if (render.code) |code_spec| {
        var code = try render_object.objectField("code");
        try code.optionalStringField("language", code_spec.language);
        try writeColor(&code, "plain_color", code_spec.plain);
        try writeColor(&code, "keyword_color", code_spec.keyword);
        try writeColor(&code, "comment_color", code_spec.comment);
        try writeColor(&code, "string_color", code_spec.string);
        try code.end();
    } else {
        try render_object.nullField("code");
    }

    var chrome = try render_object.objectField("chrome");
    try writeOptionalColor(&chrome, "fill", render.chrome.fill);
    try writeOptionalColor(&chrome, "stroke", render.chrome.stroke);
    try chrome.floatField("line_width", render.chrome.line_width, "{d:.1}");
    try chrome.floatField("radius", render.chrome.radius, "{d:.1}");
    try chrome.end();

    var underline = try render_object.objectField("underline");
    try writeOptionalColor(&underline, "color", render.underline.color);
    try underline.floatField("width", render.underline.width, "{d:.1}");
    try underline.floatField("offset", render.underline.offset, "{d:.1}");
    try underline.end();

    var rule = try render_object.objectField("rule");
    try writeOptionalColor(&rule, "stroke", render.rule.stroke);
    try rule.floatField("line_width", render.rule.line_width, "{d:.1}");
    if (render.rule.dash) |dash| {
        var dash_array = try rule.arrayField("dash");
        try dash_array.floatItem(dash.on, "{d:.4}");
        try dash_array.floatItem(dash.off, "{d:.4}");
        try dash_array.end();
    } else {
        try rule.nullField("dash");
    }
    try rule.end();
    try render_object.end();
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

fn writeDiagnostic(allocator: std.mem.Allocator, diagnostics: *json.Array, diagnostic: core.Diagnostic) !void {
    var item = try diagnostics.objectItem();
    try item.enumTagField("phase", diagnostic.phase);
    try item.enumTagField("severity", diagnostic.severity);
    try item.optionalIntField("page_id", diagnostic.page_id);
    try item.optionalIntField("node_id", diagnostic.node_id);
    try item.optionalStringField("origin", diagnostic.origin);
    switch (diagnostic.data) {
        .user_report => |data| {
            try item.stringField("code", "user_report");
            try item.stringField("message", data.message);
        },
        .asset_not_found => |data| {
            try item.stringField("code", "asset_not_found");
            try item.stringField("requested_path", data.requested_path);
            try item.stringField("resolved_path", data.resolved_path);
            try item.optionalEnumTagField("payload_kind", data.payload_kind);
        },
        .asset_invalid => |data| {
            try item.stringField("code", "asset_invalid");
            try item.stringField("reason", data.reason);
            try item.optionalEnumTagField("payload_kind", data.payload_kind);
        },
        .type_mismatch => |data| {
            try item.stringField("code", @tagName(data.code));
            try item.stringField("expected", @tagName(data.expected));
            try item.stringField("actual", @tagName(data.actual));
        },
        .recursive_function => |data| {
            try item.stringField("code", "RecursiveFunction");
            try item.stringField("function_name", data.function_name);
        },
        .unresolved_frame => |data| {
            try item.stringField("code", "unresolved_frame");
            try item.boolField("missing_horizontal", data.missing_horizontal);
            try item.boolField("missing_vertical", data.missing_vertical);
        },
        .page_overflow => |data| {
            try item.stringField("code", "page_overflow");
            try item.floatField("overflow_left", data.overflow_left, "{d:.1}");
            try item.floatField("overflow_right", data.overflow_right, "{d:.1}");
            try item.floatField("overflow_top", data.overflow_top, "{d:.1}");
            try item.floatField("overflow_bottom", data.overflow_bottom, "{d:.1}");
        },
    }
    try item.end();
    _ = allocator;
}
