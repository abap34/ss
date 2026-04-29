const std = @import("std");
const core = @import("core");
const theme_loader = @import("../theme_loader.zig");
const ast = @import("ast.zig");
const names = @import("names.zig");
const registry = @import("registry.zig");
const syntax = @import("syntax.zig");

const Program = ast.Program;
const FunctionDecl = ast.FunctionDecl;
const Statement = ast.Statement;
const Expr = ast.Expr;
const CallExpr = ast.CallExpr;
const AnchorRef = ast.AnchorRef;

const ExecFlow = union(enum) {
    none,
    returned: core.Value,
};

const EvalMode = union(enum) {
    attached,
    detached: *DetachedBuilder,
};

const DetachedBuilder = struct {
    page_id: core.NodeId,
    node_ids: std.ArrayList(core.NodeId),
    constraints: core.ConstraintSet,
    deps: std.ArrayList(*core.Fragment),

    fn init(page_id: core.NodeId) DetachedBuilder {
        return .{
            .page_id = page_id,
            .node_ids = std.ArrayList(core.NodeId).empty,
            .constraints = core.ConstraintSet.init(),
            .deps = std.ArrayList(*core.Fragment).empty,
        };
    }

    fn deinit(self: *DetachedBuilder, allocator: std.mem.Allocator) void {
        self.node_ids.deinit(allocator);
        self.constraints.deinit(allocator);
        self.deps.deinit(allocator);
    }

    fn trackNode(self: *DetachedBuilder, allocator: std.mem.Allocator, node_id: core.NodeId) !void {
        for (self.node_ids.items) |existing| {
            if (existing == node_id) return;
        }
        try self.node_ids.append(allocator, node_id);
    }

    fn appendConstraintSet(self: *DetachedBuilder, allocator: std.mem.Allocator, constraints: core.ConstraintSet) !void {
        try self.constraints.items.appendSlice(allocator, constraints.items.items);
    }

    fn trackFragment(self: *DetachedBuilder, allocator: std.mem.Allocator, fragment: *core.Fragment) !void {
        for (self.deps.items) |existing| {
            if (existing == fragment) return;
        }
        try self.deps.append(allocator, fragment);
    }

    fn isEmpty(self: *const DetachedBuilder) bool {
        return self.node_ids.items.len == 0 and self.constraints.items.items.len == 0 and self.deps.items.len == 0;
    }
};

const FunctionContract = struct {
    param_count: usize,
    returns_value: bool,
};

var diagnostic_source: []const u8 = "";
var diagnostic_path: []const u8 = "";

const ByteSpan = struct {
    start: usize,
    end: usize,
};

fn reportUnknownFunction(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError("function", name, origin);
}

fn reportUnknownQuery(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError("query", name, origin);
}

fn reportUnknownTransform(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError("transform", name, origin);
}

fn reportUnknownIdentifier(name: []const u8, origin: []const u8) void {
    reportNamedResolutionError("identifier", name, origin);
}

fn reportNamedResolutionError(kind: []const u8, name: []const u8, origin: []const u8) void {
    if (parseByteOrigin(origin)) |span| {
        const loc = computeLineColumn(diagnostic_source, span.start);
        const line = extractLine(diagnostic_source, span.start);
        const caret_width = computeCaretWidth(diagnostic_source, span);
        if (diagnostic_path.len != 0) {
            std.debug.print("{s}:{d}:{d}: error: unknown {s}: {s}\n", .{ diagnostic_path, loc.line, loc.column, kind, name });
        } else {
            std.debug.print("unknown {s}: {s} at {d}:{d}\n", .{ kind, name, loc.line, loc.column });
        }
        if (line.text.len != 0) {
            std.debug.print("  {s}\n", .{line.text});
            std.debug.print("  ", .{});
            printSpaces(loc.column - 1);
            printCarets(caret_width);
            std.debug.print("\n", .{});
        }
        return;
    }
    std.debug.print("unknown {s}: {s} at {s}\n", .{ kind, name, origin });
}

fn parseByteOrigin(origin: []const u8) ?ByteSpan {
    if (!std.mem.startsWith(u8, origin, "bytes:")) return null;
    const payload = origin["bytes:".len..];
    const dash = std.mem.indexOfScalar(u8, payload, '-') orelse return null;
    const start = std.fmt.parseInt(usize, payload[0..dash], 10) catch return null;
    const end = std.fmt.parseInt(usize, payload[dash + 1 ..], 10) catch return null;
    return .{ .start = start, .end = end };
}

fn computeLineColumn(source: []const u8, byte_index: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    const limit = @min(byte_index, source.len);
    while (i < limit) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const prefix = source[line_start..limit];
    const column = (std.unicode.utf8CountCodepoints(prefix) catch prefix.len) + 1;
    return .{ .line = line, .column = column };
}

fn extractLine(source: []const u8, byte_index: usize) struct { text: []const u8, start: usize } {
    const limit = @min(byte_index, source.len);
    var start: usize = limit;
    while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
    var end: usize = limit;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    return .{ .text = source[start..end], .start = start };
}

fn computeCaretWidth(source: []const u8, span: ByteSpan) usize {
    const line = extractLine(source, span.start);
    const line_end = line.start + line.text.len;
    const clamped_end = @min(@max(span.end, span.start + 1), line_end);
    const slice = source[span.start..clamped_end];
    return @max(std.unicode.utf8CountCodepoints(slice) catch slice.len, 1);
}

fn printSpaces(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print(" ", .{});
}

fn printCarets(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print("^", .{});
}

fn functionRefFor(func: FunctionDecl) core.FunctionRef {
    const contract = functionContract(func);
    return .{
        .name = func.name,
        .param_count = contract.param_count,
        .returns_value = contract.returns_value,
    };
}

pub fn lowerToEngine(program: Program, source: []const u8, engine: *core.Engine, io: std.Io) !void {
    diagnostic_source = source;
    diagnostic_path = "";
    return lowerToEngineWithPath(program, source, "", engine, io);
}

pub fn lowerToEngineWithPath(program: Program, source: []const u8, path: []const u8, engine: *core.Engine, io: std.Io) !void {
    diagnostic_source = source;
    diagnostic_path = path;
    var base_program: ?Program = null;
    defer if (base_program) |*prog| prog.deinit(engine.allocator);
    var theme_program: ?Program = null;
    defer if (theme_program) |*prog| prog.deinit(engine.allocator);

    var functions = std.StringHashMap(FunctionDecl).init(engine.allocator);
    defer functions.deinit();

    base_program = try loadThemeProgram(engine, io, "base");
    for (base_program.?.functions.items) |func| {
        try functions.put(func.name, func);
    }

    const theme_name = program.theme_name orelse "default";
    if (!std.mem.eql(u8, theme_name, "base")) {
        theme_program = try loadThemeProgram(engine, io, theme_name);
        for (theme_program.?.functions.items) |func| {
            try functions.put(func.name, func);
        }
    }

    for (program.functions.items) |func| {
        try functions.put(func.name, func);
    }

    for (program.pages.items) |page| {
        const page_id = try engine.addPage(page.name);
        var last_code_like: ?core.NodeId = null;
        var env = std.StringHashMap(core.Value).init(engine.allocator);
        defer env.deinit();

        for (page.statements.items) |stmt| {
            const flow = try executeStatement(engine, page_id, .attached, &env, &functions, &last_code_like, stmt, null);
            switch (flow) {
                .none => {},
                .returned => |value| {
                    var owned = value;
                    owned.deinit(engine.allocator);
                    return error.ReturnOutsideFunction;
                },
            }
        }
    }

    try engine.finalize();
}

fn validateThemeProgram(program: Program) !void {
    if (program.theme_name != null) return error.InvalidThemeModule;
    if (program.pages.items.len != 0) return error.InvalidThemeModule;
}

fn loadThemeProgram(engine: *core.Engine, io: std.Io, theme_name: []const u8) !Program {
    const source = try theme_loader.loadThemeSource(engine.allocator, io, engine.asset_base_dir, theme_name);
    defer engine.allocator.free(source);
    const program = try syntax.parse(engine.allocator, source);
    try validateThemeProgram(program);
    return program;
}

fn evalExpr(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    expr: Expr,
) anyerror!core.Value {
    return switch (expr) {
        .ident => |name| blk: {
            if (env.get(name)) |value| break :blk value;
            if (functions.get(name)) |func| break :blk .{ .function = functionRefFor(func) };
            reportUnknownIdentifier(name, current_origin);
            break :blk error.UnknownIdentifier;
        },
        .string => |text| .{ .string = text },
        .number => |value| .{ .number = value },
        .call => |call| try evalCall(engine, page_id, mode, env, functions, current_origin, call),
    };
}

fn evalCall(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    if (env.get(call.name)) |value| {
        switch (value) {
            .function => |func_ref| {
                if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
                const func = functions.get(func_ref.name) orelse {
                    reportUnknownFunction(func_ref.name, current_origin);
                    return error.UnknownFunction;
                };
                if (call.args.items.len != func_ref.param_count) return error.InvalidArity;
                return try invokeUserFunctionValue(engine, page_id, mode, env, functions, func, current_origin, call);
            },
            else => {},
        }
    }
    if (functions.get(call.name)) |func| {
        if (!functionContract(func).returns_value) return error.FunctionDoesNotReturnValue;
        return try invokeUserFunctionValue(engine, page_id, mode, env, functions, func, current_origin, call);
    }
    if (registry.lookupPrimitiveCall(call.name)) |descriptor| {
        return try evalPrimitiveCall(engine, page_id, mode, env, functions, current_origin, call, descriptor);
    }
    reportUnknownFunction(call.name, current_origin);
    return error.UnknownFunction;
}

fn evalPrimitiveCall(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    descriptor: registry.PrimitiveDescriptor,
) anyerror!core.Value {
    try validateArityRange(call.args.items.len, descriptor.min_arity, descriptor.max_arity);
    switch (descriptor.op) {
        .pagectx => {
            return .{ .page = page_id };
        },
        .docctx => {
            return .{ .document = engine.document_id };
        },
        .select => return try evalSelectCall(engine, page_id, mode, env, functions, current_origin, call),
        .derive => return try evalDeriveCall(engine, page_id, mode, env, functions, current_origin, call),
        .anchor => {
            const node_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const anchor_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const anchor = names.parseAnchorName(anchor_name) orelse return error.UnknownAnchor;
            return .{ .anchor = .{ .node = .{ .node_id = node_id, .anchor = anchor } } };
        },
        .page_anchor => {
            const anchor_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const anchor = names.parseAnchorName(anchor_name) orelse return error.UnknownAnchor;
            return .{ .anchor = .{ .page = anchor } };
        },
        .equal => {
            const target = try evalCallAnchorArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const source = try evalCallAnchorArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const offset: f32 = if (call.args.items.len == 3)
                try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2)
            else
                0;
            return .{ .constraints = try anchorEqualityConstraintSet(engine, target, source, offset, current_origin) };
        },
        .style => {
            const style_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            return .{ .style = .{ .name = style_name } };
        },
        .neg => {
            const value = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            return .{ .number = -value };
        },
        .previous_page => {
            return try engine.select(engine.allocator, .{ .page = page_id }, core.Query.previousPage());
        },
        .objects => {
            const base = try normalizeForUse(engine, mode, try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]));
            const role = try evalCallRoleArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            return try engine.select(engine.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .first => {
            const selection = try normalizeForUse(engine, mode, try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]));
            return switch (selection) {
                .selection => |sel| switch (sel.item_sort) {
                    .object => .{ .object = sel.first() orelse return error.EmptySelection },
                    .page => .{ .page = sel.first() orelse return error.EmptySelection },
                },
                else => return error.ExpectedSelection,
            };
        },
        .text => {
            const content = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const role_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const role = try evalCallRoleArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const object_id = switch (mode) {
                .attached => try engine.makeObjectWithOrigin(page_id, role_name, role, .text, .text, content, current_origin),
                .detached => |builder| blk: {
                    const id = try engine.makeDetachedObjectWithOrigin(page_id, role_name, role, .text, .text, content, current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .object => {
            const content = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const role_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const role = try evalCallRoleArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const payload = try evalCallPayloadArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            const object_id = switch (mode) {
                .attached => try engine.makeObjectWithOrigin(page_id, role_name, role, payload.object_kind, payload.payload_kind, content, current_origin),
                .detached => |builder| blk: {
                    const id = try engine.makeDetachedObjectWithOrigin(page_id, role_name, role, payload.object_kind, payload.payload_kind, content, current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .group => {
            var child_ids = std.ArrayList(core.NodeId).empty;
            defer child_ids.deinit(engine.allocator);
            for (call.args.items, 0..) |_, index| {
                try child_ids.append(engine.allocator, try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, index));
            }
            const object_id = switch (mode) {
                .attached => try engine.makeGroupWithOrigin(page_id, true, child_ids.items, current_origin),
                .detached => |builder| blk: {
                    const id = try engine.makeGroupWithOrigin(page_id, false, child_ids.items, current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .set_prop => {
            const object_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const key = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const value = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            try engine.setNodeProperty(object_id, key, value);
            return .{ .object = object_id };
        },
        .set_style => {
            const object_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const style = try evalCallStyleArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            try engine.setNodeProperty(object_id, "style", style.name);
            return .{ .object = object_id };
        },
        .page_number_object => {
            const object_id = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, .{ .page = page_id }, core.Transform.pageNumber(), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, .{ .page = page_id }, core.Transform.pageNumber(), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .toc_object => {
            const object_id = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, .{ .document = engine.document_id }, core.Transform.toc(), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, .{ .document = engine.document_id }, core.Transform.toc(), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .rewrite_text => {
            const base = try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]);
            const old = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const new = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            const object_id = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            };
            return .{ .object = object_id };
        },
        .highlight => {
            const base = try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]);
            const note = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const object_id = try deriveHighlight(engine, page_id, mode, current_origin, base, note);
            return .{ .object = object_id };
        },
        .constraints => {
            var bundle = core.ConstraintSet.init();
            errdefer bundle.deinit(engine.allocator);
            for (call.args.items) |arg_expr| {
                var value = try evalExpr(engine, page_id, mode, env, functions, current_origin, arg_expr);
                defer value.deinit(engine.allocator);
                switch (value) {
                    .constraints => |constraints| {
                        for (constraints.items.items) |constraint| {
                            try bundle.items.append(engine.allocator, constraint);
                        }
                    },
                    else => return error.ExpectedConstraintSet,
                }
            }
            return .{ .constraints = bundle };
        },
        .left_inset => {
            return .{ .constraints = try singleConstraintSet(engine, .{
                .target_node = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .target_anchor = .left,
                .source = .{ .page = .left },
                .offset = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .origin = current_origin,
            }) };
        },
        .right_inset => {
            return .{ .constraints = try singleConstraintSet(engine, .{
                .target_node = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .target_anchor = .right,
                .source = .{ .page = .right },
                .offset = -try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .origin = current_origin,
            }) };
        },
        .top_inset => {
            return .{ .constraints = try singleConstraintSet(engine, .{
                .target_node = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .target_anchor = .top,
                .source = .{ .page = .top },
                .offset = -try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .origin = current_origin,
            }) };
        },
        .bottom_inset => {
            return .{ .constraints = try singleConstraintSet(engine, .{
                .target_node = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .target_anchor = .bottom,
                .source = .{ .page = .bottom },
                .offset = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .origin = current_origin,
            }) };
        },
        .same_left => {
            return .{ .constraints = try nodeAnchorConstraintSet(
                engine,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .left,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .left,
                try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2),
                current_origin,
            ) };
        },
        .same_right => {
            return .{ .constraints = try nodeAnchorConstraintSet(
                engine,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .right,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .right,
                try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2),
                current_origin,
            ) };
        },
        .same_top => {
            return .{ .constraints = try nodeAnchorConstraintSet(
                engine,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .top,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .top,
                try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2),
                current_origin,
            ) };
        },
        .same_bottom => {
            return .{ .constraints = try nodeAnchorConstraintSet(
                engine,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .bottom,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .bottom,
                try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2),
                current_origin,
            ) };
        },
        .below => {
            return .{ .constraints = try nodeAnchorConstraintSet(
                engine,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0),
                .top,
                try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1),
                .bottom,
                -try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2),
                current_origin,
            ) };
        },
        .inset_x => {
            const node_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const left = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const right = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            var bundle = core.ConstraintSet.init();
            errdefer bundle.deinit(engine.allocator);
            try bundle.items.append(engine.allocator, .{
                .target_node = node_id,
                .target_anchor = .left,
                .source = .{ .page = .left },
                .offset = left,
            });
            try bundle.items.append(engine.allocator, .{
                .target_node = node_id,
                .target_anchor = .right,
                .source = .{ .page = .right },
                .offset = -right,
            });
            return .{ .constraints = bundle };
        },
        .surround => {
            const panel_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 0);
            const inner_id = try evalCallObjectArg(engine, page_id, mode, env, functions, current_origin, call, 1);
            const pad_x = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            const pad_y = try evalCallNumberArg(engine, page_id, mode, env, functions, current_origin, call, 3);
            var bundle = core.ConstraintSet.init();
            errdefer bundle.deinit(engine.allocator);
            try bundle.items.append(engine.allocator, .{
                .target_node = panel_id,
                .target_anchor = .left,
                .source = .{ .node = .{ .node_id = inner_id, .anchor = .left } },
                .offset = -pad_x,
            });
            try bundle.items.append(engine.allocator, .{
                .target_node = panel_id,
                .target_anchor = .right,
                .source = .{ .node = .{ .node_id = inner_id, .anchor = .right } },
                .offset = pad_x,
            });
            try bundle.items.append(engine.allocator, .{
                .target_node = panel_id,
                .target_anchor = .top,
                .source = .{ .node = .{ .node_id = inner_id, .anchor = .top } },
                .offset = pad_y,
            });
            try bundle.items.append(engine.allocator, .{
                .target_node = panel_id,
                .target_anchor = .bottom,
                .source = .{ .node = .{ .node_id = inner_id, .anchor = .bottom } },
                .offset = -pad_y,
            });
            return .{ .constraints = bundle };
        },
    }
}

fn evalSelectCall(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(engine, mode, try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
    const descriptor = registry.lookupQueryOp(op_name) orelse {
        reportUnknownQuery(op_name, current_origin);
        return error.UnknownQuery;
    };
    try validateFixedArity(call.args.items.len, descriptor.arity);
    try ensureValueSort(base, descriptor.input_sort);
    switch (descriptor.op) {
        .self_object => {
            return try engine.select(engine.allocator, base, core.Query.selfObject());
        },
        .previous_page => {
            return try engine.select(engine.allocator, base, core.Query.previousPage());
        },
        .parent_page => {
            return try engine.select(engine.allocator, base, core.Query.parentPage());
        },
        .document_pages => {
            return try engine.select(engine.allocator, base, core.Query.documentPages());
        },
        .page_objects_by_role => {
            const role = try evalCallRoleArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            return try engine.select(engine.allocator, base, core.Query.pageObjectsByRole(role));
        },
        .document_objects_by_role => {
            const role = try evalCallRoleArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            return try engine.select(engine.allocator, base, core.Query.documentObjectsByRole(role));
        },
    }
}

fn evalDeriveCall(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const base = try normalizeForUse(engine, mode, try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[0]));
    const op_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 1);
    const descriptor = registry.lookupTransformOp(op_name) orelse {
        reportUnknownTransform(op_name, current_origin);
        return error.UnknownTransform;
    };
    try validateArityRange(call.args.items.len, descriptor.min_arity, descriptor.max_arity);
    if (descriptor.input_sort) |expected| try ensureValueSort(base, expected);
    switch (descriptor.op) {
        .page_number => {
            return .{ .object = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, base, core.Transform.pageNumber(), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, base, core.Transform.pageNumber(), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            } };
        },
        .toc => {
            return .{ .object = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, base, core.Transform.toc(), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, base, core.Transform.toc(), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            } };
        },
        .rewrite_text => {
            const old = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            const new = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 3);
            return .{ .object = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, base, core.Transform.rewriteText(old, new), current_origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            } };
        },
        .highlight => {
            const note = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, 2);
            return .{ .object = try deriveHighlight(engine, page_id, mode, current_origin, base, note) };
        },
    }
}

fn deriveHighlight(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    current_origin: []const u8,
    base: core.Value,
    note: []const u8,
) !core.NodeId {
    return switch (base) {
        .object => |id| blk: {
            const selection = try engine.select(engine.allocator, .{ .object = id }, core.Query.selfObject());
            break :blk switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, selection, core.Transform.highlight(note), current_origin),
                .detached => |builder| blk2: {
                    const derived = try engine.deriveDetachedWithOrigin(page_id, selection, core.Transform.highlight(note), current_origin);
                    try builder.trackNode(engine.allocator, derived);
                    break :blk2 derived;
                },
            };
        },
        .selection => blk: {
            break :blk switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, base, core.Transform.highlight(note), current_origin),
                .detached => |builder| blk2: {
                    const derived = try engine.deriveDetachedWithOrigin(page_id, base, core.Transform.highlight(note), current_origin);
                    try builder.trackNode(engine.allocator, derived);
                    break :blk2 derived;
                },
            };
        },
        else => return error.ExpectedObject,
    };
}

fn validateFixedArity(actual: usize, expected: u8) !void {
    if (actual != expected) return error.InvalidArity;
}

fn validateArityRange(actual: usize, min: u8, max: u8) !void {
    if (actual < min or actual > max) return error.InvalidArity;
}

fn ensureValueSort(value: core.Value, expected: core.SemanticSort) !void {
    const actual: core.SemanticSort = switch (value) {
        .document => .document,
        .page => .page,
        .object => .object,
        .selection => .selection,
        .anchor => .anchor,
        .function => .function,
        .style => .style,
        .string => .string,
        .number => .number,
        .constraints => .constraints,
        .fragment => .fragment,
    };
    if (actual != expected) return error.InvalidSemanticSort;
}

fn fragmentRootToValue(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.Value {
    const root = fragment.root orelse unreachable;
    return switch (root) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = try selection.clone(allocator) },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = function },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
    };
}

fn fragmentRootCloneFromFragment(allocator: std.mem.Allocator, fragment: *const core.Fragment) !core.FragmentRoot {
    const root = fragment.root orelse unreachable;
    return try root.clone(allocator);
}

fn normalizeForUse(engine: *core.Engine, mode: EvalMode, value: core.Value) !core.Value {
    return switch (value) {
        .fragment => |fragment| switch (mode) {
            .attached => blk: {
                try engine.materializeFragment(fragment);
                break :blk try fragmentRootToValue(engine.allocator, fragment);
            },
            .detached => |builder| blk: {
                try builder.trackFragment(engine.allocator, fragment);
                break :blk try fragmentRootToValue(engine.allocator, fragment);
            },
        },
        else => value,
    };
}

fn resolveValueString(value: core.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => return error.ExpectedStringArgument,
    };
}

fn resolveValueNumber(value: core.Value) !f32 {
    return switch (value) {
        .number => |number| number,
        else => return error.ExpectedNumberArgument,
    };
}

fn resolveValueStyle(value: core.Value) !core.StyleRef {
    return switch (value) {
        .style => |style| style,
        else => return error.ExpectedStyleArgument,
    };
}

fn resolveValueAnchor(value: core.Value) !core.AnchorValue {
    return switch (value) {
        .anchor => |anchor| anchor,
        else => return error.ExpectedAnchor,
    };
}

fn resolveValueObjectId(engine: *core.Engine, mode: EvalMode, value: core.Value) !core.NodeId {
    return switch (try normalizeForUse(engine, mode, value)) {
        .object => |id| id,
        else => return error.ExpectedObject,
    };
}

fn evalCallArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Value {
    return try evalExpr(engine, page_id, mode, env, functions, current_origin, call.args.items[index]);
}

fn evalCallStringArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror![]const u8 {
    return try resolveValueString(try evalCallArg(engine, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallNumberArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!f32 {
    return try resolveValueNumber(try evalCallArg(engine, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallObjectArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.NodeId {
    return try resolveValueObjectId(engine, mode, try evalCallArg(engine, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallAnchorArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.AnchorValue {
    return try resolveValueAnchor(try evalCallArg(engine, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallStyleArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.StyleRef {
    return try resolveValueStyle(try evalCallArg(engine, page_id, mode, env, functions, current_origin, call, index));
}

fn evalCallRoleArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!core.Role {
    const role_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, index);
    return names.parseRoleName(role_name) orelse error.UnknownRole;
}

fn evalCallPayloadArg(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    current_origin: []const u8,
    call: CallExpr,
    index: usize,
) anyerror!names.ParsedPayload {
    const payload_name = try evalCallStringArg(engine, page_id, mode, env, functions, current_origin, call, index);
    return names.parsePayloadName(payload_name) orelse error.UnknownPayloadKind;
}

fn singleConstraintSet(engine: *core.Engine, constraint: core.Constraint) !core.ConstraintSet {
    var bundle = core.ConstraintSet.init();
    errdefer bundle.deinit(engine.allocator);
    try bundle.items.append(engine.allocator, constraint);
    return bundle;
}

fn nodeAnchorConstraintSet(
    engine: *core.Engine,
    target_node: core.NodeId,
    target_anchor: core.Anchor,
    source_node: core.NodeId,
    source_anchor: core.Anchor,
    offset: f32,
    origin: []const u8,
) !core.ConstraintSet {
    return try singleConstraintSet(engine, .{
        .target_node = target_node,
        .target_anchor = target_anchor,
        .source = .{ .node = .{ .node_id = source_node, .anchor = source_anchor } },
        .offset = offset,
        .origin = origin,
    });
}

fn anchorEqualityConstraintSet(
    engine: *core.Engine,
    target: core.AnchorValue,
    source: core.AnchorValue,
    offset: f32,
    origin: []const u8,
) !core.ConstraintSet {
    return switch (target) {
        .page => error.PageCannotBeConstraintTarget,
        .node => |node| try singleConstraintSet(engine, .{
            .target_node = node.node_id,
            .target_anchor = node.anchor,
            .source = source.toConstraintSource(),
            .offset = offset,
            .origin = origin,
        }),
    };
}

const ResolvedTarget = struct {
    node_id: core.NodeId,
    anchor: core.Anchor,
};

fn executeStatement(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    last_code_like: *?core.NodeId,
    stmt: Statement,
    origin_override: ?[]const u8,
) anyerror!ExecFlow {
    const origin = if (origin_override) |override| override else try statementOrigin(engine.allocator, stmt.span);
    switch (stmt.kind) {
        .title => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "title", "title", .text, .text, text, origin),
        .subtitle => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "subtitle", "subtitle", .text, .text, text, origin),
        .math => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "math", "math", .source, .math_text, text, origin),
        .mathtex => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "mathtex", "math", .asset, .math_tex, text, origin),
        .figure => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "figure", "figure", .source, .figure_text, text, origin),
        .image => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "image", "figure", .asset, .image_ref, text, origin),
        .pdf_ref => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "pdf", "figure", .asset, .pdf_ref, text, origin),
        .code => |text| last_code_like.* = try makeLegacyNode(engine, page_id, mode, "code", "code", .source, .code, text, origin),
        .page_number => {
            const value: core.Value = .{ .object = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, .{ .page = page_id }, core.Transform.pageNumber(), origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, .{ .page = page_id }, core.Transform.pageNumber(), origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            } };
            try materializeStatementValue(engine, mode, last_code_like, value);
        },
        .toc => {
            const value: core.Value = .{ .object = switch (mode) {
                .attached => try engine.deriveWithOrigin(page_id, .{ .document = engine.document_id }, core.Transform.toc(), origin),
                .detached => |builder| blk: {
                    const id = try engine.deriveDetachedWithOrigin(page_id, .{ .document = engine.document_id }, core.Transform.toc(), origin);
                    try builder.trackNode(engine.allocator, id);
                    break :blk id;
                },
            } };
            try materializeStatementValue(engine, mode, last_code_like, value);
        },
        .let_binding => |binding| {
            const value = try evalExpr(engine, page_id, mode, env, functions, origin, binding.expr);
            switch (mode) {
                .attached => try materializeStatementValue(engine, mode, last_code_like, value),
                .detached => {},
            }
            try env.put(binding.name, value);
        },
        .bind_binding => |binding| {
            switch (mode) {
                .attached => {
                    var builder = DetachedBuilder.init(page_id);
                    errdefer builder.deinit(engine.allocator);
                    const value = try evalExpr(engine, page_id, .{ .detached = &builder }, env, functions, origin, binding.expr);
                    switch (value) {
                        .fragment => {
                            if (builder.isEmpty()) {
                                builder.deinit(engine.allocator);
                                try env.put(binding.name, value);
                            } else {
                                const root = try fragmentRootCloneFromFragment(engine.allocator, value.fragment);
                                try builder.trackFragment(engine.allocator, value.fragment);
                                const fragment = try engine.createFragment(page_id, root, builder.node_ids, builder.constraints, builder.deps);
                                try env.put(binding.name, .{ .fragment = fragment });
                            }
                        },
                        else => {
                            const root = try fragmentRootFromValue(value);
                            const fragment = try engine.createFragment(page_id, root, builder.node_ids, builder.constraints, builder.deps);
                            try env.put(binding.name, .{ .fragment = fragment });
                        },
                    }
                },
                .detached => {
                    const value = try evalExpr(engine, page_id, mode, env, functions, origin, binding.expr);
                    try env.put(binding.name, value);
                },
            }
        },
        .return_expr => |expr| {
            const value = try evalExpr(engine, page_id, mode, env, functions, origin, expr);
            return .{ .returned = value };
        },
        .constrain => |decl| {
            const target = try resolveAnchorRef(engine, mode, env, origin, decl.target, true);
            const source = try resolveAnchorRef(engine, mode, env, origin, decl.source, false);
            switch (mode) {
                .attached => try engine.addAnchorConstraint(target.node_id, target.anchor, source, decl.offset, origin),
                .detached => |builder| try builder.constraints.items.append(engine.allocator, .{
                    .target_node = target.node_id,
                    .target_anchor = target.anchor,
                    .source = source,
                    .offset = decl.offset,
                }),
            }
        },
        .expr_stmt => |expr| switch (expr) {
            .call => |call| {
                if (functions.contains(call.name)) {
                    try executeCallStatement(engine, page_id, mode, env, functions, last_code_like, origin, call);
                } else {
                    var value = try evalExpr(engine, page_id, mode, env, functions, origin, expr);
                    defer value.deinit(engine.allocator);
                    try materializeStatementValue(engine, mode, last_code_like, value);
                }
            },
            else => {
                var value = try evalExpr(engine, page_id, mode, env, functions, origin, expr);
                defer value.deinit(engine.allocator);
                try materializeStatementValue(engine, mode, last_code_like, value);
            },
        },
        .highlight => |note| {
            const target = last_code_like.* orelse return error.MissingHighlightTarget;
            var selection = try engine.select(engine.allocator, .{ .object = target }, core.Query.selfObject());
            defer selection.deinit(engine.allocator);
            _ = try deriveHighlight(engine, page_id, mode, origin, selection, note);
        },
    }
    return .none;
}

fn materializeStatementValue(engine: *core.Engine, mode: EvalMode, last_code_like: *?core.NodeId, value: core.Value) !void {
    switch (mode) {
        .attached => switch (value) {
            .fragment => |fragment| {
                try engine.materializeFragment(fragment);
                if (fragment.root) |root| {
                    switch (root) {
                        .object => |id| last_code_like.* = id,
                        .constraints => {},
                        else => {},
                    }
                }
            },
            .constraints => |constraints| try engine.addConstraintSet(constraints),
            .object => |id| last_code_like.* = id,
            else => {},
        },
        .detached => |builder| switch (value) {
            .constraints => |constraints| try builder.appendConstraintSet(engine.allocator, constraints),
            .object => |id| {
                last_code_like.* = id;
                try builder.trackNode(engine.allocator, id);
            },
            .fragment => |fragment| {
                try builder.trackFragment(engine.allocator, fragment);
                if (fragment.root) |root| {
                    switch (root) {
                        .object => |id| last_code_like.* = id,
                        else => {},
                    }
                }
            },
            else => {},
        },
    }
}

fn makeLegacyNode(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    name: []const u8,
    role: []const u8,
    object_kind: core.ObjectKind,
    payload_kind: core.PayloadKind,
    content: []const u8,
    origin: []const u8,
) !core.NodeId {
    return switch (mode) {
        .attached => try engine.makeObjectWithOrigin(page_id, name, role, object_kind, payload_kind, content, origin),
        .detached => |builder| blk: {
            const id = try engine.makeDetachedObjectWithOrigin(page_id, name, role, object_kind, payload_kind, content, origin);
            try builder.trackNode(engine.allocator, id);
            break :blk id;
        },
    };
}

fn fragmentRootFromValue(value: core.Value) !core.FragmentRoot {
    return switch (value) {
        .document => |id| .{ .document = id },
        .page => |id| .{ .page = id },
        .object => |id| .{ .object = id },
        .selection => |selection| .{ .selection = selection },
        .anchor => |anchor| .{ .anchor = anchor },
        .function => |function| .{ .function = function },
        .style => |style| .{ .style = style },
        .string => |text| .{ .string = text },
        .number => |number| .{ .number = number },
        .constraints => |constraints| .{ .constraints = constraints },
        .fragment => error.UnsupportedFragmentRoot,
    };
}

fn executeCallStatement(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    last_code_like: *?core.NodeId,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!void {
    const func = functions.get(call.name) orelse {
        _ = try evalCall(engine, page_id, mode, env, functions, current_origin, call);
        return;
    };
    const func_ref = functionRefFor(func);
    if (call.args.items.len != func_ref.param_count) return error.InvalidArity;

    var local_env = std.StringHashMap(core.Value).init(engine.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| {
        try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    for (func.params.items, call.args.items) |param, arg_expr| {
        const value = try evalExpr(engine, page_id, mode, env, functions, current_origin, arg_expr);
        try local_env.put(param, value);
    }
    for (func.statements.items) |inner| {
        const flow = try executeStatement(engine, page_id, mode, &local_env, functions, last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| {
                defer {
                    var owned = value;
                    owned.deinit(engine.allocator);
                }
                try materializeStatementValue(engine, mode, last_code_like, value);
                return;
            },
        }
    }
}

fn invokeUserFunctionValue(
    engine: *core.Engine,
    page_id: core.NodeId,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    functions: *std.StringHashMap(FunctionDecl),
    func: FunctionDecl,
    current_origin: []const u8,
    call: CallExpr,
) anyerror!core.Value {
    const func_ref = functionRefFor(func);
    if (!func_ref.returns_value) return error.FunctionDoesNotReturnValue;
    if (call.args.items.len != func_ref.param_count) return error.InvalidArity;

    var local_env = std.StringHashMap(core.Value).init(engine.allocator);
    defer local_env.deinit();
    var it = env.iterator();
    while (it.next()) |entry| {
        try local_env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    for (func.params.items, call.args.items) |param, arg_expr| {
        const value = try evalExpr(engine, page_id, mode, env, functions, current_origin, arg_expr);
        try local_env.put(param, value);
    }

    var last_code_like: ?core.NodeId = null;
    for (func.statements.items) |inner| {
        const flow = try executeStatement(engine, page_id, mode, &local_env, functions, &last_code_like, inner, current_origin);
        switch (flow) {
            .none => {},
            .returned => |value| return value,
        }
    }

    return error.FunctionDidNotReturnValue;
}

fn statementOrigin(allocator: std.mem.Allocator, span: ast.Span) ![]const u8 {
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ span.start, span.end });
}

fn functionContract(func: FunctionDecl) FunctionContract {
    return .{
        .param_count = func.params.items.len,
        .returns_value = functionReturnsValue(func),
    };
}

fn functionReturnsValue(func: FunctionDecl) bool {
    for (func.statements.items) |stmt| {
        switch (stmt.kind) {
            .return_expr => return true,
            else => {},
        }
    }
    return false;
}

fn resolveAnchorRef(
    engine: *core.Engine,
    mode: EvalMode,
    env: *std.StringHashMap(core.Value),
    current_origin: []const u8,
    anchor_ref: AnchorRef,
    comptime is_target: bool,
) !if (is_target) ResolvedTarget else core.ConstraintSource {
    switch (anchor_ref.kind) {
        .page => {
            if (is_target) return error.PageCannotBeConstraintTarget;
            return .{ .page = anchor_ref.anchor };
        },
        .node => {
            const value = env.get(anchor_ref.node_name.?) orelse {
                reportUnknownIdentifier(anchor_ref.node_name.?, current_origin);
                return error.UnknownIdentifier;
            };
            const node_id = try resolveValueObjectId(engine, mode, value);
            if (is_target) {
                return .{ .node_id = node_id, .anchor = anchor_ref.anchor };
            }
            return .{ .node = .{ .node_id = node_id, .anchor = anchor_ref.anchor } };
        },
    }
}
