const std = @import("std");
const ast = @import("ast");
const surface = ast.Surface;
const parser = @import("../parse.zig");
const utils = @import("utils");

/// File acquisition belongs to the module loader; expansion only handles syntax.
pub const Resolver = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror!surface.SourceFile,
    report: ?*const fn (*anyopaque, []const u8, []const u8, anyerror, ?parser.ParseDiagnostic) anyerror!void = null,
};

pub fn expand(allocator: std.mem.Allocator, input: *const surface.Module, path: []const u8, length: usize, resolver: Resolver, failure: *?ast.Span, cancellation: ?utils.Cancellation) !surface.Module {
    var context = Context{ .allocator = allocator, .resolver = resolver, .next_offset = length + 1, .cancellation = cancellation };
    defer {
        for (context.files.items) |*file| file.deinit(allocator);
        context.files.deinit(allocator);
        context.stack.deinit(allocator);
    }
    const root = try std.fs.path.resolve(allocator, &.{path});
    defer allocator.free(root);
    try context.stack.append(allocator, root);
    var result = try input.clone(allocator);
    errdefer result.deinit(allocator);
    context.module(&result, path) catch |err| {
        failure.* = context.failure;
        return err;
    };
    result.source_files = context.files;
    context.files = .empty;
    return result;
}

const Context = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    files: std.ArrayList(surface.SourceFile) = .empty,
    stack: std.ArrayList([]const u8) = .empty,
    next_offset: usize,
    failure: ?ast.Span = null,
    cancellation: ?utils.Cancellation,

    fn module(self: *Context, value: *surface.Module, path: []const u8) anyerror!void {
        const original = try value.top_level_items.toOwnedSlice(self.allocator);
        defer self.allocator.free(original);
        for (original) |item| {
            if (self.cancellation) |token| try token.check();
            if (item != .include) {
                try value.top_level_items.append(self.allocator, item);
                continue;
            }
            const directive = value.includes.items[item.include];
            self.include(value, path, directive) catch |err| {
                self.failure = directive.path_span;
                return err;
            };
        }
        for (value.includes.items) |*directive| directive.deinit(self.allocator);
        value.includes.clearRetainingCapacity();
    }

    fn include(self: *Context, target: *surface.Module, path: []const u8, directive: surface.IncludeDecl) !void {
        var file = try self.resolver.read(self.resolver.context, self.allocator, path, directive.path);
        var moved = false;
        errdefer if (!moved) file.deinit(self.allocator);
        for (self.stack.items) |ancestor| if (std.mem.eql(u8, ancestor, file.path)) return error.IncludeCycle;
        for (self.files.items) |previous| if (std.mem.eql(u8, previous.path, file.path)) return error.DuplicateInclude;
        if (self.stack.items.len >= 128 or self.next_offset + file.source.len > 16 * 1024 * 1024) return error.IncludeLimitExceeded;
        file.offset = self.next_offset;
        file.included_at = directive.span.start;
        self.next_offset += file.source.len + 1;
        try self.files.append(self.allocator, file);
        moved = true;
        try self.stack.append(self.allocator, file.path);
        defer _ = self.stack.pop();
        var failure: parser.ParseFailure = .{};
        var child = parser.parseWithSourceNameAndFailure(self.allocator, file.source, file.path, &failure) catch |err| {
            if (self.resolver.report) |report| try report(self.resolver.context, file.path, file.source, err, failure.diagnostic);
            return err;
        };
        defer child.deinit(self.allocator);
        // Every span remains unique within the shared name and binding environment.
        offsetSpans(&child, file.offset);
        for (child.imports.items) |*decl| decl.base_dir = try self.allocator.dupe(u8, std.fs.path.dirname(file.path) orelse ".");
        self.module(&child, file.path) catch |err| {
            if (self.resolver.report) |report| {
                var diagnostic: ?parser.ParseDiagnostic = null;
                if (self.failure) |span| diagnostic = .{
                    .err = err,
                    .span = .{ .start = span.start - file.offset, .end = span.end - file.offset },
                };
                try report(self.resolver.context, file.path, file.source, err, diagnostic);
            }
            return err;
        };
        const import_start = target.imports.items.len;
        const document_start = target.document_blocks.items.len;
        const page_start = target.pages.items.len;
        for (child.document_blocks.items) |*block| block.statement_start += target.document_statements.items.len;
        inline for (.{ "imports", "types", "records", "constants", "functions", "document_blocks", "document_statements", "pages" }) |name| {
            try @field(target, name).appendSlice(self.allocator, @field(child, name).items);
            @field(child, name).clearRetainingCapacity();
        }
        for (child.top_level_items.items) |item| try target.top_level_items.append(self.allocator, switch (item) {
            .import => |index| .{ .import = import_start + index },
            .document => |index| .{ .document = document_start + index },
            .page => |index| .{ .page = page_start + index },
            .include => unreachable,
        });
    }
};

fn offsetSpans(value: anytype, offset: usize) void {
    const T = @TypeOf(value.*);
    if (T == ast.Span) {
        value.start += offset;
        value.end += offset;
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => inline for (comptime std.meta.fieldNames(T)) |name| {
            if (!std.mem.eql(u8, name, "capacity")) offsetSpans(&@field(value.*, name), offset);
        },
        .@"union" => switch (value.*) {
            inline else => |*payload| offsetSpans(payload, offset),
        },
        .optional => if (value.*) |*payload| offsetSpans(payload, offset),
        .pointer => |pointer| switch (pointer.size) {
            .one => offsetSpans(@constCast(value.*), offset),
            .slice => if (pointer.child != u8) {
                for (@constCast(value.*)) |*payload| offsetSpans(payload, offset);
            },
            else => {},
        },
        else => {},
    }
}
