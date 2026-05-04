const std = @import("std");
const core = @import("core");
const ast = @import("ast");
const registry = @import("../language/registry.zig");

pub fn evalCall(ctx: anytype, call: ast.CallExpr, descriptor: registry.PrimitiveDescriptor) anyerror!core.Value {
    try ctx.checkArityRange(call.args.items.len, descriptor.min_arity, descriptor.max_arity);
    return switch (descriptor.op) {
        .pagectx => ctx.currentPageValue(),
        .docctx => ctx.currentDocumentValue(),
        .select => try ctx.runSelectCall(call),
        .derive => try ctx.runDeriveCall(call),
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
        .style => blk: {
            const style_name = try ctx.evalStringArg(call, 0);
            break :blk .{ .style = .{ .name = style_name } };
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
            break :blk .{ .string = try std.fmt.allocPrint(ctx.ir.allocator, "{d}", .{value}) };
        },
        .concat => blk: {
            const left = try ctx.evalStringArg(call, 0);
            const right = try ctx.evalStringArg(call, 1);
            break :blk .{ .string = try std.fmt.allocPrint(ctx.ir.allocator, "{s}{s}", .{ left, right }) };
        },
        .first => blk: {
            const selection = try ctx.materializeForUse(try ctx.evalExprValue(call.args.items[0]));
            break :blk switch (selection) {
                .selection => |sel| switch (sel.item_sort) {
                    .object => .{ .object = sel.first() orelse return error.EmptySelection },
                    .page => .{ .page = sel.first() orelse return error.EmptySelection },
                },
                else => return error.ExpectedSelection,
            };
        },
        .object => blk: {
            const content = try ctx.evalStringArg(call, 0);
            const role_name = try ctx.evalStringArg(call, 1);
            const role = try ctx.evalRoleArg(call, 1);
            const payload = try ctx.evalPayloadArg(call, 2);
            break :blk .{ .object = try ctx.makeObject(role_name, role, payload.object_kind, payload.payload_kind, content) };
        },
        .group => blk: {
            var child_ids = std.ArrayList(core.NodeId).empty;
            defer child_ids.deinit(ctx.ir.allocator);
            for (call.args.items, 0..) |_, index| {
                try child_ids.append(ctx.ir.allocator, try ctx.evalObjectArg(call, index));
            }
            break :blk .{ .object = try ctx.makeGroup(child_ids.items) };
        },
        .set_prop => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            const key = try ctx.evalStringArg(call, 1);
            const value = try ctx.evalPropertyStringArg(call, 2);
            try ctx.setNodeProperty(object_id, key, value);
            break :blk .{ .object = object_id };
        },
        .layout_v => blk: {
            const policy = try ctx.evalStringArg(call, 0);
            if (std.mem.eql(u8, policy, "top") or std.mem.eql(u8, policy, "top_flow")) {
                try ctx.setCurrentPageProperty("layout_v", "top");
            } else if (std.mem.eql(u8, policy, "center") or std.mem.eql(u8, policy, "center_stack")) {
                try ctx.setCurrentPageProperty("layout_v", "center");
            } else {
                return error.InvalidLayoutPolicy;
            }
            break :blk ctx.currentPageValue();
        },
        .layout_v_all => blk: {
            const policy = try ctx.evalStringArg(call, 0);
            if (std.mem.eql(u8, policy, "top") or std.mem.eql(u8, policy, "top_flow")) {
                try ctx.setAllPageProperty("layout_v", "top");
            } else if (std.mem.eql(u8, policy, "center") or std.mem.eql(u8, policy, "center_stack")) {
                try ctx.setAllPageProperty("layout_v", "center");
            } else {
                return error.InvalidLayoutPolicy;
            }
            break :blk ctx.currentDocumentValue();
        },
        .set_style => blk: {
            const object_id = try ctx.evalObjectArg(call, 0);
            const style = try ctx.evalStyleArg(call, 1);
            try ctx.setNodeProperty(object_id, "style", style.name);
            break :blk .{ .object = object_id };
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
