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
    new_group,
    set_prop,
    extend_render_env,
    style,
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
    metadata,
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
    result_policy: PrimitiveResultPolicy = .declared,
    callback: ?PrimitiveCallbackSpec = null,
    effects: []const core.Effect = &.{.Pure},
    summary: []const u8,
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
    expected_result_sort: ?core.SemanticSort = null,
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
    output_type: types.Type,
    summary: []const u8,
};

const primitive_descriptors = [_]PrimitiveDescriptor{
    .{ .op = .pagectx, .name = "pagectx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .page, .summary = "Return the current page context" },
    .{ .op = .docctx, .name = "docctx", .min_arity = 0, .max_arity = 0, .arg_names = &.{}, .arg_sorts = &.{}, .result_sort = .document, .summary = "Return the current document context" },
    .{ .op = .select, .name = "select", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "base", "query_name" }, .arg_sorts = &.{ .any, .string }, .result_sort = .selection, .result_policy = .select_query, .effects = &.{.ReadGraph}, .summary = "Build a Selection using the query registry" },
    .{ .op = .anchor, .name = "anchor", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "anchor_name" }, .arg_sorts = &.{ .object, .string }, .result_sort = .anchor, .summary = "Return an object anchor" },
    .{ .op = .page_anchor, .name = "page_anchor", .min_arity = 1, .max_arity = 1, .arg_names = &.{"anchor_name"}, .arg_sorts = &.{.string}, .result_sort = .anchor, .summary = "Return a page anchor" },
    .{ .op = .equal, .name = "equal", .min_arity = 2, .max_arity = 3, .arg_names = &.{ "target", "source", "offset" }, .arg_sorts = &.{ .anchor, .anchor, .number }, .result_sort = .constraints, .effects = &.{.WriteConstraint}, .summary = "Create an anchor equality constraint" },
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
    .{ .op = .foreach, .name = "foreach", .min_arity = 2, .max_arity = 255, .arg_names = &.{ "selection", "callback" }, .arg_sorts = &.{ .selection, .function, .any }, .result_sort = .selection, .result_policy = .first_arg, .callback = .{ .function_arg_index = 1, .supplied_arg_count = 1 }, .summary = "Call a callback once for every item in a finite Selection snapshot" },
    .{ .op = .fold, .name = "fold", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "initial", "callback" }, .arg_sorts = &.{ .selection, .string, .function, .any }, .result_sort = .string, .callback = .{ .function_arg_index = 2, .supplied_arg_count = 2, .expected_result_sort = .string }, .summary = "Fold a finite Selection snapshot with a string accumulator" },
    .{ .op = .join, .name = "join", .min_arity = 3, .max_arity = 255, .arg_names = &.{ "selection", "separator", "callback" }, .arg_sorts = &.{ .selection, .string, .function, .any }, .result_sort = .string, .callback = .{ .function_arg_index = 2, .supplied_arg_count = 1, .expected_result_sort = .string }, .summary = "Map a finite Selection snapshot to strings and join them" },
    .{ .op = .first, .name = "first", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = null, .result_policy = .first_selection_item, .summary = "Get the first element of a Selection" },
    .{ .op = .selection_union, .name = "selection_union", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .result_policy = .selection_algebra, .summary = "Return the union of two Selections" },
    .{ .op = .selection_intersection, .name = "selection_intersection", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .result_policy = .selection_algebra, .summary = "Return the intersection of two Selections" },
    .{ .op = .selection_difference, .name = "selection_difference", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "left", "right" }, .arg_sorts = &.{ .selection, .selection }, .result_sort = .selection, .result_policy = .selection_algebra, .summary = "Return the left Selection without members from the right Selection" },
    .{ .op = .page_index, .name = "page_index", .min_arity = 1, .max_arity = 1, .arg_names = &.{"page"}, .arg_sorts = &.{.page}, .result_sort = .number, .effects = &.{.ReadGraph}, .summary = "Return a page's one-based document index" },
    .{ .op = .page_count, .name = "page_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"document"}, .arg_sorts = &.{.document}, .result_sort = .number, .effects = &.{.ReadGraph}, .summary = "Return the number of pages in a document" },
    .{ .op = .frame_x, .name = "frame_x", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .effects = &.{.ReadLayout}, .summary = "Return the solved x coordinate for an object" },
    .{ .op = .frame_y, .name = "frame_y", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .effects = &.{.ReadLayout}, .summary = "Return the solved y coordinate for an object" },
    .{ .op = .frame_width, .name = "frame_width", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .effects = &.{.ReadLayout}, .summary = "Return the solved width for an object" },
    .{ .op = .frame_height, .name = "frame_height", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .number, .effects = &.{.ReadLayout}, .summary = "Return the solved height for an object" },
    .{ .op = .content, .name = "content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .string, .effects = &.{.ReadGraph}, .summary = "Return an object's textual content" },
    .{ .op = .emit_metadata, .name = "emit_metadata", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "kind", "value" }, .arg_sorts = &.{ .any, .string, .string }, .result_sort = .metadata, .effects = &.{.EmitMetadata}, .summary = "Append a metadata fact associated with a document, page, or object" },
    .{ .op = .metadata_in_document, .name = "metadata_in_document", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "document", "kind" }, .arg_sorts = &.{ .document, .string }, .result_sort = .selection, .result_policy = .metadata_selection, .effects = &.{.ReadMetadata}, .summary = "Select metadata facts by kind across the whole document" },
    .{ .op = .metadata_on_page, .name = "metadata_on_page", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "kind" }, .arg_sorts = &.{ .page, .string }, .result_sort = .selection, .result_policy = .metadata_selection, .effects = &.{.ReadMetadata}, .summary = "Select metadata facts by kind on one page" },
    .{ .op = .metadata_content, .name = "metadata_content", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_sorts = &.{.metadata}, .result_sort = .string, .effects = &.{.ReadMetadata}, .summary = "Return a metadata fact's textual value" },
    .{ .op = .metadata_kind, .name = "metadata_kind", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_sorts = &.{.metadata}, .result_sort = .string, .effects = &.{.ReadMetadata}, .summary = "Return a metadata fact's kind" },
    .{ .op = .metadata_page, .name = "metadata_page", .min_arity = 1, .max_arity = 1, .arg_names = &.{"metadata"}, .arg_sorts = &.{.metadata}, .result_sort = .page, .effects = &.{.ReadMetadata}, .summary = "Return the page associated with a metadata fact" },
    .{ .op = .prop, .name = "prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "default" }, .arg_sorts = &.{ .any, .string, .string }, .result_sort = .string, .effects = &.{.ReadGraph}, .summary = "Read a property from a document, page, or object, falling back to a default" },
    .{ .op = .has_prop, .name = "has_prop", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "target", "key" }, .arg_sorts = &.{ .any, .string }, .result_sort = .boolean, .effects = &.{.ReadGraph}, .summary = "Return whether a document, page, or object has a property" },
    .{ .op = .prop_eq, .name = "prop_eq", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_sorts = &.{ .any, .string, .string }, .result_sort = .boolean, .effects = &.{.ReadGraph}, .summary = "Return whether a property equals a string value" },
    .{ .op = .selection_empty, .name = "selection_empty", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = .boolean, .summary = "Return whether a Selection has no members" },
    .{ .op = .selection_count, .name = "selection_count", .min_arity = 1, .max_arity = 1, .arg_names = &.{"selection"}, .arg_sorts = &.{.selection}, .result_sort = .number, .summary = "Return the number of members in a Selection" },
    .{ .op = .set_content, .name = "set_content", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "object", "text" }, .arg_sorts = &.{ .object, .string }, .result_sort = .object, .result_policy = .first_arg, .effects = &.{.WriteContent}, .summary = "Replace an object's textual content" },
    .{ .op = .group, .name = "group", .min_arity = 1, .max_arity = 255, .arg_names = &.{"child"}, .arg_sorts = &.{.object}, .result_sort = .object, .result_policy = .group_object, .effects = &.{.CreateNode}, .summary = "Create a bbox group from multiple objects" },
    .{ .op = .new_page, .name = "new_page", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "document", "title" }, .arg_sorts = &.{ .document, .string }, .result_sort = .page, .effects = &.{.CreatePage}, .summary = "Create a page in the scheduled document graph" },
    .{ .op = .new, .name = "new", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "page", "content", "role_name", "payload_name" }, .arg_sorts = &.{ .page, .string, .string, .string }, .result_sort = .object, .result_policy = .object_from_role_arg, .effects = &.{ .CreateNode, .WriteContent }, .summary = "Create an object on an explicit page in the scheduled document graph" },
    .{ .op = .new_group, .name = "new_group", .min_arity = 2, .max_arity = 2, .arg_names = &.{ "page", "children" }, .arg_sorts = &.{ .page, .selection }, .result_sort = .object, .result_policy = .group_object, .effects = &.{.CreateNode}, .summary = "Create a group on an explicit page in the scheduled document graph" },
    .{ .op = .set_prop, .name = "set_prop", .min_arity = 3, .max_arity = 3, .arg_names = &.{ "target", "key", "value" }, .arg_sorts = &.{ .any, .string, .any }, .result_sort = null, .result_policy = .target_arg, .effects = &.{.WriteProperty}, .summary = "Attach a property to a document, page, or object" },
    .{ .op = .extend_render_env, .name = "extend_render_env", .min_arity = 4, .max_arity = 4, .arg_names = &.{ "target", "op", "key", "value" }, .arg_sorts = &.{ .any, .string, .string, .string }, .result_sort = null, .result_policy = .target_arg, .effects = &.{.WriteRenderPolicy}, .summary = "Extend a scoped render environment" },
    .{ .op = .style, .name = "style", .min_arity = 1, .max_arity = 1, .arg_names = &.{"style_name"}, .arg_sorts = &.{.string}, .result_sort = .style, .summary = "Create a style value" },
    .{ .op = .constraints, .name = "constraints", .min_arity = 0, .max_arity = 255, .arg_names = &.{"constraint_set"}, .arg_sorts = &.{.constraints}, .result_sort = .constraints, .effects = &.{.WriteConstraint}, .summary = "Bundle a ConstraintSet" },
    .{ .op = .report_error, .name = "report_error", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effects = &.{.EmitDiagnostics}, .summary = "Report error diagnostics from user-defined checks" },
    .{ .op = .report_warning, .name = "report_warning", .min_arity = 1, .max_arity = 1, .arg_names = &.{"message"}, .arg_sorts = &.{.string}, .result_sort = .string, .effects = &.{.EmitDiagnostics}, .summary = "Report warning diagnostics from user-defined checks" },
    .{ .op = .require_asset_exists, .name = "require_asset_exists", .min_arity = 1, .max_arity = 1, .arg_names = &.{"object"}, .arg_sorts = &.{.object}, .result_sort = .object, .effects = &.{.EmitDiagnostics}, .summary = "Check that the referenced file for an asset object exists" },
};

const query_descriptors = [_]QueryDescriptor{
    .{ .op = .self_object, .name = "self_object", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .output_type = types.Type.selection(.object), .summary = "Return the object itself as a one-element Selection" },
    .{ .op = .previous_page, .name = "previous_page", .arity = 2, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .page, .output_type = types.Type.page, .summary = "Select the previous page" },
    .{ .op = .parent_page, .name = "parent_page", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .page, .output_type = types.Type.page, .summary = "Select the parent page" },
    .{ .op = .children, .name = "children", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .output_type = types.Type.selection(.object), .summary = "Select direct object children" },
    .{ .op = .descendants, .name = "descendants", .arity = 2, .input_name = "base", .input_sort = .object, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .output_type = types.Type.selection(.object), .summary = "Select recursive object descendants" },
    .{ .op = .document_pages, .name = "document_pages", .arity = 2, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{}, .extra_arg_sorts = &.{}, .output_sort = .selection, .output_type = types.Type.selection(.page), .summary = "Select all pages in the document" },
    .{ .op = .page_objects_by_role, .name = "page_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .page, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .output_type = types.Type.selection(.object), .summary = "Select objects by role within a page" },
    .{ .op = .document_objects_by_role, .name = "document_objects_by_role", .arity = 3, .input_name = "base", .input_sort = .document, .extra_arg_names = &.{"role_name"}, .extra_arg_sorts = &.{.string}, .output_sort = .selection, .output_type = types.Type.selection(.object), .summary = "Select objects by role across the whole document" },
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

pub fn argSortType(sort: ArgSort) ?types.Type {
    return switch (sort) {
        .any => null,
        .document => types.Type.document,
        .page => types.Type.page,
        .object => types.Type.object,
        .metadata => types.Type.metadata,
        .selection => types.Type.selection(.any),
        .anchor => types.Type.anchor,
        .function => .{ .tag = .function },
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
    return switch (descriptor.result_policy) {
        .metadata_selection => types.Type.selection(.metadata),
        .declared,
        .first_selection_item,
        .first_arg,
        .selection_algebra,
        .select_query,
        .target_arg,
        .group_object,
        .object_from_role_arg,
        => if (descriptor.result_sort) |sort| types.Type.fromSort(sort) else null,
    };
}

pub fn primitiveEffects(descriptor: PrimitiveDescriptor) core.EffectSet {
    var set = core.EffectSet.empty();
    for (descriptor.effects) |effect| {
        set.insert(effect);
    }
    return set;
}

pub fn queryInputType(descriptor: QueryDescriptor) types.Type {
    return types.Type.fromSort(descriptor.input_sort);
}

pub fn queryOutputType(descriptor: QueryDescriptor) types.Type {
    return descriptor.output_type;
}
