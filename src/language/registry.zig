const std = @import("std");
const types = @import("language_type");

const Type = types.Type;

pub const PrimitiveCall = enum {
    pagectx,
    docctx,
    select,
    anchor,
    page_anchor,
    equal,
    logical_not,
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
    readlines,
    foreach,
    foreach_enumerate,
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
    emit_metadata,
    metadata_in_document,
    metadata_on_page,
    metadata_content,
    metadata_kind,
    metadata_page,
    prop,
    has_prop,
    prop_eq,
    selection_empty,
    selection_count,
    set_content,
    group,
    new_page,
    new,
    place_on,
    set_prop,
    extend_render_env,
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

pub const PrimitiveDescriptor = struct {
    op: PrimitiveCall,
    name: []const u8,
    min_arity: u8,
    max_arity: u8,
    arg_names: []const []const u8,
    arg_types: []const Type,
    result_type: ?Type,
    result_policy: PrimitiveResultPolicy = .declared,
    result_arg_index: usize = 0,
    context: PrimitiveContext = .any,
    callback: ?PrimitiveCallbackSpec = null,
    places_objects: bool = false,
    summary: []const u8,
};

pub const PrimitiveContext = enum {
    any,
    page,
};

pub const PrimitiveResultPolicy = enum {
    declared,
    first_selection_item,
    first_arg,
    selection_algebra,
    select_query,
    target_arg,
    metadata_selection,
    group_object,
    object_from_role_arg,
};

pub const PrimitiveCallbackSpec = struct {
    function_arg_index: usize,
    supplied_arg_count: usize,
    expected_result_type: ?Type = null,
};

pub const QueryDescriptor = struct {
    op: QueryOp,
    name: []const u8,
    arity: u8,
    input_name: []const u8,
    input_type: Type,
    extra_arg_names: []const []const u8,
    extra_arg_types: []const Type,
    output_type: Type,
    summary: []const u8,
};

const primitive_descriptors = [_]PrimitiveDescriptor{
    .{ .op = .pagectx, .name = "pagectx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_types = &.{}, .result_type = Type.page, .context = .page, .summary = "Return the current page context" },
    .{ .op = .docctx, .name = "docctx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_types = &.{}, .result_type = Type.document, .summary = "Return the current document context" },
    .{ .op = .select, .name = "select", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "query_name" }, .arg_types = &.{ Type.any, Type.string }, .result_type = Type.selection(.any), .result_policy = .select_query, .summary = "Build a Selection using the query registry" },
    .{ .op = .anchor, .name = "anchor", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "anchor_name" }, .arg_types = &.{ Type.object, Type.string }, .result_type = Type.anchor, .summary = "Return an object anchor" },
    .{ .op = .page_anchor, .name = "page_anchor", .min_arity = 1, .max_arity = 1, .arg_names = &.{"anchor_name"}, .arg_types = &.{Type.string}, .result_type = Type.anchor, .summary = "Return a page anchor" },
    .{ .op = .equal, .name = "equal", .min_arity = 2, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_types = &.{ Type.anchor, Type.anchor, Type.number }, .result_type = Type.constraints, .summary = "Create an anchor equality constraint" },
    .{ .op = .logical_not, .name = "not", .min_arity = 1, .max_arity = 1, .arg_names = &.{"value"}, .arg_types = &.{Type.boolean}, .result_type = Type.boolean, .summary = "Negate a boolean value" },
    .{ .op = .neg, .name = "neg", .min_arity = 1, .max_arity = 1, .arg_names = &.{"value"}, .arg_types = &.{Type.number}, .result_type = Type.number, .summary = "Negate a number" },
    .{ .op = .add, .name = "add", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Add two numbers" },
    .{ .op = .sub, .name = "sub", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Subtract two numbers" },
    .{ .op = .mul, .name = "mul", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Multiply two numbers" },
    .{ .op = .div, .name = "div", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Divide two numbers" },
    .{ .op = .min, .name = "min", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Return the smaller number" },
    .{ .op = .max, .name = "max", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.number, Type.number }, .result_type = Type.number, .summary = "Return the larger number" },
    .{ .op = .str, .name = "str", .min_arity = 1, .max_arity = 1, .arg_names = &.{"value"}, .arg_types = &.{Type.number}, .result_type = Type.string, .summary = "Convert a number to string" },
    .{ .op = .concat, .name = "concat", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.string, Type.string }, .result_type = Type.string, .summary = "Concatenate two strings" },
    .{ .op = .replace, .name = "replace", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "text", "old", "new" }, .arg_types = &.{ Type.string, Type.string, Type.string }, .result_type = Type.string, .summary = "Replace all string occurrences" },
    .{ .op = .readlines, .name = "readlines", .min_arity = 1, .max_arity = 1, .arg_names = &.{"path"}, .arg_types = &.{Type.string}, .result_type = Type.string, .summary = "Read a text file from the asset base directory" },
    .{ .op = .foreach, .name = "foreach", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "selection", "callback" }, .arg_types = &.{ Type.selection(.any), Type.function, Type.any }, .result_type = Type.selection(.any), .result_policy = .first_arg, .callback = .{ .function_arg_index = 1, .supplied_arg_count = 1 }, .summary = "Call a callback once for every item in a finite Selection snapshot" },
    .{ .op = .foreach_enumerate, .name = "foreach_enumerate", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "selection", "callback" }, .arg_types = &.{ Type.selection(.any), Type.function, Type.any }, .result_type = Type.selection(.any), .result_policy = .first_arg, .callback = .{ .function_arg_index = 1, .supplied_arg_count = 2 }, .summary = "Call a callback once for every item in a finite Selection snapshot with a one-based index" },
    .{ .op = .fold, .name = "fold", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "initial", "callback" }, .arg_types = &.{ Type.selection(.any), Type.string, Type.function, Type.any }, .result_type = Type.string, .callback = .{ .function_arg_index = 2, .supplied_arg_count = 2, .expected_result_type = Type.string }, .summary = "Fold a finite Selection snapshot with a string accumulator" },
    .{ .op = .join, .name = "join", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "separator", "callback" }, .arg_types = &.{ Type.selection(.any), Type.string, Type.function, Type.any }, .result_type = Type.string, .callback = .{ .function_arg_index = 2, .supplied_arg_count = 1, .expected_result_type = Type.string }, .summary = "Map a finite Selection snapshot to strings and join them" },
    .{ .op = .first, .name = "first", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_types = &.{Type.selection(.any)}, .result_type = null, .result_policy = .first_selection_item, .summary = "Get the first element of a Selection" },
    .{ .op = .selection_union, .name = "selection_union", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.selection(.any), Type.selection(.any) }, .result_type = Type.selection(.any), .result_policy = .selection_algebra, .summary = "Return the union of two Selections" },
    .{ .op = .selection_intersection, .name = "selection_intersection", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.selection(.any), Type.selection(.any) }, .result_type = Type.selection(.any), .result_policy = .selection_algebra, .summary = "Return the intersection of two Selections" },
    .{ .op = .selection_difference, .name = "selection_difference", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_types = &.{ Type.selection(.any), Type.selection(.any) }, .result_type = Type.selection(.any), .result_policy = .selection_algebra, .summary = "Return the left Selection without members from the right Selection" },
    .{ .op = .page_index, .name = "page_index", .min_arity = 1, .max_arity = 1, .arg_names = &.{"page"}, .arg_types = &.{Type.page}, .result_type = Type.number, .summary = "Return a page's one-based document index" },
    .{ .op = .page_count, .name = "page_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"document"}, .arg_types = &.{Type.document}, .result_type = Type.number, .summary = "Return the number of pages in a document" },
    .{ .op = .frame_x, .name = "frame_x", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.number, .summary = "Return the solved x coordinate for an object" },
    .{ .op = .frame_y, .name = "frame_y", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.number, .summary = "Return the solved y coordinate for an object" },
    .{ .op = .frame_width, .name = "frame_width", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.number, .summary = "Return the solved width for an object" },
    .{ .op = .frame_height, .name = "frame_height", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.number, .summary = "Return the solved height for an object" },
    .{ .op = .content, .name = "content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.string, .summary = "Return an object's textual content" },
    .{ .op = .emit_metadata, .name = "emit_metadata", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "kind", "value" }, .arg_types = &.{ Type.any, Type.string, Type.string }, .result_type = Type.metadata, .summary = "Append a metadata fact associated with a document, page, or object" },
    .{ .op = .metadata_in_document, .name = "metadata_in_document", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "document", "kind" }, .arg_types = &.{ Type.document, Type.string }, .result_type = Type.selection(.any), .result_policy = .metadata_selection, .summary = "Select metadata facts by kind across the whole document" },
    .{ .op = .metadata_on_page, .name = "metadata_on_page", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "kind" }, .arg_types = &.{ Type.page, Type.string }, .result_type = Type.selection(.any), .result_policy = .metadata_selection, .summary = "Select metadata facts by kind on one page" },
    .{ .op = .metadata_content, .name = "metadata_content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_types = &.{Type.metadata}, .result_type = Type.string, .summary = "Return a metadata fact's textual value" },
    .{ .op = .metadata_kind, .name = "metadata_kind", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_types = &.{Type.metadata}, .result_type = Type.string, .summary = "Return a metadata fact's kind" },
    .{ .op = .metadata_page, .name = "metadata_page", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_types = &.{Type.metadata}, .result_type = Type.page, .summary = "Return the page associated with a metadata fact" },
    .{ .op = .prop, .name = "prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "default" }, .arg_types = &.{ Type.any, Type.string, Type.string }, .result_type = Type.string, .summary = "Read a property from a document, page, or object, falling back to a default" },
    .{ .op = .has_prop, .name = "has_prop", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "target", "key" }, .arg_types = &.{ Type.any, Type.string }, .result_type = Type.boolean, .summary = "Return whether a document, page, or object has a property" },
    .{ .op = .prop_eq, .name = "prop_eq", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_types = &.{ Type.any, Type.string, Type.string }, .result_type = Type.boolean, .summary = "Return whether a property equals a string value" },
    .{ .op = .selection_empty, .name = "selection_empty", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_types = &.{Type.selection(.any)}, .result_type = Type.boolean, .summary = "Return whether a Selection has no members" },
    .{ .op = .selection_count, .name = "selection_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_types = &.{Type.selection(.any)}, .result_type = Type.number, .summary = "Return the number of members in a Selection" },
    .{ .op = .set_content, .name = "set_content", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "text" }, .arg_types = &.{ Type.object, Type.string }, .result_type = Type.object, .result_policy = .first_arg, .summary = "Replace an object's textual content" },
    .{ .op = .group, .name = "group", .min_arity = 1, .max_arity = 255, .arg_names = &.{"child"}, .arg_types = &.{Type.object}, .result_type = Type.object, .result_policy = .group_object, .summary = "Create a bbox group from multiple objects" },
    .{ .op = .new_page, .name = "new_page", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "document", "title" }, .arg_types = &.{ Type.document, Type.string }, .result_type = Type.page, .summary = "Create a page in the scheduled document graph" },
    .{ .op = .new, .name = "new", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "content", "role_name", "payload_name" }, .arg_types = &.{ Type.string, Type.string, Type.string }, .result_type = Type.object, .result_policy = .object_from_role_arg, .summary = "Create an unplaced object" },
    .{ .op = .place_on, .name = "place_on!", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "object" }, .arg_types = &.{ Type.page, Type.object }, .result_type = Type.object, .result_policy = .target_arg, .result_arg_index = 1, .places_objects = true, .summary = "Place an object on a page" },
    .{ .op = .set_prop, .name = "set_prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_types = &.{ Type.any, Type.string, Type.any }, .result_type = null, .result_policy = .target_arg, .summary = "Attach a property to a document, page, or object" },
    .{ .op = .extend_render_env, .name = "extend_render_env", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "target", "op", "key", "value" }, .arg_types = &.{ Type.any, Type.string, Type.string, Type.string }, .result_type = null, .result_policy = .target_arg, .summary = "Extend a scoped render environment" },
    .{ .op = .constraints, .name = "constraints", .min_arity = 0, .max_arity = 255, .arg_names = &.{"constraint_set"}, .arg_types = &.{Type.constraints}, .result_type = Type.constraints, .summary = "Bundle a ConstraintSet" },
    .{ .op = .report_error, .name = "report_error", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_types = &.{Type.string}, .result_type = Type.string, .summary = "Report error diagnostics from user-defined checks" },
    .{ .op = .report_warning, .name = "report_warning", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_types = &.{Type.string}, .result_type = Type.string, .summary = "Report warning diagnostics from user-defined checks" },
    .{ .op = .require_asset_exists, .name = "require_asset_exists", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_types = &.{Type.object}, .result_type = Type.object, .summary = "Check that the referenced file for an asset object exists" },
};

const query_descriptors = [_]QueryDescriptor{
    .{ .op = .self_object, .name = "self_object", .arity = 2, .input_name = "base", .input_type = Type.object, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.selection(.object), .summary = "Return the object itself as a one-element Selection" },
    .{ .op = .previous_page, .name = "previous_page", .arity = 2, .input_name = "base", .input_type = Type.page, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.page, .summary = "Select the previous page" },
    .{ .op = .parent_page, .name = "parent_page", .arity = 2, .input_name = "base", .input_type = Type.object, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.page, .summary = "Select the parent page" },
    .{ .op = .children, .name = "children", .arity = 2, .input_name = "base", .input_type = Type.object, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.selection(.object), .summary = "Select direct object children" },
    .{ .op = .descendants, .name = "descendants", .arity = 2, .input_name = "base", .input_type = Type.object, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.selection(.object), .summary = "Select recursive object descendants" },
    .{ .op = .document_pages, .name = "document_pages", .arity = 2, .input_name = "base", .input_type = Type.document, .extra_arg_names = &.{}, .extra_arg_types = &.{}, .output_type = Type.selection(.page), .summary = "Select all pages in the document" },
    .{ .op = .page_objects_by_role, .name = "page_objects_by_role", .arity = 3, .input_name = "base", .input_type = Type.page, .extra_arg_names = &.{"role_name"}, .extra_arg_types = &.{Type.string}, .output_type = Type.selection(.object), .summary = "Select objects by role within a page" },
    .{ .op = .document_objects_by_role, .name = "document_objects_by_role", .arity = 3, .input_name = "base", .input_type = Type.document, .extra_arg_names = &.{"role_name"}, .extra_arg_types = &.{Type.string}, .output_type = Type.selection(.object), .summary = "Select objects by role across the whole document" },
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

pub fn validateQueryArity(descriptor: QueryDescriptor, actual: usize) !void {
    if (actual != descriptor.arity) return error.InvalidArity;
}

pub fn primitiveArgType(descriptor: PrimitiveDescriptor, index: usize) ?Type {
    if (descriptor.arg_types.len == 0)
        return null
    else if (index < descriptor.arg_types.len)
        return descriptor.arg_types[index]
    else
        return descriptor.arg_types[descriptor.arg_types.len - 1];
}

pub fn primitiveResultType(descriptor: PrimitiveDescriptor) ?Type {
    return switch (descriptor.result_policy) {
        .metadata_selection => Type.selection(.metadata),
        .declared,
        .first_selection_item,
        .first_arg,
        .selection_algebra,
        .select_query,
        .target_arg,
        .group_object,
        .object_from_role_arg,
        => descriptor.result_type,
    };
}

pub fn queryInputType(descriptor: QueryDescriptor) Type {
    return descriptor.input_type;
}

pub fn queryOutputType(descriptor: QueryDescriptor) Type {
    return descriptor.output_type;
}
