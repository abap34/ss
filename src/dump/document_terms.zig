const core = @import("core");
const elaboration = @import("../elaboration.zig");

const json = @import("utils").json;

pub fn writeDocTermsField(root: *json.Object, terms: []const elaboration.Term) !void {
    var array = try root.arrayField("document_terms");
    for (terms) |term| try writeDocTerm(&array, term);
    try array.end();
}

fn writeDocTerm(terms: *json.Array, term: elaboration.Term) !void {
    var item = try terms.objectItem();
    switch (term) {
        .add_page => |page| {
            try item.stringField("kind", "add_page");
            try item.intField("handle", page.handle);
            try item.stringField("name", page.name);
        },
        .make_node => |node| {
            try item.stringField("kind", "make_object");
            try item.intField("handle", node.handle);
            try item.intField("page", node.page);
            try item.boolField("attached", node.attached);
            try item.enumTagField("node_kind", node.kind);
            try item.stringField("name", node.name);
            try item.optionalStringField("role", node.role);
            try item.enumTagField("object_kind", node.object_kind);
            try item.enumTagField("payload_kind", node.payload_kind);
            try item.optionalStringField("content", node.content);
            try item.optionalStringField("origin", node.origin);
        },
        .add_containment => |edge| {
            try item.stringField("kind", "add_containment");
            try item.intField("parent", edge.parent);
            try item.intField("child", edge.child);
        },
        .set_property => |property| {
            try item.stringField("kind", "set_prop");
            try item.intField("node", property.node);
            try item.stringField("key", property.key);
            try item.stringField("value", property.value);
        },
        .unset_property => |property| {
            try item.stringField("kind", "unset_prop");
            try item.intField("node", property.node);
            try item.stringField("key", property.key);
        },
        .extend_render_env => |entry| {
            try item.stringField("kind", "extend_render_env");
            try item.intField("node", entry.node);
            try item.stringField("op", entry.op);
            try item.stringField("key", entry.key);
            try item.stringField("value", entry.value);
        },
        .set_content => |content| {
            try item.stringField("kind", "set_content");
            try item.intField("node", content.node);
            try item.stringField("value", content.value);
        },
        .add_metadata => |metadata| {
            try item.stringField("kind", "add_metadata");
            try item.stringField("metadata_kind", metadata.kind);
            try item.stringField("value", metadata.value);
            try item.optionalIntField("page", metadata.page);
            try item.optionalStringField("origin", metadata.origin);
        },
        .add_constraint => |constraint| {
            try item.stringField("kind", "add_constraints");
            try writeDocConstraint(&item, constraint);
        },
    }
    try item.end();
}

fn writeDocConstraint(item: *json.Object, constraint: core.Constraint) !void {
    try writeConstraintFields(item, constraint, "target_handle", "source_handle", "object");
}

fn writeConstraintFields(
    item: *json.Object,
    constraint: core.Constraint,
    target_key: []const u8,
    source_key: []const u8,
    node_source_kind: []const u8,
) !void {
    try item.intField(target_key, constraint.target_node);
    try item.enumTagField("target_anchor", constraint.target_anchor);
    switch (constraint.source) {
        .page => |anchor| {
            try item.stringField("source_kind", "page");
            try item.enumTagField("source_anchor", anchor);
            try item.nullField(source_key);
        },
        .node => |source| {
            try item.stringField("source_kind", node_source_kind);
            try item.enumTagField("source_anchor", source.anchor);
            try item.intField(source_key, source.node_id);
        },
    }
    try item.floatField("offset", constraint.offset, "{d:.1}");
    try item.optionalStringField("origin", constraint.origin);
}
