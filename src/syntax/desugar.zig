const std = @import("std");
const ast = @import("ast");
const surface = ast.Surface;
const utils = @import("utils");
const build = @import("desugar/build.zig");
const drawing = @import("desugar/drawing.zig");
const staging = @import("desugar/staging.zig");
const functions = @import("desugar/functions.zig");
const includes = @import("desugar/include.zig");
pub const IncludeResolver = includes.Resolver;

pub const Failure = staging.Failure;
pub const Options = struct {
    expand_stages: bool = true,
    expand_includes: bool = true,
    include_resolver: ?IncludeResolver = null,
    source_name: []const u8 = "",
    source_length: usize = 0,
    failure: ?*Failure = null,
    cancellation: ?utils.Cancellation = null,
};

// Borrow the surface tree; the caller owns the independent expanded tree.
// Semantic analysis and evaluation only accept the expanded AST type.
// Unresolved type names in both trees retain the usual source-text lifetime.
pub fn desugar(allocator: std.mem.Allocator, input: *const surface.Module, options: Options) !ast.Module {
    if (options.failure) |failure| failure.* = .{};
    var context = Context{ .allocator = allocator, .cancellation = options.cancellation };
    var expanded: ?surface.Module = null;
    defer if (expanded) |*value| value.deinit(allocator);
    if (options.expand_includes and input.includes.items.len != 0) {
        const resolver = options.include_resolver orelse return error.IncludeRequiresSourceLoader;
        var span: ?ast.Span = null;
        expanded = includes.expand(allocator, input, options.source_name, options.source_length, resolver, &span, options.cancellation) catch |err| {
            if (options.failure) |failure| failure.span = span;
            return err;
        };
    }
    var result = try context.module(if (expanded) |value| value else input.*);
    errdefer result.deinit(allocator);
    if (expanded) |*value| {
        result.source_files = value.source_files;
        value.source_files = .empty;
    }
    if (options.expand_stages) {
        var failure: Failure = .{};
        staging.expand(allocator, &result, &failure, options.cancellation) catch |err| {
            if (options.include_resolver) |resolver| {
                if (failure.span) |span| {
                    for (result.source_files.items) |file| {
                        if (span.start < file.offset or span.start > file.offset + file.source.len) continue;
                        if (resolver.report) |report| try report(resolver.context, file.path, file.source, err, .{
                            .err = err,
                            .span = .{ .start = span.start - file.offset, .end = span.end - file.offset },
                            .detail = failure.detail,
                        });
                        var start = file.included_at;
                        // The outer diagnostic points at the root include site.
                        var index = result.source_files.items.len;
                        while (index > 0) {
                            index -= 1;
                            const parent = result.source_files.items[index];
                            if (start >= parent.offset and start <= parent.offset + parent.source.len) start = parent.included_at;
                        }
                        failure.span = .{ .start = start, .end = start + "include".len };
                        break;
                    }
                }
            }
            if (options.failure) |output| output.* = failure;
            return err;
        };
    }
    return result;
}

const Context = struct {
    allocator: std.mem.Allocator,
    cancellation: ?utils.Cancellation,

    fn module(self: *Context, input: surface.Module) !ast.Module {
        var result = ast.Module.init();
        errdefer result.deinit(self.allocator);
        result.imports = try self.convert(@TypeOf(result.imports), input.imports);
        for (input.top_level_items.items) |item| switch (item) {
            .import => |i| try result.top_level_items.append(self.allocator, .{ .import = i }),
            .document => |i| try result.top_level_items.append(self.allocator, .{ .document = i }),
            .page => |i| try result.top_level_items.append(self.allocator, .{ .page = i }),
            .include => {},
        };
        result.types = try self.convert(@TypeOf(result.types), input.types);
        result.records = try self.convert(@TypeOf(result.records), input.records);
        result.constants = try self.convert(@TypeOf(result.constants), input.constants);
        for (input.functions.items) |original| {
            var func = try self.convert(ast.FunctionDecl, original);
            var moved = false;
            errdefer if (!moved) func.deinit(self.allocator);
            if (original.expression_body and func.result_type.kind != .void) {
                const expr = func.statements.items[0].kind.expr_stmt;
                func.statements.items[0].kind = .{ .return_expr = expr };
            }
            try result.functions.append(self.allocator, func);
            moved = true;
            if (original.paired) {
                var placed = try functions.placement(self.allocator, func);
                errdefer placed.deinit(self.allocator);
                try result.functions.append(self.allocator, placed);
            }
        }
        for (input.document_blocks.items) |block| {
            var body = try self.statements(input.document_statements.items[block.statement_start..][0..block.statement_count]);
            defer self.release(&body);
            const start = result.document_statements.items.len;
            try result.document_statements.appendSlice(self.allocator, body.items);
            body.clearRetainingCapacity();
            try result.document_blocks.append(self.allocator, .{
                .statement_start = start,
                .statement_count = result.document_statements.items.len - start,
                .span = block.span,
            });
        }
        result.pages = try self.convert(@TypeOf(result.pages), input.pages);
        return result;
    }

    fn statements(self: *Context, input: []const surface.Statement) anyerror!std.ArrayList(ast.Statement) {
        var result = std.ArrayList(ast.Statement).empty;
        errdefer self.release(&result);
        for (input) |original| {
            if (self.cancellation) |token| try token.check();
            if (original.kind == .show) {
                const block = original.kind.show;
                var condition = try self.convert(ast.Expr, block.condition);
                defer condition.deinit(self.allocator);
                var body = try self.statements(block.statements.items);
                defer self.release(&body);
                var expanded = try drawing.expand(self.allocator, &condition, block.condition_span, &body);
                defer self.release(&expanded);
                try result.appendSlice(self.allocator, expanded.items);
                expanded.clearRetainingCapacity();
            } else {
                var statement = try self.convert(ast.Statement, original);
                errdefer statement.deinit(self.allocator);
                try result.append(self.allocator, statement);
            }
        }
        return result;
    }

    fn operation(self: *Context, input: surface.OperationExpr) !ast.Expr {
        var args = try self.convert(std.ArrayList(ast.Expr), input.args);
        defer self.release(&args);
        const name: []const u8 = switch (input.operator) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .concat => "concat",
            .eq => "num_eq",
            .ne => "num_ne",
            .lt => "num_lt",
            .le => "num_le",
            .gt => "num_gt",
            .ge => "num_ge",
            .logical_not => "not",
            .neg => "neg",
            .selection_union => "selection_union",
            .selection_intersection => "selection_intersection",
            .horizontal, .vertical, .equal_horizontal, .equal_vertical => "group",
            .current_page => "pagectx",
            .constrain => "constrain_on!",
        };
        var result = try build.call(self.allocator, name, args.items, input.span);
        args.clearRetainingCapacity();
        errdefer result.deinit(self.allocator);
        result.call.arg_spans = try self.convert(std.ArrayList(ast.Span), input.arg_spans);
        result.call.callee.composition = switch (input.operator) {
            .horizontal => .horizontal,
            .vertical => .vertical,
            .equal_horizontal => .equal_horizontal,
            .equal_vertical => .equal_vertical,
            else => null,
        };
        if (result.call.callee.composition != null) result.call.callee.name_span = input.span;
        return result;
    }

    // Structural nodes are shared by both AST definitions. Only surface
    // operations, show blocks, and paired/expression functions need rewriting.
    fn convert(self: *Context, comptime T: type, input: anytype) anyerror!T {
        if (self.cancellation) |token| try token.check();
        if (T == ast.Expr and @TypeOf(input) == surface.Expr) {
            if (input == .operation) return self.operation(input.operation);
        }
        if (T == std.ArrayList(ast.Statement)) return self.statements(input.items);
        if (T == ast.AnchorRef) return input.cloneWithAnchor(self.allocator, input.anchor);
        if (T == @TypeOf(input) and @typeInfo(T) == .@"struct") {
            if (!@hasField(T, "items") and @hasDecl(T, "clone")) return input.clone(self.allocator);
        }
        return switch (@typeInfo(T)) {
            .void => {},
            .@"enum" => @fromBackingInt(@intCast(@backingInt(input))),
            .@"struct" => blk: {
                if (@hasField(T, "items") and @hasField(T, "capacity")) {
                    var result: T = .empty;
                    errdefer self.release(&result);
                    try result.ensureTotalCapacity(self.allocator, input.items.len);
                    const Child = @typeInfo(@TypeOf(result.items)).pointer.child;
                    for (input.items) |item| result.appendAssumeCapacity(try self.convert(Child, item));
                    break :blk result;
                }
                var result: T = undefined;
                var initialized: usize = 0;
                errdefer inline for (comptime std.meta.fieldNames(T), 0..) |name, index| {
                    if (index < initialized) self.release(&@field(result, name));
                };
                inline for (comptime std.meta.fieldNames(T)) |name| {
                    @field(result, name) = try self.convert(@TypeOf(@field(result, name)), @field(input, name));
                    initialized += 1;
                }
                break :blk result;
            },
            .@"union" => switch (input) {
                inline else => |payload, tag| if (comptime @hasField(T, @tagName(tag)))
                    @unionInit(T, @tagName(tag), try self.convert(@TypeOf(@field(@as(T, undefined), @tagName(tag))), payload))
                else if (comptime (@TypeOf(input) == surface.Expr and std.mem.eql(u8, @tagName(tag), "operation")) or
                    (@TypeOf(input) == surface.Statement.Kind and std.mem.eql(u8, @tagName(tag), "show")))
                    unreachable
                else
                    @compileError("Surface node requires an explicit expansion: " ++ @tagName(tag)),
            },
            .optional => |optional| if (input) |item| try self.convert(optional.child, item) else null,
            .pointer => |pointer| switch (pointer.size) {
                .one => blk: {
                    const result = try self.allocator.create(pointer.child);
                    errdefer self.allocator.destroy(result);
                    result.* = try self.convert(pointer.child, input.*);
                    break :blk result;
                },
                .slice => blk: {
                    if (pointer.child == u8) break :blk try self.allocator.dupe(u8, input);
                    const result = try self.allocator.alloc(pointer.child, input.len);
                    var initialized: usize = 0;
                    errdefer {
                        for (result[0..initialized]) |*item| self.release(item);
                        self.allocator.free(result);
                    }
                    for (input, result) |item, *copy| {
                        copy.* = try self.convert(pointer.child, item);
                        initialized += 1;
                    }
                    break :blk result;
                },
                else => @compileError("Unsupported AST pointer"),
            },
            else => input,
        };
    }

    fn release(self: *Context, value: anytype) void {
        const T = @TypeOf(value.*);
        switch (@typeInfo(T)) {
            .@"struct" => {
                if (@hasField(T, "items") and @hasField(T, "capacity")) {
                    for (value.items) |*item| self.release(item);
                    value.deinit(self.allocator);
                } else if (@hasDecl(T, "deinit")) {
                    value.deinit(self.allocator);
                } else inline for (comptime std.meta.fieldNames(T)) |name| self.release(&@field(value.*, name));
            },
            .@"union" => switch (value.*) {
                inline else => |*item| self.release(item),
            },
            .optional => if (value.*) |*item| self.release(item),
            .pointer => |pointer| switch (pointer.size) {
                .one => {
                    self.release(value.*);
                    self.allocator.destroy(value.*);
                },
                .slice => {
                    if (pointer.child != u8) for (@constCast(value.*)) |*item| self.release(item);
                    self.allocator.free(value.*);
                },
                else => @compileError("Unsupported AST pointer"),
            },
            else => {},
        }
    }
};
