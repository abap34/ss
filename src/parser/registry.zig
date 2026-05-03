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
    add,
    sub,
    mul,
    div,
    min,
    max,
    str,
    concat,
    previous_page,
    objects,
    first,
    text,
    object,
    group,
    set_prop,
    layout_v,
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
    report_error,
    report_warning,
    require_asset_exists,
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
    effect: core.FunctionEffect = .pure,
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
    .{ .op = .pagectx, .name = "pagectx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .page, .summary = "Return the current page context" },
    .{ .op = .docctx, .name = "docctx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .document, .summary = "Return the current document context" },
    .{ .op = .select, .name = "select", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "query_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .selection, .summary = "Build a Selection using the query registry" },
    .{ .op = .derive, .name = "derive", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "transform_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .object, .summary = "Build a derived object using the transform registry" },
    .{ .op = .anchor, .name = "anchor", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "anchor_name" }, .arg_sorts = &.{ .object, .string }, .result_sort = .anchor, .summary = "Return an object anchor" },
    .{ .op = .page_anchor, .name = "page_anchor", .min_arity = 1, .max_arity = 1, .arg_names = &.{"anchor_name"}, .arg_sorts = &.{.string}, .result_sort = .anchor, .summary = "Return a page anchor" },
    .{ .op = .equal, .name = "equal", .min_arity = 2, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .anchor, .anchor, .number }, .result_sort = .constraints, .summary = "Create an anchor equality constraint" },
    .{ .op = .neg, .name = "neg", .min_arity = 1, .max_arity = 1, .arg_names = &.{"value"}, .arg_sorts = &.{.number}, .result_sort = .number, .summary = "Negate a number" },
    .{ .op = .add, .name = "add", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Add two numbers" },
    .{ .op = .sub, .name = "sub", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Subtract two numbers" },
    .{ .op = .mul, .name = "mul", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Multiply two numbers" },
    .{ .op = .div, .name = "div", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Divide two numbers" },
    .{ .op = .min, .name = "min", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Return the smaller number" },
    .{ .op = .max, .name = "max", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .number, .number }, .result_sort = .number, .summary = "Return the larger number" },
    .{ .op = .str, .name = "str", .min_arity = 1, .max_arity = 1, .arg_names = &.{"value"}, .arg_sorts = &.{.number}, .result_sort = .string, .summary = "Convert a number to string" },
    .{ .op = .concat, .name = "concat", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .string, .string }, .result_sort = .string, .summary = "Concatenate two strings" },
    .{ .op = .previous_page, .name = "previous_page", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .selection, .summary = "Compatibility sugar: select the previous page" },
    .{ .op = .objects, .name = "objects", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "role_name" }, .arg_sorts = &.{ .page, .string }, .result_sort = .selection, .summary = "Compatibility sugar: select objects by role from a page" },
    .{ .op = .first, .name = "first", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = null, .summary = "Get the first element of a Selection" },
    .{ .op = .text, .name = "text", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "content", "role_name" }, .arg_sorts = &.{ .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Compatibility sugar: create a text object" },
    .{ .op = .object, .name = "object", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "content", "role_name", "payload_name" }, .arg_sorts = &.{ .string, .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Low-level object constructor" },
    .{ .op = .group, .name = "group", .min_arity = 1, .max_arity = 255, .arg_names = &.{"child"}, .arg_sorts = &.{.object}, .result_sort = .object, .effect = .builds_graph, .summary = "Create a bbox group from multiple objects" },
    .{ .op = .set_prop, .name = "set_prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "object", "key", "value" }, .arg_sorts = &.{ .object, .string, .any }, .result_sort = .object, .summary = "Attach a property to an object" },
    .{ .op = .layout_v, .name = "layout_v", .min_arity = 1, .max_arity = 1, .arg_names = &.{"policy"}, .arg_sorts = &.{.string}, .result_sort = .page, .effect = .builds_graph, .summary = "Set the current page vertical fallback policy" },
    .{ .op = .style, .name = "style", .min_arity = 1, .max_arity = 1, .arg_names = &.{"style_name"}, .arg_sorts = &.{.string}, .result_sort = .style, .summary = "Create a style value" },
    .{ .op = .set_style, .name = "set_style", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "style" }, .arg_sorts = &.{ .object, .style }, .result_sort = .object, .summary = "Attach a typed style to an object" },
    .{ .op = .page_number_object, .name = "page_number_object", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .object, .effect = .builds_graph, .summary = "Compatibility sugar: create page-number object" },
    .{ .op = .toc_object, .name = "toc_object", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .object, .effect = .builds_graph, .summary = "Compatibility sugar: create a ToC object" },
    .{ .op = .rewrite_text, .name = "rewrite_text", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "base", "old", "new" }, .arg_sorts = &.{ .object, .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Compatibility sugar: apply text rewrite transform" },
    .{ .op = .highlight, .name = "highlight", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "base", "note" }, .arg_sorts = &.{ .any, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Compatibility sugar: apply highlight transform" },
    .{ .op = .constraints, .name = "constraints", .min_arity = 0, .max_arity = 255, .arg_names = &.{"constraint_set"}, .arg_sorts = &.{.constraints}, .result_sort = .constraints, .effect = .adds_constraints, .summary = "Bundle a ConstraintSet" },
    .{ .op = .left_inset, .name = "left_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: left inset constraint" },
    .{ .op = .right_inset, .name = "right_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: right inset constraint" },
    .{ .op = .top_inset, .name = "top_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: top inset constraint" },
    .{ .op = .bottom_inset, .name = "bottom_inset", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "inset" }, .arg_sorts = &.{ .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: bottom inset constraint" },
    .{ .op = .same_left, .name = "same_left", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: left anchor equality" },
    .{ .op = .same_right, .name = "same_right", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: right anchor equality" },
    .{ .op = .same_top, .name = "same_top", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: top anchor equality" },
    .{ .op = .same_bottom, .name = "same_bottom", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: bottom anchor equality" },
    .{ .op = .below, .name = "below", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "source", "gap" }, .arg_sorts = &.{ .object, .object, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: vertical stacking constraint" },
    .{ .op = .inset_x, .name = "inset_x", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "object", "left", "right" }, .arg_sorts = &.{ .object, .number, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: left/right inset bundle" },
    .{ .op = .surround, .name = "surround", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "panel", "inner", "pad_x", "pad_y" }, .arg_sorts = &.{ .object, .object, .number, .number }, .result_sort = .constraints, .summary = "Compatibility sugar: panel surround constraint bundle" },
    .{ .op = .report_error, .name = "report_error", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effect = .reports_diagnostics, .summary = "Report error diagnostics from user-defined checks" },
    .{ .op = .report_warning, .name = "report_warning", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effect = .reports_diagnostics, .summary = "Report warning diagnostics from user-defined checks" },
    .{ .op = .require_asset_exists, .name = "require_asset_exists", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .object, .effect = .reports_diagnostics, .summary = "Check that the referenced file for an asset object exists" },
};

const query_descriptors = [_]QueryDescriptor{
    .{ .op = .self_object, .name = "self_object", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Return the object itself as a one-element Selection" },
    .{ .op = .previous_page, .name = "previous_page", .arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select the previous page" },
    .{ .op = .parent_page, .name = "parent_page", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select the parent page" },
    .{ .op = .document_pages, .name = "document_pages", .arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select all pages in the document" },
    .{ .op = .page_objects_by_role, .name = "page_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "Select objects by role within a page" },
    .{ .op = .document_objects_by_role, .name = "document_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "Select objects by role across the whole document" },
};

const transform_descriptors = [_]TransformDescriptor{
    .{ .op = .page_number, .name = "page_number", .min_arity = 2, .max_arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .object, .summary = "Generate a page number object from a page" },
    .{ .op = .toc, .name = "toc", .min_arity = 2, .max_arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .object, .summary = "Generate a ToC object from a document" },
    .{ .op = .rewrite_text, .name = "rewrite_text", .min_arity = 4, .max_arity = 4, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{ "old", "new" }, .extra_arg_sorts = &.{ .string, .string }, .output_sort = .object, .summary = "Apply text-based rewrite" },
    .{ .op = .highlight, .name = "highlight", .min_arity = 3, .max_arity = 3, .input_name = "base", .input_sort = null, .extra_arg_names = &.{"note"}, .extra_arg_sorts = &.{.string}, .output_sort = .object, .summary = "Highlight an object or a selection" },
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
