const std = @import("std");
const core = @import("core");
const types = @import("language_type");

pub const PrimitiveCall = enum {
    pagectx,
    docctx,
    select,
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
    replace,
    foreach,
    fold,
    join,
    first,
    selection_union,
    selection_intersection,
    selection_difference,
    page_index,
    page_count,
    frame_x,
    frame_y,
    frame_width,
    frame_height,
    content,
    prop,
    has_prop,
    prop_eq,
    selection_empty,
    selection_count,
    rewrite_text,
    set_content,
    clear_content,
    append_content,
    object,
    group,
    new_page,
    new_object,
    new_group,
    set_prop,
    extend_render_env,
    style,
    set_style,
    constraints,
    report_error,
    report_warning,
    require_asset_exists,
};

pub const QueryOp = enum {
    self_object,
    previous_page,
    parent_page,
    children,
    descendants,
    document_pages,
    page_objects_by_role,
    document_objects_by_role,
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
    boolean,
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

const primitive_descriptors = [_]PrimitiveDescriptor{
    .{ .op = .pagectx, .name = "pagectx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .page, .summary = "Return the current page context" },
    .{ .op = .docctx, .name = "docctx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .document, .summary = "Return the current document context" },
    .{ .op = .select, .name = "select", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "query_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .selection, .summary = "Build a Selection using the query registry" },
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
    .{ .op = .replace, .name = "replace", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "text", "old", "new" }, .arg_sorts = &.{ .string, .string, .string }, .result_sort = .string, .summary = "Replace all string occurrences" },
    .{ .op = .foreach, .name = "foreach", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "selection", "callback" }, .arg_sorts = &.{ .selection, .function, .any }, .result_sort = .selection, .summary = "Call a callback once for every item in a finite Selection snapshot" },
    .{ .op = .fold, .name = "fold", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "initial", "callback" }, .arg_sorts = &.{ .selection, .string, .function, .any }, .result_sort = .string, .summary = "Fold a finite Selection snapshot with a string accumulator" },
    .{ .op = .join, .name = "join", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "separator", "callback" }, .arg_sorts = &.{ .selection, .string, .function, .any }, .result_sort = .string, .summary = "Map a finite Selection snapshot to strings and join them" },
    .{ .op = .first, .name = "first", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = null, .summary = "Get the first element of a Selection" },
    .{ .op = .selection_union, .name = "selection_union", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .summary = "Return the union of two Selections" },
    .{ .op = .selection_intersection, .name = "selection_intersection", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .summary = "Return the intersection of two Selections" },
    .{ .op = .selection_difference, .name = "selection_difference", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .summary = "Return the left Selection without members from the right Selection" },
    .{ .op = .page_index, .name = "page_index", .min_arity = 1, .max_arity = 1, .arg_names = &.{"page"}, .arg_sorts = &.{.page}, .result_sort = .number, .summary = "Return a page's one-based document index" },
    .{ .op = .page_count, .name = "page_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"document"}, .arg_sorts = &.{.document}, .result_sort = .number, .summary = "Return the number of pages in a document" },
    .{ .op = .frame_x, .name = "frame_x", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .summary = "Return the solved x coordinate for an object" },
    .{ .op = .frame_y, .name = "frame_y", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .summary = "Return the solved y coordinate for an object" },
    .{ .op = .frame_width, .name = "frame_width", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .summary = "Return the solved width for an object" },
    .{ .op = .frame_height, .name = "frame_height", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .summary = "Return the solved height for an object" },
    .{ .op = .content, .name = "content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .string, .summary = "Return an object's textual content" },
    .{ .op = .prop, .name = "prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "default" }, .arg_sorts = &.{ .any, .string, .string }, .result_sort = .string, .summary = "Read a property from a document, page, or object, falling back to a default" },
    .{ .op = .has_prop, .name = "has_prop", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "target", "key" }, .arg_sorts = &.{ .any, .string }, .result_sort = .boolean, .summary = "Return whether a document, page, or object has a property" },
    .{ .op = .prop_eq, .name = "prop_eq", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_sorts = &.{ .any, .string, .string }, .result_sort = .boolean, .summary = "Return whether a property equals a string value" },
    .{ .op = .selection_empty, .name = "selection_empty", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = .boolean, .summary = "Return whether a Selection has no members" },
    .{ .op = .selection_count, .name = "selection_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = .number, .summary = "Return the number of members in a Selection" },
    .{ .op = .rewrite_text, .name = "rewrite_text", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "object", "old", "new" }, .arg_sorts = &.{ .object, .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Rewrite occurrences in an object's textual content" },
    .{ .op = .set_content, .name = "set_content", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "text" }, .arg_sorts = &.{ .object, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Replace an object's textual content" },
    .{ .op = .clear_content, .name = "clear_content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .object, .effect = .builds_graph, .summary = "Clear an object's textual content" },
    .{ .op = .append_content, .name = "append_content", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "text" }, .arg_sorts = &.{ .object, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Append text to an object's textual content" },
    .{ .op = .object, .name = "object", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "content", "role_name", "payload_name" }, .arg_sorts = &.{ .string, .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Low-level object constructor" },
    .{ .op = .group, .name = "group", .min_arity = 1, .max_arity = 255, .arg_names = &.{"child"}, .arg_sorts = &.{.object}, .result_sort = .object, .effect = .builds_graph, .summary = "Create a bbox group from multiple objects" },
    .{ .op = .new_page, .name = "new_page", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "document", "title" }, .arg_sorts = &.{ .document, .string }, .result_sort = .page, .effect = .builds_graph, .summary = "Create a page during an augment pass" },
    .{ .op = .new_object, .name = "new_object", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "page", "content", "role_name", "payload_name" }, .arg_sorts = &.{ .page, .string, .string, .string }, .result_sort = .object, .effect = .builds_graph, .summary = "Create an object on an explicit page during an augment pass" },
    .{ .op = .new_group, .name = "new_group", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "children" }, .arg_sorts = &.{ .page, .selection }, .result_sort = .object, .effect = .builds_graph, .summary = "Create a group on an explicit page during an augment pass" },
    .{ .op = .set_prop, .name = "set_prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_sorts = &.{ .any, .string, .any }, .result_sort = null, .summary = "Attach a property to a document, page, or object" },
    .{ .op = .extend_render_env, .name = "extend_render_env", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "target", "op", "key", "value" }, .arg_sorts = &.{ .any, .string, .string, .string }, .result_sort = null, .summary = "Extend a scoped render environment" },
    .{ .op = .style, .name = "style", .min_arity = 1, .max_arity = 1, .arg_names = &.{"style_name"}, .arg_sorts = &.{.string}, .result_sort = .style, .summary = "Create a style value" },
    .{ .op = .set_style, .name = "set_style", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "target", "style" }, .arg_sorts = &.{ .any, .style }, .result_sort = null, .summary = "Attach a typed style to an object or object selection" },
    .{ .op = .constraints, .name = "constraints", .min_arity = 0, .max_arity = 255, .arg_names = &.{"constraint_set"}, .arg_sorts = &.{.constraints}, .result_sort = .constraints, .effect = .adds_constraints, .summary = "Bundle a ConstraintSet" },
    .{ .op = .report_error, .name = "report_error", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effect = .reports_diagnostics, .summary = "Report error diagnostics from user-defined checks" },
    .{ .op = .report_warning, .name = "report_warning", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effect = .reports_diagnostics, .summary = "Report warning diagnostics from user-defined checks" },
    .{ .op = .require_asset_exists, .name = "require_asset_exists", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .object, .effect = .reports_diagnostics, .summary = "Check that the referenced file for an asset object exists" },
};

const query_descriptors = [_]QueryDescriptor{
    .{ .op = .self_object, .name = "self_object", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Return the object itself as a one-element Selection" },
    .{ .op = .previous_page, .name = "previous_page", .arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .page, .summary = "Select the previous page" },
    .{ .op = .parent_page, .name = "parent_page", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .page, .summary = "Select the parent page" },
    .{ .op = .children, .name = "children", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select direct object children" },
    .{ .op = .descendants, .name = "descendants", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select recursive object descendants" },
    .{ .op = .document_pages, .name = "document_pages", .arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .summary = "Select all pages in the document" },
    .{ .op = .page_objects_by_role, .name = "page_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "Select objects by role within a page" },
    .{ .op = .document_objects_by_role, .name = "document_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .summary = "Select objects by role across the whole document" },
};

pub fn primitiveDescriptors() []const PrimitiveDescriptor {
    return &primitive_descriptors;
}

pub fn queryDescriptors() []const QueryDescriptor {
    return &query_descriptors;
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

pub fn argSortType(sort: ArgSort) ?types.Type {
    return switch (sort) {
        .any => null,
        .document => types.Type.document,
        .page => types.Type.page,
        .object => types.Type.object,
        .selection => types.Type.selection(.any),
        .anchor => types.Type.anchor,
        .function => types.Type.function,
        .style => types.Type.style,
        .string => types.Type.string,
        .number => types.Type.number,
        .boolean => types.Type.boolean,
        .constraints => types.Type.constraints,
    };
}

pub fn primitiveArgType(descriptor: PrimitiveDescriptor, index: usize) ?types.Type {
    const arg_sort = if (descriptor.arg_sorts.len == 0)
        return null
    else if (index < descriptor.arg_sorts.len)
        descriptor.arg_sorts[index]
    else
        descriptor.arg_sorts[descriptor.arg_sorts.len - 1];
    return argSortType(arg_sort);
}

pub fn primitiveResultType(descriptor: PrimitiveDescriptor) ?types.Type {
    if (descriptor.result_sort) |sort| return types.Type.fromSort(sort);
    return null;
}

pub fn primitiveEffects(descriptor: PrimitiveDescriptor) core.EffectSet {
    var set = core.EffectSet.empty();
    switch (descriptor.op) {
        .select, .page_index, .page_count, .content, .prop, .has_prop, .prop_eq => set.insert(.ReadGraph),
        .frame_x, .frame_y, .frame_width, .frame_height => set.insert(.ReadLayout),
        .rewrite_text, .set_content, .clear_content, .append_content => set.insert(.WriteContent),
        .object, .group => set.insert(.CreateNode),
        .new_page => set.insert(.CreatePage),
        .new_object => {
            set.insert(.CreateNode);
            set.insert(.WriteContent);
        },
        .new_group => set.insert(.CreateNode),
        .set_prop, .set_style => set.insert(.WriteProperty),
        .extend_render_env => set.insert(.WriteRenderPolicy),
        .equal, .constraints => set.insert(.WriteConstraint),
        .report_error, .report_warning, .require_asset_exists => set.insert(.EmitDiagnostics),
        else => set.insert(.Pure),
    }
    return set;
}

pub fn queryInputType(descriptor: QueryDescriptor) types.Type {
    return types.Type.fromSort(descriptor.input_sort);
}

pub fn queryOutputType(descriptor: QueryDescriptor) types.Type {
    return switch (descriptor.op) {
        .self_object, .children, .descendants, .page_objects_by_role, .document_objects_by_role => types.Type.selection(.object),
        .document_pages => types.Type.selection(.page),
        .previous_page, .parent_page => types.Type.page,
    };
}
