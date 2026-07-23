const std = @import("std");
const ast = @import("ast");

const editor_edit = @import("../../../editor/edit.zig");
const syntax = @import("../../../syntax.zig");

pub const invalid_width_message = std.fmt.comptimePrint(
    "Component width must be at least {d} points and remain inside the page.",
    .{editor_edit.minimum_component_width},
);

pub fn existingUpdate(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    page_span: editor_edit.ByteSpan,
    binding: []const u8,
) !?editor_edit.ExistingWidthUpdate {
    var module = syntax.parseWithSourceName(allocator, source, path) catch return null;
    defer module.deinit(allocator);
    const page = sourcePage(&module, page_span) orelse return null;
    var latest: ?editor_edit.ExistingWidthUpdate = null;
    for (page.statements.items) |statement| {
        const constraint = switch (statement.kind) {
            .constrain => |value| value,
            else => continue,
        };
        if (constraint.action != .update or
            !anchorMatchesBinding(constraint.target, binding, .right)) continue;
        const constraint_syntax = constraint.syntax orelse continue;
        if (constraint.target_kind == .dimension) {
            const source_anchor = constraint.source orelse continue;
            if (!anchorMatchesBinding(source_anchor, binding, .left)) continue;
            const offset = constraint_syntax.offset orelse continue;
            latest = .{
                .value = .{ .start = offset.start, .end = offset.end },
                .direct_dimension = true,
            };
            continue;
        }
        const source_anchor = constraint.source orelse continue;
        if (!anchorMatchesBinding(source_anchor, binding, .left)) continue;
        const source_span = constraint_syntax.source orelse continue;
        const offset: ast.Span = constraint_syntax.offset orelse .{
            .start = source_span.end,
            .end = source_span.end,
        };
        latest = .{
            .value = .{ .start = offset.start, .end = offset.end },
            .direct_dimension = false,
        };
    }
    return latest;
}

fn sourcePage(module: *const ast.Module, span: editor_edit.ByteSpan) ?*const ast.PageDecl {
    for (module.pages.items) |*page| {
        if (page.span.start == span.start and page.span.end == span.end) return page;
    }
    return null;
}

fn anchorMatchesBinding(anchor: ast.AnchorRef, binding: []const u8, expected: @TypeOf(anchor.anchor)) bool {
    if (anchor.kind != .node or anchor.anchor != expected) return false;
    return std.mem.eql(u8, anchor.node_path orelse anchor.node_name orelse return false, binding);
}
