const std = @import("std");
const core = @import("core");
const ast = @import("ast");

pub const ObjectShape = enum {
    unknown,
    document,
    page,
    generic,
    text,
    code,
    math,
    figure,
    asset_image,
    asset_pdf,
    panel,
    rule,
    page_number,
    toc,
    group,
};

pub const PropertyValueType = enum {
    string,
    scalar_like,
    color_string,
    fit_policy,
    render_kind,
    wrap_mode,
    layout_policy,
};

pub const SchemaRef = struct {
    declaration: *const ast.PropertyDecl,
    value_type: PropertyValueType,
};

pub fn lookupInIr(ir: *const core.Ir, key: []const u8) ?SchemaRef {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        if (lookupInProgram(module.program, key)) |property| {
            return .{
                .declaration = property,
                .value_type = resolveValueType(ir, module.id, property.value_type) orelse return null,
            };
        }
    }
    return null;
}

fn lookupInProgram(program: ast.Program, key: []const u8) ?*const ast.PropertyDecl {
    var index = program.properties.items.len;
    while (index > 0) {
        index -= 1;
        const property = &program.properties.items[index];
        if (std.mem.eql(u8, property.key, key)) return property;
    }
    return null;
}

pub fn schemaValueType(schema: SchemaRef) ?PropertyValueType {
    return schema.value_type;
}

pub fn isSchemaShapeAllowed(schema: SchemaRef, shape: ObjectShape) bool {
    return isDeclaredShapeAllowed(schema.declaration, shape);
}

pub fn schemaValueMatches(schema: SchemaRef, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    const value_type = schemaValueType(schema) orelse return false;
    return valueTypeMatches(value_type, string_literal, sort);
}

pub fn schemaValueTypeLabel(schema: SchemaRef) []const u8 {
    const value_type = schemaValueType(schema) orelse return "known property value type";
    return valueTypeLabel(value_type);
}

pub fn valueTypeNameMatches(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    const value_type = resolveValueType(ir, module_id, name) orelse return false;
    return valueTypeMatches(value_type, string_literal, sort);
}

pub fn valueTypeNameLabel(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) []const u8 {
    const value_type = resolveValueType(ir, module_id, name) orelse return "known value type";
    return valueTypeLabel(value_type);
}

pub fn parseValueType(name: []const u8) ?PropertyValueType {
    inline for (std.meta.fields(PropertyValueType)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseShape(name: []const u8) ?ObjectShape {
    inline for (std.meta.fields(ObjectShape)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn isDeclaredShapeAllowed(declared: *const ast.PropertyDecl, shape: ObjectShape) bool {
    if (shape == .unknown or shape == .generic) return true;
    var has_any = false;
    for (declared.shapes.items) |shape_name| {
        if (std.mem.eql(u8, shape_name, "any")) {
            has_any = true;
            continue;
        }
        const allowed = parseShape(shape_name) orelse continue;
        if (allowed == shape) return true;
    }
    if (shape == .document or shape == .page) return false;
    return has_any;
}

pub fn resolveValueType(ir: *const core.Ir, module_id: core.SourceModuleId, name: []const u8) ?PropertyValueType {
    if (parseValueType(name)) |value_type| return value_type;
    if (inferValueType("", name)) |value_type| return value_type;
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const current_id = ir.module_order.items[index];
        if (current_id != module_id) continue;
        const module = ir.moduleById(current_id) orelse return null;
        return resolveValueTypeInProgram(module.program, name);
    }
    return null;
}

fn resolveValueTypeInProgram(program: ast.Program, name: []const u8) ?PropertyValueType {
    for (program.types.items) |decl| {
        if (!std.mem.eql(u8, decl.name, name)) continue;
        return inferValueType(decl.name, decl.body);
    }
    return null;
}

fn inferValueType(name: []const u8, body: []const u8) ?PropertyValueType {
    if (std.mem.eql(u8, body, "string")) {
        if (std.mem.eql(u8, name, "Color")) return .color_string;
        return .string;
    }
    if (std.mem.eql(u8, body, "string | number")) return .scalar_like;
    if (std.mem.indexOf(u8, body, "\"top\"") != null) return .layout_policy;
    if (std.mem.indexOf(u8, body, "\"vector_math\"") != null) return .render_kind;
    if (std.mem.indexOf(u8, body, "\"on\"") != null and std.mem.indexOf(u8, body, "\"off\"") != null) return .wrap_mode;
    if (std.mem.indexOf(u8, body, "\"warn\"") != null) return .fit_policy;
    return parseValueType(body);
}

pub fn shapeLabel(shape: ObjectShape) []const u8 {
    return @tagName(shape);
}

fn valueTypeMatches(value_type: PropertyValueType, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    return switch (value_type) {
        .string => sort == .string,
        .scalar_like => sort == .string or sort == .number,
        .color_string => sort == .string,
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

pub fn valueTypeLabel(kind: PropertyValueType) []const u8 {
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

pub fn shapeForNode(role: ?core.Role, object_kind: ?core.ObjectKind, payload_kind: ?core.PayloadKind) ObjectShape {
    const role_shape = shapeForRole(role);
    if (role_shape != .generic) return role_shape;
    _ = object_kind;
    return switch (payload_kind orelse .text) {
        .text => .text,
        .code => .code,
        .math_text, .math_tex => .math,
        .figure_text => .figure,
        .image_ref => .asset_image,
        .pdf_ref => .asset_pdf,
    };
}

pub fn shapeForRole(role: ?core.Role) ObjectShape {
    const name = role orelse return .generic;
    if (std.mem.eql(u8, name, "panel")) return .panel;
    if (std.mem.eql(u8, name, "rule")) return .rule;
    if (std.mem.eql(u8, name, "group")) return .group;
    if (std.mem.eql(u8, name, "page_number")) return .page_number;
    if (std.mem.eql(u8, name, "toc")) return .toc;
    if (std.mem.eql(u8, name, "code")) return .code;
    if (std.mem.eql(u8, name, "math")) return .math;
    if (std.mem.eql(u8, name, "figure")) return .figure;
    if (std.mem.eql(u8, name, "title")) return .text;
    if (std.mem.eql(u8, name, "subtitle")) return .text;
    if (std.mem.eql(u8, name, "body")) return .text;
    if (std.mem.eql(u8, name, "note")) return .text;
    if (std.mem.eql(u8, name, "byline")) return .text;
    if (std.mem.eql(u8, name, "label")) return .text;
    return .generic;
}
