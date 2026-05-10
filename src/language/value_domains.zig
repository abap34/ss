const std = @import("std");
const core = @import("core");
const color_utils = @import("utils").color;

pub const ValueType = enum {
    string,
    scalar_like,
    color_string,
    fit_policy,
    render_kind,
    wrap_mode,
    layout_policy,
};

pub fn resolve(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?ValueType {
    if (parse(name)) |value_type| return value_type;
    if (infer("", name)) |value_type| return value_type;
    if (resolveInModule(ir, module_id, name)) |value_type| return value_type;
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const current_id = ir.module_order.items[index];
        if (current_id == module_id) continue;
        if (resolveInModule(ir, current_id, name)) |value_type| return value_type;
    }
    return null;
}

fn resolveInModule(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?ValueType {
    const module = ir.moduleById(module_id) orelse return null;
    return resolveInProgram(module.program, name);
}

fn resolveInProgram(program: anytype, name: []const u8) ?ValueType {
    for (program.types.items) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) continue;
        return resolveDeclaration(decl.name, decl.body);
    }
    return null;
}

pub fn parse(name: []const u8) ?ValueType {
    inline for (std.meta.fields(ValueType)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn resolveDeclaration(name: []const u8, body: []const u8) ?ValueType {
    return infer(name, body);
}

fn infer(name: []const u8, body: []const u8) ?ValueType {
    if (std.mem.eql(u8, body, "string")) {
        if (std.mem.eql(u8, name, "Color")) return .color_string;
        return .string;
    }
    if (std.mem.eql(u8, body, "string | number")) return .scalar_like;
    if (std.mem.indexOf(u8, body, "\"top\"") != null) return .layout_policy;
    if (std.mem.indexOf(u8, body, "\"vector_math\"") != null) return .render_kind;
    if (std.mem.indexOf(u8, body, "\"on\"") != null and std.mem.indexOf(u8, body, "\"off\"") != null) return .wrap_mode;
    if (std.mem.indexOf(u8, body, "\"warn\"") != null) return .fit_policy;
    if (std.mem.indexOfScalar(u8, body, '"') != null) return .string;
    return parse(body);
}

pub fn matches(kind: ValueType, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    return switch (kind) {
        .string => sort == .string,
        .scalar_like => sort == .string or sort == .number,
        .color_string => if (string_literal) |text| text.len == 0 or color_utils.parse(text) != null else sort == .string,
        .fit_policy => if (string_literal) |text|
            std.mem.eql(u8, text, "warn") or std.mem.eql(u8, text, "error") or std.mem.eql(u8, text, "ignore")
        else
            sort == .string,
        .render_kind => if (string_literal) |text|
            std.mem.eql(u8, text, "text") or
                std.mem.eql(u8, text, "code") or
                std.mem.eql(u8, text, "vector_math") or
                std.mem.eql(u8, text, "vector_asset") or
                std.mem.eql(u8, text, "raster_asset") or
                std.mem.eql(u8, text, "chrome") or
                std.mem.eql(u8, text, "chrome_only")
        else
            sort == .string,
        .wrap_mode => if (string_literal) |text|
            std.mem.eql(u8, text, "on") or std.mem.eql(u8, text, "off")
        else
            sort == .string,
        .layout_policy => if (string_literal) |text|
            std.mem.eql(u8, text, "top") or
                std.mem.eql(u8, text, "top_flow") or
                std.mem.eql(u8, text, "center") or
                std.mem.eql(u8, text, "center_stack")
        else
            sort == .string,
    };
}

pub fn label(kind: ValueType) []const u8 {
    return switch (kind) {
        .string => "string",
        .scalar_like => "string or number",
        .color_string => "color string",
        .fit_policy => "\"warn\" | \"error\" | \"ignore\"",
        .render_kind => "\"text\" | \"code\" | \"vector_math\" | \"vector_asset\" | \"raster_asset\" | \"chrome\"",
        .wrap_mode => "\"on\" | \"off\"",
        .layout_policy => "\"top\" | \"top_flow\" | \"center\" | \"center_stack\"",
    };
}

pub fn nameMatches(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    const value_type = resolve(ir, module_id, name) orelse return false;
    return matches(value_type, string_literal, sort);
}

pub fn nameLabel(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) []const u8 {
    const value_type = resolve(ir, module_id, name) orelse return "known value type";
    return label(value_type);
}
