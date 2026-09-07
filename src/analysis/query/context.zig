const std = @import("std");
const ast = @import("ast");

const language_names = @import("../../language/names.zig");
const cursor = @import("cursor.zig");
const source_query = @import("source.zig");
const types = @import("types.zig");
const utils = @import("utils");

pub const Context = struct {
    target: []u8,
    target_kind: ?cursor.SourceNameKind = null,
    qualifier: ?[]u8 = null,
    parsed: source_query.ParsedSource = .{},
    offset: usize,
    budget: ?types.QueryBudget = null,

    pub fn init(allocator: std.mem.Allocator, req: types.SourceRequest) !Context {
        return initWithBudget(allocator, req, null);
    }

    pub fn initWithBudget(allocator: std.mem.Allocator, req: types.SourceRequest, budget: ?types.QueryBudget) !Context {
        return initWithParsed(allocator, req, try source_query.ParsedSource.parse(allocator, req, budget), budget);
    }

    pub fn initFromSnapshot(allocator: std.mem.Allocator, snapshot: anytype, req: types.SourceRequest, budget: ?types.QueryBudget) !Context {
        return initWithParsed(allocator, req, try source_query.ParsedSource.init(allocator, snapshot, req, budget), budget);
    }

    fn initWithParsed(allocator: std.mem.Allocator, req: types.SourceRequest, source: source_query.ParsedSource, budget: ?types.QueryBudget) !Context {
        var parsed = source;
        errdefer parsed.deinit(allocator);
        const parsed_module = parsed.module();
        const target = try targetAtOffset(allocator, req.source, req.offset, parsed_module, budget) orelse return error.NoQueryTarget;
        return .{
            .target = target.text,
            .target_kind = target.kind,
            .qualifier = target.qualifier,
            .parsed = parsed,
            .offset = req.offset,
            .budget = budget,
        };
    }

    pub fn deinit(self: *Context, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        if (self.qualifier) |qualifier| allocator.free(qualifier);
        self.parsed.deinit(allocator);
    }

    pub fn expired(self: *const Context) bool {
        return if (self.budget) |value| value.expired() else false;
    }

    pub fn module(self: *const Context) ?*const ast.Module {
        return self.parsed.module();
    }

    pub fn qualifiedCallableAlias(self: *const Context) ?[]const u8 {
        if (self.kindIs(.callable_name)) return self.qualifier;
        const parsed = self.module() orelse return null;
        return cursor.qualifiedCallableQualifierForName(self.budget, parsed, self.offset);
    }

    pub fn isQualifiedCallableQualifier(self: *const Context) bool {
        if (self.kindIs(.callable_qualifier)) return true;
        const parsed = self.module() orelse return false;
        return cursor.isQualifiedCallableQualifierAt(self.budget, parsed, self.offset);
    }

    pub fn isImportAlias(self: *const Context) bool {
        if (self.kindIs(.import_alias)) return true;
        const parsed = self.module() orelse return false;
        return cursor.isImportAliasAt(self.budget, parsed, self.offset);
    }

    pub fn importSpecAtOffset(self: *const Context) bool {
        if (self.kindIs(.import_spec)) return true;
        const parsed = self.module() orelse return false;
        return cursor.importSpecAt(self.budget, parsed, self.offset) != null;
    }

    pub fn targetKindIs(self: *const Context, kind: cursor.SourceNameKind) bool {
        return self.kindIs(kind);
    }

    pub fn callableRoleIsName(self: *const Context) bool {
        const parsed = self.module() orelse return false;
        if (cursor.callableAt(self.budget, parsed, self.offset)) |target| {
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

fn targetAtOffset(allocator: std.mem.Allocator, text: []const u8, offset: usize, program: ?*const ast.Module, budget: ?types.QueryBudget) !?TargetAtOffset {
    if (program) |parsed| {
        if (cursor.sourceNameAt(budget, parsed, offset)) |target| {
            const name = try allocator.dupe(u8, target.text);
            errdefer allocator.free(name);
            return .{
                .text = name,
                .kind = target.kind,
                .qualifier = if (target.qualifier) |qualifier| try allocator.dupe(u8, qualifier) else null,
            };
        }
    }
    const span = utils.source.wordSpanAt(text, offset, language_names.isCallableNameChar) orelse return null;
    return .{
        .text = try allocator.dupe(u8, text[span.start..span.end]),
    };
}
