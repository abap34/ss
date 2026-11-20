const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const Scope = std.StringHashMapUnmanaged(u32);

pub fn scopeFor(allocator: std.mem.Allocator, statements: []const ast.Statement) !Scope {
    var scope: Scope = .{};
    errdefer scope.deinit(allocator);
    for (statements) |stmt| if (stmt.kind == .let_binding) {
        const binding = stmt.kind.let_binding;
        if (binding.binding_id) |id| {
            const entry = try scope.getOrPut(allocator, binding.name);
            if (!entry.found_existing) entry.value_ptr.* = id;
        }
    };
    return scope;
}

// Each expanded stage owns distinct statements and binding identities.
// Function and branch locals remain sequential and do not receive an ID.
pub fn collect(state: *core.DocumentState, module: *core.SourceModule) !void {
    try collectStatements(state, module.id, null, module.syntax.document_statements.items);
    for (module.syntax.pages.items, 0..) |page, index|
        try collectStatements(state, module.id, index, page.statements.items);
}

fn collectStatements(state: *core.DocumentState, module_id: core.SourceModuleId, page_index: ?usize, statements: []ast.Statement) !void {
    for (statements) |*stmt| {
        if (stmt.kind != .let_binding or std.mem.eql(u8, stmt.kind.let_binding.name, "_")) continue;
        const binding = &stmt.kind.let_binding;
        const id = std.math.cast(u32, state.scheduled_bindings.items.len) orelse return error.TooManyBindings;
        try state.scheduled_bindings.append(state.allocator, .{
            .name = binding.name,
            .name_span = binding.name_span,
            .page_index = page_index,
            .module_id = module_id,
            .ty = binding.type_annotation,
            .initializer = &binding.expr,
        });
        binding.binding_id = id;
    }
}
