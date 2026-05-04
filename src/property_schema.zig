const std = @import("std");
const core = @import("core");

pub const ObjectShape = enum {
    unknown,
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
};

pub const PropertySchema = struct {
    key: []const u8,
    value_type: PropertyValueType,
    allowed_shapes: []const ObjectShape,
};

const any_shapes = [_]ObjectShape{};
const text_shapes = [_]ObjectShape{ .text, .code, .math, .figure, .page_number, .toc };
const asset_shapes = [_]ObjectShape{ .asset_image, .asset_pdf };
const chrome_shapes = [_]ObjectShape{ .panel, .rule };

const property_schemas = [_]PropertySchema{
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

pub fn isShapeAllowed(schema: PropertySchema, shape: ObjectShape) bool {
    if (shape == .unknown or shape == .generic) return true;
    if (schema.allowed_shapes.len == 0) return true;
    for (schema.allowed_shapes) |allowed| {
        if (allowed == shape) return true;
    }
    return false;
}

pub fn shapeLabel(shape: ObjectShape) []const u8 {
    return @tagName(shape);
}

pub fn valueMatches(schema: PropertySchema, string_literal: ?[]const u8, sort: core.SemanticSort) bool {
    return switch (schema.value_type) {
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
