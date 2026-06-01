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
    try ir.addContainmentFromStage(page, object);
    try ir.addContainmentFromStage(page, object);

    const children = ir.childrenOf(page).?;
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqual(object, children[0]);
}

test "core IR spec: node properties are last-write-wins by key" {
    var ir = try initEmptyIr();
    defer ir.deinit();

    const page = try ir.addPage("Page");
    const object = try ir.makeObject(page, "shape", null, .overlay, .text, "");

    try ir.setNodeProperty(object, "fill", "red");
    try ir.setNodeProperty(object, "stroke", "black");
    try ir.setNodeProperty(object, "fill", "blue");

    const node = ir.getNode(object).?;
    try testing.expectEqual(@as(usize, 2), node.properties.items.len);
    try testing.expectEqualStrings("blue", ir.getNodeProperty(object, "fill").?);
    try testing.expectEqualStrings("black", ir.getNodeProperty(object, "stroke").?);
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
