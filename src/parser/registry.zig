const std = @import("std");
const core = @import("core");

pub const PrimitiveCall = enum {
    pagectx,
    docctx,
    select,
    derive,
    anchor,
    page_anchor,
    equal,
    neg,
    previous_page,
    objects,
    first,
    text,
    object,
    group,
    set_prop,
    style,
    set_style,
    page_number_object,
    toc_object,
    rewrite_text,
    highlight,
    constraints,
    left_inset,
    right_inset,
    top_inset,
    bottom_inset,
    same_left,
    same_right,
    same_top,
    same_bottom,
    below,
    inset_x,
    surround,
};

pub const QueryOp = enum {
    self_object,
    previous_page,
    parent_page,
    document_pages,
    page_objects_by_role,
    document_objects_by_role,
};

pub const TransformOp = enum {
    page_number,
    toc,
    rewrite_text,
    highlight,
};

pub const ArgSort = enum {
    any,
    document,
    page,
    object,
    selection,
    anchor,
    function,
    style,
    string,
    number,
    constraints,
};

pub const PrimitiveDescriptor = struct {
    op: PrimitiveCall,
    name: []const u8,
    min_arity: u8,
    max_arity: u8,
    arg_names: []const []const u8,
    arg_sorts: []const ArgSort,
    result_sort: ?core.SemanticSort,
    summary: []const u8,
};

pub const QueryDescriptor = struct {
    op: QueryOp,
    name: []const u8,
    arity: u8,
    input_name: []const u8,
    input_sort: core.SemanticSort,
    extra_arg_names: []const []const u8,
    extra_arg_sorts: []const ArgSort,
    output_sort: core.SemanticSort,
    summary: []const u8,
};

pub const TransformDescriptor = struct {
    op: TransformOp,
    name: []const u8,
    min_arity: u8,
    max_arity: u8,
    input_name: ?[]const u8,
    input_sort: ?core.SemanticSort,
    extra_arg_names: []const []const u8,
    extra_arg_sorts: []const ArgSort,
    output_sort: core.SemanticSort,
    summary: []const u8,
};

const primitive_descriptors = [_]PrimitiveDescriptor{
    .{ .op = .pagectx, .name = "pagectx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .page, .summary = "現在の page context を返す" },
    .{ .op = .docctx, .name = "docctx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .document, .summary = "現在の document context を返す" },
    .{ .op = .select, .name = "select", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "query_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .selection, .summary = "query registry を使って Selection を作る" },
    .{ .op = .derive, .name = "derive", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "transform_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .object, .summary = "transform registry を使って派生 object を作る" },
    .{ .op = .anchor, .name = "anchor", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "anchor_name" }, .arg_sorts = &.{ .object, .string }, .result_sort = .anchor, .summary = "object anchor を返す" },
    .{ .op = .page_anchor, .name = "page_anchor", .min_arity = 1, .max_arity = 1, .arg_names = &.{ "anchor_name" }, .arg_sorts = &.{ .string }, .result_sort = .anchor, .summary = "page anchor を返す" },
    .{ .op = .equal, .name = "equal", .min_arity = 2, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .anchor, .anchor, .number }, .result_sort = .constraints, .summary = "anchor equality constraint を作る" },
    .{ .op = .neg, .name = "neg", .min_arity = 1, .max_arity = 1, .arg_names = &.{ "value" }, .arg_sorts = &.{ .number }, .result_sort = .number, .summary = "数値の符号を反転する" },
    .{ .op = .previous_page, .name = "previous_page", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .selection, .summary = "互換 sugar: 前ページを選択する" },
    .{ .op = .objects, .name = "objects", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "role_name" }, .arg_sorts = &.{ .page, .string }, .result_sort = .selection, .summary = "互換 sugar: page から role で object を選択する" },
    .{ .op = .first, .name = "first", .min_arity = 1, .max_arity = 1, .arg_names = &.{ "selection" }, .arg_sorts = &.{ .selection }, .result_sort = null, .summary = "Selection の先頭要素を取り出す" },
    .{ .op = .text, .name = "text", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "content", "role_name" }, .arg_sorts = &.{ .string, .string }, .result_sort = .object, .summary = "互換 sugar: text object を作る" },
    .{ .op = .object, .name = "object", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "content", "role_name", "payload_name" }, .arg_sorts = &.{ .string, .string, .string }, .result_sort = .object, .summary = "低水準 object constructor" },
    .{ .op = .group, .name = "group", .min_arity = 1, .max_arity = 255, .arg_names = &.{ "child" }, .arg_sorts = &.{.object}, .result_sort = .object, .summary = "複数 object の bbox group を作る" },
    .{ .op = .set_prop, .name = "set_prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "object", "key", "value" }, .arg_sorts = &.{ .object, .string, .string }, .result_sort = .object, .summary = "object property を付与する" },
    .{ .op = .style, .name = "style", .min_arity = 1, .max_arity = 1, .arg_names = &.{ "style_name" }, .arg_sorts = &.{.string}, .result_sort = .style, .summary = "style 値を作る" },
    .{ .op = .set_style, .name = "set_style", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "style" }, .arg_sorts = &.{ .object, .style }, .result_sort = .object, .summary = "object に typed style を付与する" },
    .{ .op = .page_number_object, .name = "page_number_object", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .object, .summary = "互換 sugar: page number object を作る" },
    .{ .op = .toc_object, .name = "toc_object", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .object, .summary = "互換 sugar: ToC object を作る" },
    .{ .op = .rewrite_text, .name = "rewrite_text", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "base", "old", "new" }, .arg_sorts = &.{ .object, .string, .string }, .result_sort = .object, .summary = "互換 sugar: text rewrite transform を適用する" },
    .{ .op = .highlight, .name = "highlight", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "base", "note" }, .arg_sorts = &.{ .any, .string }, .result_sort = .object, .summary = "互換 sugar: highlight transform を適用する" },
    .{ .op = .constraints, .name = "constraints", .min_arity = 0, .max_arity = 255, .arg_names = &.{ "constraint_set" }, .arg_sorts = &.{ .constraints }, .result_sort = .constraints, .summary = "ConstraintSet を束ねる" },
    .{ .op = .left_inset, .name = "left_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: left inset constraint" },
    .{ .op = .right_inset, .name = "right_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: right inset constraint" },
    .{ .op = .top_inset, .name = "top_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: top inset constraint" },
    .{ .op = .bottom_inset, .name = "bottom_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: bottom inset constraint" },
    .{ .op = .same_left, .name = "same_left", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: left anchor equality" },
    .{ .op = .same_right, .name = "same_right", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: right anchor equality" },
    .{ .op = .same_top, .name = "same_top", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: top anchor equality" },
    .{ .op = .same_bottom, .name = "same_bottom", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: bottom anchor equality" },
    .{ .op = .below, .name = "below", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "gap" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "互換 sugar: vertical stacking constraint" },
    .{ .op = .inset_x, .name = "inset_x", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "object", "left", "right" }, .arg_sorts = &.{ .object, .number, .number }, .result_sort = .constraints, .summary = "互換 sugar: left/right inset bundle" },
    .{ .op = .surround, .name = "surround", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "panel", "inner", "pad_x", "pad_y" }, .arg_sorts = &.{ .object, .object, .number, .number }, .result_sort = .constraints, .summary = "互換 sugar: panel surround constraint bundle" },
};

const query_descriptors = [_]QueryDescriptor{
    .{ .op = .self_object, .name = "self_object", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "object 自身を 1 要素の Selection として返す" },
    .{ .op = .previous_page, .name = "previous_page", .arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "前ページを選択する" },
    .{ .op = .parent_page, .name = "parent_page", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "親 page を選択する" },
    .{ .op = .document_pages, .name = "document_pages", .arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "document 内の page 群を選択する" },
    .{ .op = .page_objects_by_role, .name = "page_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{ "role_name" }, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "page 内の object を role で選択する" },
    .{ .op = .document_objects_by_role, .name = "document_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{ "role_name" }, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "document 全体の object を role で選択する" },
};

const transform_descriptors = [_]TransformDescriptor{
    .{ .op = .page_number, .name = "page_number", .min_arity = 2, .max_arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .object, .summary = "page から page number object を生成する" },
    .{ .op = .toc, .name = "toc", .min_arity = 2, .max_arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .object, .summary = "document から ToC object を生成する" },
    .{ .op = .rewrite_text, .name = "rewrite_text", .min_arity = 4, .max_arity = 4, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{ "old", "new" }, .extra_arg_sorts = &.{ .string, .string }, .output_sort = .object, .summary = "text-based rewrite を適用する" },
    .{ .op = .highlight, .name = "highlight", .min_arity = 3, .max_arity = 3, .input_name = "base", .input_sort = null, .extra_arg_names = &.{ "note" }, .extra_arg_sorts = &.{.string}, .output_sort = .object, .summary = "object または selection を highlight する" },
};

pub fn primitiveDescriptors() []const PrimitiveDescriptor {
    return &primitive_descriptors;
}

pub fn queryDescriptors() []const QueryDescriptor {
    return &query_descriptors;
}

pub fn transformDescriptors() []const TransformDescriptor {
    return &transform_descriptors;
}

pub fn lookupPrimitiveCall(name: []const u8) ?PrimitiveDescriptor {
    inline for (primitive_descriptors) |descriptor| {
        if (std.mem.eql(u8, name, descriptor.name)) return descriptor;
    }
    return null;
}

pub fn lookupQueryOp(name: []const u8) ?QueryDescriptor {
    inline for (query_descriptors) |descriptor| {
        if (std.mem.eql(u8, name, descriptor.name)) return descriptor;
    }
    return null;
}

pub fn lookupTransformOp(name: []const u8) ?TransformDescriptor {
    inline for (transform_descriptors) |descriptor| {
        if (std.mem.eql(u8, name, descriptor.name)) return descriptor;
    }
    return null;
}
