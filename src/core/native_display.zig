const std = @import("std");
const ast = @import("ast");
const model = @import("model");

pub const Kind = model.NativeDisplayKind;
pub const Target = union(enum) {
    function: model.FunctionKey,
    native: Kind,
};

pub const Step = struct { input: ast.Type, target: Target };

pub const Plan = struct {
    allocator: std.mem.Allocator,
    steps: std.ArrayList(Step) = .empty,

    pub fn deinit(self: *Plan) void {
        for (self.steps.items) |*step| step.input.deinit(self.allocator);
        self.steps.deinit(self.allocator);
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

/// Renderer leaves are identified by their defining module and nominal type,
/// never by a role, field shape, or an unqualified user-defined name.
pub fn kindForType(state: anytype, ty: ast.Type) ?Kind {
    if (isLibraryType(state, ty, "std:text/content", "Text")) return .text;
    return null;
}

pub fn validateType(state: anytype, ty: ast.Type, kind: Kind) !void {
    if (kindForType(state, ty) != kind) return error.InvalidNativeDisplay;
    const id = ty.nominalId().?;
    const index = state.declaration_index;
    switch (kind) {
        .text => {
            const content = index.recordField(id, "content") orelse return error.InvalidNativeDisplay;
            if (!ast.Type.eql(content.value_type, ast.Type.string)) return error.InvalidNativeDisplay;
            const style = index.recordField(id, "style") orelse return error.InvalidNativeDisplay;
            if (!isLibraryType(state, style.value_type, "std:text/types", "TextStyle")) return error.InvalidNativeDisplay;
        },
    }
}

pub fn validateValue(state: anytype, value: model.Value, kind: Kind) !void {
    const record = switch (value) {
        .record => |record| record,
        else => return error.InvalidNativeDisplay,
    };
    try validateType(state, record.ty, kind);
    switch (kind) {
        .text => {
            const content = record.field("content") orelse return error.InvalidNativeDisplay;
            if (content != .string) return error.InvalidNativeDisplay;
            const style = record.field("style") orelse return error.InvalidNativeDisplay;
            if (style != .record or !isLibraryType(state, style.record.ty, "std:text/types", "TextStyle")) return error.InvalidNativeDisplay;
        },
    }
}
