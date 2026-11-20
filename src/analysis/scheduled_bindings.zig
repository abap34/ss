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
    try collectStatements(state, module.id, null, null, module.syntax.document_statements.items);
    for (module.syntax.pages.items, 0..) |page, index|
        try collectStatements(state, module.id, index, page.name_span, page.statements.items);
}

fn collectStatements(state: *core.DocumentState, module_id: core.SourceModuleId, page_index: ?usize, page_name_span: ?ast.Span, statements: []ast.Statement) !void {
    for (statements) |*stmt| {
        if (stmt.kind != .let_binding or std.mem.eql(u8, stmt.kind.let_binding.name, "_")) continue;
        const binding = &stmt.kind.let_binding;
        const id = std.math.cast(u32, state.scheduled_bindings.items.len) orelse return error.TooManyBindings;
        try state.scheduled_bindings.append(state.allocator, .{
            .name = binding.name,
            .name_span = binding.name_span,
            .page_index = page_index,
            .page_name_span = page_name_span,
            .module_id = module_id,
            .ty = binding.type_annotation,
            .initializer = &binding.expr,
        });
        binding.binding_id = id;
    }
}

// Resolve against the expanded module: each stage has distinct let statements
// even when the source spans and names coincide. Ordinary names and '&' share
// these identities; function and branch locals remain sequential bindings.
pub const Resolver = struct {
    state: *core.DocumentState,
    document: Scope = .{},
    pages: []Scope,
    source_pages: []const ast.PageDecl,
    names: std.StringHashMapUnmanaged(?usize) = .{},
    active: ?*const Scope = null,
    page_index: ?usize = null,

    pub fn init(state: *core.DocumentState, module: *core.SourceModule) !Resolver {
        const allocator = state.allocator;
        const pages = try allocator.alloc(Scope, module.syntax.pages.items.len);
        @memset(pages, .{});
        var self = Resolver{ .state = state, .pages = pages, .source_pages = module.syntax.pages.items };
        errdefer self.deinit();
        self.document = try scopeFor(allocator, module.syntax.document_statements.items);
        for (module.syntax.pages.items, pages, 0..) |page, *scope, i| {
            scope.* = try scopeFor(allocator, page.statements.items);
            const name = page.source_name orelse page.name;
            if (std.mem.eql(u8, name, "_")) continue;
            const entry = try self.names.getOrPut(allocator, name);
            entry.value_ptr.* = if (entry.found_existing) null else i;
        }
        return self;
    }

    pub fn deinit(self: *Resolver) void {
        const allocator = self.state.allocator;
        self.document.deinit(allocator);
        for (self.pages) |*scope| scope.deinit(allocator);
        allocator.free(self.pages);
        self.names.deinit(allocator);
    }

    pub fn resolve(self: *Resolver, ref: *ast.BindingRefExpr) !void {
        const name = ref.ident.reference();
        const scope = if (name.qualifier) |page_name| blk: {
            if (std.mem.eql(u8, page_name, "_")) return;
            if (self.page_index) |i| {
                const page = self.source_pages[i];
                if (std.mem.eql(u8, page_name, page.source_name orelse page.name)) break :blk &self.pages[i];
            }
            const entry = self.names.get(page_name) orelse return;
            const i = entry orelse {
                ref.ambiguous_page = true;
                return;
            };
            break :blk &self.pages[i];
        } else self.active orelse return;
        const id = scope.get(name.name) orelse return;
        self.state.scheduled_bindings.items[id].referenced = true;
        ref.binding_id = id;
    }
};
