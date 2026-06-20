const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const registry = @import("../language/registry.zig");
const eval_value = @import("value.zig");

pub fn evalCall(ctx: anytype, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor) anyerror!core.Value {
    try ctx.checkArityRange(call.args.items.len, descriptor.min_arity, descriptor.max_arity);
    return switch (descriptor.op) {
        .pagectx => ctx.currentPageValue(),
        .docctx => ctx.currentDocumentValue(),
        .select => try ctx.runSelectCall(call),
        .anchor => blk: {
            const node_id = try ctx.evalObjectArg(call, 0);
            const anchor_name = try ctx.evalStringArg(call, 1);
            break :blk try ctx.anchorValueForObject(node_id, anchor_name);
        },
        .page_anchor => blk: {
            const anchor_name = try ctx.evalStringArg(call, 0);
            break :blk try ctx.pageAnchorValue(anchor_name);
        },
        .equal => blk: {
            const target = try ctx.evalAnchorArg(call, 0);
            const source = try ctx.evalAnchorArg(call, 1);
            const offset: f32 = if (call.args.items.len == 3) try ctx.evalNumberArg(call, 2) else 0;
            break :blk .{ .constraints = try ctx.equalAnchorConstraintSet(target, source, offset) };
        },
        .logical_not => blk: {
            var value = try ctx.evalExprValue(call.args.items[0]);
            defer value.deinit(ctx.ir.allocator);
            const boolean = try eval_value.boolean(value);
            break :blk .{ .boolean = !boolean };
        },
        .neg => blk: {
            const value = try ctx.evalNumberArg(call, 0);
            break :blk .{ .number = -value };
        },
        .add => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = left + right };
        },
        .sub => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = left - right };
        },
        .mul => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = left * right };
        },
        .div => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = left / right };
        },
        .min => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = if (left < right) left else right };
        },
        .max => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .number = if (left > right) left else right };
        },
        .str => blk: {
            const value = try ctx.evalNumberArg(call, 0);
            break :blk .{ .string = try ctx.ownString(try std.fmt.allocPrint(ctx.ir.allocator, "{d}", .{value})) };
        },
        .concat => blk: {
            const left = try ctx.evalStringArg(call, 0);
            const right = try ctx.evalStringArg(call, 1);
            var provenance = std.ArrayList(core.ContentProvenance).empty;
            defer deinitContentProvenance(ctx.ir.allocator, &provenance);
            try appendContentProvenance(ctx.ir.allocator, &provenance, ctx.ir.stringProvenance(left), 0);
            try appendContentProvenance(ctx.ir.allocator, &provenance, ctx.ir.stringProvenance(right), left.len);
            break :blk .{ .string = try ctx.ownStringWithProvenance(
                try std.fmt.allocPrint(ctx.ir.allocator, "{s}{s}", .{ left, right }),
                provenance.items,
            ) };
        },
        .replace => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const old = try ctx.evalStringArg(call, 1);
            const new = try ctx.evalStringArg(call, 2);
            break :blk .{ .string = try ctx.ownString(try replaceAll(ctx.ir.allocator, text, old, new)) };
        },
        .readlines => blk: {
            const path = try ctx.evalStringArg(call, 0);
            break :blk .{ .string = try ctx.readlines(path) };
        },
        .foreach => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            errdefer target.deinit(ctx.ir.allocator);
            var callback = try evalFunctionArg(ctx, call, 1);
            defer callback.deinit(ctx.ir.allocator);
            var extras = try evalExtraArgs(ctx, call, 2);
            defer extras.deinit(ctx.ir.allocator);
            defer deinitValues(ctx.ir.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.ir.allocator);
            defer snapshot.deinit(ctx.ir.allocator);
            for (snapshot.ids.items) |id| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.ir.allocator);
                try args.append(ctx.ir.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.ir.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.ir.allocator);
            }
            break :blk target;
        },
        .foreach_enumerate => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            errdefer target.deinit(ctx.ir.allocator);
            var callback = try evalFunctionArg(ctx, call, 1);
            defer callback.deinit(ctx.ir.allocator);
            var extras = try evalExtraArgs(ctx, call, 2);
            defer extras.deinit(ctx.ir.allocator);
            defer deinitValues(ctx.ir.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.ir.allocator);
            defer snapshot.deinit(ctx.ir.allocator);
            for (snapshot.ids.items, 0..) |id, index| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.ir.allocator);
                try args.append(ctx.ir.allocator, itemValue(snapshot.item_tag, id));
                try args.append(ctx.ir.allocator, .{ .number = @floatFromInt(index + 1) });
                try args.appendSlice(ctx.ir.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.ir.allocator);
            }
            break :blk target;
        },
        .fold => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            var accumulator = try ctx.evalStringArg(call, 1);
            var callback = try evalFunctionArg(ctx, call, 2);
            defer callback.deinit(ctx.ir.allocator);
            var extras = try evalExtraArgs(ctx, call, 3);
            defer extras.deinit(ctx.ir.allocator);
            defer deinitValues(ctx.ir.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.ir.allocator);
            defer snapshot.deinit(ctx.ir.allocator);
            for (snapshot.ids.items) |id| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.ir.allocator);
                try args.append(ctx.ir.allocator, .{ .string = accumulator });
                try args.append(ctx.ir.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.ir.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.ir.allocator);
                accumulator = switch (result) {
                    .string => |text| text,
                    else => return error.ExpectedStringArgument,
                };
            }
            break :blk .{ .string = accumulator };
        },
        .join => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const separator = try ctx.evalStringArg(call, 1);
            var callback = try evalFunctionArg(ctx, call, 2);
            defer callback.deinit(ctx.ir.allocator);
            var extras = try evalExtraArgs(ctx, call, 3);
            defer extras.deinit(ctx.ir.allocator);
            defer deinitValues(ctx.ir.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.ir.allocator);
            defer snapshot.deinit(ctx.ir.allocator);
            var out = std.ArrayList(u8).empty;
            defer out.deinit(ctx.ir.allocator);
            var provenance = std.ArrayList(core.ContentProvenance).empty;
            defer deinitContentProvenance(ctx.ir.allocator, &provenance);
            for (snapshot.ids.items, 0..) |id, index| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.ir.allocator);
                try args.append(ctx.ir.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.ir.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.ir.allocator);
                const text = switch (result) {
                    .string => |value| value,
                    else => return error.ExpectedStringArgument,
                };
                if (index > 0) {
                    try appendContentProvenance(ctx.ir.allocator, &provenance, ctx.ir.stringProvenance(separator), out.items.len);
                    try out.appendSlice(ctx.ir.allocator, separator);
                }
                try appendContentProvenance(ctx.ir.allocator, &provenance, ctx.ir.stringProvenance(text), out.items.len);
                try out.appendSlice(ctx.ir.allocator, text);
            }
            break :blk .{ .string = try ctx.ownStringWithProvenance(try out.toOwnedSlice(ctx.ir.allocator), provenance.items) };
        },
        .first => blk: {
            const selection = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            break :blk switch (selection) {
                .selection => |sel| switch (sel.item_tag) {
                    .object => .{ .object = sel.first() orelse return error.EmptySelection },
                    .page => .{ .page = sel.first() orelse return error.EmptySelection },
                },
                else => return error.ExpectedSelection,
            };
        },
        .selection_union, .selection_intersection, .selection_difference => blk: {
            var left_value = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer left_value.deinit(ctx.ir.allocator);
            var right_value = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[1]));
            defer right_value.deinit(ctx.ir.allocator);
            const left = switch (left_value) {
                .selection => |selection| selection,
                else => return error.ExpectedSelection,
            };
            const right = switch (right_value) {
                .selection => |selection| selection,
                else => return error.ExpectedSelection,
            };
            if (left.item_tag != right.item_tag) return error.InvalidSelectionItemType;
            var result = core.Selection.init(left.item_tag, descriptor.name);
            errdefer result.deinit(ctx.ir.allocator);
            switch (descriptor.op) {
                .selection_union => {
                    for (left.ids.items) |id| try result.appendUnique(ctx.ir.allocator, id);
                    for (right.ids.items) |id| try result.appendUnique(ctx.ir.allocator, id);
                },
                .selection_intersection => {
                    for (left.ids.items) |id| {
                        if (right.contains(id)) try result.appendUnique(ctx.ir.allocator, id);
                    }
                },
                .selection_difference => {
                    for (left.ids.items) |id| {
                        if (!right.contains(id)) try result.appendUnique(ctx.ir.allocator, id);
                    }
                },
                else => unreachable,
            }
            break :blk .{ .selection = result };
        },
        .page_index => blk: {
            const page_id = try evalPageArg(ctx, call, 0);
            break :blk .{ .number = @floatFromInt(ctx.pageIndex(page_id)) };
        },
        .page_count => blk: {
            _ = try evalDocumentArg(ctx, call, 0);
            break :blk .{ .number = @floatFromInt(ctx.pageCount()) };
        },
        .frame_x => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            break :blk .{ .number = try ctx.frameX(object_id) };
        },
        .frame_y => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            break :blk .{ .number = try ctx.frameY(object_id) };
        },
        .frame_width => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            break :blk .{ .number = try ctx.frameWidth(object_id) };
        },
        .frame_height => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            break :blk .{ .number = try ctx.frameHeight(object_id) };
        },
        .content => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            break :blk .{ .string = ctx.nodeContent(object_id) orelse "" };
        },
        .prop => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const key = try ctx.evalStringArg(call, 1);
            const default_value = try ctx.evalStringArg(call, 2);
            break :blk .{ .string = ctx.nodeProperty(target, key) orelse default_value };
        },
        .has_prop => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const key = try ctx.evalStringArg(call, 1);
            break :blk .{ .boolean = ctx.nodeProperty(target, key) != null };
        },
        .prop_eq => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const key = try ctx.evalStringArg(call, 1);
            const expected = try ctx.evalStringArg(call, 2);
            const actual = ctx.nodeProperty(target, key);
            break :blk .{ .boolean = if (actual) |value| std.mem.eql(u8, value, expected) else false };
        },
        .selection_empty, .selection_count => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            break :blk switch (descriptor.op) {
                .selection_empty => .{ .boolean = selection.ids.items.len == 0 },
                .selection_count => .{ .number = @floatFromInt(selection.ids.items.len) },
                else => unreachable,
            };
        },
        .set_content => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            const text = try ctx.evalStringArg(call, 1);
            try ctx.setNodeContent(object_id, text);
            break :blk .{ .object = object_id };
        },
        .group => blk: {
            var child_ids = std.ArrayList(core.NodeId).empty;
            defer child_ids.deinit(ctx.ir.allocator);
            for (call.args.items, 0..) |_, index| {
                try child_ids.append(ctx.ir.allocator, try ctx.evalObjectArg(call, index));
            }
            break :blk .{ .object = try ctx.makeGroup(child_ids.items) };
        },
        .new_page => blk: {
            _ = try evalDocumentArg(ctx, call, 0);
            const title = try ctx.evalStringArg(call, 1);
            break :blk .{ .page = try ctx.makePage(title) };
        },
        .new => blk: {
            const content = try ctx.evalStringArg(call, 0);
            const role_name = try ctx.evalStringArg(call, 1);
            const role = try ctx.evalRoleArg(call, 1);
            const payload = try ctx.evalPayloadArg(call, 2);
            break :blk .{ .object = try ctx.makeObject(role_name, role, payload.object_kind, payload.payload_kind, content) };
        },
        .place_on => blk: {
            const page_id = try evalPageArg(ctx, call, 0);
            const object_id = try ctx.evalObjectArg(call, 1);
            try ctx.placeObjectOnPage(page_id, object_id);
            break :blk .{ .object = object_id };
        },
        .set_prop => blk: {
            const raw_target = try ctx.evalExprValue(call.args.items[0]);
            var target = try ctx.materializeForUse(raw_target);
            const key = try ctx.evalStringArg(call, 1);
            var value_arg = try ctx.evalExprValue(call.args.items[2]);
            defer value_arg.deinit(ctx.ir.allocator);
            switch (value_arg) {
                .none => break :blk switch (target) {
                    .document => |id| blk2: {
                        try ctx.unsetNodeProperty(id, key);
                        break :blk2 .{ .document = id };
                    },
                    .page => |id| blk2: {
                        try ctx.unsetNodeProperty(id, key);
                        break :blk2 .{ .page = id };
                    },
                    .object => |id| blk2: {
                        try ctx.unsetNodeProperty(id, key);
                        break :blk2 .{ .object = id };
                    },
                    .selection => |sel| blk2: {
                        if (sel.item_tag != .object) {
                            target.deinit(ctx.ir.allocator);
                            return error.InvalidSelectionItemType;
                        }
                        for (sel.ids.items) |id| try ctx.unsetNodeProperty(id, key);
                        break :blk2 target;
                    },
                    else => {
                        target.deinit(ctx.ir.allocator);
                        return error.InvalidValueTag;
                    },
                },
                else => {},
            }
            const value = try eval_value.propertyString(ctx.ir.allocator, value_arg);
            defer if (eval_value.propertyStringNeedsFree(value_arg)) ctx.ir.allocator.free(value);
            break :blk switch (target) {
                .document => |id| blk2: {
                    try ctx.setNodeProperty(id, key, value);
                    try expandStyleRecordProperty(ctx, id, key, value_arg);
                    break :blk2 .{ .document = id };
                },
                .page => |id| blk2: {
                    try ctx.setNodeProperty(id, key, value);
                    try expandStyleRecordProperty(ctx, id, key, value_arg);
                    break :blk2 .{ .page = id };
                },
                .object => |id| blk2: {
                    try ctx.setNodeProperty(id, key, value);
                    try expandStyleRecordProperty(ctx, id, key, value_arg);
                    break :blk2 .{ .object = id };
                },
                .selection => |sel| blk2: {
                    if (sel.item_tag != .object) {
                        target.deinit(ctx.ir.allocator);
                        return error.InvalidSelectionItemType;
                    }
                    for (sel.ids.items) |id| {
                        try ctx.setNodeProperty(id, key, value);
                        try expandStyleRecordProperty(ctx, id, key, value_arg);
                    }
                    break :blk2 target;
                },
                else => {
                    target.deinit(ctx.ir.allocator);
                    return error.InvalidValueTag;
                },
            };
        },
        .extend_render_env => blk: {
            const raw_target = try ctx.evalExprValue(call.args.items[0]);
            var target = try ctx.materializeForUse(raw_target);
            const op = try ctx.evalStringArg(call, 1);
            const key = try ctx.evalStringArg(call, 2);
            const value = try ctx.evalStringArg(call, 3);
            if (!core.render_env.isSupported(op, key)) {
                try ctx.emitDiagnosticReport(.@"error", "InvalidRenderEnv: supported render environment operations are add math.tex.preamble and add math.tex.preamble.file");
                break :blk target;
            }
            if (core.render_env.isTexPreambleFileKey(key) and !core.render_env.isValidTexPreambleFilePath(value)) {
                try ctx.emitDiagnosticReport(.@"error", "InvalidRenderEnv: empty TeX preamble file path");
                break :blk target;
            }
            break :blk switch (target) {
                .document => |id| blk2: {
                    try ctx.extendRenderEnv(id, op, key, value);
                    break :blk2 .{ .document = id };
                },
                .page => |id| blk2: {
                    try ctx.extendRenderEnv(id, op, key, value);
                    break :blk2 .{ .page = id };
                },
                .object => |id| blk2: {
                    try ctx.extendRenderEnv(id, op, key, value);
                    break :blk2 .{ .object = id };
                },
                .selection => |sel| blk2: {
                    if (sel.item_tag != .object) {
                        target.deinit(ctx.ir.allocator);
                        return error.InvalidSelectionItemType;
                    }
                    for (sel.ids.items) |id| try ctx.extendRenderEnv(id, op, key, value);
                    break :blk2 target;
                },
                else => {
                    target.deinit(ctx.ir.allocator);
                    return error.InvalidValueTag;
                },
            };
        },
        .constraints => blk: {
            var bundle = core.ConstraintSet.init();
            errdefer bundle.deinit(ctx.ir.allocator);
            for (call.args.items) |arg_expr| {
                var value = try ctx.evalExprValue(arg_expr);
                defer value.deinit(ctx.ir.allocator);
                switch (value) {
                    .constraints => |constraints| {
                        for (constraints.items.items) |constraint| {
                            try bundle.items.append(ctx.ir.allocator, constraint);
                        }
                    },
                    else => return error.ExpectedConstraintSet,
                }
            }
            break :blk .{ .constraints = bundle };
        },
        .report_error => blk: {
            const message = try ctx.evalStringArg(call, 0);
            try ctx.emitDiagnosticReport(.@"error", message);
            break :blk .{ .string = message };
        },
        .report_warning => blk: {
            const message = try ctx.evalStringArg(call, 0);
            try ctx.emitDiagnosticReport(.warning, message);
            break :blk .{ .string = message };
        },
        .require_asset_exists => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            try ctx.checkAssetExists(object_id);
            break :blk .{ .object = object_id };
        },
    };
}

fn appendContentProvenance(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(core.ContentProvenance),
    entries: []const core.ContentProvenance,
    offset: usize,
) !void {
    for (entries) |entry| {
        try out.append(allocator, try entry.cloneWithOffset(allocator, offset));
    }
}

fn deinitContentProvenance(allocator: std.mem.Allocator, entries: *std.ArrayList(core.ContentProvenance)) void {
    for (entries.items) |*entry| entry.deinit(allocator);
    entries.deinit(allocator);
}

fn replaceAll(allocator: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (old.len == 0) return allocator.dupe(u8, text);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (std.mem.indexOf(u8, text[index..], old)) |relative_match| {
        const match_start = index + relative_match;
        try out.appendSlice(allocator, text[index..match_start]);
        try out.appendSlice(allocator, new);
        index = match_start + old.len;
    }
    try out.appendSlice(allocator, text[index..]);
    return try out.toOwnedSlice(allocator);
}

fn itemValue(tag: core.SelectionItemTag, id: core.NodeId) core.Value {
    return switch (tag) {
        .page => .{ .page = id },
        .object => .{ .object = id },
    };
}

const RecordFieldMapping = struct {
    field: []const u8,
    property: []const u8,
};

fn expandStyleRecordProperty(ctx: anytype, node_id: core.NodeId, key: []const u8, value: core.Value) !void {
    if (value != .record) return;
    const record = value.record;
    if (std.mem.eql(u8, key, "layout")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "font_size", .property = "layout_font_size" },
            .{ .field = "line_height", .property = "layout_line_height" },
            .{ .field = "spacing_after", .property = "layout_spacing_after" },
            .{ .field = "x", .property = "layout_x" },
            .{ .field = "right_inset", .property = "layout_right_inset" },
            .{ .field = "wrap", .property = "wrap" },
            .{ .field = "fit", .property = "fit" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "text")) {
        if (record.field("font")) |font| try expandFontFace(ctx, node_id, font, "text_font_family", "text_font_weight", "text_font_style", "text_font_stretch");
        if (record.field("code_font")) |font| try expandFontFace(ctx, node_id, font, "text_code_font_family", "text_code_font_weight", "text_code_font_style", "text_code_font_stretch");
        const mappings = [_]RecordFieldMapping{
            .{ .field = "parse", .property = "text_parse" },
            .{ .field = "bold_weight", .property = "text_markdown_bold_weight" },
            .{ .field = "italic_style", .property = "text_markdown_italic_style" },
            .{ .field = "size", .property = "text_size" },
            .{ .field = "line_height", .property = "text_line_height" },
            .{ .field = "color", .property = "text_color" },
            .{ .field = "link_color", .property = "text_link_color" },
            .{ .field = "markdown_bold_color", .property = "text_markdown_bold_color" },
            .{ .field = "link_underline_width", .property = "text_link_underline_width" },
            .{ .field = "link_underline_offset", .property = "text_link_underline_offset" },
            .{ .field = "inline_math_height_factor", .property = "text_inline_math_height_factor" },
            .{ .field = "inline_math_spacing", .property = "text_inline_math_spacing" },
            .{ .field = "display_math_height_factor", .property = "text_display_math_height_factor" },
            .{ .field = "math_align", .property = "math_align" },
            .{ .field = "emoji_spacing", .property = "text_emoji_spacing" },
            .{ .field = "markdown_block_gap", .property = "text_markdown_block_gap" },
            .{ .field = "markdown_list_inset", .property = "text_markdown_list_inset" },
            .{ .field = "markdown_list_indent", .property = "text_markdown_list_indent" },
            .{ .field = "markdown_code_font_size", .property = "text_markdown_code_font_size" },
            .{ .field = "markdown_code_line_height", .property = "text_markdown_code_line_height" },
            .{ .field = "markdown_code_pad_x", .property = "text_markdown_code_pad_x" },
            .{ .field = "markdown_code_pad_y", .property = "text_markdown_code_pad_y" },
            .{ .field = "markdown_code_fill", .property = "text_markdown_code_fill" },
            .{ .field = "markdown_code_stroke", .property = "text_markdown_code_stroke" },
            .{ .field = "markdown_code_line_width", .property = "text_markdown_code_line_width" },
            .{ .field = "markdown_code_radius", .property = "text_markdown_code_radius" },
            .{ .field = "markdown_code_plain_color", .property = "text_markdown_code_plain_color" },
            .{ .field = "markdown_code_keyword_color", .property = "text_markdown_code_keyword_color" },
            .{ .field = "markdown_code_function_color", .property = "text_markdown_code_function_color" },
            .{ .field = "markdown_code_type_color", .property = "text_markdown_code_type_color" },
            .{ .field = "markdown_code_constant_color", .property = "text_markdown_code_constant_color" },
            .{ .field = "markdown_code_number_color", .property = "text_markdown_code_number_color" },
            .{ .field = "markdown_code_variable_color", .property = "text_markdown_code_variable_color" },
            .{ .field = "markdown_code_operator_color", .property = "text_markdown_code_operator_color" },
            .{ .field = "markdown_code_comment_color", .property = "text_markdown_code_comment_color" },
            .{ .field = "markdown_code_string_color", .property = "text_markdown_code_string_color" },
            .{ .field = "markdown_table_cell_pad_x", .property = "text_markdown_table_cell_pad_x" },
            .{ .field = "markdown_table_cell_pad_y", .property = "text_markdown_table_cell_pad_y" },
            .{ .field = "markdown_table_border", .property = "text_markdown_table_border" },
            .{ .field = "markdown_table_line_width", .property = "text_markdown_table_line_width" },
            .{ .field = "markdown_table_header_fill", .property = "text_markdown_table_header_fill" },
            .{ .field = "markdown_table_alt_row_fill", .property = "text_markdown_table_alt_row_fill" },
            .{ .field = "cjk_bold_passes", .property = "text_cjk_bold_passes" },
            .{ .field = "cjk_bold_dx", .property = "text_cjk_bold_dx" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "math")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "scale", .property = "math_scale" },
            .{ .field = "block_line_height", .property = "math_block_line_height" },
            .{ .field = "block_min_height", .property = "math_block_min_height" },
            .{ .field = "block_vertical_padding", .property = "math_block_vertical_padding" },
            .{ .field = "align", .property = "math_align" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "code")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "plain_color", .property = "code_plain_color" },
            .{ .field = "keyword_color", .property = "code_keyword_color" },
            .{ .field = "function_color", .property = "code_function_color" },
            .{ .field = "type_color", .property = "code_type_color" },
            .{ .field = "constant_color", .property = "code_constant_color" },
            .{ .field = "number_color", .property = "code_number_color" },
            .{ .field = "variable_color", .property = "code_variable_color" },
            .{ .field = "operator_color", .property = "code_operator_color" },
            .{ .field = "comment_color", .property = "code_comment_color" },
            .{ .field = "string_color", .property = "code_string_color" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "chrome")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "fill", .property = "chrome_fill" },
            .{ .field = "stroke", .property = "chrome_stroke" },
            .{ .field = "line_width", .property = "chrome_line_width" },
            .{ .field = "radius", .property = "chrome_radius" },
            .{ .field = "pad_x", .property = "chrome_pad_x" },
            .{ .field = "pad_y", .property = "chrome_pad_y" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "underline")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "color", .property = "underline_color" },
            .{ .field = "width", .property = "underline_width" },
            .{ .field = "offset", .property = "underline_offset" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "rule")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "stroke", .property = "rule_stroke" },
            .{ .field = "line_width", .property = "rule_line_width" },
            .{ .field = "dash", .property = "rule_dash" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
        return;
    }
    if (std.mem.eql(u8, key, "asset")) {
        const mappings = [_]RecordFieldMapping{
            .{ .field = "scale", .property = "asset_scale" },
            .{ .field = "width", .property = "asset_width" },
        };
        try expandMappedFields(ctx, node_id, record, &mappings);
    }
}

fn expandMappedFields(ctx: anytype, node_id: core.NodeId, record: core.RecordValue, mappings: []const RecordFieldMapping) !void {
    for (mappings) |mapping| {
        for (record.fields.items) |field| {
            if (!field.explicit or !std.mem.eql(u8, field.name, mapping.field)) continue;
            try setNodePropertyValue(ctx, node_id, mapping.property, field.value);
        }
    }
}

fn expandFontFace(ctx: anytype, node_id: core.NodeId, value: core.Value, family: []const u8, weight: []const u8, style: []const u8, stretch: []const u8) !void {
    if (value != .record) return;
    const record = value.record;
    for (record.fields.items) |field| {
        if (!field.explicit) continue;
        if (std.mem.eql(u8, field.name, "family")) try setNodePropertyValue(ctx, node_id, family, field.value);
        if (std.mem.eql(u8, field.name, "weight")) try setNodePropertyValue(ctx, node_id, weight, field.value);
        if (std.mem.eql(u8, field.name, "style")) try setNodePropertyValue(ctx, node_id, style, field.value);
        if (std.mem.eql(u8, field.name, "stretch")) try setNodePropertyValue(ctx, node_id, stretch, field.value);
    }
}

fn setNodePropertyValue(ctx: anytype, node_id: core.NodeId, key: []const u8, value: core.Value) !void {
    if (value == .none) {
        try ctx.unsetNodeProperty(node_id, key);
        return;
    }
    const text = try eval_value.propertyString(ctx.ir.allocator, value);
    defer if (eval_value.propertyStringNeedsFree(value)) ctx.ir.allocator.free(text);
    try ctx.setNodeProperty(node_id, key, text);
}

fn evalFunctionArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.FunctionRef {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.ir.allocator);
    return switch (value) {
        .function => |function| try function.clone(ctx.ir.allocator),
        else => error.InvalidValueTag,
    };
}

fn evalPageArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.NodeId {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.ir.allocator);
    return switch (value) {
        .page => |id| id,
        else => error.InvalidValueTag,
    };
}

fn evalDocumentArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.NodeId {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.ir.allocator);
    return switch (value) {
        .document => |id| id,
        else => error.InvalidValueTag,
    };
}

fn evalExtraArgs(ctx: anytype, call: ast.CallExpr, start_index: usize) !std.ArrayList(core.Value) {
    var values = std.ArrayList(core.Value).empty;
    errdefer {
        deinitValues(ctx.ir.allocator, values.items);
        values.deinit(ctx.ir.allocator);
    }
    var index = start_index;
    while (index < call.args.items.len) : (index += 1) {
        try values.append(ctx.ir.allocator, try ctx.evalExprValue(call.args.items[index]));
    }
    return values;
}

fn deinitValues(allocator: std.mem.Allocator, values: []core.Value) void {
    for (values) |value| {
        var owned = value;
        owned.deinit(allocator);
    }
}
