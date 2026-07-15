const std = @import("std");
const core = @import("core");

const json = @import("utils").json;

pub fn writePageOrderField(root: *json.Object, page_order: []const core.NodeId) !void {
    var array = try root.arrayField("page_order");
    for (page_order) |page_id| try array.intItem(page_id);
    try array.end();
}

pub fn writeContainsField(root: *json.Object, contains_map: *std.AutoHashMap(core.NodeId, std.ArrayList(core.NodeId))) !void {
    var contains = try root.arrayField("contains");
    var contains_iterator = contains_map.iterator();
    while (contains_iterator.next()) |entry| {
        var item = try contains.objectItem();
        try item.intField("parent", entry.key_ptr.*);
        var children = try item.arrayField("children");
        for (entry.value_ptr.items) |child_id| try children.intItem(child_id);
        try children.end();
        try item.end();
    }
    try contains.end();
}

pub fn writeConstraintsField(root: *json.Object, constraints: []const core.Constraint) !void {
    try writeNamedConstraintsField(root, "constraints", constraints);
}

pub fn writeOverriddenConstraintsField(root: *json.Object, constraints: []const core.Constraint) !void {
    try writeNamedConstraintsField(root, "overridden_constraints", constraints);
}

fn writeNamedConstraintsField(root: *json.Object, field_name: []const u8, constraints: []const core.Constraint) !void {
    var array = try root.arrayField(field_name);
    for (constraints) |constraint| {
        var item = try array.objectItem();
        try writeConstraintFields(&item, constraint, "target_node", "source_node", "node");
        try item.end();
    }
    try array.end();
}

pub fn writeConstraintUpdatesField(root: *json.Object, updates: []const core.ConstraintUpdate) !void {
    var array = try root.arrayField("constraint_updates");
    for (updates) |update| {
        var item = try array.objectItem();
        try item.intField("target_node", update.target_node);
        try item.enumTagField("target_anchor", update.target_anchor);
        try item.enumTagField("role", update.role);
        try item.intField("scope_depth", update.scope_depth);
        try item.boolField("active", update.active);
        try item.optionalStringField("origin", update.origin);
        if (update.replacement) |replacement| {
            var relation = try item.objectField("replacement");
            try writeConstraintFields(&relation, replacement, "target_node", "source_node", "node");
            try relation.end();
        } else {
            try item.nullField("replacement");
        }
        try item.end();
    }
    try array.end();
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
    try item.enumTagField("role", constraint.role);
    try item.intField("scope_depth", constraint.scope_depth);
    try item.boolField("from_update", constraint.from_update);
}
