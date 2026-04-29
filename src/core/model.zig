const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const NodeId = u32;
pub const Role = []const u8;
pub const GroupRole: Role = "group";

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const NodeKind = enum {
    document,
    page,
    object,
    derived,
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
    role: ?Role = null,
    object_kind: ?ObjectKind = null,
    payload_kind: ?PayloadKind = null,
    content: ?[]const u8 = null,
    page_index: ?usize = null,
    derived_from: ?NodeId = null,
    origin: ?[]const u8 = null,
    properties: std.ArrayList(Property) = .empty,
    frame: Frame = .{},

    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.properties.deinit(allocator);
    }
};

pub const SemanticSort = enum {
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
    fragment,
};

pub const SelectionItemSort = enum {
    page,
    object,
};

pub const Selection = struct {
    item_sort: SelectionItemSort,
    provenance: []const u8,
    ids: std.ArrayList(NodeId),

    pub fn init(item_sort: SelectionItemSort, provenance: []const u8) Selection {
        return .{
            .item_sort = item_sort,
            .provenance = provenance,
            .ids = std.ArrayList(NodeId).empty,
        };
    }

    pub fn deinit(self: *Selection, allocator: Allocator) void {
        self.ids.deinit(allocator);
    }

    pub fn clone(self: Selection, allocator: Allocator) !Selection {
        var copied = Selection.init(self.item_sort, self.provenance);
        errdefer copied.deinit(allocator);
        try copied.ids.appendSlice(allocator, self.ids.items);
        return copied;
    }

    pub fn first(self: Selection) ?NodeId {
        if (self.ids.items.len == 0) return null;
        return self.ids.items[0];
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
    param_count: usize,
    returns_value: bool,
};

pub const StyleRef = struct {
    name: []const u8,
};

pub const FragmentRoot = union(enum) {
    document: NodeId,
    page: NodeId,
    object: NodeId,
    selection: Selection,
    anchor: AnchorValue,
    function: FunctionRef,
    style: StyleRef,
    string: []const u8,
    number: f32,
    constraints: ConstraintSet,

    pub fn deinit(self: *FragmentRoot, allocator: Allocator) void {
        switch (self.*) {
            .selection => |*selection| selection.deinit(allocator),
            .constraints => |*constraints| constraints.deinit(allocator),
            else => {},
        }
    }

    pub fn clone(self: FragmentRoot, allocator: Allocator) !FragmentRoot {
        return switch (self) {
            .document => |id| .{ .document = id },
            .page => |id| .{ .page = id },
            .object => |id| .{ .object = id },
            .selection => |selection| .{ .selection = try selection.clone(allocator) },
            .anchor => |anchor| .{ .anchor = anchor },
            .function => |function| .{ .function = function },
            .style => |style| .{ .style = style },
            .string => |text| .{ .string = text },
            .number => |number| .{ .number = number },
            .constraints => |constraints| .{ .constraints = try constraints.clone(allocator) },
        };
    }

    pub fn firstId(self: FragmentRoot) ?NodeId {
        return switch (self) {
            .document => |id| id,
            .page => |id| id,
            .object => |id| id,
            .selection => |selection| selection.first(),
            .anchor, .function, .style, .string, .number, .constraints => null,
        };
    }
};

pub const Fragment = struct {
    page_id: NodeId,
    root: ?FragmentRoot = null,
    node_ids: std.ArrayList(NodeId),
    constraints: ConstraintSet,
    deps: std.ArrayList(*Fragment),
    materialized: bool = false,

    pub fn init(page_id: NodeId) Fragment {
        return .{
            .page_id = page_id,
            .node_ids = std.ArrayList(NodeId).empty,
            .constraints = ConstraintSet.init(),
            .deps = std.ArrayList(*Fragment).empty,
        };
    }

    pub fn deinit(self: *Fragment, allocator: Allocator) void {
        if (self.root) |*root| {
            root.deinit(allocator);
        }
        self.node_ids.deinit(allocator);
        self.constraints.deinit(allocator);
        self.deps.deinit(allocator);
    }
};

pub const Value = union(SemanticSort) {
    document: NodeId,
    page: NodeId,
    object: NodeId,
    selection: Selection,
    anchor: AnchorValue,
    function: FunctionRef,
    style: StyleRef,
    string: []const u8,
    number: f32,
    constraints: ConstraintSet,
    fragment: *Fragment,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .selection => |*selection| selection.deinit(allocator),
            .constraints => |*constraints| constraints.deinit(allocator),
            else => {},
        }
    }

    pub fn firstId(self: Value) ?NodeId {
        return switch (self) {
            .document => |id| id,
            .page => |id| id,
            .object => |id| id,
            .selection => |selection| selection.first(),
            .fragment => |fragment| if (fragment.root) |root| root.firstId() else null,
            .anchor, .function, .style, .string, .number, .constraints => null,
        };
    }
};

pub const PageLayout = struct {
    pub const width: f32 = 1280;
    pub const height: f32 = 720;
    pub const flow_margin_x: f32 = 60;
    pub const flow_top: f32 = 660;
    pub const page_number_right_inset: f32 = 24;
    pub const page_number_bottom_inset: f32 = 20;
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
    data: Data,

    pub const Data = union(enum) {
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
    };
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
    input: SemanticSort,
    output: SemanticSort,
    name: []const u8,
    op: Op,

    pub const Op = union(enum) {
        self_object: void,
        previous_page: void,
        parent_page: void,
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

pub const Transform = struct {
    input: SemanticSort,
    name: []const u8,
    op: Op,

    pub const Op = union(enum) {
        rewrite_text: struct {
            old: []const u8,
            new: []const u8,
        },
        highlight: struct {
            note: []const u8,
        },
        page_number: void,
        toc: void,
    };

    pub fn rewriteText(old: []const u8, new: []const u8) Transform {
        return .{
            .input = .object,
            .name = "rewrite-text",
            .op = .{ .rewrite_text = .{ .old = old, .new = new } },
        };
    }

    pub fn highlight(note: []const u8) Transform {
        return .{
            .input = .selection,
            .name = "highlight",
            .op = .{ .highlight = .{ .note = note } },
        };
    }

    pub fn pageNumber() Transform {
        return .{
            .input = .page,
            .name = "page-number",
            .op = .{ .page_number = {} },
        };
    }

    pub fn toc() Transform {
        return .{
            .input = .document,
            .name = "toc",
            .op = .{ .toc = {} },
        };
    }
};
