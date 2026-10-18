const std = @import("std");
const ast = @import("ast");
const model = @import("model");

pub const Kind = model.NativeDisplayKind;
pub const Target = union(enum) {
    function: model.FunctionKey,
    native: Kind,
};

pub const Step = struct {
    input: ast.Type,
    target: Target,
    parent: ?usize,
    path: []const usize,
    children: std.ArrayList(usize) = .empty,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,

    pub fn deinit(self: *Plan) void {
        for (self.steps.items) |*step| {
            step.input.deinit(self.allocator);
            self.allocator.free(step.path);
            step.children.deinit(self.allocator);
        }
        self.steps.deinit(self.allocator);
    }

    /// Parents precede children, but siblings need not be adjacent. Publish the
    /// step and its parent edge together after all allocation has succeeded.
    pub fn append(self: *Plan, input: ast.Type, target: Target, parent: ?usize) !usize {
        if (parent) |index| {
            if (index >= self.steps.items.len) return error.InvalidDisplayPlan;
        } else if (self.steps.items.len != 0) return error.InvalidDisplayPlan;
        var owned = try input.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const path = try self.allocator.alloc(usize, if (parent) |owner| self.steps.items[owner].path.len + 1 else 0);
        errdefer self.allocator.free(path);
        if (parent) |owner| {
            @memcpy(path[0 .. path.len - 1], self.steps.items[owner].path);
            path[path.len - 1] = self.steps.items[owner].children.items.len;
        }
        try self.steps.ensureUnusedCapacity(self.allocator, 1);
        if (parent) |index| try self.steps.items[index].children.ensureUnusedCapacity(self.allocator, 1);
        const index = self.steps.items.len;
        self.steps.appendAssumeCapacity(.{
            .input = owned,
            .target = target,
            .parent = parent,
            .path = path,
        });
        if (parent) |owner| self.steps.items[owner].children.appendAssumeCapacity(index);
        return index;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    plans: std.ArrayList(Plan) = .empty,
    call_targets: std.AutoHashMap(u64, usize),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .call_targets = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        for (self.plans.items) |*plan| plan.deinit();
        self.plans.deinit(self.allocator);
        self.call_targets.deinit();
    }

    pub fn find(self: *const Store, input: ast.Type) ?usize {
        for (self.plans.items, 0..) |plan, index| {
            if (ast.Type.eql(plan.steps.items[0].input, input)) return index;
        }
        return null;
    }
};

fn isLibraryType(state: anytype, ty: ast.Type, spec: []const u8, name: []const u8) bool {
    if (ty.kind != .record or ty.arguments.len != 0) return false;
    const id = ty.nominalId() orelse return false;
    const module = state.moduleById(id.module_id) orelse return false;
    return module.kind == .library and std.mem.eql(u8, module.spec, spec) and std.mem.eql(u8, id.name, name);
}

const Contract = struct {
    module: []const u8,
    name: []const u8,
    string_fields: []const []const u8,
    record_fields: []const struct { field: []const u8, module: []const u8, name: []const u8 },
};

fn contract(kind: Kind) Contract {
    return switch (kind) {
        .text => .{
            .module = "std:text/content",
            .name = "Text",
            .string_fields = &.{"content"},
            .record_fields = &.{.{ .field = "style", .module = "std:text/style", .name = "TextBlockStyle" }},
        },
        .image => .{
            .module = "std:assets/content",
            .name = "Image",
            .string_fields = &.{"path"},
            .record_fields = &.{.{ .field = "style", .module = "std:assets/style", .name = "AssetBlockStyle" }},
        },
        .code => .{
            .module = "std:code/content",
            .name = "Code",
            .string_fields = &.{ "source", "language" },
            .record_fields = &.{.{ .field = "style", .module = "std:code/style", .name = "CodeBlockStyle" }},
        },
        .pdf => .{
            .module = "std:assets/content",
            .name = "Pdf",
            .string_fields = &.{"path"},
            .record_fields = &.{.{ .field = "style", .module = "std:assets/style", .name = "AssetBlockStyle" }},
        },
        .latex => .{
            .module = "std:math/content",
            .name = "Latex",
            .string_fields = &.{"source"},
            .record_fields = &.{
                .{ .field = "style", .module = "std:math/style", .name = "LatexBlockStyle" },
                .{ .field = "config", .module = "std:math/types", .name = "LatexConfig" },
            },
        },
    };
}

/// Renderer leaves are identified by their defining module and nominal type,
/// never by a role, field shape, or an unqualified user-defined name.
pub fn kindForType(state: anytype, ty: ast.Type) ?Kind {
    inline for (std.meta.tags(Kind)) |kind| {
        const expected = contract(kind);
        if (isLibraryType(state, ty, expected.module, expected.name)) return kind;
    }
    return null;
}

pub fn validateType(state: anytype, ty: ast.Type, kind: Kind) !void {
    if (kindForType(state, ty) != kind) return error.InvalidNativeDisplay;
    const id = ty.nominalId().?;
    const index = state.declaration_index;
    const expected = contract(kind);
    for (expected.string_fields) |name| {
        const field = index.recordField(id, name) orelse return error.InvalidNativeDisplay;
        if (!ast.Type.eql(field.value_type, ast.Type.string)) return error.InvalidNativeDisplay;
    }
    for (expected.record_fields) |record| {
        const field = index.recordField(id, record.field) orelse return error.InvalidNativeDisplay;
        if (!isLibraryType(state, field.value_type, record.module, record.name)) return error.InvalidNativeDisplay;
    }
}

pub fn validateValue(state: anytype, value: model.Value, kind: Kind) !void {
    const record = switch (value) {
        .record => |record| record,
        else => return error.InvalidNativeDisplay,
    };
    try validateType(state, record.ty, kind);
    const expected = contract(kind);
    for (expected.string_fields) |name| {
        const field = record.field(name) orelse return error.InvalidNativeDisplay;
        if (field != .string) return error.InvalidNativeDisplay;
    }
    for (expected.record_fields) |expected_record| {
        const field = record.field(expected_record.field) orelse return error.InvalidNativeDisplay;
        if (field != .record or !isLibraryType(state, field.record.ty, expected_record.module, expected_record.name)) return error.InvalidNativeDisplay;
    }
}
