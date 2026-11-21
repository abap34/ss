// Result types of scheduled bindings are demanded in the lexical
// environment of their declarations. These are type edges, not execution edges.
const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const infer = @import("infer.zig");
const types = @import("types.zig");
const SemanticEnv = @import("../language/env.zig").SemanticEnv;
const addUserReport = @import("diagnostics.zig").addUserReport;

const Scope = struct {
    module_id: core.SourceModuleId,
    page: ?[]const u8,
    names: std.StringHashMapUnmanaged(usize) = .{},
};

const Node = struct {
    stmt: *const ast.Statement,
    scope: usize,
    // Literal and callable facts are queried separately from an already known
    // type. A facts query points back to its declaration node.
    declaration: ?usize = null,
    value_query: ?usize = null,
    result: ?types.TypeInfo = null,
    demanded: bool = false,
    queued: bool = false,
    invalid: bool = false,
    waiting: std.ArrayList(usize) = .empty,
    readers: std.ArrayList(usize) = .empty,
    last_request: usize = 0,
};

pub const Solver = struct {
    arena: std.mem.Allocator,
    state: *core.DocumentState,
    scopes: std.ArrayList(Scope) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    roots: []usize,
    context: *infer.Context,
    queue: std.ArrayList(usize) = .empty,
    current: usize = 0,
    attempt: usize = 0,
    subscriptions: std.AutoHashMapUnmanaged(struct { reader: usize, producer: usize }, void) = .empty,

    fn index(self: *Solver, module_id: core.SourceModuleId, page: ?[]const u8, statements: []const ast.Statement) !void {
        const scope = self.scopes.items.len;
        try self.scopes.append(self.arena, .{ .module_id = module_id, .page = page });
        for (statements) |*stmt| {
            if (stmt.kind != .let_binding) continue;
            const binding = stmt.kind.let_binding;
            if (std.mem.eql(u8, binding.name, "_")) continue;
            const node_index = self.nodes.items.len;
            try self.nodes.append(self.arena, .{ .stmt = stmt, .scope = scope });
            // Duplicate declarations are diagnosed in the source checker.
            const entry = try self.scopes.items[scope].names.getOrPut(self.arena, binding.name);
            if (!entry.found_existing) entry.value_ptr.* = node_index;
            if (binding.type_annotation) |ty| self.nodes.items[node_index].result = types.infoFromType(ty);
            if (binding.binding_id) |id| self.roots[id] = node_index;
        }
    }

    fn enqueue(self: *Solver, node_index: usize) !void {
        const node = &self.nodes.items[node_index];
        if (node.queued or node.result != null or node.invalid) return;
        node.queued = true;
        node.demanded = true;
        try self.queue.append(self.arena, node_index);
    }

    fn demand(self: *Solver, node_index: usize) !types.TypeInfo {
        const target = &self.nodes.items[node_index];
        if (target.result) |info| return info;
        if (target.invalid) return error.InvalidType;
        if (!target.demanded) try self.enqueue(node_index);
        if (target.last_request != self.attempt) {
            target.last_request = self.attempt;
            try self.nodes.items[self.current].waiting.append(self.arena, node_index);
            const subscription = try self.subscriptions.getOrPut(self.arena, .{ .reader = self.current, .producer = node_index });
            if (!subscription.found_existing) try target.readers.append(self.arena, self.current);
        }
        return error.PendingBindingType;
    }

    pub fn reference(self: *Solver, id: u32) !ast.Type {
        return (try self.demand(self.roots[id])).ty;
    }

    pub fn local(self: *Solver, name: []const u8, require_literal: bool) !?types.TypeInfo {
        const scope = self.scopes.items[self.nodes.items[self.current].scope];
        const binding_index = scope.names.get(name) orelse return null;
        var info = try self.demand(binding_index);
        if (require_literal and info.ty.kind == .string and info.string_literal == null) {
            info = try self.demand(try self.ensureValueQuery(binding_index));
        }
        info.binding_id = self.nodes.items[binding_index].stmt.kind.let_binding.binding_id;
        return info;
    }

    fn ensureValueQuery(self: *Solver, binding_index: usize) !usize {
        const binding = self.nodes.items[binding_index];
        if (binding.value_query) |query| return query;
        const query = self.nodes.items.len;
        try self.nodes.append(self.arena, .{ .stmt = binding.stmt, .scope = binding.scope, .declaration = binding_index });
        self.nodes.items[binding_index].value_query = query;
        return query;
    }

    fn solve(self: *Solver, sema: *const SemanticEnv) !void {
        for (self.roots) |root| try self.enqueue(root);
        var cursor: usize = 0;
        while (cursor < self.queue.items.len) : (cursor += 1) {
            try self.state.checkAnalysisCanceled();
            const node_index = self.queue.items[cursor];
            self.current = node_index;
            self.attempt += 1;
            self.nodes.items[node_index].queued = false;
            self.nodes.items[node_index].waiting.clearRetainingCapacity();
            self.inferNode(node_index, sema) catch |err| switch (err) {
                error.PendingBindingType => continue,
                error.OutOfMemory, error.Canceled => return err,
                else => self.nodes.items[node_index].invalid = true, // ordinary checking reports the source error
            };
            for (self.nodes.items[node_index].readers.items) |reader| try self.enqueue(reader);
        }
        self.queue.clearRetainingCapacity();
    }

    fn inferNode(self: *Solver, node_index: usize, sema: *const SemanticEnv) !void {
        // Recursive lookups may append facts queries and relocate the nodes.
        // Keep the index across inference and copy only the declaration inputs.
        const node = self.nodes.items[node_index];
        const scope = self.scopes.items[node.scope];
        var binding_sema = sema.forModule(scope.module_id);
        binding_sema.record_source_facts = false;
        var trial = std.heap.ArenaAllocator.init(self.state.allocator);
        defer trial.deinit();
        const info = try infer.bindingResult(trial.allocator(), &binding_sema, node.stmt, self, node.declaration != null);

        // Only published facts outlive the trial arena.
        const storage = self.state.inferenceAllocator();
        var owned = types.infoFromType(try info.ty.clone(storage));
        owned.hole = info.hole;
        if (info.string_literal) |literal| owned.string_literal = try storage.dupe(u8, literal);
        if (info.function_labels.len != 0) {
            const labels = try storage.alloc([]const u8, info.function_labels.len);
            for (info.function_labels, labels) |label, *output| output.* = try storage.dupe(u8, label);
            owned.function_labels = labels;
        }
        self.nodes.items[node_index].result = owned;
        if (node.declaration == null) {
            if (node.stmt.kind.let_binding.binding_id) |id| self.state.scheduled_bindings.items[id].ty = owned.ty;
        }
    }

    // Literal/callable facts are useful to ordinary checking even when no type
    // depends on them. Their absence must not turn a known type into a cycle.
    fn completeValueQueries(self: *Solver, sema: *const SemanticEnv) !void {
        for (self.roots) |root| {
            const node = self.nodes.items[root];
            const info = node.result orelse continue;
            if (info.ty.kind != .string and info.ty.kind != .function) continue;
            if (node.value_query != null) continue;
            try self.enqueue(try self.ensureValueQuery(root));
        }
        try self.solve(sema);
    }

    fn publishResults(self: *Solver) !void {
        for (self.roots, 0..) |root, binding_id| {
            const node = self.nodes.items[root];
            var info = node.result orelse types.TypeInfo{ .failed = true };
            if (node.value_query) |query| {
                if (self.nodes.items[query].result) |value| {
                    info.string_literal = value.string_literal;
                    info.function_labels = value.function_labels;
                }
            }
            info.binding_id = @intCast(binding_id);
            try self.context.binding_infos.put(@intCast(binding_id), info);
        }
    }

    fn unresolved(node: Node) bool {
        return node.demanded and node.result == null and !node.invalid;
    }

    // Diagnose each strongly connected component of the final, unsolved
    // graph once. Both passes are iterative, including for long invalid chains.
    fn reportCycles(self: *Solver) !void {
        for (self.nodes.items) |node| {
            if (unresolved(node)) break;
        } else return;
        const count = self.nodes.items.len;
        const seen = try self.arena.alloc(bool, count);
        @memset(seen, false);
        const incoming = try self.arena.alloc(std.ArrayList(usize), count);
        @memset(incoming, .empty);
        var finished: std.ArrayList(usize) = .empty;
        const Frame = struct { node: usize, next: usize = 0 };
        var stack: std.ArrayList(Frame) = .empty;
        for (self.nodes.items, 0..) |node, root| {
            if (!unresolved(node) or seen[root]) continue;
            try stack.append(self.arena, .{ .node = root });
            seen[root] = true;
            while (stack.items.len != 0) {
                const frame = &stack.items[stack.items.len - 1];
                const edges = self.nodes.items[frame.node].waiting.items;
                if (frame.next == edges.len) {
                    try finished.append(self.arena, frame.node);
                    _ = stack.pop();
                    continue;
                }
                const to = edges[frame.next];
                frame.next += 1;
                if (!unresolved(self.nodes.items[to])) continue;
                try incoming[to].append(self.arena, frame.node);
                if (seen[to]) continue;
                seen[to] = true;
                try stack.append(self.arena, .{ .node = to });
            }
        }
        @memset(seen, false);
        var component: std.ArrayList(usize) = .empty;
        while (finished.pop()) |root| {
            if (seen[root]) continue;
            component.clearRetainingCapacity();
            try component.append(self.arena, root);
            seen[root] = true;
            var i: usize = 0;
            while (i < component.items.len) : (i += 1) {
                for (incoming[component.items[i]].items) |to| {
                    if (seen[to]) continue;
                    seen[to] = true;
                    try component.append(self.arena, to);
                }
            }
            if (component.items.len == 1 and std.mem.indexOfScalar(usize, incoming[root].items, root) == null) continue;
            try self.reportCycle(component.items);
        }
    }

    fn reportCycle(self: *Solver, component: []usize) !void {
        // Type and literal facts can belong to the same declaration.
        for (component) |*id| id.* = self.nodes.items[id.*].declaration orelse id.*;
        std.mem.sort(usize, component, {}, std.sort.asc(usize));
        var names: std.ArrayList(u8) = .empty;
        for (component, 0..) |id, position| {
            if (position > 0 and id == component[position - 1]) continue;
            const member = self.nodes.items[id];
            if (names.items.len != 0) try names.appendSlice(self.arena, ", ");
            if (self.scopes.items[member.scope].page) |page| {
                try names.appendSlice(self.arena, page);
                try names.appendSlice(self.arena, "::");
            }
            try names.appendSlice(self.arena, member.stmt.kind.let_binding.name);
        }
        const first = self.nodes.items[component[0]];
        const module = self.state.moduleById(self.scopes.items[first.scope].module_id).?;
        try addUserReport(self.state, core.SourceOrigin.at(module.path orelse module.spec, first.stmt.span), "ReferenceNeedsType", "cannot infer the mutually dependent types of {s}; annotate a binding in the cycle", .{names.items});
    }
};

pub fn resolve(context: *infer.Context, state: *core.DocumentState, sema: *const SemanticEnv) !void {
    if (state.scheduled_bindings.items.len == 0) return;
    var temporary = std.heap.ArenaAllocator.init(state.allocator);
    defer temporary.deinit();
    const arena = temporary.allocator();
    var solver = Solver{
        .state = state,
        .context = context,
        .arena = arena,
        .roots = try arena.alloc(usize, state.scheduled_bindings.items.len),
    };
    for (state.modules.order.items) |id| {
        const module = state.moduleById(id) orelse continue;
        try solver.index(id, null, module.syntax.document_statements.items);
        for (module.syntax.pages.items) |page| try solver.index(id, page.name, page.statements.items);
    }
    try solver.solve(sema);
    try solver.reportCycles();
    try solver.completeValueQueries(sema);
    try solver.publishResults();
}
