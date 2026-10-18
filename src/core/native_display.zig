const std = @import("std");
const ast = @import("ast");
const model = @import("model");
const fontawesome = @import("fontawesome.zig");

pub const Kind = model.NativeDisplayKind;
pub const Target = union(enum) {
    function: model.FunctionKey,
    native: Kind,
    group,
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
    typed_group_calls: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .call_targets = .init(allocator), .typed_group_calls = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        for (self.plans.items) |*plan| plan.deinit();
        self.plans.deinit(self.allocator);
        self.call_targets.deinit();
        self.typed_group_calls.deinit();
    }

    pub fn isTypedGroupCall(self: *const Store, call_id: ?u64) bool {
        return if (call_id) |id| self.typed_group_calls.contains(id) else false;
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
    value_fields: []const struct { field: []const u8, ty: ast.Type, tag: model.ValueTag } = &.{},
    record_fields: []const struct { field: []const u8, module: []const u8, name: []const u8, optional: bool = false },
};

fn contract(kind: Kind) Contract {
    return switch (kind) {
        .path_shape => .{
            .module = "std:graphics/content",
            .name = "PathShape",
            .value_fields = &.{
                .{ .field = "path", .ty = ast.Type.path, .tag = .path },
                .{ .field = "width", .ty = ast.Type.number, .tag = .number },
                .{ .field = "height", .ty = ast.Type.number, .tag = .number },
            },
            .record_fields = &.{
                .{ .field = "style", .module = "std:graphics/types", .name = "VectorStyle" },
                .{ .field = "marker_start", .module = "std:graphics/types", .name = "MarkerStyle", .optional = true },
                .{ .field = "marker_end", .module = "std:graphics/types", .name = "MarkerStyle", .optional = true },
            },
        },
        .text => .{
            .module = "std:text/content",
            .name = "Text",
            .value_fields = &.{.{ .field = "content", .ty = ast.Type.string, .tag = .string }},
            .record_fields = &.{.{ .field = "style", .module = "std:text/style", .name = "TextBlockStyle" }},
        },
        .icon => .{
            .module = "std:assets/content",
            .name = "Icon",
            .value_fields = &.{.{ .field = "source", .ty = ast.Type.string, .tag = .string }},
            .record_fields = &.{.{ .field = "style", .module = "std:assets/style", .name = "AssetBlockStyle" }},
        },
        .image => .{
            .module = "std:assets/content",
            .name = "Image",
            .value_fields = &.{.{ .field = "path", .ty = ast.Type.string, .tag = .string }},
            .record_fields = &.{.{ .field = "style", .module = "std:assets/style", .name = "AssetBlockStyle" }},
        },
        .code => .{
            .module = "std:code/content",
            .name = "Code",
            .value_fields = &.{ .{ .field = "source", .ty = ast.Type.string, .tag = .string }, .{ .field = "language", .ty = ast.Type.string, .tag = .string } },
            .record_fields = &.{.{ .field = "style", .module = "std:code/style", .name = "CodeBlockStyle" }},
        },
        .pdf => .{
            .module = "std:assets/content",
            .name = "Pdf",
            .value_fields = &.{.{ .field = "path", .ty = ast.Type.string, .tag = .string }},
            .record_fields = &.{.{ .field = "style", .module = "std:assets/style", .name = "AssetBlockStyle" }},
        },
        .latex => .{
            .module = "std:math/content",
            .name = "Latex",
            .value_fields = &.{.{ .field = "source", .ty = ast.Type.string, .tag = .string }},
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
    for (expected.value_fields) |value| {
        const field = index.recordField(id, value.field) orelse return error.InvalidNativeDisplay;
        if (!ast.Type.eql(field.value_type, value.ty)) return error.InvalidNativeDisplay;
    }
    for (expected.record_fields) |record| {
        const field = index.recordField(id, record.field) orelse return error.InvalidNativeDisplay;
        const field_type = if (record.optional) blk: {
            if (field.value_type.kind != .optional) return error.InvalidNativeDisplay;
            break :blk (field.value_type.optional_child orelse return error.InvalidNativeDisplay).*;
        } else field.value_type;
        if (!isLibraryType(state, field_type, record.module, record.name)) return error.InvalidNativeDisplay;
    }
}

pub fn validateValue(state: anytype, value: model.Value, kind: Kind) !void {
    const record = switch (value) {
        .record => |record| record,
        else => return error.InvalidNativeDisplay,
    };
    try validateType(state, record.ty, kind);
    const expected = contract(kind);
    for (expected.value_fields) |expected_value| {
        const field = record.field(expected_value.field) orelse return error.InvalidNativeDisplay;
        if (std.meta.activeTag(field) != expected_value.tag) return error.InvalidNativeDisplay;
    }
    for (expected.record_fields) |expected_record| {
        const field = record.field(expected_record.field) orelse return error.InvalidNativeDisplay;
        if (expected_record.optional and field == .none) continue;
        if (field != .record or !isLibraryType(state, field.record.ty, expected_record.module, expected_record.name)) return error.InvalidNativeDisplay;
    }
    if (kind == .path_shape) try validateShapeDimensions(value);
    if (kind == .icon) {
        const spec = fontawesome.parseSource(record.field("source").?.string) orelse return error.InvalidFontAwesomeIcon;
        if (!fontawesome.contains(spec)) return error.InvalidFontAwesomeIcon;
    }
}

/// Dimensions describe the natural frame. Placement constraints may resize it.
fn validateShapeDimensions(value: model.Value) !void {
    for ([_][]const u8{ "width", "height" }) |name| {
        const number = value.record.field(name).?.number;
        if (!std.math.isFinite(number) or number <= 0) return error.InvalidShapeSize;
    }
}
