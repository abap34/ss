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

pub const PropertySchema = struct {
    key: []const u8,
    value_type: PropertyValueType,
    allowed_shapes: []const ObjectShape,
};

pub const SchemaRef = union(enum) {
    builtin: PropertySchema,
    declared: *const ast.PropertyDecl,
};

const any_shapes = [_]ObjectShape{};
const layout_owner_shapes = [_]ObjectShape{ .document, .page };
const text_shapes = [_]ObjectShape{ .text, .code, .math, .figure, .page_number, .toc };
const asset_shapes = [_]ObjectShape{ .asset_image, .asset_pdf };
const chrome_shapes = [_]ObjectShape{ .panel, .rule };

const property_schemas = [_]PropertySchema{
    .{ .key = "layout_v", .value_type = .layout_policy, .allowed_shapes = &layout_owner_shapes },
    .{ .key = "render_kind", .value_type = .render_kind, .allowed_shapes = &any_shapes },
    .{ .key = "wrap", .value_type = .wrap_mode, .allowed_shapes = &any_shapes },
    .{ .key = "text_font", .value_type = .string, .allowed_shapes = &text_shapes },
    .{ .key = "text_bold_font", .value_type = .string, .allowed_shapes = &text_shapes },
    .{ .key = "text_italic_font", .value_type = .string, .allowed_shapes = &text_shapes },
    .{ .key = "text_code_font", .value_type = .string, .allowed_shapes = &text_shapes },
    .{ .key = "text_size", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_line_height", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "text_link_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "text_link_underline_width", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_link_underline_offset", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_inline_math_height_factor", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_inline_math_spacing", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_block_gap", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_list_indent", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_font_size", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_line_height", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_pad_x", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_pad_y", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_fill", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_stroke", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_line_width", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_markdown_code_radius", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_cjk_bold_passes", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "text_cjk_bold_dx", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "code_plain_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "code_keyword_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "code_comment_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "code_string_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "layout_font_size", .value_type = .scalar_like, .allowed_shapes = &any_shapes },
    .{ .key = "layout_line_height", .value_type = .scalar_like, .allowed_shapes = &any_shapes },
    .{ .key = "layout_spacing_after", .value_type = .scalar_like, .allowed_shapes = &any_shapes },
    .{ .key = "layout_x", .value_type = .scalar_like, .allowed_shapes = &any_shapes },
    .{ .key = "layout_right_inset", .value_type = .scalar_like, .allowed_shapes = &any_shapes },
    .{ .key = "math_scale", .value_type = .scalar_like, .allowed_shapes = &.{.math} },
    .{ .key = "asset_scale", .value_type = .scalar_like, .allowed_shapes = &asset_shapes },
    .{ .key = "language", .value_type = .string, .allowed_shapes = &text_shapes },
    .{ .key = "style", .value_type = .string, .allowed_shapes = &any_shapes },
    .{ .key = "fit", .value_type = .fit_policy, .allowed_shapes = &any_shapes },
    .{ .key = "chrome_fill", .value_type = .color_string, .allowed_shapes = &chrome_shapes },
    .{ .key = "chrome_stroke", .value_type = .color_string, .allowed_shapes = &chrome_shapes },
    .{ .key = "chrome_line_width", .value_type = .scalar_like, .allowed_shapes = &chrome_shapes },
    .{ .key = "chrome_radius", .value_type = .scalar_like, .allowed_shapes = &chrome_shapes },
    .{ .key = "underline_color", .value_type = .color_string, .allowed_shapes = &text_shapes },
    .{ .key = "underline_width", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "underline_offset", .value_type = .scalar_like, .allowed_shapes = &text_shapes },
    .{ .key = "rule_stroke", .value_type = .color_string, .allowed_shapes = &.{.rule} },
    .{ .key = "rule_line_width", .value_type = .scalar_like, .allowed_shapes = &.{.rule} },
    .{ .key = "rule_dash", .value_type = .string, .allowed_shapes = &.{.rule} },
};

pub fn propertySchemas() []const PropertySchema {
    return &property_schemas;
}

pub fn lookup(key: []const u8) ?PropertySchema {
    inline for (property_schemas) |schema| {
        if (std.mem.eql(u8, key, schema.key)) return schema;
    }
    return null;
}

pub fn lookupInIr(ir: *const core.Ir, key: []const u8) ?SchemaRef {
    var index = ir.module_order.items.len;
    while (index > 0) {
        index -= 1;
        const module = ir.moduleById(ir.module_order.items[index]) orelse continue;
        if (lookupInProgram(module.program, key)) |property| return .{ .declared = property };
    }
    if (lookup(key)) |schema| return .{ .builtin = schema };
    return null;
}

pub fn lookupRef(key: []const u8) ?SchemaRef {
    if (lookup(key)) |schema| return .{ .builtin = schema };
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

pub fn schemaKey(schema: SchemaRef) []const u8 {
    return switch (schema) {
        .builtin => |builtin| builtin.key,
        .declared => |declared| declared.key,
    };
}

pub fn schemaValueType(schema: SchemaRef) ?PropertyValueType {
    return switch (schema) {
        .builtin => |builtin| builtin.value_type,
        .declared => |declared| parseValueType(declared.value_type),
    };
}

pub fn isSchemaShapeAllowed(schema: SchemaRef, shape: ObjectShape) bool {
    return switch (schema) {
        .builtin => |builtin| isShapeAllowed(builtin, shape),
        .declared => |declared| isDeclaredShapeAllowed(declared, shape),
    };
}

pub fn schemaValueMatches(schema: SchemaRef, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    const value_type = schemaValueType(schema) orelse return false;
    return valueTypeMatches(value_type, string_literal, sort);
}

pub fn schemaValueTypeLabel(schema: SchemaRef) []const u8 {
    const value_type = schemaValueType(schema) orelse return "known property value type";
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

pub fn isShapeAllowed(schema: PropertySchema, shape: ObjectShape) bool {
    if (shape == .unknown or shape == .generic) return true;
    for (schema.allowed_shapes) |allowed| {
        if (allowed == shape) return true;
    }
    if (shape == .document or shape == .page) return false;
    if (schema.allowed_shapes.len == 0) return true;
    return false;
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

pub fn shapeLabel(shape: ObjectShape) []const u8 {
    return @tagName(shape);
}

pub fn valueMatches(schema: PropertySchema, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    return valueTypeMatches(schema.value_type, string_literal, sort);
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
    if (role) |name| {
        if (std.mem.eql(u8, name, "panel")) return .panel;
        if (std.mem.eql(u8, name, "rule")) return .rule;
        if (std.mem.eql(u8, name, "group")) return .group;
        if (std.mem.eql(u8, name, "page_number")) return .page_number;
        if (std.mem.eql(u8, name, "toc")) return .toc;
    }
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
