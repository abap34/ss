const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const context_query = @import("context.zig");

pub fn moduleIdForContext(snapshot: anytype, context: *const context_query.Context, request_path: []const u8) ?core.SourceModuleId {
    const module = snapshot.moduleForPath(request_path) orelse return null;
    const alias_context = context.isQualifiedCallableQualifier() or context.isImportAlias();
    for (module.imports) |import_fact| {
        if (context.expired()) return null;
        if (alias_context) {
            const alias = import_fact.alias orelse continue;
            if (!std.mem.eql(u8, alias, context.target)) continue;
            return import_fact.module_id;
        }
        const alias_hit = if (import_fact.alias_span) |span| spanContainsOffset(span, context.offset) else false;
        if (!alias_hit and !spanContainsOffset(import_fact.spec_span, context.offset)) continue;
        return import_fact.module_id;
    }
    return null;
}

pub const SelectedBinding = struct {
    module_id: core.SourceModuleId,
    name: []const u8,
};

pub fn selectedBindingAt(snapshot: anytype, context: *const context_query.Context, request_path: []const u8) ?SelectedBinding {
    const module = snapshot.moduleForPath(request_path) orelse return null;
    for (module.imports) |import_fact| {
        if (context.expired()) return null;
        for (import_fact.selected) |item| {
            if (context.expired()) return null;
            if (spanContainsOffset(item.span, context.offset)) return .{
                .module_id = import_fact.module_id orelse return null,
                .name = item.name,
            };
        }
    }
    return null;
}

fn spanContainsOffset(span: ast.Span, offset: usize) bool {
    return offset >= span.start and offset <= span.end;
}
