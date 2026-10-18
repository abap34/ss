const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const registry = @import("../language/registry.zig");
const eval_value = @import("value.zig");
const path_eval = @import("path.zig");

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
            var page_value = try ctx.evalExprValue(call.args.items[0]);
            defer page_value.deinit(ctx.state.allocator);
            const page_id = switch (page_value) {
                .page => |id| id,
                else => return error.ExpectedPage,
            };
            const anchor_name = try ctx.evalStringArg(call, 1);
            break :blk try ctx.pageAnchorValue(page_id, anchor_name);
        },
        .num_eq => blk: {
            var left = try ctx.evalExprValue(call.args.items[0]);
            defer left.deinit(ctx.state.allocator);
            var right = try ctx.evalExprValue(call.args.items[1]);
            defer right.deinit(ctx.state.allocator);
            if (left == .anchor and right == .anchor) {
                break :blk .{ .constraints = try ctx.equalAnchorConstraintSet(left.anchor, right.anchor, 0) };
            }
            break :blk .{ .boolean = try eval_value.number(left) == try eval_value.number(right) };
        },
        .num_ne, .num_lt, .num_le, .num_gt, .num_ge => blk: {
            const left = try ctx.evalNumberArg(call, 0);
            const right = try ctx.evalNumberArg(call, 1);
            break :blk .{ .boolean = switch (descriptor.op) {
                .num_ne => left != right,
                .num_lt => left < right,
                .num_le => left <= right,
                .num_gt => left > right,
                .num_ge => left >= right,
                else => unreachable,
            } };
        },
        .logical_not => blk: {
            var value = try ctx.evalExprValue(call.args.items[0]);
            defer value.deinit(ctx.state.allocator);
            const boolean = try eval_value.boolean(value);
            break :blk .{ .boolean = !boolean };
        },
        .neg => blk: {
            const value = try ctx.evalNumberArg(call, 0);
            break :blk .{ .number = -value };
        },
        .add, .sub => blk: {
            var left = try ctx.evalExprValue(call.args.items[0]);
            defer left.deinit(ctx.state.allocator);
            var right = try ctx.evalExprValue(call.args.items[1]);
            defer right.deinit(ctx.state.allocator);
            const sign: f32 = if (descriptor.op == .add) 1 else -1;
            if (descriptor.op == .sub and left == .selection and right == .selection) {
                break :blk try selectionAlgebra(ctx, .selection_difference, left, right);
            }
            if (left == .anchor) break :blk .{ .anchor = left.anchor.shifted(sign * try eval_value.number(right)) };
            if (descriptor.op == .add and right == .anchor) break :blk .{ .anchor = right.anchor.shifted(try eval_value.number(left)) };
            break :blk .{ .number = try eval_value.number(left) + sign * try eval_value.number(right) };
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
            break :blk .{ .string = try ctx.ownString(try std.fmt.allocPrint(ctx.state.allocator, "{d}", .{value})) };
        },
        .concat => blk: {
            const left = try ctx.evalStringArg(call, 0);
            const right = try ctx.evalStringArg(call, 1);
            var provenance = std.ArrayList(core.ContentProvenance).empty;
            defer deinitContentProvenance(ctx.state.allocator, &provenance);
            try appendContentProvenance(ctx.state.allocator, &provenance, ctx.state.stringProvenance(left), 0);
            try appendContentProvenance(ctx.state.allocator, &provenance, ctx.state.stringProvenance(right), left.len);
            break :blk .{ .string = try ctx.ownStringWithProvenance(
                try std.fmt.allocPrint(ctx.state.allocator, "{s}{s}", .{ left, right }),
                provenance.items,
            ) };
        },
        .replace => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const old = try ctx.evalStringArg(call, 1);
            const new = try ctx.evalStringArg(call, 2);
            break :blk .{ .string = try ctx.ownString(try replaceAll(ctx.state.allocator, text, old, new)) };
        },
        .str_contains => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const needle = try ctx.evalStringArg(call, 1);
            break :blk .{ .boolean = std.mem.indexOf(u8, text, needle) != null };
        },
        .str_before => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const needle = try ctx.evalStringArg(call, 1);
            const match_start = std.mem.indexOf(u8, text, needle) orelse text.len;
            break :blk .{ .string = try ctx.ownString(try ctx.state.allocator.dupe(u8, text[0..match_start])) };
        },
        .str_after => blk: {
            const text = try ctx.evalStringArg(call, 0);
            const needle = try ctx.evalStringArg(call, 1);
            const match_start = std.mem.indexOf(u8, text, needle) orelse text.len;
            const after_start = if (match_start < text.len) match_start + needle.len else text.len;
            break :blk .{ .string = try ctx.ownString(try ctx.state.allocator.dupe(u8, text[after_start..])) };
        },
        .readlines => blk: {
            const path = try ctx.evalStringArg(call, 0);
            break :blk .{ .string = try ctx.readlines(path) };
        },
        .foreach => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            errdefer target.deinit(ctx.state.allocator);
            const callback = try evalFunctionArg(ctx, call, 1);
            var extras = try evalExtraArgs(ctx, call, 2);
            defer extras.deinit(ctx.state.allocator);
            defer deinitValues(ctx.state.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.state.allocator);
            defer snapshot.deinit(ctx.state.allocator);
            for (snapshot.ids.items) |id| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.state.allocator);
                try args.append(ctx.state.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.state.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.state.allocator);
            }
            break :blk target;
        },
        .selection_filter => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            errdefer target.deinit(ctx.state.allocator);
            const predicate = try evalFunctionArg(ctx, call, 1);
            if (target != .selection) return error.ExpectedSelection;
            // Expression evaluation owns this snapshot; compacting it cannot
            // change the caller's selection or the callback's captured values.
            var kept: usize = 0;
            for (target.selection.ids.items) |id| {
                var keep = try ctx.invokeCallback(predicate, &.{itemValue(target.selection.item_tag, id)});
                defer keep.deinit(ctx.state.allocator);
                if (try eval_value.boolean(keep)) {
                    target.selection.ids.items[kept] = id;
                    kept += 1;
                }
            }
            target.selection.ids.items.len = kept;
            break :blk target;
        },
        .foreach_enumerate => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            errdefer target.deinit(ctx.state.allocator);
            const callback = try evalFunctionArg(ctx, call, 1);
            var extras = try evalExtraArgs(ctx, call, 2);
            defer extras.deinit(ctx.state.allocator);
            defer deinitValues(ctx.state.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.state.allocator);
            defer snapshot.deinit(ctx.state.allocator);
            for (snapshot.ids.items, 0..) |id, index| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.state.allocator);
                try args.append(ctx.state.allocator, itemValue(snapshot.item_tag, id));
                try args.append(ctx.state.allocator, .{ .number = @floatFromInt(index + 1) });
                try args.appendSlice(ctx.state.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.state.allocator);
            }
            break :blk target;
        },
        .fold => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            defer target.deinit(ctx.state.allocator);
            var accumulator = try ctx.evalExprValue(call.args.items[1]);
            errdefer accumulator.deinit(ctx.state.allocator);
            const callback = try evalFunctionArg(ctx, call, 2);
            var extras = try evalExtraArgs(ctx, call, 3);
            defer extras.deinit(ctx.state.allocator);
            defer deinitValues(ctx.state.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.state.allocator);
            defer snapshot.deinit(ctx.state.allocator);
            for (snapshot.ids.items) |id| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.state.allocator);
                try args.append(ctx.state.allocator, accumulator);
                try args.append(ctx.state.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.state.allocator, extras.items);
                const result = try ctx.invokeCallback(callback, args.items);
                accumulator.deinit(ctx.state.allocator);
                accumulator = result;
            }
            break :blk accumulator;
        },
        .join => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            defer target.deinit(ctx.state.allocator);
            const separator = try ctx.evalStringArg(call, 1);
            const callback = try evalFunctionArg(ctx, call, 2);
            var extras = try evalExtraArgs(ctx, call, 3);
            defer extras.deinit(ctx.state.allocator);
            defer deinitValues(ctx.state.allocator, extras.items);
            const selection = switch (target) {
                .selection => |sel| sel,
                else => return error.ExpectedSelection,
            };
            var snapshot = try selection.clone(ctx.state.allocator);
            defer snapshot.deinit(ctx.state.allocator);
            var out = std.ArrayList(u8).empty;
            defer out.deinit(ctx.state.allocator);
            var provenance = std.ArrayList(core.ContentProvenance).empty;
            defer deinitContentProvenance(ctx.state.allocator, &provenance);
            for (snapshot.ids.items, 0..) |id, index| {
                var args = std.ArrayList(core.Value).empty;
                defer args.deinit(ctx.state.allocator);
                try args.append(ctx.state.allocator, itemValue(snapshot.item_tag, id));
                try args.appendSlice(ctx.state.allocator, extras.items);
                var result = try ctx.invokeCallback(callback, args.items);
                defer result.deinit(ctx.state.allocator);
                const text = switch (result) {
                    .string => |value| value,
                    else => return error.ExpectedStringArgument,
                };
                if (index > 0) {
                    try appendContentProvenance(ctx.state.allocator, &provenance, ctx.state.stringProvenance(separator), out.items.len);
                    try out.appendSlice(ctx.state.allocator, separator);
                }
                try appendContentProvenance(ctx.state.allocator, &provenance, ctx.state.stringProvenance(text), out.items.len);
                try out.appendSlice(ctx.state.allocator, text);
            }
            break :blk .{ .string = try ctx.ownStringWithProvenance(try out.toOwnedSlice(ctx.state.allocator), provenance.items) };
        },
        .first => blk: {
            var selection = try ctx.evalExprValue(call.args.items[0]);
            defer selection.deinit(ctx.state.allocator);
            break :blk switch (selection) {
                .selection => |sel| switch (sel.item_tag) {
                    .object => .{ .object = sel.first() orelse return error.EmptySelection },
                    .page => .{ .page = sel.first() orelse return error.EmptySelection },
                },
                else => return error.ExpectedSelection,
            };
        },
        .selection_union, .selection_intersection, .selection_difference => blk: {
            var left_value = try ctx.evalExprValue(call.args.items[0]);
            defer left_value.deinit(ctx.state.allocator);
            var right_value = try ctx.evalExprValue(call.args.items[1]);
            defer right_value.deinit(ctx.state.allocator);
            break :blk try selectionAlgebra(ctx, descriptor.op, left_value, right_value);
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
        .selection_empty, .selection_count => blk: {
            var target = try ctx.evalExprValue(call.args.items[0]);
            defer target.deinit(ctx.state.allocator);
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
        .group => blk: {
            var result = core.GroupValue{ .ty = .{ .kind = .group }, .composition = call.callee.composition orelse .overlay };
            errdefer result.deinit(ctx.state.allocator);
            try result.children.ensureTotalCapacity(ctx.state.allocator, call.args.items.len);
            const types = try ctx.state.allocator.alloc(ast.Type, call.args.items.len);
            defer ctx.state.allocator.free(types);
            for (call.args.items, types) |arg, *ty| {
                const child = try ctx.evalExprValue(arg);
                result.children.appendAssumeCapacity(child);
                ty.* = child.presentationType() orelse return error.InvalidType;
            }
            result.ty = try result.ty.withArguments(ctx.state.allocator, types);
            break :blk .{ .group = result };
        },
        .new_page => blk: {
            _ = try evalDocumentArg(ctx, call, 0);
            const title = try ctx.evalStringArg(call, 1);
            break :blk .{ .page = try ctx.makePage(title) };
        },
        .place_on => blk: {
            const page_id = try evalPageArg(ctx, call, 0);
            var value = try ctx.evalExprValue(call.args.items[1]);
            defer value.deinit(ctx.state.allocator);
            if (value != .record and value != .group) return error.InvalidType;
            break :blk .{ .object = try ctx.registerPlacement(page_id, value, call.callee.call_id) };
        },
        .constrain_on => blk: {
            var page_value = try ctx.evalExprValue(call.args.items[0]);
            defer page_value.deinit(ctx.state.allocator);
            var rules = try ctx.evalExprValue(call.args.items[1]);
            defer rules.deinit(ctx.state.allocator);
            const page_id = switch (page_value) {
                .page => |id| id,
                else => return error.ExpectedPage,
            };
            if (rules != .constraints) return error.ExpectedConstraintSet;
            try ctx.registerConstraints(page_id, rules.constraints.items.items);
            break :blk .{ .void = {} };
        },
        .constraints => blk: {
            var bundle = core.ConstraintSet.init();
            errdefer bundle.deinit(ctx.state.allocator);
            for (call.args.items) |arg_expr| {
                var value = try ctx.evalExprValue(arg_expr);
                defer value.deinit(ctx.state.allocator);
                switch (value) {
                    .constraints => |constraints| {
                        for (constraints.items.items) |constraint| {
                            try bundle.items.append(ctx.state.allocator, constraint);
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
        .path => blk: {
            var values = std.ArrayList(core.Value).empty;
            defer values.deinit(ctx.state.allocator);
            defer deinitValues(ctx.state.allocator, values.items);
            for (call.args.items) |arg| try values.append(ctx.state.allocator, try ctx.evalExprValue(arg));
            for (values.items, 0..) |value, index| try ctx.ensurePrimitiveArgType(descriptor, index, value);
            break :blk .{ .path = try path_eval.build(ctx.state.allocator, values.items) };
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

fn evalFunctionArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.FunctionRef {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.state.allocator);
    return switch (value) {
        .function => |function| function,
        else => error.InvalidValueTag,
    };
}

fn evalPageArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.NodeId {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.state.allocator);
    return switch (value) {
        .page => |id| id,
        else => error.InvalidValueTag,
    };
}

fn evalDocumentArg(ctx: anytype, call: ast.CallExpr, index: usize) !core.NodeId {
    var value = try ctx.evalExprValue(call.args.items[index]);
    defer value.deinit(ctx.state.allocator);
    return switch (value) {
        .document => |id| id,
        else => error.InvalidValueTag,
    };
}

fn selectionAlgebra(ctx: anytype, op: registry.PrimitiveCall, left_value: core.Value, right_value: core.Value) !core.Value {
    const left = switch (left_value) {
        .selection => |selection| selection,
        else => return error.ExpectedSelection,
    };
    const right = switch (right_value) {
        .selection => |selection| selection,
        else => return error.ExpectedSelection,
    };
    if (left.item_tag != right.item_tag) return error.InvalidSelectionItemType;
    var result = core.Selection.init(left.item_tag, @tagName(op));
    errdefer result.deinit(ctx.state.allocator);
    switch (op) {
        .selection_union => {
            for (left.ids.items) |id| try result.appendUnique(ctx.state.allocator, id);
            for (right.ids.items) |id| try result.appendUnique(ctx.state.allocator, id);
        },
        .selection_intersection, .selection_difference => {
            for (left.ids.items) |id| {
                if (right.contains(id) == (op == .selection_intersection)) try result.appendUnique(ctx.state.allocator, id);
            }
        },
        else => unreachable,
    }
    try ctx.state.orderSelection(ctx.state.allocator, &result);
    return .{ .selection = result };
}

fn evalExtraArgs(ctx: anytype, call: ast.CallExpr, start_index: usize) !std.ArrayList(core.Value) {
    var values = std.ArrayList(core.Value).empty;
    errdefer {
        deinitValues(ctx.state.allocator, values.items);
        values.deinit(ctx.state.allocator);
    }
    var index = start_index;
    while (index < call.args.items.len) : (index += 1) {
        try values.append(ctx.state.allocator, try ctx.evalExprValue(call.args.items[index]));
    }
    return values;
}

fn deinitValues(allocator: std.mem.Allocator, values: []core.Value) void {
    for (values) |value| {
        var owned = value;
        owned.deinit(allocator);
    }
}
