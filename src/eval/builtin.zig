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
            break :blk .{ .string = try ctx.ownString(try std.fmt.allocPrint(ctx.ir.allocator, "{s}{s}", .{ left, right })) };
        },
        .replace => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const old = try ctx.evalStringArg(call, 1);
            const new = try ctx.evalStringArg(call, 2);
            break :blk .{ .string = try ctx.ownString(try replaceAll(ctx.ir.allocator, text, old, new)) };
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
                if (index > 0) try out.appendSlice(ctx.ir.allocator, separator);
                try out.appendSlice(ctx.ir.allocator, text);
            }
            break :blk .{ .string = try ctx.ownString(try out.toOwnedSlice(ctx.ir.allocator)) };
        },
        .first => blk: {
            const selection = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            break :blk switch (selection) {
                .selection => |sel| switch (sel.item_tag) {
                    .object => .{ .object = sel.first() orelse return error.EmptySelection },
                    .page => .{ .page = sel.first() orelse return error.EmptySelection },
                    .metadata => .{ .metadata = sel.first() orelse return error.EmptySelection },
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
        .emit_metadata => blk: {
            var target = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            defer target.deinit(ctx.ir.allocator);
            const kind = try ctx.evalStringArg(call, 1);
            const value = try ctx.evalStringArg(call, 2);
            break :blk .{ .metadata = try ctx.emitMetadata(target, kind, value) };
        },
        .metadata_in_document => blk: {
            const document_id = try evalDocumentArg(ctx, call, 0);
            _ = document_id;
            const kind = try ctx.evalStringArg(call, 1);
            break :blk .{ .selection = try ctx.metadataInDocument(kind) };
        },
        .metadata_on_page => blk: {
            const page_id = try evalPageArg(ctx, call, 0);
            const kind = try ctx.evalStringArg(call, 1);
            break :blk .{ .selection = try ctx.metadataOnPage(page_id, kind) };
        },
        .metadata_content => blk: {
            const metadata_id = try evalMetadataArg(ctx, call, 0);
            break :blk .{ .string = try ctx.metadataContent(metadata_id) };
        },
        .metadata_kind => blk: {
            const metadata_id = try evalMetadataArg(ctx, call, 0);
            break :blk .{ .string = try ctx.metadataKind(metadata_id) };
        },
        .metadata_page => blk: {
            const metadata_id = try evalMetadataArg(ctx, call, 0);
            break :blk .{ .page = try ctx.metadataPage(metadata_id) };
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
                    break :blk2 .{ .document = id };
                },
                .page => |id| blk2: {
                    try ctx.setNodeProperty(id, key, value);
                    break :blk2 .{ .page = id };
                },
                .object => |id| blk2: {
                    try ctx.setNodeProperty(id, key, value);
                    break :blk2 .{ .object = id };
                },
                .selection => |sel| blk2: {
                    if (sel.item_tag != .object) {
                        target.deinit(ctx.ir.allocator);
                        return error.InvalidSelectionItemType;
                    }
                    for (sel.ids.items) |id| try ctx.setNodeProperty(id, key, value);
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
        .metadata => .{ .metadata = id },
    };
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

fn evalMetadataArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.MetadataId {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.ir.allocator);
    return switch (value) {
        .metadata => |id| id,
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
