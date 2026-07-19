const std = @import("std");
const path_model = @import("path.zig");

pub const Path = path_model.Path;
pub const PathCommand = path_model.Command;
pub const PathPoint = path_model.Point;
pub const PathCubic = path_model.Cubic;

pub const Allocator = std.mem.Allocator;
pub const NodeId = u32;
pub const Role = []const u8;
pub const GroupRole: Role = "group";
pub const ConnectorRole: Role = "connector";

pub const Field = struct {
    key: []const u8,
    value: Value,

    pub fn deinit(self: *Field, allocator: Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }
};

pub const ContentProvenance = struct {
    content_start: usize,
    content_end: usize,
    origin: []const u8,

    pub fn deinit(self: *ContentProvenance, allocator: Allocator) void {
        allocator.free(self.origin);
    }

    pub fn clone(self: ContentProvenance, allocator: Allocator) !ContentProvenance {
        return .{
            .content_start = self.content_start,
            .content_end = self.content_end,
            .origin = try allocator.dupe(u8, self.origin),
        };
    }

    pub fn cloneWithOffset(self: ContentProvenance, allocator: Allocator, offset: usize) !ContentProvenance {
        return .{
            .content_start = self.content_start + offset,
            .content_end = self.content_end + offset,
            .origin = try allocator.dupe(u8, self.origin),
        };
    }
};

pub const RenderEnvEntry = struct {
    op: []const u8,
    key: []const u8,
    value: []const u8,
};

pub const NodeKind = enum {
    document,
    page,
    object,
};

pub const ObjectKind = enum {
    text,
    source,
    overlay,
    asset,
};

pub const PayloadKind = enum {
    text,
    code,
    math_text,
    math_tex,
    figure_text,
    image_ref,
    pdf_ref,
};

pub const Anchor = enum {
    left,
    right,
    top,
    bottom,
    center_x,
    center_y,
};

pub const Axis = enum {
    horizontal,
    vertical,
};

pub const ConstraintSource = union(enum) {
    page: Anchor,
    node: struct {
        node_id: NodeId,
        anchor: Anchor,
    },
};

pub const ConstraintRole = enum {
    position,
    size,
};

pub const Constraint = struct {
    target_node: NodeId,
    target_anchor: Anchor,
    source: ConstraintSource,
    offset: f32,
    origin: ?[]const u8 = null,
    role: ConstraintRole = .position,
    scope_depth: u32 = 0,
    from_update: bool = false,
};

pub const ConstraintUpdate = struct {
    target_node: NodeId,
    target_anchor: Anchor,
    role: ConstraintRole,
    scope_depth: u32,
    replacement: ?Constraint = null,
    origin: ?[]const u8 = null,
    active: bool = false,
};

pub fn constraintRoleForRelation(target_node: NodeId, target_anchor: Anchor, source: ConstraintSource) ConstraintRole {
    const node_source = switch (source) {
        .page => return .position,
        .node => |value| value,
    };
    if (node_source.node_id != target_node or node_source.anchor == target_anchor) return .position;
    return if (anchorAxis(target_anchor) == anchorAxis(node_source.anchor)) .size else .position;
}

pub fn anchorAxis(anchor: Anchor) Axis {
    return switch (anchor) {
        .left, .right, .center_x => .horizontal,
        .top, .bottom, .center_y => .vertical,
    };
}

pub const ConstraintFailureKind = enum {
    conflict,
    negative_frame_size,
};

pub const ConstraintFailureReason = enum {
    anchor_value_conflict,
    overconstrained_frame,
    negative_frame_size,
    constraint_cycle,
    group_size_conflict,
};

pub const ConstraintFailure = struct {
    kind: ConstraintFailureKind,
    reason: ConstraintFailureReason,
    page_id: NodeId,
    axis: ?Axis = null,
    constraint: Constraint,
    existing_constraint: ?Constraint = null,
    actual: ?f32 = null,
    expected: ?f32 = null,
    propagation: ?ConstraintPropagation = null,

    pub fn deinit(self: *ConstraintFailure, allocator: Allocator) void {
        if (self.propagation) |*propagation| propagation.deinit(allocator);
        self.propagation = null;
    }

    pub fn clone(self: ConstraintFailure, allocator: Allocator) !ConstraintFailure {
        var cloned = ConstraintFailure{
            .kind = self.kind,
            .reason = self.reason,
            .page_id = self.page_id,
            .axis = self.axis,
            .constraint = self.constraint,
            .existing_constraint = self.existing_constraint,
            .actual = self.actual,
            .expected = self.expected,
            .propagation = null,
        };
        if (self.propagation) |propagation| {
            cloned.propagation = try propagation.clone(allocator);
        }
        return cloned;
    }
};

pub const ConstraintPropagation = struct {
    target: ?[]const u8 = null,
    paths: []PropagationPath = &.{},
    result: []const []const u8 = &.{},

    pub fn deinit(self: *ConstraintPropagation, allocator: Allocator) void {
        if (self.target) |target| allocator.free(target);
        for (self.paths) |*path| path.deinit(allocator);
        allocator.free(self.paths);
        for (self.result) |line| allocator.free(line);
        allocator.free(self.result);
        self.* = .{};
    }

    pub fn clone(self: ConstraintPropagation, allocator: Allocator) !ConstraintPropagation {
        var cloned = ConstraintPropagation{};
        cloned.target = if (self.target) |target| try allocator.dupe(u8, target) else null;
        errdefer if (cloned.target) |target| allocator.free(target);
        cloned.paths = try allocator.alloc(PropagationPath, self.paths.len);
        var copied_paths: usize = 0;
        errdefer {
            for (cloned.paths[0..copied_paths]) |*path| path.deinit(allocator);
            allocator.free(cloned.paths);
        }
        for (self.paths, 0..) |path, index| {
            cloned.paths[index] = try path.clone(allocator);
            copied_paths += 1;
        }
        const result_lines = try allocator.alloc([]const u8, self.result.len);
        var copied_result: usize = 0;
        errdefer {
            for (result_lines[0..copied_result]) |line| allocator.free(line);
            allocator.free(result_lines);
        }
        for (self.result, 0..) |line, index| {
            result_lines[index] = try allocator.dupe(u8, line);
            copied_result += 1;
        }
        cloned.result = result_lines;
        return cloned;
    }
};

pub const PropagationPath = struct {
    title: []const u8,
    lines: []const []const u8,
    line_sources: []const ?[]const u8 = &.{},

    pub fn deinit(self: *PropagationPath, allocator: Allocator) void {
        allocator.free(self.title);
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
        for (self.line_sources) |source| {
            if (source) |text| allocator.free(text);
        }
        allocator.free(self.line_sources);
        self.* = .{ .title = "", .lines = &.{}, .line_sources = &.{} };
    }

    pub fn clone(self: PropagationPath, allocator: Allocator) !PropagationPath {
        var cloned = PropagationPath{
            .title = try allocator.dupe(u8, self.title),
            .lines = &.{},
            .line_sources = &.{},
        };
        errdefer allocator.free(cloned.title);
        const lines = try allocator.alloc([]const u8, self.lines.len);
        var copied_lines: usize = 0;
        errdefer {
            for (lines[0..copied_lines]) |line| allocator.free(line);
            allocator.free(lines);
        }
        for (self.lines, 0..) |line, index| {
            lines[index] = try allocator.dupe(u8, line);
            copied_lines += 1;
        }
        const line_sources = try allocator.alloc(?[]const u8, self.line_sources.len);
        var copied_sources: usize = 0;
        errdefer {
            for (line_sources[0..copied_sources]) |source| {
                if (source) |text| allocator.free(text);
            }
            allocator.free(line_sources);
        }
        for (self.line_sources, 0..) |source, index| {
            line_sources[index] = if (source) |text| try allocator.dupe(u8, text) else null;
            copied_sources += 1;
        }
        cloned.lines = lines;
        cloned.line_sources = line_sources;
        return cloned;
    }
};

pub const AnchorValue = union(enum) {
    page: Anchor,
    node: struct {
        node_id: NodeId,
        anchor: Anchor,
    },

    pub fn toConstraintSource(self: AnchorValue) ConstraintSource {
        return switch (self) {
            .page => |anchor| .{ .page = anchor },
            .node => |node| .{ .node = .{ .node_id = node.node_id, .anchor = node.anchor } },
        };
    }
};

pub const Frame = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    x_set: bool = false,
    y_set: bool = false,
};

pub const AxisState = struct {
    start: ?f32 = null,
    end: ?f32 = null,
    center: ?f32 = null,
    size: ?f32 = null,
    start_source: ?Constraint = null,
    end_source: ?Constraint = null,
    center_source: ?Constraint = null,
    size_source: ?Constraint = null,
    size_is_default: bool = false,
};

pub const Node = struct {
    id: NodeId,
    kind: NodeKind,
    name: []const u8,
    attached: bool = false,
    discarded: bool = false,
    role: ?Role = null,
    object_kind: ?ObjectKind = null,
    payload_kind: ?PayloadKind = null,
    content: ?[]const u8 = null,
    content_owned: bool = false,
    content_provenance: std.ArrayList(ContentProvenance) = .empty,
    display_content: ?[]const u8 = null,
    display_content_owned: bool = false,
    display_content_provenance: std.ArrayList(ContentProvenance) = .empty,
    repr_function: ?FunctionRef = null,
    page_index: ?usize = null,
    origin: ?[]const u8 = null,
    fields: std.ArrayList(Field) = .empty,
    render_env: std.ArrayList(RenderEnvEntry) = .empty,
    frame: Frame = .{},

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.fields.items) |*field| field.deinit(allocator);
        self.fields.deinit(allocator);
        for (self.render_env.items) |entry| {
            allocator.free(entry.op);
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        self.render_env.deinit(allocator);
        if (self.content_owned) {
            if (self.content) |content| allocator.free(content);
        }
        for (self.content_provenance.items) |*entry| entry.deinit(allocator);
        self.content_provenance.deinit(allocator);
        if (self.display_content_owned) {
            if (self.display_content) |content| allocator.free(content);
        }
        for (self.display_content_provenance.items) |*entry| entry.deinit(allocator);
        self.display_content_provenance.deinit(allocator);
        if (self.repr_function) |*function| function.deinit(allocator);
    }
};

pub const LayoutMeasurementMode = enum {
    natural,
    width_constrained,
};

pub const LayoutMeasurement = struct {
    width: f32,
    height: f32,
    cache_key: ?u64 = null,
};

pub const LayoutMeasurementProvider = struct {
    context: *anyopaque,
    measure: *const fn (
        context: *anyopaque,
        state: *anyopaque,
        node: *const Node,
        width: f32,
        mode: LayoutMeasurementMode,
    ) anyerror!?LayoutMeasurement,
};

pub const ValueTag = enum {
    none,
    document,
    page,
    object,
    selection,
    anchor,
    function,
    string,
    enum_case,
    record,
    path,
    number,
    boolean,
    constraints,
    void,
};

pub const SelectionItemTag = enum {
    page,
    object,
};

pub const Selection = struct {
    item_tag: SelectionItemTag,
    provenance: []const u8,
    ids: std.ArrayList(NodeId),

    pub fn init(item_tag: SelectionItemTag, provenance: []const u8) Selection {
        return .{
            .item_tag = item_tag,
            .provenance = provenance,
            .ids = std.ArrayList(NodeId).empty,
        };
    }

    pub fn deinit(self: *Selection, allocator: Allocator) void {
        self.ids.deinit(allocator);
    }

    pub fn clone(self: Selection, allocator: Allocator) !Selection {
        var copied = Selection.init(self.item_tag, self.provenance);
        errdefer copied.deinit(allocator);
        try copied.ids.appendSlice(allocator, self.ids.items);
        return copied;
    }

    pub fn first(self: Selection) ?NodeId {
        if (self.ids.items.len == 0) return null;
        return self.ids.items[0];
    }

    pub fn contains(self: Selection, id: NodeId) bool {
        for (self.ids.items) |existing| {
            if (existing == id) return true;
        }
        return false;
    }

    pub fn appendUnique(self: *Selection, allocator: Allocator, id: NodeId) !void {
        if (self.contains(id)) return;
        try self.ids.append(allocator, id);
    }
};

pub const ConstraintSet = struct {
    items: std.ArrayList(Constraint),

    pub fn init() ConstraintSet {
        return .{ .items = std.ArrayList(Constraint).empty };
    }

    pub fn deinit(self: *ConstraintSet, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    pub fn clone(self: ConstraintSet, allocator: Allocator) !ConstraintSet {
        var copied = ConstraintSet.init();
        errdefer copied.deinit(allocator);
        try copied.items.appendSlice(allocator, self.items.items);
        return copied;
    }
};

pub const FunctionRef = struct {
    name: []const u8,
    module_id: u32 = 0,
    closure_id: ?usize = null,
    param_count: usize,
    returns_value: bool,

    pub fn deinit(self: *FunctionRef, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }

    pub fn clone(self: FunctionRef, allocator: Allocator) !FunctionRef {
        _ = allocator;
        return .{
            .name = self.name,
            .module_id = self.module_id,
            .closure_id = self.closure_id,
            .param_count = self.param_count,
            .returns_value = self.returns_value,
        };
    }
};

pub const EnumCaseValue = struct {
    enum_name: []const u8,
    case_name: []const u8,
};

pub const RecordFieldValue = struct {
    name: []const u8,
    value: Value,
    explicit: bool = true,

    pub fn deinit(self: *RecordFieldValue, allocator: Allocator) void {
        self.value.deinit(allocator);
    }

    pub fn clone(self: RecordFieldValue, allocator: Allocator) anyerror!RecordFieldValue {
        return .{
            .name = self.name,
            .value = try self.value.clone(allocator),
            .explicit = self.explicit,
        };
    }
};

pub const RecordValue = struct {
    type_name: []const u8,
    fields: std.ArrayList(RecordFieldValue),

    pub fn init(type_name: []const u8) RecordValue {
        return .{
            .type_name = type_name,
            .fields = .empty,
        };
    }

    pub fn deinit(self: *RecordValue, allocator: Allocator) void {
        for (self.fields.items) |*item| item.deinit(allocator);
        self.fields.deinit(allocator);
    }

    pub fn clone(self: RecordValue, allocator: Allocator) anyerror!RecordValue {
        var copied = RecordValue.init(self.type_name);
        errdefer copied.deinit(allocator);
        for (self.fields.items) |item| {
            try copied.fields.append(allocator, try item.clone(allocator));
        }
        return copied;
    }

    pub fn field(self: RecordValue, name: []const u8) ?Value {
        for (self.fields.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }
};

pub const Value = union(ValueTag) {
    none: void,
    document: NodeId,
    page: NodeId,
    object: NodeId,
    selection: Selection,
    anchor: AnchorValue,
    function: FunctionRef,
    string: []const u8,
    enum_case: EnumCaseValue,
    record: RecordValue,
    path: Path,
    number: f32,
    boolean: bool,
    constraints: ConstraintSet,
    void: void,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .selection => |*selection| selection.deinit(allocator),
            .function => |*function| function.deinit(allocator),
            .record => |*record| record.deinit(allocator),
            .path => |*value| value.deinit(allocator),
            .constraints => |*constraints| constraints.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: Allocator) anyerror!Value {
        return switch (self) {
            .none => .{ .none = {} },
            .document => |id| .{ .document = id },
            .page => |id| .{ .page = id },
            .object => |id| .{ .object = id },
            .selection => |selection| .{ .selection = try selection.clone(allocator) },
            .anchor => |anchor| .{ .anchor = anchor },
            .function => |function| .{ .function = try function.clone(allocator) },
            .string => |text| .{ .string = text },
            .enum_case => |enum_case| .{ .enum_case = enum_case },
            .record => |record| .{ .record = try record.clone(allocator) },
            .path => |value| .{ .path = try value.clone(allocator) },
            .number => |number| .{ .number = number },
            .boolean => |boolean| .{ .boolean = boolean },
            .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
            .void => .{ .void = {} },
        };
    }

    pub fn firstId(self: Value) ?NodeId {
        return switch (self) {
            .document => |id| id,
            .page => |id| id,
            .object => |id| id,
            .selection => |selection| selection.first(),
            .none, .anchor, .function, .string, .enum_case, .record, .path, .number, .boolean, .constraints, .void => null,
        };
    }
};

pub const TextStyle = struct {
    font_size: f32,
    line_height: f32,
    spacing_after: f32,
    default_x: f32,
    default_right_inset: f32,
};

pub const DiagnosticPhase = enum {
    layout,
    validation,
    render,
};

pub const DiagnosticSeverity = enum {
    warning,
    @"error",
};

pub const Diagnostic = struct {
    phase: DiagnosticPhase,
    severity: DiagnosticSeverity,
    page_id: ?NodeId = null,
    node_id: ?NodeId = null,
    origin: ?[]const u8 = null,
    data: Data,

    pub const Data = union(enum) {
        user_report: struct {
            message: []const u8,
        },
        asset_not_found: struct {
            requested_path: []const u8,
            resolved_path: []const u8,
            payload_kind: ?PayloadKind = null,
        },
        asset_invalid: struct {
            reason: []const u8,
            payload_kind: ?PayloadKind = null,
        },
        render_failed: struct {
            reason: []const u8,
            payload_kind: ?PayloadKind = null,
        },
        type_mismatch: struct {
            code: TypeMismatchCode,
            expected: ValueTag,
            actual: ValueTag,
        },
        recursive_function: struct {
            function_name: []const u8,
        },
        page_overflow: struct {
            overflow_left: f32,
            overflow_right: f32,
            overflow_top: f32,
            overflow_bottom: f32,
        },
        content_overflow: struct {
            required_width: f32,
            frame_width: f32,
            overflow_width: f32,
            required_height: f32,
            frame_height: f32,
            overflow_height: f32,
        },
    };

    pub fn deinit(self: *Diagnostic, allocator: Allocator) void {
        if (self.origin) |origin| allocator.free(origin);
        switch (self.data) {
            .user_report => |data| allocator.free(data.message),
            .asset_not_found => |data| {
                allocator.free(data.requested_path);
                allocator.free(data.resolved_path);
            },
            .asset_invalid => |data| allocator.free(data.reason),
            .render_failed => |data| allocator.free(data.reason),
            else => {},
        }
    }

    pub fn clone(self: Diagnostic, allocator: Allocator) !Diagnostic {
        var cloned = Diagnostic{
            .phase = self.phase,
            .severity = self.severity,
            .page_id = self.page_id,
            .node_id = self.node_id,
            .origin = if (self.origin) |origin| try allocator.dupe(u8, origin) else null,
            .data = undefined,
        };
        errdefer if (cloned.origin) |origin| allocator.free(origin);
        cloned.data = try cloneDiagnosticData(allocator, self.data);
        return cloned;
    }
};

fn cloneDiagnosticData(allocator: Allocator, data: Diagnostic.Data) !Diagnostic.Data {
    return switch (data) {
        .user_report => |value| .{
            .user_report = .{ .message = try allocator.dupe(u8, value.message) },
        },
        .asset_not_found => |value| blk: {
            const requested_path = try allocator.dupe(u8, value.requested_path);
            errdefer allocator.free(requested_path);
            const resolved_path = try allocator.dupe(u8, value.resolved_path);
            break :blk .{
                .asset_not_found = .{
                    .requested_path = requested_path,
                    .resolved_path = resolved_path,
                    .payload_kind = value.payload_kind,
                },
            };
        },
        .asset_invalid => |value| .{
            .asset_invalid = .{
                .reason = try allocator.dupe(u8, value.reason),
                .payload_kind = value.payload_kind,
            },
        },
        .render_failed => |value| .{
            .render_failed = .{
                .reason = try allocator.dupe(u8, value.reason),
                .payload_kind = value.payload_kind,
            },
        },
        .type_mismatch => |value| .{ .type_mismatch = value },
        .recursive_function => |value| .{ .recursive_function = value },
        .page_overflow => |value| .{ .page_overflow = value },
        .content_overflow => |value| .{ .content_overflow = value },
    };
}

pub const TypeMismatchCode = enum {
    UnmatchedArgumentType,
    UnmatchedReturnType,
    UnmatchedInputType,
};

pub fn roleEq(role: ?Role, expected: []const u8) bool {
    return role != null and std.mem.eql(u8, role.?, expected);
}

pub fn nodeField(node: *const Node, key: []const u8) ?Value {
    for (node.fields.items) |field| {
        if (std.mem.eql(u8, field.key, key)) return field.value;
    }
    return null;
}

pub fn nodeDisplayContent(node: *const Node) []const u8 {
    if (node.display_content) |content| return content;
    return node.content orelse "";
}

pub fn nodeDisplayContentProvenance(node: *const Node) []const ContentProvenance {
    if (node.display_content != null) return node.display_content_provenance.items;
    return node.content_provenance.items;
}

pub const Query = struct {
    input: ValueTag,
    output: ValueTag,
    name: []const u8,
    op: Op,

    pub const Op = union(enum) {
        self_object: void,
        previous_page: void,
        parent_page: void,
        children: void,
        descendants: void,
        page_objects_by_role: Role,
        document_objects_by_role: Role,
        document_pages: void,
    };

    pub fn selfObject() Query {
        return .{
            .input = .object,
            .output = .selection,
            .name = "self-object",
            .op = .{ .self_object = {} },
        };
    }

    pub fn previousPage() Query {
        return .{
            .input = .page,
            .output = .page,
            .name = "previous-page",
            .op = .{ .previous_page = {} },
        };
    }

    pub fn parentPage() Query {
        return .{
            .input = .object,
            .output = .page,
            .name = "parent-page",
            .op = .{ .parent_page = {} },
        };
    }

    pub fn children() Query {
        return .{
            .input = .object,
            .output = .selection,
            .name = "children",
            .op = .{ .children = {} },
        };
    }

    pub fn descendants() Query {
        return .{
            .input = .object,
            .output = .selection,
            .name = "descendants",
            .op = .{ .descendants = {} },
        };
    }

    pub fn pageObjectsByRole(role: Role) Query {
        return .{
            .input = .page,
            .output = .selection,
            .name = "page-objects-by-role",
            .op = .{ .page_objects_by_role = role },
        };
    }

    pub fn documentObjectsByRole(role: Role) Query {
        return .{
            .input = .document,
            .output = .selection,
            .name = "document-objects-by-role",
            .op = .{ .document_objects_by_role = role },
        };
    }

    pub fn documentPages() Query {
        return .{
            .input = .document,
            .output = .selection,
            .name = "document-pages",
            .op = .{ .document_pages = {} },
        };
    }
};
