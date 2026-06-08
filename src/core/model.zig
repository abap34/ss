const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const NodeId = u32;
pub const MetadataId = u32;
pub const Role = []const u8;
pub const GroupRole: Role = "group";

pub const Property = struct {
    key: []const u8,
    value: []const u8,
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

pub const ConstraintSource = union(enum) {
    page: Anchor,
    node: struct {
        node_id: NodeId,
        anchor: Anchor,
    },
};

pub const Constraint = struct {
    target_node: NodeId,
    target_anchor: Anchor,
    source: ConstraintSource,
    offset: f32,
    origin: ?[]const u8 = null,
};

pub const ConstraintFailureKind = enum {
    conflict,
    negative_size,
};

pub const ConstraintFailure = struct {
    kind: ConstraintFailureKind,
    page_id: NodeId,
    constraint: Constraint,
    existing_constraint: ?Constraint = null,
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

pub const Axis = enum {
    horizontal,
    vertical,
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
    page_index: ?usize = null,
    origin: ?[]const u8 = null,
    properties: std.ArrayList(Property) = .empty,
    render_env: std.ArrayList(RenderEnvEntry) = .empty,
    frame: Frame = .{},

    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.properties.items) |property| {
            allocator.free(property.key);
            allocator.free(property.value);
        }
        self.properties.deinit(allocator);
        for (self.render_env.items) |entry| {
            allocator.free(entry.op);
            allocator.free(entry.key);
            allocator.free(entry.value);
        }
        self.render_env.deinit(allocator);
        if (self.content_owned) {
            if (self.content) |content| allocator.free(content);
        }
    }
};

pub const Metadata = struct {
    id: MetadataId,
    kind: []const u8,
    value: []const u8,
    page_id: ?NodeId = null,
    origin: ?[]const u8 = null,

    pub fn deinit(self: *Metadata, allocator: Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.value);
        if (self.origin) |origin| allocator.free(origin);
    }
};

pub const ValueTag = enum {
    none,
    document,
    page,
    object,
    metadata,
    selection,
    anchor,
    function,
    string,
    enum_case,
    number,
    boolean,
    constraints,
    void,
};

pub const SelectionItemTag = enum {
    page,
    object,
    metadata,
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

pub const Value = union(ValueTag) {
    none: void,
    document: NodeId,
    page: NodeId,
    object: NodeId,
    metadata: MetadataId,
    selection: Selection,
    anchor: AnchorValue,
    function: FunctionRef,
    string: []const u8,
    enum_case: EnumCaseValue,
    number: f32,
    boolean: bool,
    constraints: ConstraintSet,
    void: void,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .selection => |*selection| selection.deinit(allocator),
            .function => |*function| function.deinit(allocator),
            .constraints => |*constraints| constraints.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: Value, allocator: Allocator) !Value {
        return switch (self) {
            .none => .{ .none = {} },
            .document => |id| .{ .document = id },
            .page => |id| .{ .page = id },
            .object => |id| .{ .object = id },
            .metadata => |id| .{ .metadata = id },
            .selection => |selection| .{ .selection = try selection.clone(allocator) },
            .anchor => |anchor| .{ .anchor = anchor },
            .function => |function| .{ .function = try function.clone(allocator) },
            .string => |text| .{ .string = text },
            .enum_case => |enum_case| .{ .enum_case = enum_case },
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
            .metadata => |id| id,
            .selection => |selection| selection.first(),
            .none, .anchor, .function, .string, .enum_case, .number, .boolean, .constraints, .void => null,
        };
    }
};

pub const PageLayout = struct {
    pub const width: f32 = 1280;
    pub const height: f32 = 720;
    pub const flow_margin_x: f32 = 60;
    pub const flow_top: f32 = 660;
    pub const content_indent: f32 = 18;
    pub const max_visual_width: f32 = 1160;
    pub const default_asset_width: f32 = 220;
    pub const max_figure_height: f32 = 220;
    pub const max_math_height: f32 = 80;
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
        type_mismatch: struct {
            code: TypeMismatchCode,
            expected: ValueTag,
            actual: ValueTag,
        },
        recursive_function: struct {
            function_name: []const u8,
        },
        unresolved_frame: struct {
            missing_horizontal: bool,
            missing_vertical: bool,
        },
        page_overflow: struct {
            overflow_left: f32,
            overflow_right: f32,
            overflow_top: f32,
            overflow_bottom: f32,
        },
        content_overflow: struct {
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
            else => {},
        }
    }
};

pub const TypeMismatchCode = enum {
    UnmatchedArgumentType,
    UnmatchedReturnType,
    UnmatchedInputType,
};

pub fn roleEq(role: ?Role, expected: []const u8) bool {
    return role != null and std.mem.eql(u8, role.?, expected);
}

pub fn nodeProperty(node: *const Node, key: []const u8) ?[]const u8 {
    for (node.properties.items) |property| {
        if (std.mem.eql(u8, property.key, key)) return property.value;
    }
    return null;
}

pub fn nodePropertyEq(node: *const Node, key: []const u8, expected: []const u8) bool {
    return if (nodeProperty(node, key)) |value|
        std.mem.eql(u8, value, expected)
    else
        false;
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
