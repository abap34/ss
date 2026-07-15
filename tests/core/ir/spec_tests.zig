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

test "core IR spec: page-local validation reports duplicate page ownership" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const first = try ir.addPage("First");
    const second = try ir.addPage("Second");
    const object = try ir.makeObject(first, "title", null, .text, .text, "Hello");
    try ir.addContainment(second, object);

    try ir.validatePageLocalLayout();

    try expectDiagnosticCode(&ir, "PageOwnershipConflict:");
}

test "core IR spec: page-local validation reports cross-page constraints" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const first = try ir.addPage("First");
    const second = try ir.addPage("Second");
    const target = try ir.makeObject(first, "target", null, .text, .text, "Target");
    const source = try ir.makeObject(second, "source", null, .text, .text, "Source");

    try ir.addAnchorConstraint(target, .top, .{ .node = .{ .node_id = source, .anchor = .top } }, 0, "cross-page");
    try ir.validatePageLocalLayout();

    try expectDiagnosticCode(&ir, "CrossPageConstraint:");
}

test "core IR spec: page-local validation reports unowned layout objects" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const placed = try ir.makeObject(page, "placed", null, .text, .text, "Placed");
    const helper = try ir.createObjectWithOrigin("helper", null, .text, .text, "Helper", null);

    try ir.addAnchorConstraint(placed, .top, .{ .node = .{ .node_id = helper, .anchor = .top } }, 0, "unowned");
    try ir.validatePageLocalLayout();

    try expectDiagnosticCode(&ir, "UnownedLayoutObject:");
}

test "core IR spec: position updates replace deeper constraints across anchors on the same axis" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "item", null, .text, .text, "Item");
    try ir.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try ir.addAnchorConstraintAtScope(object, .right, .{ .node = .{ .node_id = object, .anchor = .left } }, 240, "component-width", 1);
    try ir.addConstraintUpdate(object, .left, .position, 0, .{
        .target_node = object,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 80,
        .origin = "page-left",
        .role = .position,
        .scope_depth = 0,
        .from_update = true,
    }, "page-left");

    try core.constraint_updates.resolve(&ir);

    try testing.expectEqual(@as(usize, 2), ir.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), ir.overridden_constraints.items.len);
    try testing.expectEqual(core.Anchor.center_x, ir.overridden_constraints.items[0].target_anchor);
    try testing.expectEqual(core.ConstraintRole.size, ir.constraints.items[0].role);
    try testing.expectEqual(core.Anchor.left, ir.constraints.items[1].target_anchor);
    try testing.expect(ir.constraints.items[1].from_update);
}

test "core IR spec: pure updates suppress inherited constraints without adding a replacement" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "item", null, .text, .text, "Item");
    try ir.addAnchorConstraintAtScope(object, .top, .{ .page = .top }, -40, "component-top", 1);
    try ir.addConstraintUpdate(object, .top, .position, 0, null, "page-top");

    try core.constraint_updates.resolve(&ir);

    try testing.expectEqual(@as(usize, 0), ir.constraints.items.len);
    try testing.expectEqual(@as(usize, 1), ir.overridden_constraints.items.len);
    try testing.expect(ir.constraint_updates.items[0].active);
}

test "core IR spec: suppressed cross-page constraints are not diagnosed" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const first = try ir.addPage("First");
    const second = try ir.addPage("Second");
    const target = try ir.makeObject(first, "target", null, .text, .text, "Target");
    const source = try ir.makeObject(second, "source", null, .text, .text, "Source");
    try ir.addAnchorConstraintAtScope(target, .left, .{ .node = .{ .node_id = source, .anchor = .left } }, 0, "component-left", 1);
    try ir.addConstraintUpdate(target, .left, .position, 0, null, "page-left");

    try core.constraint_updates.resolve(&ir);
    try ir.validatePageLocalLayout();

    for (ir.diagnostics.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| try testing.expect(!std.mem.startsWith(u8, data.message, "CrossPageConstraint:")),
            else => {},
        }
    }
}

test "core IR spec: caller updates have authority over deeper updates" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "item", null, .text, .text, "Item");
    try ir.addConstraintUpdate(object, .left, .position, 2, .{
        .target_node = object,
        .target_anchor = .left,
        .source = .{ .page = .left },
        .offset = 20,
        .role = .position,
        .scope_depth = 2,
        .from_update = true,
    }, "nested-left");
    try ir.addConstraintUpdate(object, .right, .position, 0, .{
        .target_node = object,
        .target_anchor = .right,
        .source = .{ .page = .right },
        .offset = -60,
        .role = .position,
        .scope_depth = 0,
        .from_update = true,
    }, "page-right");
    try ir.addConstraintUpdate(object, .center_x, .position, 1, .{
        .target_node = object,
        .target_anchor = .center_x,
        .source = .{ .page = .center_x },
        .offset = 10,
        .role = .position,
        .scope_depth = 1,
        .from_update = true,
    }, "component-center");

    try core.constraint_updates.resolve(&ir);

    try testing.expect(!ir.constraint_updates.items[0].active);
    try testing.expect(ir.constraint_updates.items[1].active);
    try testing.expect(!ir.constraint_updates.items[2].active);
    try testing.expectEqual(@as(usize, 1), ir.constraints.items.len);
    try testing.expectEqual(core.Anchor.right, ir.constraints.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -60), ir.constraints.items[0].offset);
    try testing.expectEqual(@as(usize, 2), ir.overridden_constraints.items.len);
}

test "core IR spec: later updates replace earlier updates in the same scope" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "item", null, .text, .text, "Item");
    try ir.addAnchorConstraintAtScope(object, .center_x, .{ .page = .center_x }, 0, "component-center", 1);
    try ir.addConstraintUpdate(object, .left, .position, 0, null, "first");
    try ir.addConstraintUpdate(object, .right, .position, 0, .{
        .target_node = object,
        .target_anchor = .right,
        .source = .{ .page = .right },
        .offset = -40,
        .role = .position,
        .scope_depth = 0,
        .from_update = true,
    }, "second");

    try core.constraint_updates.resolve(&ir);

    try testing.expect(!ir.constraint_updates.items[0].active);
    try testing.expect(ir.constraint_updates.items[1].active);
    try testing.expectEqual(@as(usize, 1), ir.constraints.items.len);
    try testing.expectEqual(core.Anchor.right, ir.constraints.items[0].target_anchor);
    try testing.expectEqual(@as(f32, -40), ir.constraints.items[0].offset);
    try testing.expectEqual(@as(usize, 1), ir.overridden_constraints.items.len);
}

test "core IR spec: page unit collects inline math asset dependencies" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    _ = try ir.makeObject(page, "body", null, .text, .text, "value $x+y$");

    var pages = try core.page_unit.prepare(testing.allocator, &ir);
    defer pages.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), pages.pages.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].objects.len);
    const object = pages.pages[0].objects[0];
    try testing.expectEqual(@as(usize, 1), object.asset_deps.len);
    try testing.expectEqual(core.page_unit.AssetDependency.Kind.inline_math, object.asset_deps[0].kind);
    try testing.expectEqualStrings("x+y", object.asset_deps[0].source);
    try testing.expectEqual(@as(usize, 1), object.asset_keys.len);
    try testing.expectEqual(@as(usize, 1), pages.pages[0].asset_keys.len);
    try testing.expectEqual(object.asset_keys[0], pages.pages[0].asset_keys[0]);
    try testing.expectEqual(core.page_unit.assetDependencyKey(object.asset_deps[0], object.tex_preamble), object.asset_keys[0]);
}

test "core IR spec: prepared page asset keys attach to layout results" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "value $x+y$");
    try ir.addAnchorConstraint(object, .left, .{ .page = .left }, 40, "body-left");
    try ir.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var pages = try core.page_unit.prepare(testing.allocator, &ir);
    defer pages.deinit(testing.allocator);
    var results = try core.layout.solveLayoutResultsWithTracePathAndOptions(&ir, null, .{});
    defer results.deinit(testing.allocator);
    try core.page_unit.attachAssetKeysToLayoutResults(testing.allocator, &results, &pages);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expectEqual(@as(usize, 1), results.pages[0].asset_keys.len);
    try testing.expectEqual(pages.pages[0].asset_keys[0], results.pages[0].asset_keys[0]);
}

test "core IR spec: layout results collect solved page frames" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "Hello");
    try ir.addAnchorConstraint(object, .left, .{ .page = .left }, 40, "body-left");
    try ir.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var results = try core.layout.solveLayoutResultsWithTracePathAndOptions(&ir, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expectEqual(page, results.pages[0].page_id);
    const result_frame = results.frameOf(page, object) orelse return error.MissingLayoutFrame;
    const node_frame = ir.getNode(object).?.frame;
    try testing.expect(result_frame.x_set);
    try testing.expect(result_frame.y_set);
    try testing.expectEqual(node_frame, result_frame);
    try testing.expect(results.pages[0].measurement_keys.len > 0);
}

test "core IR spec: layout results own page diagnostics" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "body", null, .text, .text, "Hello");
    try ir.addAnchorConstraint(object, .left, .{ .page = .left }, -40, "body-left");
    try ir.addAnchorConstraint(object, .top, .{ .page = .top }, -80, "body-top");

    var results = try core.layout.solveLayoutResultsWithTracePathAndOptions(&ir, null, .{});
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.pages.len);
    try testing.expect(results.pages[0].diagnostics.len > 0);
    try testing.expect(ir.diagnostics.items.len > 0);
    try testing.expectEqual(core.DiagnosticPhase.layout, results.pages[0].diagnostics[0].phase);
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

fn expectDiagnosticCode(ir: *core.Ir, code: []const u8) !void {
    for (ir.diagnostics.items) |diagnostic| {
        switch (diagnostic.data) {
            .user_report => |data| {
                if (std.mem.startsWith(u8, data.message, code)) return;
            },
            else => {},
        }
    }
    return error.ExpectedDiagnosticMissing;
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
