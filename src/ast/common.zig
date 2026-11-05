const std = @import("std");
const core = @import("model");
pub const types = @import("language_type");
const Allocator = std.mem.Allocator;
pub const Type = types.Type;
pub const GroupComposition = types.GroupComposition;
pub const HoleId = u32;

/// Physical sources share one module and occupy disjoint virtual byte ranges.
pub const SourceFile = struct {
    path: []const u8,
    source: []const u8,
    offset: usize,
    included_at: usize = 0,

    pub const Location = struct { path: []const u8, source: []const u8, span: Span };

    pub fn locate(files: []const SourceFile, path: []const u8, source: []const u8, span: Span) Location {
        for (files) |file| {
            if (span.start >= file.offset and span.start <= file.offset + file.source.len) return .{
                .path = file.path,
                .source = file.source,
                .span = .{ .start = span.start - file.offset, .end = @min(span.end -| file.offset, file.source.len) },
            };
        }
        return .{ .path = path, .source = source, .span = span };
    }

    pub fn deinit(self: *SourceFile, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
    }

    pub fn clone(self: SourceFile, allocator: Allocator) !SourceFile {
        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);
        return .{ .path = path, .source = try allocator.dupe(u8, self.source), .offset = self.offset, .included_at = self.included_at };
    }
};

pub const IncludeDecl = struct {
    path: []const u8,
    span: Span,
    path_span: Span,

    pub fn deinit(self: *IncludeDecl, allocator: Allocator) void {
        allocator.free(self.path);
    }

    pub fn clone(self: IncludeDecl, allocator: Allocator) !IncludeDecl {
        var result = self;
        result.path = try allocator.dupe(u8, self.path);
        return result;
    }
};

/// Ordinary type clones borrow names; included source buffers belong to the tree.
pub fn rebindSources(value: anytype, previous: []const SourceFile, next: []const SourceFile) void {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .@"struct" => inline for (comptime std.meta.fieldNames(T)) |name| {
            if (!std.mem.eql(u8, name, "capacity")) rebindSources(&@field(value.*, name), previous, next);
        },
        .@"union" => switch (value.*) {
            inline else => |*payload| rebindSources(payload, previous, next),
        },
        .optional => if (value.*) |*payload| rebindSources(payload, previous, next),
        .pointer => |pointer| switch (pointer.size) {
            .one => rebindSources(@constCast(value.*), previous, next),
            .slice => if (pointer.child == u8) {
                const address = @intFromPtr(value.ptr);
                for (previous, next) |old, new| {
                    const start = @intFromPtr(old.source.ptr);
                    if (address >= start and address + value.len <= start + old.source.len) {
                        value.* = @constCast(new.source[address - start ..][0..value.len]);
                        break;
                    }
                }
            } else {
                for (@constCast(value.*)) |*payload| rebindSources(payload, previous, next);
            },
            else => {},
        },
        else => {},
    }
}

pub const TopLevelItem = union(enum) {
    import: usize,
    document: usize,
    page: usize,
};

pub const ImportDecl = struct {
    pub const SelectedName = struct {
        name: []const u8,
        span: Span,
    };

    pub const Mode = struct {
        alias: ?[]const u8 = null,
        unqualified: bool = false,
        selected: []const SelectedName = &.{},

        pub fn deinit(self: *Mode, allocator: Allocator) void {
            if (self.alias) |alias| allocator.free(alias);
            for (self.selected) |item| allocator.free(item.name);
            allocator.free(self.selected);
        }

        pub fn clone(self: Mode, allocator: Allocator) !Mode {
            var result = Mode{ .unqualified = self.unqualified };
            errdefer result.deinit(allocator);
            result.alias = if (self.alias) |alias| try allocator.dupe(u8, alias) else null;
            var selected = std.ArrayList(SelectedName).empty;
            errdefer {
                for (selected.items) |item| allocator.free(item.name);
                selected.deinit(allocator);
            }
            try selected.ensureTotalCapacity(allocator, self.selected.len);
            for (self.selected) |item| selected.appendAssumeCapacity(.{
                .name = try allocator.dupe(u8, item.name),
                .span = item.span,
            });
            result.selected = try selected.toOwnedSlice(allocator);
            return result;
        }
    };

    spec: []const u8,
    spec_span: Span,
    mode: Mode,
    alias_span: ?Span = null,
    base_dir: ?[]const u8 = null,
    span: Span,

    pub fn deinit(self: *ImportDecl, allocator: Allocator) void {
        allocator.free(self.spec);
        self.mode.deinit(allocator);
        if (self.base_dir) |base| allocator.free(base);
    }

    pub fn clone(self: ImportDecl, allocator: Allocator) !ImportDecl {
        const spec = try allocator.dupe(u8, self.spec);
        errdefer allocator.free(spec);
        var mode = try self.mode.clone(allocator);
        errdefer mode.deinit(allocator);
        return .{
            .spec = spec,
            .spec_span = self.spec_span,
            .mode = mode,
            .alias_span = self.alias_span,
            .base_dir = if (self.base_dir) |base| try allocator.dupe(u8, base) else null,
            .span = self.span,
        };
    }
};

pub const TypeDecl = struct {
    name: []const u8,
    name_span: ?Span = null,
    cases: std.ArrayList(EnumCaseDecl),
    span: Span,

    pub fn deinit(self: *TypeDecl, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.cases.items) |*case_decl| case_decl.deinit(allocator);
        self.cases.deinit(allocator);
    }

    pub fn clone(self: TypeDecl, allocator: Allocator) !TypeDecl {
        var result = TypeDecl{
            .name = try allocator.dupe(u8, self.name),
            .name_span = self.name_span,
            .cases = .empty,
            .span = self.span,
        };
        errdefer result.deinit(allocator);
        try result.cases.ensureTotalCapacity(allocator, self.cases.items.len);
        for (self.cases.items) |value| result.cases.appendAssumeCapacity(try value.clone(allocator));
        return result;
    }
};

pub const EnumCaseDecl = struct {
    name: []const u8,
    name_span: ?Span = null,

    pub fn deinit(self: *EnumCaseDecl, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: EnumCaseDecl, allocator: Allocator) !EnumCaseDecl {
        return .{ .name = try allocator.dupe(u8, self.name), .name_span = self.name_span };
    }
};

pub const TypeParameter = struct {
    // Like unresolved Type names, parameter names borrow the source text.
    name: []const u8,
    span: Span,

    pub fn deinit(self: *TypeParameter, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn clone(self: TypeParameter, allocator: Allocator) !TypeParameter {
        _ = allocator;
        return self;
    }
};

pub fn cloneTypeParameters(allocator: Allocator, parameters: []const TypeParameter) !std.ArrayList(TypeParameter) {
    var result = std.ArrayList(TypeParameter).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, parameters);
    return result;
}

pub fn cloneTypeArguments(allocator: Allocator, arguments: []const Type) !std.ArrayList(Type) {
    var result = std.ArrayList(Type).empty;
    errdefer {
        for (result.items) |*argument| argument.deinit(allocator);
        result.deinit(allocator);
    }
    try result.ensureTotalCapacity(allocator, arguments.len);
    for (arguments) |argument| result.appendAssumeCapacity(try argument.clone(allocator));
    return result;
}

pub const StagesDecl = struct {
    name: []const u8,
    name_span: Span,
    entries: std.ArrayList(EnumCaseDecl),
    span: Span,

    pub fn deinit(self: *StagesDecl, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn clone(self: StagesDecl, allocator: Allocator) !StagesDecl {
        var result = StagesDecl{
            .name = try allocator.dupe(u8, self.name),
            .name_span = self.name_span,
            .entries = .empty,
            .span = self.span,
        };
        errdefer result.deinit(allocator);
        try result.entries.ensureTotalCapacity(allocator, self.entries.items.len);
        for (self.entries.items) |entry| result.entries.appendAssumeCapacity(try entry.clone(allocator));
        return result;
    }
};

pub const DocumentBlockDecl = struct {
    statement_start: usize,
    statement_count: usize,
    span: Span,
};

pub const CallableName = struct {
    pub const Resolution = enum { lexical, intrinsic, function };

    call_id: ?u64 = null,
    // Expansion fixes generated references to their kernel or function binding.
    resolution: Resolution = .lexical,
    composition: ?GroupComposition = null,
    qualifier: ?[]const u8 = null,
    name: []const u8,
    name_hole: ?HoleId = null,
    qualifier_span: ?Span = null,
    name_span: ?Span = null,
    span: ?Span = null,

    pub fn bare(name: []const u8) CallableName {
        return .{ .name = name };
    }

    /// Borrow a value reference's name without allocating or taking ownership.
    pub fn fromText(text: []const u8) CallableName {
        if (std.mem.indexOf(u8, text, "::")) |separator| {
            return qualified(text[0..separator], text[separator + 2 ..]);
        }
        return bare(text);
    }

    pub fn qualified(qualifier: []const u8, name: []const u8) CallableName {
        return .{ .qualifier = qualifier, .name = name };
    }

    pub fn isQualified(self: CallableName) bool {
        return self.qualifier != null;
    }

    pub fn displayAlloc(self: CallableName, allocator: Allocator) ![]const u8 {
        if (self.name_hole != null) {
            if (self.qualifier) |qualifier| return std.fmt.allocPrint(allocator, "{s}::<hole>", .{qualifier});
            return allocator.dupe(u8, "<hole>");
        }
        if (self.qualifier) |qualifier| {
            return std.fmt.allocPrint(allocator, "{s}::{s}", .{ qualifier, self.name });
        }
        return allocator.dupe(u8, self.name);
    }

    pub fn clone(self: CallableName, allocator: Allocator) !CallableName {
        const qualifier = if (self.qualifier) |value| try allocator.dupe(u8, value) else null;
        errdefer if (qualifier) |value| allocator.free(value);
        return .{
            .qualifier = qualifier,
            .name = try allocator.dupe(u8, self.name),
            .name_hole = self.name_hole,
            .call_id = self.call_id,
            .resolution = self.resolution,
            .composition = self.composition,
            .qualifier_span = self.qualifier_span,
            .name_span = self.name_span,
            .span = self.span,
        };
    }

    pub fn deinit(self: *CallableName, allocator: Allocator) void {
        if (self.qualifier) |qualifier| allocator.free(qualifier);
        allocator.free(self.name);
    }
};

pub const RecordPathSegment = struct {
    name: []const u8,
    span: Span,
    name_hole: ?HoleId = null,

    pub fn deinit(self: *RecordPathSegment, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: RecordPathSegment, allocator: Allocator) !RecordPathSegment {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .span = self.span,
            .name_hole = self.name_hole,
        };
    }
};

pub fn formatRecordPath(allocator: Allocator, path: []const RecordPathSegment) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (path, 0..) |segment, index| {
        if (index > 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, segment.name);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn recordPathsOverlap(left: []const RecordPathSegment, right: []const RecordPathSegment) bool {
    const shared = @min(left.len, right.len);
    for (0..shared) |index| {
        if (!std.mem.eql(u8, left[index].name, right[index].name)) return false;
    }
    return true;
}

pub const EnumCaseExpr = struct {
    module_id: ?u32 = null,
    enum_name: []const u8,
    enum_name_span: ?Span = null,
    case_name: []const u8,
    case_name_span: ?Span = null,

    pub fn deinit(self: *EnumCaseExpr, allocator: Allocator) void {
        allocator.free(self.enum_name);
        allocator.free(self.case_name);
    }

    pub fn clone(self: EnumCaseExpr, allocator: Allocator) anyerror!EnumCaseExpr {
        const enum_name = try allocator.dupe(u8, self.enum_name);
        errdefer allocator.free(enum_name);
        return .{
            .enum_name = enum_name,
            .enum_name_span = self.enum_name_span,
            .module_id = self.module_id,
            .case_name = try allocator.dupe(u8, self.case_name),
            .case_name_span = self.case_name_span,
        };
    }
};

pub const Span = types.SourceSpan;

pub const StringLiteral = struct {
    text: []const u8,
    source_span: ?Span = null,

    pub fn deinit(self: *StringLiteral, allocator: Allocator) void {
        allocator.free(self.text);
    }

    pub fn clone(self: StringLiteral, allocator: Allocator) !StringLiteral {
        return .{
            .text = try allocator.dupe(u8, self.text),
            .source_span = self.source_span,
        };
    }
};

pub const IdentifierExpr = struct {
    name: []const u8,
    name_span: ?Span = null,

    pub fn reference(self: IdentifierExpr) CallableName {
        var result = CallableName.fromText(self.name);
        result.span = self.name_span;
        result.name_span = self.name_span;
        if (self.name_span) |span| if (result.qualifier) |qualifier| {
            result.qualifier_span = .{ .start = span.start, .end = span.start + qualifier.len };
            result.name_span = .{ .start = span.end - result.name.len, .end = span.end };
        };
        return result;
    }

    pub fn deinit(self: *IdentifierExpr, allocator: Allocator) void {
        allocator.free(self.name);
    }

    pub fn clone(self: IdentifierExpr, allocator: Allocator) !IdentifierExpr {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .name_span = self.name_span,
        };
    }
};

pub const AnchorRef = struct {
    kind: enum {
        page,
        node,
    },
    anchor: core.Anchor,
    node_name: ?[]const u8 = null,
    node_path: ?[]const u8 = null,

    pub fn page(anchor: core.Anchor) AnchorRef {
        return .{ .kind = .page, .anchor = anchor };
    }

    pub fn nodePath(allocator: Allocator, path: []const u8, anchor: core.Anchor) !AnchorRef {
        const cloned_path = try allocator.dupe(u8, path);
        return .{
            .kind = .node,
            .anchor = anchor,
            .node_name = firstPathSegment(cloned_path),
            .node_path = cloned_path,
        };
    }

    pub fn cloneWithAnchor(self: AnchorRef, allocator: Allocator, anchor: core.Anchor) !AnchorRef {
        if (self.kind == .page) return page(anchor);

        return nodePath(allocator, self.node_path orelse self.node_name.?, anchor);
    }

    pub fn deinit(self: *AnchorRef, allocator: Allocator) void {
        if (self.node_path) |path| {
            allocator.free(path);
        } else if (self.node_name) |name| {
            allocator.free(name);
        }
    }

    fn firstPathSegment(path: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, path, '.')) |index| return path[0..index];
        return path;
    }
};
