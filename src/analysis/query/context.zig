const std = @import("std");
const ast = @import("ast");

const language_names = @import("../../language/names.zig");
const cursor = @import("cursor.zig");
const syntax = @import("../../syntax.zig");
const types = @import("types.zig");
const utils = @import("utils");

pub const Context = struct {
    target: []u8,
    target_kind: ?cursor.SourceNameKind = null,
    qualifier: ?[]u8 = null,
    parsed: ?syntax.ParseResult = null,
    offset: usize,

    pub fn init(allocator: std.mem.Allocator, req: types.SourceRequest) !Context {
        var parsed = syntax.parseRecoveringWithSourceName(allocator, req.source, req.path) catch null;
        errdefer if (parsed) |*result| result.deinit(allocator);
        const parsed_program = if (parsed) |*result| &result.program else null;
        const target = try targetAtOffset(allocator, req.source, req.offset, parsed_program) orelse return error.NoQueryTarget;
        return .{
            .target = target.text,
            .target_kind = target.kind,
            .qualifier = target.qualifier,
            .parsed = parsed,
            .offset = req.offset,
        };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.qualifier) |qualifier| allocator.free(qualifier);
        if (self.parsed) |*result| result.deinit(allocator);
    }

    pub fn program(self: *const Context) ?*const ast.Program {
        return if (self.parsed) |*result| &result.program else null;
    }

    pub fn qualifiedCallableAlias(self: *const Context) ?[]const u8 {
        if (self.kindIs(.callable_name)) return self.qualifier;
        const parsed = self.program() orelse return null;
        return cursor.qualifiedCallableQualifierForName(parsed, self.offset);
    }

    pub fn isQualifiedCallableQualifier(self: *const Context) bool {
        if (self.kindIs(.callable_qualifier)) return true;
        const parsed = self.program() orelse return false;
        return cursor.isQualifiedCallableQualifierAt(parsed, self.offset);
    }

    pub fn isImportAlias(self: *const Context) bool {
        if (self.kindIs(.import_alias)) return true;
        const parsed = self.program() orelse return false;
        return cursor.isImportAliasAt(parsed, self.offset);
    }

    pub fn importSpecAtOffset(self: *const Context) bool {
        if (self.kindIs(.import_spec)) return true;
        const parsed = self.program() orelse return false;
        return cursor.importSpecAt(parsed, self.offset) != null;
    }

    pub fn targetKindIs(self: *const Context, kind: cursor.SourceNameKind) bool {
        return self.kindIs(kind);
    }

    pub fn callableRoleIsName(self: *const Context) bool {
        const parsed = self.program() orelse return false;
        if (cursor.callableAt(parsed, self.offset)) |target| {
            return target.role == .name;
        }
        return false;
    }

    fn kindIs(self: *const Context, kind: cursor.SourceNameKind) bool {
        return if (self.target_kind) |target_kind| target_kind == kind else false;
    }
};

const TargetAtOffset = struct {
    text: []u8,
    kind: ?cursor.SourceNameKind = null,
    qualifier: ?[]u8 = null,
};

fn targetAtOffset(allocator: std.mem.Allocator, text: []const u8, offset: usize, program: ?*const ast.Program) !?TargetAtOffset {
    if (program) |parsed| {
        if (cursor.sourceNameAt(parsed, offset)) |target| return .{
            .text = try allocator.dupe(u8, target.text),
            .kind = target.kind,
            .qualifier = if (target.qualifier) |qualifier| try allocator.dupe(u8, qualifier) else null,
        };
    }
    const span = utils.source.wordSpanAt(text, offset, language_names.isCallableNameChar) orelse return null;
    return .{
        .text = try allocator.dupe(u8, text[span.start..span.end]),
    };
}
