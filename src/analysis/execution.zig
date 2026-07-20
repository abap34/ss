const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const utils = @import("utils");

const dependencies = @import("dependencies.zig");
const semantic_env = @import("../language/env.zig");
const declarations = @import("../language/declarations.zig");

const SemanticEnv = semantic_env.SemanticEnv;

pub const PageIdMode = enum {
    synthetic,
    create,
};

pub const BuildOptions = struct {
    page_id_mode: PageIdMode = .synthetic,
};

pub const ExecutionUnit = struct {
    module_id: core.SourceModuleId,
    source: []const u8,
    path: []const u8,
    source_order: usize,
    span: ast.Span,
    summary: dependencies.AccessSummary,
    kind: Kind,

    pub const Kind = union(enum) {
        document_statement: struct {
            stmt: ast.Statement,
            index: usize,
        },
        page_statement: struct {
            stmt: ast.Statement,
            page_id: core.NodeId,
            index: usize,
        },
    };

    pub fn deinit(self: *ExecutionUnit) void {
        self.summary.deinit();
    }
};

pub const DependencyEdge = struct {
    from: usize,
    to: usize,
};

pub const ExecutionGraph = struct {
    allocator: std.mem.Allocator,
    declarations: declarations.DeclarationIndex,
    units: std.ArrayList(ExecutionUnit),
    edges: std.ArrayList(DependencyEdge),
    order: []usize,

    pub fn build(
        allocator: std.mem.Allocator,
        state: *const core.DocumentState,
        diagnostic_state: *core.DocumentState,
        options: BuildOptions,
    ) !ExecutionGraph {
        var graph = ExecutionGraph{
            .allocator = allocator,
            .declarations = try declarations.build(allocator, state),
            .units = .empty,
            .edges = .empty,
            .order = &.{},
        };
        errdefer graph.deinit();

        var collected_modules = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
        defer collected_modules.deinit();
        var run_cache = dependencies.RunCache.init(allocator);
        defer run_cache.deinit();
        try run_cache.reserve(state);
        var builder = GraphBuilder{
            .allocator = allocator,
            .state = state,
            .diagnostic_state = diagnostic_state,
            .functions = &state.functions,
            .declarations = &graph.declarations,
            .units = &graph.units,
            .collected_modules = &collected_modules,
            .run_cache = &run_cache,
            .source_order = 0,
            .page_id_mode = options.page_id_mode,
        };
        try builder.collectExecutionUnits(state.projectModule());
        try validateExecutionUnits(diagnostic_state, graph.units.items);
        try buildDependencyEdges(allocator, graph.units.items, &graph.edges);
        var cycle_hint: ?usize = null;
        graph.order = scheduleFromEdges(allocator, graph.units.items, graph.edges.items, &cycle_hint) catch |err| {
            if (err == error.ExecutionDependencyCycle and graph.units.items.len != 0) {
                try addUnitErrorDiagnostic(diagnostic_state, graph.units.items[cycle_hint orelse 0], analysisErrorMessage(err));
            }
            return err;
        };
        return graph;
    }

    pub fn deinit(self: *ExecutionGraph) void {
        self.allocator.free(self.order);
        self.edges.deinit(self.allocator);
        for (self.units.items) |*unit| unit.deinit();
        self.units.deinit(self.allocator);
        self.declarations.deinit();
    }
};

pub fn validateDependencies(allocator: std.mem.Allocator, state: *core.DocumentState) !void {
    var graph = try ExecutionGraph.build(allocator, state, state, .{ .page_id_mode = .synthetic });
    defer graph.deinit();
}

const GraphBuilder = struct {
    allocator: std.mem.Allocator,
    state: *const core.DocumentState,
    diagnostic_state: *core.DocumentState,
    functions: *const core.FunctionMap,
    declarations: *const declarations.DeclarationIndex,
    units: *std.ArrayList(ExecutionUnit),
    collected_modules: *std.AutoHashMap(core.SourceModuleId, void),
    run_cache: *dependencies.RunCache,
    source_order: usize,
    synthetic_page_count: core.NodeId = 0,
    page_id_mode: PageIdMode,

    fn collectExecutionUnits(self: *GraphBuilder, module: *const core.SourceModule) !void {
        if (module.kind == .library) {
            if (self.collected_modules.contains(module.id)) return;
            try self.collected_modules.put(module.id, {});
        }

        if (module.syntax.top_level_items.items.len == 0) {
            try self.appendDocumentStatementUnits(module, 0, module.syntax.document_statements.items.len);
            for (module.syntax.pages.items) |page| try self.appendPageStatementUnits(module, page);
            return;
        }

        for (module.syntax.top_level_items.items) |item| {
            switch (item) {
                .import => |import_index| {
                    if (import_index >= module.resolved_import_ids.items.len) continue;
                    const import_id = module.resolved_import_ids.items[import_index];
                    const imported = self.state.moduleById(import_id) orelse continue;
                    try self.collectExecutionUnits(imported);
                },
                .document => |document_index| {
                    if (document_index >= module.syntax.document_blocks.items.len) continue;
                    const block = module.syntax.document_blocks.items[document_index];
                    try self.appendDocumentStatementUnits(module, block.statement_start, block.statement_count);
                },
                .page => |page_index| {
                    if (page_index >= module.syntax.pages.items.len) continue;
                    try self.appendPageStatementUnits(module, module.syntax.pages.items[page_index]);
                },
            }
        }
    }

    fn appendDocumentStatementUnits(
        self: *GraphBuilder,
        module: *const core.SourceModule,
        statement_start: usize,
        statement_count: usize,
    ) !void {
        const sema = SemanticEnv.init(self.state, self.declarations, self.functions).forModule(module.id);
        var analyzer = dependencies.Analyzer.initWithScopeAndCache(self.allocator, &sema, .{ .document = sema.module_id }, self.run_cache);
        defer analyzer.deinit();
        const statement_end = @min(statement_start + statement_count, module.syntax.document_statements.items.len);
        for (module.syntax.document_statements.items[statement_start..statement_end], statement_start..) |stmt, stmt_index| {
            const summary = try analyzer.statement(stmt);
            errdefer {
                var owned = summary;
                owned.deinit();
            }
            try self.units.append(self.allocator, .{
                .module_id = module.id,
                .source = module.source,
                .path = module.path orelse module.spec,
                .source_order = self.source_order,
                .span = stmt.span,
                .summary = summary,
                .kind = .{ .document_statement = .{
                    .stmt = stmt,
                    .index = stmt_index,
                } },
            });
            self.source_order += 1;
        }
    }

    fn appendPageStatementUnits(
        self: *GraphBuilder,
        module: *const core.SourceModule,
        page: ast.PageDecl,
    ) !void {
        const page_id = try self.nextPageId(module, page);
        const sema = SemanticEnv.init(self.diagnostic_state, self.declarations, self.functions).forModule(module.id);
        var analyzer = dependencies.Analyzer.initWithScopeAndCache(self.allocator, &sema, .{ .page = page_id }, self.run_cache);
        defer analyzer.deinit();
        for (page.statements.items, 0..) |stmt, stmt_index| {
            const summary = try analyzer.statement(stmt);
            errdefer {
                var owned = summary;
                owned.deinit();
            }
            try self.units.append(self.allocator, .{
                .module_id = module.id,
                .source = module.source,
                .path = module.path orelse module.spec,
                .source_order = self.source_order,
                .span = stmt.span,
                .summary = summary,
                .kind = .{ .page_statement = .{
                    .stmt = stmt,
                    .page_id = page_id,
                    .index = stmt_index,
                } },
            });
            self.source_order += 1;
        }
    }

    fn nextPageId(self: *GraphBuilder, module: *const core.SourceModule, page: ast.PageDecl) !core.NodeId {
        return switch (self.page_id_mode) {
            .create => blk: {
                const page_id = try self.diagnostic_state.addPage(page.name);
                try self.diagnostic_state.addPageSource(
                    page_id,
                    module.id,
                    module.path orelse module.spec,
                    page.span,
                );
                break :blk page_id;
            },
            .synthetic => blk: {
                const id = std.math.maxInt(core.NodeId) - self.synthetic_page_count;
                self.synthetic_page_count += 1;
                break :blk id;
            },
        };
    }
};

fn validateExecutionUnits(state: *core.DocumentState, units: []const ExecutionUnit) !void {
    for (units) |unit| {
        if (unit.summary.invalid_selection_mutation) |invalid| {
            const message = "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated";
            try addUnitErrorDiagnostic(state, unit, message);
            _ = invalid;
            return error.InvalidSelectionMutation;
        }
        if (unit.summary.reads_layout and unit.summary.writes_layout_input) {
            const message = "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once";
            try addUnitErrorDiagnostic(state, unit, message);
            return error.LayoutDependencyCycle;
        }
        if (unit.summary.reads_layout) {
            const message = "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet";
            try addUnitErrorDiagnostic(state, unit, message);
            return error.PostLayoutComputationUnsupported;
        }
    }
}

fn buildDependencyEdges(allocator: std.mem.Allocator, units: []const ExecutionUnit, edges: *std.ArrayList(DependencyEdge)) !void {
    var edge_index = EdgeIndex.init(allocator);
    defer edge_index.deinit();

    var writer_index = ResourceWriterIndex.init(allocator);
    defer writer_index.deinit();
    for (units, 0..) |writer, unit_index| {
        try writer_index.addSummary(unit_index, writer.summary);
    }

    for (units, 0..) |reader, reader_index| {
        if (reader.summary.reads.items.len == 0) continue;
        for (reader.summary.reads.items) |read| {
            try writer_index.addEdgesForRead(read, reader_index, edges, &edge_index);
        }
    }
}

const EdgeKey = struct {
    from: usize,
    to: usize,
};

const EdgeKeyContext = struct {
    pub fn hash(_: EdgeKeyContext, key: EdgeKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.from));
        hasher.update(std.mem.asBytes(&key.to));
        return hasher.final();
    }

    pub fn eql(_: EdgeKeyContext, left: EdgeKey, right: EdgeKey) bool {
        return left.from == right.from and left.to == right.to;
    }
};

const EdgeIndex = std.HashMap(EdgeKey, usize, EdgeKeyContext, std.hash_map.default_max_load_percentage);

const WriteEntry = struct {
    unit_index: usize,
    resource: dependencies.Resource,
};

const WriteEntryList = std.ArrayList(WriteEntry);
const WriteEntryStringMap = std.StringHashMap(WriteEntryList);

const ResourceWriterIndex = struct {
    allocator: std.mem.Allocator,
    variables_by_name: WriteEntryStringMap,
    pages: WriteEntryList,
    object_any: WriteEntryList,
    objects_by_role: WriteEntryStringMap,
    property_any_key: WriteEntryList,
    property_content_key: WriteEntryList,
    properties_by_key: WriteEntryStringMap,

    fn init(allocator: std.mem.Allocator) ResourceWriterIndex {
        return .{
            .allocator = allocator,
            .variables_by_name = WriteEntryStringMap.init(allocator),
            .pages = .empty,
            .object_any = .empty,
            .objects_by_role = WriteEntryStringMap.init(allocator),
            .property_any_key = .empty,
            .property_content_key = .empty,
            .properties_by_key = WriteEntryStringMap.init(allocator),
        };
    }

    fn deinit(self: *ResourceWriterIndex) void {
        deinitStringMapLists(self.allocator, &self.variables_by_name);
        self.pages.deinit(self.allocator);
        self.object_any.deinit(self.allocator);
        deinitStringMapLists(self.allocator, &self.objects_by_role);
        self.property_any_key.deinit(self.allocator);
        self.property_content_key.deinit(self.allocator);
        deinitStringMapLists(self.allocator, &self.properties_by_key);
    }

    fn addSummary(self: *ResourceWriterIndex, unit_index: usize, summary: dependencies.AccessSummary) !void {
        for (summary.writes.items) |write| {
            try self.addWrite(unit_index, write);
        }
    }

    fn addWrite(self: *ResourceWriterIndex, unit_index: usize, write: dependencies.Resource) !void {
        const entry = WriteEntry{ .unit_index = unit_index, .resource = write };
        switch (write) {
            .variable => |variable| try self.appendStringBucket(&self.variables_by_name, variable.name, entry),
            .pages => try self.pages.append(self.allocator, entry),
            .objects => |role_name| {
                if (role_name) |name| {
                    try self.appendStringBucket(&self.objects_by_role, name, entry);
                } else {
                    try self.object_any.append(self.allocator, entry);
                }
            },
            .property => |property| switch (property.key) {
                .any => try self.property_any_key.append(self.allocator, entry),
                .content => try self.property_content_key.append(self.allocator, entry),
                .named => |name| {
                    try self.appendStringBucket(&self.properties_by_key, name, entry);
                    if (propertyNameIsContent(name)) try self.property_content_key.append(self.allocator, entry);
                },
            },
        }
    }

    fn addEdgesForRead(
        self: *const ResourceWriterIndex,
        read: dependencies.Resource,
        reader_index: usize,
        edges: *std.ArrayList(DependencyEdge),
        edge_index: *EdgeIndex,
    ) !void {
        switch (read) {
            .variable => |variable| {
                if (self.variables_by_name.get(variable.name)) |entries| {
                    try self.addEdgesFromEntries(entries.items, read, reader_index, edges, edge_index);
                }
            },
            .pages => try self.addEdgesFromEntries(self.pages.items, read, reader_index, edges, edge_index),
            .objects => |role_name| {
                try self.addEdgesFromEntries(self.object_any.items, read, reader_index, edges, edge_index);
                if (role_name) |name| {
                    if (self.objects_by_role.get(name)) |entries| {
                        try self.addEdgesFromEntries(entries.items, read, reader_index, edges, edge_index);
                    }
                } else {
                    var roles = self.objects_by_role.valueIterator();
                    while (roles.next()) |entries| {
                        try self.addEdgesFromEntries(entries.items, read, reader_index, edges, edge_index);
                    }
                }
            },
            .property => |property| {
                try self.addEdgesFromEntries(self.property_any_key.items, read, reader_index, edges, edge_index);
                switch (property.key) {
                    .any => {
                        try self.addEdgesFromEntries(self.property_content_key.items, read, reader_index, edges, edge_index);
                        var keys = self.properties_by_key.valueIterator();
                        while (keys.next()) |entries| {
                            try self.addEdgesFromEntries(entries.items, read, reader_index, edges, edge_index);
                        }
                    },
                    .content => try self.addEdgesFromEntries(self.property_content_key.items, read, reader_index, edges, edge_index),
                    .named => |name| {
                        if (propertyNameIsContent(name)) {
                            try self.addEdgesFromEntries(self.property_content_key.items, read, reader_index, edges, edge_index);
                        }
                        if (self.properties_by_key.get(name)) |entries| {
                            try self.addEdgesFromEntries(entries.items, read, reader_index, edges, edge_index);
                        }
                    },
                }
            },
        }
    }

    fn addEdgesFromEntries(
        self: *const ResourceWriterIndex,
        entries: []const WriteEntry,
        read: dependencies.Resource,
        reader_index: usize,
        edges: *std.ArrayList(DependencyEdge),
        edge_index: *EdgeIndex,
    ) !void {
        for (entries) |entry| {
            if (entry.resource.intersects(read)) {
                try addDependencyEdge(self.allocator, edges, edge_index, entry.unit_index, reader_index);
            }
        }
    }

    fn appendStringBucket(self: *ResourceWriterIndex, map: *WriteEntryStringMap, key: []const u8, entry: WriteEntry) !void {
        const gop = try map.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, entry);
    }
};

fn deinitStringMapLists(allocator: std.mem.Allocator, map: *WriteEntryStringMap) void {
    var values = map.valueIterator();
    while (values.next()) |list| {
        list.deinit(allocator);
    }
    map.deinit();
}

fn propertyNameIsContent(name: []const u8) bool {
    return switch (dependencies.PropertyKey.fromName(name)) {
        .content => true,
        .any, .named => false,
    };
}

fn scheduleFromEdges(
    allocator: std.mem.Allocator,
    units: []const ExecutionUnit,
    edges: []const DependencyEdge,
    cycle_hint: *?usize,
) ![]usize {
    const count = units.len;
    const indegree = try allocator.alloc(usize, count);
    defer allocator.free(indegree);
    @memset(indegree, 0);

    for (edges) |edge| indegree[edge.to] += 1;
    const adjacency = try buildAdjacency(allocator, count, edges);
    defer adjacency.deinit(allocator);

    var done = try allocator.alloc(bool, count);
    defer allocator.free(done);
    @memset(done, false);

    var ready = ReadyQueue.init(allocator, units);
    defer ready.deinit();
    for (indegree, 0..) |degree, index| {
        if (degree == 0) try ready.push(index);
    }

    var out = try allocator.alloc(usize, count);
    errdefer allocator.free(out);
    var produced: usize = 0;
    while (ready.pop()) |next| {
        done[next] = true;
        out[produced] = next;
        produced += 1;
        for (adjacency.neighbors(next)) |to| {
            std.debug.assert(indegree[to] > 0);
            indegree[to] -= 1;
            if (indegree[to] == 0) try ready.push(to);
        }
    }
    if (produced != count) {
        var candidate: ?usize = null;
        for (units, 0..) |unit, index| {
            if (done[index] or indegree[index] == 0) continue;
            if (candidate == null or unit.source_order < units[candidate.?].source_order) candidate = index;
        }
        cycle_hint.* = candidate;
        return error.ExecutionDependencyCycle;
    }
    return out;
}

const Adjacency = struct {
    offsets: []usize,
    targets: []usize,

    fn deinit(self: Adjacency, allocator: std.mem.Allocator) void {
        allocator.free(self.offsets);
        allocator.free(self.targets);
    }

    fn neighbors(self: Adjacency, unit_index: usize) []const usize {
        return self.targets[self.offsets[unit_index]..self.offsets[unit_index + 1]];
    }
};

const ReadyQueue = struct {
    allocator: std.mem.Allocator,
    units: []const ExecutionUnit,
    heap: std.ArrayList(usize),

    fn init(allocator: std.mem.Allocator, units: []const ExecutionUnit) ReadyQueue {
        return .{
            .allocator = allocator,
            .units = units,
            .heap = .empty,
        };
    }

    fn deinit(self: *ReadyQueue) void {
        self.heap.deinit(self.allocator);
    }

    fn push(self: *ReadyQueue, unit_index: usize) !void {
        try self.heap.append(self.allocator, unit_index);
        self.siftUp(self.heap.items.len - 1);
    }

    fn pop(self: *ReadyQueue) ?usize {
        if (self.heap.items.len == 0) return null;
        const result = self.heap.items[0];
        const last = self.heap.pop().?;
        if (self.heap.items.len != 0) {
            self.heap.items[0] = last;
            self.siftDown(0);
        }
        return result;
    }

    fn siftUp(self: *ReadyQueue, start: usize) void {
        var index = start;
        while (index > 0) {
            const parent = (index - 1) / 2;
            if (!self.before(self.heap.items[index], self.heap.items[parent])) break;
            std.mem.swap(usize, &self.heap.items[index], &self.heap.items[parent]);
            index = parent;
        }
    }

    fn siftDown(self: *ReadyQueue, start: usize) void {
        var index = start;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.heap.items.len) break;
            const right = left + 1;
            var child = left;
            if (right < self.heap.items.len and self.before(self.heap.items[right], self.heap.items[left])) {
                child = right;
            }
            if (!self.before(self.heap.items[child], self.heap.items[index])) break;
            std.mem.swap(usize, &self.heap.items[index], &self.heap.items[child]);
            index = child;
        }
    }

    fn before(self: *const ReadyQueue, left: usize, right: usize) bool {
        const left_order = self.units[left].source_order;
        const right_order = self.units[right].source_order;
        if (left_order != right_order) return left_order < right_order;
        return left < right;
    }
};

fn buildAdjacency(allocator: std.mem.Allocator, unit_count: usize, edges: []const DependencyEdge) !Adjacency {
    var offsets = try allocator.alloc(usize, unit_count + 1);
    errdefer allocator.free(offsets);
    @memset(offsets, 0);

    for (edges) |edge| offsets[edge.from + 1] += 1;
    for (offsets[1..], 1..) |*offset, index| {
        offset.* += offsets[index - 1];
    }

    const targets = try allocator.alloc(usize, edges.len);
    errdefer allocator.free(targets);
    const cursor = try allocator.dupe(usize, offsets[0..unit_count]);
    defer allocator.free(cursor);
    for (edges) |edge| {
        targets[cursor[edge.from]] = edge.to;
        cursor[edge.from] += 1;
    }
    return .{ .offsets = offsets, .targets = targets };
}

fn addDependencyEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(DependencyEdge),
    edge_index: *EdgeIndex,
    from: usize,
    to: usize,
) !void {
    const key = EdgeKey{ .from = from, .to = to };
    const gop = try edge_index.getOrPut(key);
    if (gop.found_existing) return;
    errdefer _ = edge_index.remove(key);
    const edge_pos = edges.items.len;
    try edges.append(allocator, .{
        .from = from,
        .to = to,
    });
    errdefer edges.items.len -= 1;
    gop.value_ptr.* = edge_pos;
}

pub fn executionGraphJson(allocator: std.mem.Allocator, state: *const core.DocumentState, graph: *const ExecutionGraph) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try utils.json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("kind", "ss-schedule-trace");
    try root.stringField("entry_path", state.projectPath());

    var units = try root.arrayField("units");
    for (graph.units.items, 0..) |unit, index| {
        var item = try units.objectItem();
        try item.intField("id", index);
        try item.intField("source_order", unit.source_order);
        try item.intField("module_id", unit.module_id);
        try item.stringField("path", unit.path);
        try writeScheduleSpan(&item, unit.span);
        switch (unit.kind) {
            .document_statement => |data| {
                try item.stringField("kind", "document_statement");
                try item.nullField("page_id");
                try item.intField("statement_index", data.index);
            },
            .page_statement => |data| {
                try item.stringField("kind", "page_statement");
                try item.intField("page_id", data.page_id);
                try item.intField("statement_index", data.index);
            },
        }
        try item.stringField("source", executionUnitSource(unit));
        try item.end();
    }
    try units.end();

    var edges = try root.arrayField("edges");
    for (graph.edges.items) |edge| {
        var item = try edges.objectItem();
        try item.intField("from", edge.from);
        try item.intField("to", edge.to);
        try item.stringField("kind", "dependency");
        try item.end();
    }
    try edges.end();

    var execution_order = try root.arrayField("execution_order");
    for (graph.order) |unit_index| try execution_order.intItem(unit_index);
    try execution_order.end();

    try root.end();
    try utils.json.appendNewline(&buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn writeScheduleSpan(object: *utils.json.Object, span: ast.Span) !void {
    var span_object = try object.objectField("span");
    try span_object.intField("start", span.start);
    try span_object.intField("end", span.end);
    try span_object.end();
}

fn executionUnitSource(unit: ExecutionUnit) []const u8 {
    if (unit.span.start > unit.span.end or unit.span.end > unit.source.len) return "";
    return std.mem.trim(u8, unit.source[unit.span.start..unit.span.end], " \t\r\n");
}

fn addUnitErrorDiagnostic(state: *core.DocumentState, unit: ExecutionUnit, message: []const u8) !void {
    const origin = try unitOrigin(state.allocator, unit);
    defer state.allocator.free(origin);
    try state.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try state.allocator.dupe(u8, message) },
    });
}

fn unitOrigin(allocator: std.mem.Allocator, unit: ExecutionUnit) ![]const u8 {
    if (unit.path.len != 0) {
        return std.fmt.allocPrint(allocator, "path:{s}:bytes:{d}-{d}", .{ unit.path, unit.span.start, unit.span.end });
    }
    return std.fmt.allocPrint(allocator, "bytes:{d}-{d}", .{ unit.span.start, unit.span.end });
}

fn analysisErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidSelectionMutation => "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated",
        error.LayoutDependencyCycle => "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once",
        error.PostLayoutComputationUnsupported => "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet",
        error.ExecutionDependencyCycle => "ExecutionDependencyCycle: document evaluation dependencies contain a cycle",
        else => "ScheduleAnalysisFailed: scheduled unit analysis failed",
    };
}
