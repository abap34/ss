const std = @import("std");
const core = @import("core");

const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const json = @import("utils").json;

const SemanticEnv = semantic_env.SemanticEnv;

pub fn writeField(allocator: std.mem.Allocator, root: *json.Object, ir: *core.Ir) !void {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = SemanticEnv.init(ir, &declaration_index, &ir.functions);

    var render_doc = try core.render_doc.buildWithEnv(allocator, ir, &sema);
    defer render_doc.deinit(allocator);

    var object = try root.objectField("render_doc");
    var ops = try object.arrayField("ops");
    for (render_doc.ops.items) |op| {
        var item = try ops.objectItem();
        try item.intField("nodeId", op.node_id);
        try item.stringField("op", op.op);
        try writeFrame(&item, op.frame);
        var args = try item.objectField("args");
        for (op.args.items) |arg| try args.stringField(arg.key, arg.value);
        try args.end();
        try item.end();
    }
    try ops.end();
    try object.end();
}

fn writeFrame(object: *json.Object, frame: core.Frame) !void {
    var frame_object = try object.objectField("frame");
    try frame_object.floatField("x", frame.x, "{d:.1}");
    try frame_object.floatField("y", frame.y, "{d:.1}");
    try frame_object.floatField("width", frame.width, "{d:.1}");
    try frame_object.floatField("height", frame.height, "{d:.1}");
    try frame_object.end();
}
