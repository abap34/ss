const std = @import("std");
const ast = @import("ast");
const model = @import("model");

pub const Kind = model.NativeDisplayKind;
pub const Target = union(enum) {
    function: model.FunctionKey,
    native: Kind,
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
