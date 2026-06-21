const std = @import("std");
const model = @import("model");
const utils = @import("utils");
const graph = @import("graph.zig");

const AxisState = model.AxisState;
const Constraint = model.Constraint;
const PageLayout = model.PageLayout;
const json = utils.json;

const TraceState = struct {
    json_path: ?[]const u8 = null,
    json_events: usize = 0,
    run_id: usize = 0,
    pending_messages: std.ArrayList(TraceMessage) = .empty,
};

var trace_state = TraceState{};

pub fn beginSolve(allocator: std.mem.Allocator, json_path: ?[]const u8) void {
    trace_state = .{
        .json_path = json_path,
    };

    if (trace_state.json_path) |path| {
        writePath(allocator, path, JsonPrefix, .truncate) catch |err| {
            std.debug.print("layout trace: failed to initialize JSON trace {s}: {s}\n", .{ path, @errorName(err) });
            trace_state.json_path = null;
        };
    }
}

pub fn endSolve(allocator: std.mem.Allocator) void {
    if (trace_state.json_path) |path| {
        writePath(allocator, path, JsonSuffix, .append) catch |err| {
            std.debug.print("layout trace: failed to finish JSON trace {s}: {s}\n", .{ path, @errorName(err) });
        };
    }
    clearPendingMessages(allocator);
    trace_state.pending_messages.deinit(allocator);
    trace_state = .{};
}

pub fn shouldTraceAxisPass(workspace: *const graph.AxisWorkspace) bool {
    if (!workspace.owns_states) return false;
    return trace_state.json_path != null;
}

pub fn nextRunId() usize {
    trace_state.run_id += 1;
    return trace_state.run_id;
}

pub fn recordDefaultConstraints(
    allocator: std.mem.Allocator,
    workspace: *const graph.AxisWorkspace,
    constraints: []const Constraint,
) void {
    if (trace_state.json_path == null) return;
    for (constraints) |constraint| {
        if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) continue;
        var snapshot = captureSnapshot(allocator, workspace) catch |err| {
            std.debug.print("layout trace: failed to capture default constraint state: {s}\n", .{@errorName(err)});
            return;
        };
        trace_state.pending_messages.append(allocator, .{
            .kind = .default_constraint,
            .constraint = constraint,
            .axis = workspace.axis,
            .soft = true,
            .affected_node = constraint.target_node,
            .snapshot = snapshot,
        }) catch |err| {
            std.debug.print("layout trace: failed to record default constraint: {s}\n", .{@errorName(err)});
            snapshot.deinit(allocator);
            return;
        };
    }
}

pub fn recordConstraintPropagation(
    allocator: std.mem.Allocator,
    workspace: *const graph.AxisWorkspace,
    constraint: Constraint,
    is_soft: bool,
    reverse: bool,
) void {
    if (trace_state.json_path == null) return;
    if (graph.anchorAxis(constraint.target_anchor) != workspace.axis) return;
    const affected_node: ?model.NodeId = if (reverse) switch (constraint.source) {
        .page => null,
        .node => |node_source| node_source.node_id,
    } else constraint.target_node;
    const affected_state = if (affected_node) |node_id| blk: {
        const index = workspace.indexOf(node_id) orelse break :blk null;
        break :blk workspace.states[index];
    } else null;
    var snapshot = captureSnapshot(allocator, workspace) catch |err| {
        std.debug.print("layout trace: failed to capture constraint propagation state: {s}\n", .{@errorName(err)});
        return;
    };
    trace_state.pending_messages.append(allocator, .{
        .kind = .propagation,
        .constraint = constraint,
        .axis = workspace.axis,
        .soft = is_soft,
        .reverse = reverse,
        .affected_node = affected_node,
        .affected_state = affected_state,
        .snapshot = snapshot,
    }) catch |err| {
        std.debug.print("layout trace: failed to record constraint propagation: {s}\n", .{@errorName(err)});
        snapshot.deinit(allocator);
    };
}

pub fn axisPassBegin(
    allocator: std.mem.Allocator,
    ir: anytype,
    workspace: *const graph.AxisWorkspace,
    run_id: usize,
) void {
    const summary = summarizeAxisStates(workspace.states);
    emitEvent(allocator, ir, workspace, .{
        .name = "begin",
        .run_id = run_id,
        .summary = summary,
    });
}

pub fn axisPassIteration(
    allocator: std.mem.Allocator,
    ir: anytype,
    run_id: usize,
    workspace: *const graph.AxisWorkspace,
    pass: usize,
    local_iterations: usize,
    changed: bool,
    group_bounds_changed: bool,
    group_targets_changed: bool,
    group_sources_changed: bool,
    soft_group_sources_changed: bool,
) void {
    const summary = summarizeAxisStates(workspace.states);
    emitEvent(allocator, ir, workspace, .{
        .name = "iteration",
        .run_id = run_id,
        .pass = pass + 1,
        .local_iterations = local_iterations,
        .changed = changed,
        .group_bounds_changed = group_bounds_changed,
        .group_targets_changed = group_targets_changed,
        .group_sources_changed = group_sources_changed,
        .soft_group_sources_changed = soft_group_sources_changed,
        .summary = summary,
    });
}

pub fn axisPassEnd(
    allocator: std.mem.Allocator,
    ir: anytype,
    run_id: usize,
    workspace: *const graph.AxisWorkspace,
    iteration_count: usize,
    converged: bool,
) void {
    const summary = summarizeAxisStates(workspace.states);
    emitEvent(allocator, ir, workspace, .{
        .name = "end",
        .run_id = run_id,
        .iterations = iteration_count,
        .converged = converged,
        .summary = summary,
    });
}

const Event = struct {
    name: []const u8,
    run_id: usize,
    pass: ?usize = null,
    local_iterations: ?usize = null,
    changed: ?bool = null,
    group_bounds_changed: ?bool = null,
    group_targets_changed: ?bool = null,
    group_sources_changed: ?bool = null,
    soft_group_sources_changed: ?bool = null,
    iterations: ?usize = null,
    converged: ?bool = null,
    summary: AxisTraceSummary,
};

fn emitEvent(allocator: std.mem.Allocator, ir: anytype, workspace: *const graph.AxisWorkspace, event: Event) void {
    if (trace_state.json_path == null) return;

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    appendEventJson(allocator, &buffer, ir, workspace, event) catch |err| {
        std.debug.print("layout trace: failed to encode trace event: {s}\n", .{@errorName(err)});
        return;
    };

    if (trace_state.json_path) |path| {
        appendEventToPath(allocator, path, buffer.items, &trace_state.json_events) catch |err| {
            std.debug.print("layout trace: failed to write JSON trace {s}: {s}\n", .{ path, @errorName(err) });
            trace_state.json_path = null;
        };
    }
    clearPendingMessages(allocator);
}

fn appendEventToPath(allocator: std.mem.Allocator, path: []const u8, event_json: []const u8, count: *usize) !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    if (count.* != 0) try buffer.appendSlice(allocator, ",\n");
    try buffer.appendSlice(allocator, event_json);
    try writePath(allocator, path, buffer.items, .append);
    count.* += 1;
}

fn appendEventJson(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), ir: anytype, workspace: *const graph.AxisWorkspace, event: Event) !void {
    var object = try json.Object.beginBuffer(allocator, buffer);
    try object.stringField("event", event.name);
    try object.intField("run", event.run_id);
    try object.intField("page", workspace.graph.page_id);
    try object.stringField("axis", axisName(workspace.axis));
    try object.floatField("page_width", PageLayout.width, "{d:.4}");
    try object.floatField("page_height", PageLayout.height, "{d:.4}");
    try object.intField("nodes", workspace.states.len);
    try object.intField("soft_constraints", workspace.soft_constraints.len);
    try object.optionalIntField("pass", event.pass);
    try object.optionalIntField("local_iterations", event.local_iterations);
    try object.optionalBoolField("changed", event.changed);
    try object.optionalIntField("iterations", event.iterations);
    try object.optionalBoolField("converged", event.converged);

    var groups = try object.objectField("groups");
    try groups.optionalBoolField("bounds_changed", event.group_bounds_changed);
    try groups.optionalBoolField("targets_changed", event.group_targets_changed);
    try groups.optionalBoolField("sources_changed", event.group_sources_changed);
    try groups.optionalBoolField("soft_sources_changed", event.soft_group_sources_changed);
    try groups.end();

    var summary = try object.objectField("summary");
    try summary.intField("start_known", event.summary.start_known);
    try summary.intField("size_known", event.summary.size_known);
    try summary.intField("end_known", event.summary.end_known);
    try summary.intField("center_known", event.summary.center_known);
    try summary.intField("complete", event.summary.complete);
    try summary.intField("default_size", event.summary.default_size);
    try summary.end();

    var messages = try object.arrayField("messages");
    for (trace_state.pending_messages.items) |message| {
        var item = try messages.objectItem();
        try appendTraceMessage(&item, ir, message);
        try item.end();
    }
    try messages.end();

    try appendStateArray(&object, ir, "states", workspace.graph.child_ids, workspace.states);

    try object.end();
}

fn appendStateArray(object: *json.Object, ir: anytype, field_name: []const u8, child_ids: []const model.NodeId, axis_states: []const AxisState) !void {
    var states = try object.arrayField(field_name);
    for (child_ids, axis_states) |child_id, state| {
        const node = ir.getNode(child_id) orelse continue;
        var item = try states.objectItem();
        try item.intField("id", child_id);
        try item.stringField("name", node.name);
        try item.optionalStringField("role", node.role);
        try item.stringField("kind", @tagName(node.kind));
        try appendAxisState(&item, state);
        try item.end();
    }
    try states.end();
}

const MessageKind = enum {
    propagation,
    default_constraint,
};

const TraceMessage = struct {
    kind: MessageKind,
    constraint: Constraint,
    axis: model.Axis,
    soft: bool = false,
    reverse: bool = false,
    affected_node: ?model.NodeId = null,
    affected_state: ?AxisState = null,
    snapshot: TraceSnapshot = .{},

    fn deinit(self: *TraceMessage, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.* = undefined;
    }
};

fn appendTraceMessage(object: *json.Object, ir: anytype, message: TraceMessage) !void {
    try object.stringField("kind", messageKindName(message.kind));
    try object.stringField("axis", axisName(message.axis));
    try object.boolField("soft", message.soft);
    try object.boolField("reverse", message.reverse);

    var constraint = try object.objectField("constraint");
    try appendConstraint(&constraint, ir, message.constraint);
    try constraint.end();

    if (message.reverse) {
        var from = try object.objectField("from");
        try appendNodeEndpoint(&from, ir, message.constraint.target_node, message.constraint.target_anchor);
        try from.end();

        const source = switch (message.constraint.source) {
            .page => unreachable,
            .node => |node_source| node_source,
        };
        var to = try object.objectField("to");
        try appendNodeEndpoint(&to, ir, source.node_id, source.anchor);
        try to.end();
    } else {
        var from = try object.objectField("from");
        try appendConstraintSourceEndpoint(&from, ir, message.constraint.source);
        try from.end();

        var to = try object.objectField("to");
        try appendNodeEndpoint(&to, ir, message.constraint.target_node, message.constraint.target_anchor);
        try to.end();
    }

    if (message.affected_node) |node_id| {
        var affected = try object.objectField("affected");
        try appendNodeEndpoint(&affected, ir, node_id, affectedAnchor(message));
        try affected.end();
    }
    if (message.affected_state) |state| {
        var state_object = try object.objectField("state");
        try appendAxisState(&state_object, state);
        try state_object.end();
    }
    try appendStateArray(object, ir, "states", message.snapshot.child_ids, message.snapshot.states);
}

fn appendAxisState(object: *json.Object, state: AxisState) !void {
    try object.optionalFloatField("start", state.start, "{d:.4}");
    try object.optionalFloatField("size", state.size, "{d:.4}");
    try object.optionalFloatField("end", state.end, "{d:.4}");
    try object.optionalFloatField("center", state.center, "{d:.4}");
    try object.boolField("complete", state.start != null and state.size != null and state.end != null and state.center != null);
    try object.boolField("default_size", state.size_is_default);
}

const TraceSnapshot = struct {
    child_ids: []model.NodeId = &.{},
    states: []AxisState = &.{},

    fn deinit(self: *TraceSnapshot, allocator: std.mem.Allocator) void {
        if (self.child_ids.len != 0) allocator.free(self.child_ids);
        if (self.states.len != 0) allocator.free(self.states);
        self.* = .{};
    }
};

fn captureSnapshot(allocator: std.mem.Allocator, workspace: *const graph.AxisWorkspace) !TraceSnapshot {
    const child_ids = try allocator.dupe(model.NodeId, workspace.graph.child_ids);
    errdefer allocator.free(child_ids);
    const states = try allocator.dupe(AxisState, workspace.states);
    return .{
        .child_ids = child_ids,
        .states = states,
    };
}

fn clearPendingMessages(allocator: std.mem.Allocator) void {
    for (trace_state.pending_messages.items) |*message| {
        message.deinit(allocator);
    }
    trace_state.pending_messages.clearRetainingCapacity();
}

fn affectedAnchor(message: TraceMessage) model.Anchor {
    if (message.reverse) {
        return switch (message.constraint.source) {
            .page => message.constraint.target_anchor,
            .node => |node_source| node_source.anchor,
        };
    }
    return message.constraint.target_anchor;
}

fn appendConstraint(object: *json.Object, ir: anytype, constraint: Constraint) !void {
    try object.optionalStringField("origin", constraint.origin);
    try object.stringField("target_anchor", anchorName(constraint.target_anchor));
    try object.floatField("offset", constraint.offset, "{d:.4}");

    var target = try object.objectField("target");
    try appendNodeEndpoint(&target, ir, constraint.target_node, constraint.target_anchor);
    try target.end();

    var source = try object.objectField("source");
    try appendConstraintSourceEndpoint(&source, ir, constraint.source);
    try source.end();
}

fn appendConstraintSourceEndpoint(object: *json.Object, ir: anytype, source: model.ConstraintSource) !void {
    switch (source) {
        .page => |anchor| {
            try object.stringField("type", "page");
            try object.stringField("name", "page");
            try object.stringField("anchor", anchorName(anchor));
        },
        .node => |node_source| try appendNodeEndpoint(object, ir, node_source.node_id, node_source.anchor),
    }
}

fn appendNodeEndpoint(object: *json.Object, ir: anytype, node_id: model.NodeId, anchor: model.Anchor) !void {
    const node = ir.getNode(node_id);
    try object.stringField("type", "node");
    try object.intField("id", node_id);
    try object.stringField("name", if (node) |value| value.name else "unknown");
    try object.optionalStringField("role", if (node) |value| value.role else null);
    try object.stringField("anchor", anchorName(anchor));
}

const AxisTraceSummary = struct {
    start_known: usize = 0,
    size_known: usize = 0,
    end_known: usize = 0,
    center_known: usize = 0,
    complete: usize = 0,
    default_size: usize = 0,
};

fn summarizeAxisStates(states: []const AxisState) AxisTraceSummary {
    var summary = AxisTraceSummary{};
    for (states) |state| {
        const has_start = state.start != null;
        const has_size = state.size != null;
        const has_end = state.end != null;
        const has_center = state.center != null;
        if (has_start) summary.start_known += 1;
        if (has_size) summary.size_known += 1;
        if (has_end) summary.end_known += 1;
        if (has_center) summary.center_known += 1;
        if (has_start and has_size and has_end and has_center) summary.complete += 1;
        if (state.size_is_default) summary.default_size += 1;
    }
    return summary;
}

fn axisName(axis: model.Axis) []const u8 {
    return switch (axis) {
        .horizontal => "horizontal",
        .vertical => "vertical",
    };
}

fn anchorName(anchor: model.Anchor) []const u8 {
    return switch (anchor) {
        .left => "left",
        .right => "right",
        .top => "top",
        .bottom => "bottom",
        .center_x => "center_x",
        .center_y => "center_y",
    };
}

fn messageKindName(kind: MessageKind) []const u8 {
    return switch (kind) {
        .propagation => "propagation",
        .default_constraint => "default_constraint",
    };
}

const WriteMode = enum {
    truncate,
    append,
};

fn writePath(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, mode: WriteMode) !void {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    const flags: std.c.O = switch (mode) {
        .truncate => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        .append => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
    };
    const fd = std.c.open(zpath.ptr, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.TraceOpenFailed;
    defer _ = std.c.close(fd);

    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = std.c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (written < 0) return error.TraceWriteFailed;
        if (written == 0) return error.TraceWriteFailed;
        offset += @intCast(written);
    }
}

const JsonPrefix =
    \\{"schema":1,"kind":"ss-layout-trace","events":[
;

const JsonSuffix =
    \\]}
    \\
;
