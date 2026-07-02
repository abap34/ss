const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const testing = std.testing;

fn initEmptyIr() !core.Ir {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "unit-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.Ir.init(allocator, asset_base_dir, project_path, project_source, ast.Program.init());
}

test "core IR spec: pages are ordered document children with one-based page indexes" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const first = try ir.addPage("First");
    const second = try ir.addPage("Second");

    try testing.expectEqual(@as(usize, 2), ir.pageCount());
    try testing.expectEqual(first, ir.page_order.items[0]);
    try testing.expectEqual(second, ir.page_order.items[1]);
    try testing.expectEqual(@as(usize, 1), ir.pageIndexOf(first));
    try testing.expectEqual(@as(usize, 2), ir.pageIndexOf(second));

    const document_children = ir.childrenOf(ir.document_id).?;
    try testing.expectEqual(@as(usize, 2), document_children.len);
    try testing.expectEqual(first, document_children[0]);
    try testing.expectEqual(second, document_children[1]);
}

test "core IR spec: containment is idempotent for the same parent-child pair" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "title", null, .text, .text, "Hello");
    try ir.addContainment(page, object);
    try ir.addContainment(page, object);

    const children = ir.childrenOf(page).?;
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqual(object, children[0]);
}

test "core IR spec: node fields reject duplicate keys" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "shape", null, .overlay, .text, "");

    try ir.setNodeFieldValue(object, "fill", .{ .string = "red" });
    try ir.setNodeFieldValue(object, "stroke", .{ .string = "black" });
    try testing.expectError(error.DuplicatePropertyDefinition, ir.setNodeFieldValue(object, "fill", .{ .string = "blue" }));

    const node = ir.getNode(object).?;
    try testing.expectEqual(@as(usize, 2), node.fields.items.len);
    try testing.expectEqualStrings("red", ir.getNodeField(object, "fill").?.string);
    try testing.expectEqualStrings("black", ir.getNodeField(object, "stroke").?.string);
}

test "core IR spec: explicit field reads ignore inherited class defaults" {
    var ir = try initIrWithLayoutClassDefaults();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const page_node = ir.getNode(page).?;

    try testing.expectEqualStrings("top_flow", core.fields.read(ir.allocator, &ir, page_node, "layout_v", &.{}, .text).?);
    try testing.expect(core.fields.readExplicit(page_node, "layout_v", &.{}, .text) == null);

    const default_offset = core.fields.read(ir.allocator, &ir, page_node, "layout_v_center_offset", &.{}, .number).?;
    try testing.expectApproxEqAbs(@as(f32, 0), default_offset, 0.0001);
    try testing.expect(core.fields.readExplicit(page_node, "layout_v_center_offset", &.{}, .number) == null);

    try ir.setNodeFieldValue(page, "layout_v", .{ .enum_case = .{ .enum_name = "LayoutPolicy", .case_name = "center" } });
    try ir.setNodeFieldValue(page, "layout_v_center_offset", .{ .number = 40 });
    const explicit_page_node = ir.getNode(page).?;

    try testing.expectEqualStrings("center", core.fields.readExplicit(explicit_page_node, "layout_v", &.{}, .text).?);
    const explicit_offset = core.fields.readExplicit(explicit_page_node, "layout_v_center_offset", &.{}, .number).?;
    try testing.expectApproxEqAbs(@as(f32, 40), explicit_offset, 0.0001);
}

test "core IR spec: render environment entries are deduplicated by full triple" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "text", null, .text, .text, "Hello");

    try ir.extendRenderEnv(object, "set", "text_color", "red");
    try ir.extendRenderEnv(object, "set", "text_color", "red");
    try ir.extendRenderEnv(object, "set", "text_color", "blue");
    try ir.extendRenderEnv(object, "push", "text_color", "red");

    const node = ir.getNode(object).?;
    try testing.expectEqual(@as(usize, 3), node.render_env.items.len);
}

fn initIrWithLayoutClassDefaults() !core.Ir {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "layout-classes.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);

    var program = ast.Program.init();
    errdefer program.deinit(allocator);

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v"),
        .value_type = ast.Type.enumType("LayoutPolicy"),
        .default_property_value = try allocator.dupe(u8, "top_flow"),
        .span = zeroSpan(),
    });
    try program.objects.items[0].fields.append(allocator, .{
        .name = try allocator.dupe(u8, "layout_v_center_offset"),
        .value_type = ast.Type.number,
        .default_property_value = try allocator.dupe(u8, "0"),
        .span = zeroSpan(),
    });

    try program.objects.append(allocator, .{
        .name = try allocator.dupe(u8, "PageContext"),
        .base = try allocator.dupe(u8, "Doc"),
        .roles = .empty,
        .fields = .empty,
        .span = zeroSpan(),
    });

    var ir = try core.Ir.init(allocator, asset_base_dir, project_path, project_source, program);
    program = ast.Program.init();
    errdefer ir.deinit();
    try ir.module_order.append(allocator, ir.project_module_id);
    return ir;
}

fn zeroSpan() ast.Span {
    return .{ .start = 0, .end = 0 };
}

test "core IR spec: TeX preamble render environment resolves in document page object order" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "math", null, .text, .math_tex, "x");

    try ir.extendRenderEnv(ir.document_id, core.render_env.OpAdd, core.render_env.KeyMathTexPreamble, "doc preamble");
    try ir.extendRenderEnv(page, core.render_env.OpAdd, core.render_env.KeyMathTexPreambleFile, "page.tex");
    try ir.extendRenderEnv(object, core.render_env.OpAdd, core.render_env.KeyMathTexPreamble, "object preamble");

    var env = try core.render_env.resolveForNode(testing.allocator, &ir, ir.getNode(object).?);
    defer env.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), env.tex_preamble.items.len);
    try testing.expectEqual(core.render_env.TexPreambleSource.text, env.tex_preamble.items[0].source);
    try testing.expectEqualStrings("doc preamble", env.tex_preamble.items[0].value);
    try testing.expectEqual(core.render_env.TexPreambleSource.file, env.tex_preamble.items[1].source);
    try testing.expectEqualStrings("page.tex", env.tex_preamble.items[1].value);
    try testing.expectEqual(core.render_env.TexPreambleSource.text, env.tex_preamble.items[2].source);
    try testing.expectEqualStrings("object preamble", env.tex_preamble.items[2].value);
}

test "core IR spec: render doc marks math and raw TeX vector modes" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const math_object = try ir.makeObject(page, "math", null, .source, .math_text, "x + y");
    const tex_object = try ir.makeObject(page, "math_tex", null, .asset, .math_tex, "\\begin{algorithm}[H]\\end{algorithm}");
    try ir.setNodeFieldValue(math_object, "render_kind", .{ .enum_case = .{ .enum_name = "RenderKind", .case_name = "vector_math" } });
    try ir.setNodeFieldValue(tex_object, "render_kind", .{ .enum_case = .{ .enum_name = "RenderKind", .case_name = "vector_math" } });

    var doc = try core.render_doc.build(testing.allocator, &ir);
    defer doc.deinit(testing.allocator);

    const math_op = vectorMathOpForNode(doc, math_object).?;
    const tex_op = vectorMathOpForNode(doc, tex_object).?;
    try testing.expectEqualStrings("math", argValue(math_op, "tex_mode").?);
    try testing.expectEqualStrings("raw", argValue(tex_op, "tex_mode").?);
    try testing.expect(argValue(math_op, "color") == null);
    try testing.expect(argValue(tex_op, "color") == null);
}

fn argValue(op: core.render_doc.Op, key: []const u8) ?[]const u8 {
    for (op.args.items) |arg| {
        if (std.mem.eql(u8, arg.key, key)) return arg.value;
    }
    return null;
}

fn vectorMathOpForNode(doc: core.render_doc.RenderDoc, node_id: core.NodeId) ?core.render_doc.Op {
    for (doc.ops.items) |op| {
        if (op.node_id == node_id and std.mem.eql(u8, op.op, "draw_vector_math")) return op;
    }
    return null;
}
