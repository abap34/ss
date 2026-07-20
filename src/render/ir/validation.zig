const std = @import("std");
const math_validation = @import("validation/math.zig");
const text_validation = @import("validation/text.zig");

pub const Error = error{
    UnsupportedSchema,
    InvalidPageIndex,
    InvalidPageSize,
    InvalidPageName,
    InvalidItemId,
    InvalidPaintIndex,
    InvalidBounds,
    InvalidTransform,
    InvalidOpacity,
    InvalidItemGeometry,
    InvalidAnnotation,
    InvalidResource,
    MissingResource,
    InvalidFont,
    MissingFont,
    InvalidSemantics,
    SemanticCycle,
};

pub fn document(ir: anytype) Error!void {
    if (ir.schema_version != 7) return error.UnsupportedSchema;
    for (ir.resources.entries, 0..) |resource, resource_index| {
        if (resource_index > 0 and
            std.mem.order(u8, &ir.resources.entries[resource_index - 1].id, &resource.id) != .lt)
        {
            return error.InvalidResource;
        }
        if (!resource.identity_verified) {
            const expected = @import("resources.zig").identify(resource.kind, resource.bytes);
            if (!std.mem.eql(u8, &resource.id, &expected)) return error.InvalidResource;
        }
        if (resource.bytes.len == 0 or resource.name.len == 0 or !std.unicode.utf8ValidateSlice(resource.name) or
            std.fs.path.isAbsolute(resource.name) or std.mem.indexOfAny(u8, resource.name, "/\\") != null)
        {
            return error.InvalidResource;
        }
        if (std.meta.activeTag(resource.metadata) != resource.kind) return error.InvalidResource;
        try resourceMetadata(resource.metadata);
    }
    try fontCatalog(ir);
    try semanticTree(ir);
    try math_validation.catalog(ir);
    for (ir.pages, 0..) |*page, page_index| {
        if (page.index != page_index) return error.InvalidPageIndex;
        if (!positiveFinite(page.width) or !positiveFinite(page.height)) return error.InvalidPageSize;
        if (!std.unicode.utf8ValidateSlice(page.name)) return error.InvalidPageName;
        for (page.items.items, 0..) |item, paint_index| {
            const header = item.header();
            if (header.paint_index != paint_index) return error.InvalidPaintIndex;
            const expected_id = (@as(u64, @intCast(page_index + 1)) << 32) | @as(u64, @intCast(paint_index));
            if (header.item_id != expected_id) return error.InvalidItemId;
            if (!header.bounds.isValid() or !header.ink_bounds.isValid()) return error.InvalidBounds;
            if (!header.transform.isFinite()) return error.InvalidTransform;
            if (!std.math.isFinite(header.opacity) or header.opacity < 0 or header.opacity > 1) return error.InvalidOpacity;
            if (header.source) |source| if (source.start > source.end) return error.InvalidItemGeometry;
            if (header.clip) |clip| switch (clip) {
                .rect => |rect| if (!rect.isValid()) return error.InvalidBounds,
            };
            try itemGeometry(ir, item);
            if (header.semantic_id) |semantic_id| {
                const semantic = ir.semantics.find(semantic_id) orelse return error.InvalidSemantics;
                var found = false;
                for (semantic.items) |item_id| if (item_id == header.item_id) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidSemantics;
            }
        }
        for (page.links.items) |link| {
            if (!link.rect.isValid() or link.target.len == 0 or
                !std.unicode.utf8ValidateSlice(link.target) or !validLinkTarget(link.kind, link.target)) return error.InvalidAnnotation;
            if (link.kind == .destination and !hasDestination(ir, link.target)) return error.InvalidAnnotation;
        }
        for (page.destinations.items) |destination| {
            if (!std.math.isFinite(destination.point.x) or !std.math.isFinite(destination.point.y) or
                destination.name.len == 0 or !std.unicode.utf8ValidateSlice(destination.name) or destination.name[0] == '#') return error.InvalidAnnotation;
            if (destinationCount(ir, destination.name) != 1) return error.InvalidAnnotation;
        }
        for (page.reading_order) |semantic_id| if (ir.semantics.find(semantic_id) == null) return error.InvalidSemantics;
    }
}

fn resourceMetadata(metadata: anytype) Error!void {
    switch (metadata) {
        .font => {},
        .raster => |value| {
            if (value.pixel_width == 0 or value.pixel_height == 0 or value.oriented_width == 0 or value.oriented_height == 0) {
                return error.InvalidResource;
            }
        },
        .svg => |value| {
            if (!positiveFinite(value.width) or !positiveFinite(value.height)) return error.InvalidResource;
            if (value.view_box) |view_box| {
                if (!std.math.isFinite(view_box.x) or !std.math.isFinite(view_box.y) or
                    !positiveFinite(view_box.width) or !positiveFinite(view_box.height)) return error.InvalidResource;
            }
        },
        .pdf, .math_pdf => |value| {
            if (value.pages.len == 0) return error.InvalidResource;
            for (value.pages) |page| {
                if (!positiveFinite(page.user_unit) or
                    (page.rotation != 0 and page.rotation != 90 and page.rotation != 180 and page.rotation != 270)) return error.InvalidResource;
                try pdfBox(page.media);
                try pdfBox(page.crop);
                try pdfBox(page.bleed);
                try pdfBox(page.trim);
                try pdfBox(page.art);
            }
        },
    }
}

fn pdfBox(box: anytype) Error!void {
    if (!std.math.isFinite(box.left) or !std.math.isFinite(box.bottom) or
        !std.math.isFinite(box.right) or !std.math.isFinite(box.top) or
        box.right <= box.left or box.top <= box.bottom) return error.InvalidResource;
}

fn semanticTree(ir: anytype) Error!void {
    const root = ir.semantics.root orelse return error.InvalidSemantics;
    const root_node = ir.semantics.find(root) orelse return error.InvalidSemantics;
    if (root_node.role != .document) return error.InvalidSemantics;
    if (root_node.children.len != ir.pages.len) return error.InvalidSemantics;
    for (ir.semantics.nodes, 0..) |node, index| {
        if (node.id != index + 1) return error.InvalidSemantics;
        try semanticNode(node);
        if (node.role == .math) {
            const tree_id = node.math_tree orelse return error.InvalidSemantics;
            if (ir.math.find(tree_id) == null) return error.InvalidSemantics;
        } else if (node.math_tree != null) return error.InvalidSemantics;
        for (node.children, 0..) |child, child_index| {
            const child_node = ir.semantics.find(child) orelse return error.InvalidSemantics;
            if (!validSemanticChild(node.role, child_node.role)) return error.InvalidSemantics;
            for (node.children[0..child_index]) |previous| if (previous == child) return error.InvalidSemantics;
        }
        const parent_count = semanticParentCount(ir, node.id);
        if (node.id == root) {
            if (parent_count != 0) return error.InvalidSemantics;
        } else if (parent_count != 1) return error.InvalidSemantics;
        for (node.items, 0..) |item_id, item_index| {
            if (item_id == 0) return error.InvalidSemantics;
            for (node.items[0..item_index]) |previous| if (previous == item_id) return error.InvalidSemantics;
            if (!semanticItemMatches(ir, item_id, node.id)) return error.InvalidSemantics;
        }
        try rejectSemanticCycle(ir, node.id, node.id, 0);
    }
    for (ir.pages, 0..) |page, page_index| {
        const page_node = ir.semantics.find(root_node.children[page_index]) orelse return error.InvalidSemantics;
        if (page_node.role != .page or page_node.children.len != page.reading_order.len) return error.InvalidSemantics;
        for (page.reading_order, 0..) |semantic_id, reading_index| {
            if (semantic_id != page_node.children[reading_index]) return error.InvalidSemantics;
            for (page.reading_order[0..reading_index]) |previous| if (previous == semantic_id) return error.InvalidSemantics;
        }
    }
}

fn validSemanticChild(parent: anytype, child: anytype) bool {
    return switch (parent) {
        .document => child == .page,
        .page => child != .document and child != .page and child != .text,
        .list => child == .list_item,
        .table => child == .table_row,
        .table_row => child == .table_header or child == .table_cell,
        .heading, .paragraph, .table_header, .table_cell, .code => child == .text or child == .link or child == .math,
        .text, .link, .math, .decoration => false,
        .list_item, .figure, .caption, .group => child != .document and child != .page,
    };
}

fn semanticNode(node: anytype) Error!void {
    inline for (.{ node.text, node.alt_text, node.language, node.code_language, node.link_target }) |optional| {
        if (optional) |value| if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSemantics;
    }
    switch (node.role) {
        .heading => if (node.heading_level == null or node.heading_level.? < 1 or node.heading_level.? > 6) return error.InvalidSemantics,
        else => if (node.heading_level != null) return error.InvalidSemantics,
    }
    switch (node.role) {
        .list => {
            const ordered = node.list_ordered orelse return error.InvalidSemantics;
            if (ordered) {
                if (node.list_start == null) return error.InvalidSemantics;
            } else if (node.list_start != null) return error.InvalidSemantics;
        },
        else => if (node.list_ordered != null or node.list_start != null) return error.InvalidSemantics,
    }
    switch (node.role) {
        .link => {
            const kind = node.link_kind orelse return error.InvalidSemantics;
            const target = node.link_target orelse return error.InvalidSemantics;
            if (target.len == 0 or !validLinkTarget(kind, target)) return error.InvalidSemantics;
        },
        else => if (node.link_kind != null or node.link_target != null) return error.InvalidSemantics,
    }
    if (node.role != .code and node.code_language != null) return error.InvalidSemantics;
    if ((node.role == .text or node.role == .link or node.role == .math) and node.children.len != 0) return error.InvalidSemantics;
}

fn semanticParentCount(ir: anytype, id: anytype) usize {
    var count: usize = 0;
    for (ir.semantics.nodes) |node| for (node.children) |child| if (child == id) {
        count += 1;
    };
    return count;
}

fn semanticItemMatches(ir: anytype, item_id: anytype, semantic_id: anytype) bool {
    for (ir.pages) |page| for (page.items.items) |item| {
        const header = item.header();
        if (header.item_id == item_id) return header.semantic_id != null and header.semantic_id.? == semantic_id;
    };
    return false;
}

fn validLinkTarget(kind: anytype, target: []const u8) bool {
    for (target) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    if (kind == .destination) return target[0] != '#';
    const separator = std.mem.indexOfScalar(u8, target, ':') orelse return true;
    const path_separator = std.mem.indexOfAny(u8, target, "/?#") orelse target.len;
    if (separator > path_separator) return true;
    const scheme = target[0..separator];
    return std.ascii.eqlIgnoreCase(scheme, "http") or
        std.ascii.eqlIgnoreCase(scheme, "https") or
        std.ascii.eqlIgnoreCase(scheme, "mailto");
}

fn hasDestination(ir: anytype, name: []const u8) bool {
    return destinationCount(ir, name) != 0;
}

fn destinationCount(ir: anytype, name: []const u8) usize {
    var count: usize = 0;
    for (ir.pages) |page| for (page.destinations.items) |destination| {
        if (std.mem.eql(u8, destination.name, name)) count += 1;
    };
    return count;
}

fn rejectSemanticCycle(ir: anytype, origin: anytype, current: anytype, depth: usize) Error!void {
    if (depth > ir.semantics.nodes.len) return error.SemanticCycle;
    const node = ir.semantics.find(current) orelse return error.InvalidSemantics;
    for (node.children) |child| {
        if (child == origin) return error.SemanticCycle;
        try rejectSemanticCycle(ir, origin, child, depth + 1);
    }
}

fn itemGeometry(ir: anytype, item: anytype) Error!void {
    switch (item) {
        .fill_rect => |value| if (!value.rect.isValid() or !validColor(value.color)) return error.InvalidItemGeometry,
        .stroke_line => |value| {
            if (!pointFinite(value.start) or !pointFinite(value.end) or
                !nonNegativeFinite(value.line_width) or
                !nonNegativeFinite(value.dash_on) or
                !nonNegativeFinite(value.dash_off) or !validColor(value.color)) return error.InvalidItemGeometry;
        },
        .vector_path => |value| try vectorPathGeometry(value),
        .rounded_rect => |value| {
            if (!value.rect.isValid() or !nonNegativeFinite(value.radius) or !nonNegativeFinite(value.line_width) or
                (value.fill != null and !validColor(value.fill.?)) or
                (value.stroke != null and !validColor(value.stroke.?)))
            {
                return error.InvalidItemGeometry;
            }
        },
        .text => |value| {
            if (!std.math.isFinite(value.x) or !std.math.isFinite(value.y) or
                !nonNegativeFinite(value.width) or !positiveFinite(value.font_size) or !validColor(value.color)) return error.InvalidItemGeometry;
            try text_validation.layout(ir, value.layout);
        },
        .raster => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .raster);
        },
        .svg => |value| {
            if (!value.rect.isValid() or (value.tint != null and !validColor(value.tint.?))) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .svg);
        },
        .math => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            const tree = ir.math.find(value.tree) orelse return error.InvalidItemGeometry;
            switch (value.content) {
                .structured => |structured| {
                    if (tree.input_kind == .raw or !validColor(structured.color)) return error.InvalidItemGeometry;
                    const layout = structured.layout;
                    if (!nonNegativeFinite(layout.width) or !nonNegativeFinite(layout.height) or
                        !nonNegativeFinite(layout.baseline) or layout.baseline > layout.height) return error.InvalidItemGeometry;
                    for (layout.elements) |element| switch (element) {
                        .text => |text| {
                            if (tree.find(text.node) == null or !std.math.isFinite(text.x) or !std.math.isFinite(text.y) or
                                !positiveFinite(text.font_size))
                            {
                                return error.InvalidItemGeometry;
                            }
                            try text_validation.layout(ir, text.layout);
                        },
                        .rule => |rule| if (tree.find(rule.node) == null or !rule.rect.isValid()) return error.InvalidItemGeometry,
                    };
                },
                .raw_pdf => |raw| {
                    if (tree.input_kind != .raw) return error.InvalidItemGeometry;
                    try requireResource(ir, raw.resource, .math_pdf);
                    const resource = ir.resources.find(raw.resource) orelse return error.MissingResource;
                    const metadata = switch (resource.metadata) {
                        .math_pdf => |metadata| metadata,
                        else => return error.InvalidResource,
                    };
                    if (raw.page_index >= metadata.pages.len) return error.InvalidResource;
                },
            }
        },
        .pdf_page => |value| {
            if (!value.rect.isValid()) return error.InvalidItemGeometry;
            try requireResource(ir, value.resource, .pdf);
            const resource = ir.resources.find(value.resource) orelse return error.MissingResource;
            const metadata = switch (resource.metadata) {
                .pdf => |metadata| metadata,
                else => return error.InvalidResource,
            };
            if (value.page_index >= metadata.pages.len) return error.InvalidResource;
        },
    }
}

fn vectorPathGeometry(value: anytype) Error!void {
    if (!validPathCommands(value.commands) or !validFill(value.fill)) return error.InvalidItemGeometry;
    if (value.stroke) |stroke| try validStroke(stroke);
}

fn validPathCommands(commands: anytype) bool {
    if (commands.len == 0) return false;
    var has_current = false;
    var has_subpath = false;
    for (commands) |command| switch (command) {
        .move_to => |point| {
            if (!pointFinite(point)) return false;
            has_current = true;
            has_subpath = true;
        },
        .line_to => |point| {
            if (!has_current or !pointFinite(point)) return false;
        },
        .cubic_to => |cubic| {
            if (!has_current or !pointFinite(cubic.control1) or !pointFinite(cubic.control2) or !pointFinite(cubic.end)) return false;
        },
        .close => {
            if (!has_current or !has_subpath) return false;
            has_current = false;
            has_subpath = false;
        },
    };
    return true;
}

fn validFill(fill: anytype) bool {
    if (!std.math.isFinite(fill.opacity) or fill.opacity < 0 or fill.opacity > 1) return false;
    switch (fill.base) {
        .none => {},
        .solid => |color| if (!validColor(color)) return false,
        .linear => |gradient| {
            if (!pointFinite(gradient.start) or !pointFinite(gradient.end) or
                (gradient.start.x == gradient.end.x and gradient.start.y == gradient.end.y) or
                !validStops(gradient.stops)) return false;
        },
        .radial => |gradient| {
            if (!pointFinite(gradient.start_center) or !pointFinite(gradient.end_center) or
                !nonNegativeFinite(gradient.start_radius) or !positiveFinite(gradient.end_radius) or
                !validStops(gradient.stops)) return false;
        },
    }
    if (fill.overlay) |pattern| {
        if (!validPathCommands(pattern.commands) or !positiveFinite(pattern.cell_width) or !positiveFinite(pattern.cell_height) or
            !pattern.transform.isFinite() or @abs(pattern.transform.xx * pattern.transform.yy - pattern.transform.xy * pattern.transform.yx) <= 1e-12 or
            (pattern.fill == null and pattern.stroke == null)) return false;
        if (pattern.fill) |color| if (!validColor(color)) return false;
        if (pattern.stroke) |stroke| validStroke(stroke) catch return false;
    }
    return true;
}

fn validStops(stops: anytype) bool {
    if (stops.len < 2) return false;
    var previous: f64 = -1;
    for (stops) |stop| {
        if (!std.math.isFinite(stop.offset) or stop.offset < 0 or stop.offset > 1 or stop.offset < previous or !validColor(stop.color)) return false;
        previous = stop.offset;
    }
    return true;
}

fn validStroke(stroke: anytype) Error!void {
    if (!validColor(stroke.color) or !positiveFinite(stroke.width) or !positiveFinite(stroke.miter_limit) or !std.math.isFinite(stroke.dash_offset)) {
        return error.InvalidItemGeometry;
    }
    for (stroke.dash) |entry| if (!positiveFinite(entry)) return error.InvalidItemGeometry;
}

fn fontCatalog(ir: anytype) Error!void {
    for (ir.fonts.instances, 0..) |instance, index| {
        if (index > 0 and std.mem.order(u8, &ir.fonts.instances[index - 1].id, &instance.id) != .lt) return error.InvalidFont;
        const expected = @import("fonts.zig").identify(.{
            .resource = instance.resource,
            .face_index = instance.face_index,
            .family = instance.family,
            .postscript_name = instance.postscript_name,
            .weight = instance.weight,
            .style = instance.style,
            .stretch = instance.stretch,
            .ascent_ratio = instance.ascent_ratio,
            .descent_ratio = instance.descent_ratio,
            .line_gap_ratio = instance.line_gap_ratio,
            .underline_position_ratio = instance.underline_position_ratio,
            .underline_thickness_ratio = instance.underline_thickness_ratio,
            .strikethrough_position_ratio = instance.strikethrough_position_ratio,
            .strikethrough_thickness_ratio = instance.strikethrough_thickness_ratio,
            .math = instance.math,
            .variations = instance.variations,
            .features = instance.features,
            .synthetic_bold = instance.synthetic_bold,
            .synthetic_italic = instance.synthetic_italic,
            .family_substitution = instance.family_substitution,
        });
        if (!std.mem.eql(u8, &expected, &instance.id)) return error.InvalidFont;
        if (instance.family.len == 0 or instance.weight < 1 or instance.weight > 1000) return error.InvalidFont;
        if (instance.synthetic_bold or instance.synthetic_italic) return error.InvalidFont;
        if (!positiveFinite(instance.ascent_ratio) or !nonNegativeFinite(instance.descent_ratio) or
            !nonNegativeFinite(instance.line_gap_ratio)) return error.InvalidFont;
        if (!std.math.isFinite(instance.underline_position_ratio) or
            !positiveFinite(instance.underline_thickness_ratio) or
            !std.math.isFinite(instance.strikethrough_position_ratio) or
            !positiveFinite(instance.strikethrough_thickness_ratio)) return error.InvalidFont;
        if (!std.unicode.utf8ValidateSlice(instance.family) or !std.unicode.utf8ValidateSlice(instance.postscript_name)) return error.InvalidFont;
        for (instance.variations) |variation| if (!std.math.isFinite(variation.value)) return error.InvalidFont;
        if (instance.math) |constants| {
            inline for (std.meta.fields(@TypeOf(constants))) |field| {
                if (!nonNegativeFinite(@field(constants, field.name))) return error.InvalidFont;
            }
            if (constants.script_scale <= 0 or constants.script_script_scale <= 0) return error.InvalidFont;
        }
        try requireResource(ir, instance.resource, .font);
    }
}

fn requireResource(ir: anytype, id: anytype, kind: anytype) Error!void {
    const resource = ir.resources.find(id) orelse return error.MissingResource;
    if (resource.kind != kind) return error.InvalidResource;
}

fn pointFinite(point: anytype) bool {
    return std.math.isFinite(point.x) and std.math.isFinite(point.y);
}

fn nonNegativeFinite(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn positiveFinite(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn validColor(value: anytype) bool {
    return std.math.isFinite(value.r) and value.r >= 0 and value.r <= 1 and
        std.math.isFinite(value.g) and value.g >= 0 and value.g <= 1 and
        std.math.isFinite(value.b) and value.b >= 0 and value.b <= 1;
}
