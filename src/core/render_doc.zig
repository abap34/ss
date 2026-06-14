const std = @import("std");
const model = @import("model");
const render_policy = @import("render_policy.zig");

pub const Arg = struct {
    key: []const u8,
    value: []const u8,

    fn deinit(self: Arg, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const Op = struct {
    node_id: model.NodeId,
    op: []const u8,
    frame: model.Frame,
    args: std.ArrayList(Arg),

    fn init(node: *const model.Node, name: []const u8) Op {
        return .{
            .node_id = node.id,
            .op = name,
            .frame = node.frame,
            .args = .empty,
        };
    }

    fn deinit(self: *Op, allocator: std.mem.Allocator) void {
        for (self.args.items) |arg| arg.deinit(allocator);
        self.args.deinit(allocator);
    }

    fn put(self: *Op, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.args.append(allocator, .{
            .key = key,
            .value = try allocator.dupe(u8, value),
        });
    }

    fn putFloat(self: *Op, allocator: std.mem.Allocator, key: []const u8, value: f32) !void {
        try self.args.append(allocator, .{
            .key = key,
            .value = try std.fmt.allocPrint(allocator, "{d}", .{value}),
        });
    }

    fn putBool(self: *Op, allocator: std.mem.Allocator, key: []const u8, value: bool) !void {
        try self.put(allocator, key, if (value) "true" else "false");
    }

    fn putColor(self: *Op, allocator: std.mem.Allocator, key: []const u8, color: render_policy.Color) !void {
        try self.args.append(allocator, .{
            .key = key,
            .value = try std.fmt.allocPrint(allocator, "{d},{d},{d}", .{ color.r, color.g, color.b }),
        });
    }

    fn putOptionalColor(self: *Op, allocator: std.mem.Allocator, key: []const u8, color: ?render_policy.Color) !void {
        if (color) |resolved| try self.putColor(allocator, key, resolved);
    }
};

pub const RenderDoc = struct {
    ops: std.ArrayList(Op),

    pub fn init() RenderDoc {
        return .{ .ops = .empty };
    }

    pub fn deinit(self: *RenderDoc, allocator: std.mem.Allocator) void {
        for (self.ops.items) |*op| op.deinit(allocator);
        self.ops.deinit(allocator);
    }
};

pub fn build(allocator: std.mem.Allocator, ir: anytype) !RenderDoc {
    return buildWithPolicy(allocator, ir, false, {});
}

pub fn buildWithEnv(allocator: std.mem.Allocator, ir: anytype, sema: anytype) !RenderDoc {
    return buildWithPolicy(allocator, ir, true, sema);
}

fn buildWithPolicy(allocator: std.mem.Allocator, ir: anytype, comptime use_env: bool, sema: anytype) !RenderDoc {
    var doc = RenderDoc.init();
    errdefer doc.deinit(allocator);

    for (ir.page_order.items) |page_id| {
        const page = ir.getNode(page_id) orelse continue;
        const fill = if (use_env)
            render_policy.resolvePageBackgroundWithEnv(ir, page, sema)
        else
            render_policy.resolvePageBackground(ir, page);
        if (fill) |color| {
            try appendPageBackground(allocator, &doc, page, color);
        }
    }

    for (ir.nodes.items) |*node| {
        if (node.kind != .object or !node.attached) continue;
        const resolved = if (use_env)
            render_policy.resolveWithEnv(ir, node, sema)
        else
            render_policy.resolve(ir, node);
        if (resolved.rule.stroke != null) try appendRule(allocator, &doc, node, resolved.rule);
        if (hasChrome(resolved.chrome)) try appendChrome(allocator, &doc, node, resolved.chrome);
        switch (resolved.kind) {
            .text => if (resolved.text) |text| try appendText(allocator, &doc, node, text),
            .code => {
                if (resolved.text) |text| try appendText(allocator, &doc, node, text);
                if (resolved.code) |code| try appendCode(allocator, &doc, node, code);
            },
            .vector_math => if (resolved.math) |math| try appendMath(allocator, &doc, ir, node, math),
            .vector_asset => try appendAsset(allocator, &doc, node, "draw_vector_asset"),
            .raster_asset => try appendAsset(allocator, &doc, node, "draw_raster_asset"),
            .chrome_only => {},
        }
    }

    return doc;
}

fn hasChrome(chrome: render_policy.ChromePaint) bool {
    return chrome.fill != null or chrome.stroke != null or chrome.line_width != 1.0 or chrome.radius != 10.0;
}

fn appendPageBackground(allocator: std.mem.Allocator, doc: *RenderDoc, page: *const model.Node, fill: render_policy.Color) !void {
    var op = Op.init(page, "draw_chrome");
    errdefer op.deinit(allocator);
    try op.putColor(allocator, "fill", fill);
    try op.putFloat(allocator, "line_width", 0);
    try op.putFloat(allocator, "radius", 0);
    try doc.ops.append(allocator, op);
}

fn appendRule(allocator: std.mem.Allocator, doc: *RenderDoc, node: *const model.Node, rule: render_policy.RulePaint) !void {
    var op = Op.init(node, "draw_rule");
    errdefer op.deinit(allocator);
    try op.putOptionalColor(allocator, "stroke", rule.stroke);
    try op.putFloat(allocator, "line_width", rule.line_width);
    if (rule.dash) |dash| {
        try op.putFloat(allocator, "dash_on", dash.on);
        try op.putFloat(allocator, "dash_off", dash.off);
    }
    try doc.ops.append(allocator, op);
}

fn appendChrome(allocator: std.mem.Allocator, doc: *RenderDoc, node: *const model.Node, chrome: render_policy.ChromePaint) !void {
    var op = Op.init(node, "draw_chrome");
    errdefer op.deinit(allocator);
    op.frame.x -= chrome.pad_x;
    op.frame.y -= chrome.pad_y;
    op.frame.width += chrome.pad_x * 2;
    op.frame.height += chrome.pad_y * 2;
    try op.putOptionalColor(allocator, "fill", chrome.fill);
    try op.putOptionalColor(allocator, "stroke", chrome.stroke);
    try op.putFloat(allocator, "line_width", chrome.line_width);
    try op.putFloat(allocator, "radius", chrome.radius);
    try doc.ops.append(allocator, op);
}

fn appendText(allocator: std.mem.Allocator, doc: *RenderDoc, node: *const model.Node, text: render_policy.TextPaint) !void {
    var op = Op.init(node, "draw_text");
    errdefer op.deinit(allocator);
    try op.put(allocator, "content", node.content orelse "");
    try op.put(allocator, "font", text.font);
    try op.put(allocator, "bold_font", text.bold_font);
    try op.put(allocator, "italic_font", text.italic_font);
    try op.put(allocator, "code_font", text.code_font);
    try op.putFloat(allocator, "font_size", text.font_size);
    try op.putFloat(allocator, "line_height", text.line_height);
    try op.putColor(allocator, "color", text.color);
    try op.putColor(allocator, "link_color", text.link_color);
    try op.putOptionalColor(allocator, "markdown_bold_color", text.markdown_bold_color);
    try op.putBool(allocator, "wrap", text.wrap);
    try doc.ops.append(allocator, op);
}

fn appendCode(allocator: std.mem.Allocator, doc: *RenderDoc, node: *const model.Node, code: render_policy.CodePaint) !void {
    var op = Op.init(node, "draw_code_highlight");
    errdefer op.deinit(allocator);
    try op.put(allocator, "language", code.language orelse "");
    try op.putColor(allocator, "plain", code.plain);
    try op.putColor(allocator, "keyword", code.keyword);
    try op.putColor(allocator, "comment", code.comment);
    try op.putColor(allocator, "string", code.string);
    try doc.ops.append(allocator, op);
}

fn appendMath(allocator: std.mem.Allocator, doc: *RenderDoc, ir: anytype, node: *const model.Node, math: render_policy.MathPaint) !void {
    var op = Op.init(node, "draw_vector_math");
    errdefer op.deinit(allocator);
    var env = try @import("render_env.zig").resolveForNode(allocator, ir, node);
    defer env.deinit(allocator);
    const preamble = try @import("render_env.zig").joinTexPreambleEntries(allocator, env);
    defer allocator.free(preamble);
    try op.put(allocator, "capability", "compile_math");
    try op.put(allocator, "source", node.content orelse "");
    try op.put(allocator, "math_tex_preamble", preamble);
    try op.putFloat(allocator, "scale", math.scale);
    try op.putColor(allocator, "color", math.color);
    try op.put(allocator, "align", @tagName(math.horizontal_align));
    try op.putFloat(allocator, "block_line_height", math.block_line_height);
    try op.putFloat(allocator, "block_min_height", math.block_min_height);
    try op.putFloat(allocator, "block_vertical_padding", math.block_vertical_padding);
    try doc.ops.append(allocator, op);
}

fn appendAsset(allocator: std.mem.Allocator, doc: *RenderDoc, node: *const model.Node, op_name: []const u8) !void {
    var op = Op.init(node, op_name);
    errdefer op.deinit(allocator);
    try op.put(allocator, "path", node.content orelse "");
    try doc.ops.append(allocator, op);
}
