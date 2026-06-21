const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const utils = @import("utils");

const dependencies = @import("dependencies.zig");
const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

pub const PageIdMode = enum {
    synthetic,
    create,
};

pub const BuildOptions = struct {
    page_id_mode: PageIdMode = .synthetic,
};

pub const ScheduledUnit = struct {
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

    pub fn deinit(self: *ScheduledUnit) void {
        self.summary.deinit();
    }
};

pub const ScheduleEdge = struct {
    from: usize,
    to: usize,
    kind: Kind,

    pub const Kind = enum {
        dependency,
        write_order,
    };
};

pub const ScheduleGraph = struct {
    allocator: std.mem.Allocator,
    units: std.ArrayList(ScheduledUnit),
    edges: std.ArrayList(ScheduleEdge),
    order: []usize,

    pub fn build(
        allocator: std.mem.Allocator,
        ir: *const core.Ir,
        document: *core.Ir,
        options: BuildOptions,
    ) !ScheduleGraph {
        var graph = ScheduleGraph{
            .allocator = allocator,
            .units = .empty,
            .edges = .empty,
            .order = &.{},
        };
        errdefer graph.deinit();

        var collected_modules = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
        defer collected_modules.deinit();
        var context = BuildContext{
            .allocator = allocator,
            .core_ir = ir,
            .document = document,
            .functions = &ir.functions,
            .units = &graph.units,
            .collected_modules = &collected_modules,
            .source_order = 0,
            .page_id_mode = options.page_id_mode,
        };
        try context.collectScheduledUnits(ir.projectModule());
        try validateScheduledUnits(document, graph.units.items);
        try buildScheduleEdges(allocator, graph.units.items, &graph.edges);
        var cycle_hint: ?usize = null;
        graph.order = scheduleFromEdges(allocator, graph.units.items, graph.edges.items, &cycle_hint) catch |err| {
            if (err == error.ScheduledDependencyCycle and graph.units.items.len != 0) {
                try addUnitErrorDiagnostic(document, graph.units.items[cycle_hint orelse 0], analysisErrorMessage(err));
            }
            return err;
        };
        return graph;
    }

    pub fn deinit(self: *ScheduleGraph) void {
        self.allocator.free(self.order);
        self.edges.deinit(self.allocator);
        for (self.units.items) |*unit| unit.deinit();
        self.units.deinit(self.allocator);
    }
};

pub fn analyzeDependencies(allocator: std.mem.Allocator, ir: *core.Ir) !void {
    var graph = try ScheduleGraph.build(allocator, ir, ir, .{ .page_id_mode = .synthetic });
    defer graph.deinit();
}

pub fn scheduleTraceJson(allocator: std.mem.Allocator, ir: *core.Ir) ![]u8 {
    var graph = try ScheduleGraph.build(allocator, ir, ir, .{ .page_id_mode = .create });
    defer graph.deinit();
    return scheduleGraphJson(allocator, ir, &graph);
}

const BuildContext = struct {
    allocator: std.mem.Allocator,
    core_ir: *const core.Ir,
    document: *core.Ir,
    functions: *const core.FunctionMap,
    units: *std.ArrayList(ScheduledUnit),
    collected_modules: *std.AutoHashMap(core.SourceModuleId, void),
    source_order: usize,
    synthetic_page_count: core.NodeId = 0,
    page_id_mode: PageIdMode,

    fn collectScheduledUnits(self: *BuildContext, module: *const core.SourceModule) !void {
        if (module.kind == .library) {
            if (self.collected_modules.contains(module.id)) return;
            try self.collected_modules.put(module.id, {});
        }

        if (module.program.top_level_items.items.len == 0) {
            try self.appendDocumentStatementUnits(module, 0, module.program.document_statements.items.len);
            for (module.program.pages.items) |page| try self.appendPageStatementUnits(module, page);
            return;
        }

        for (module.program.top_level_items.items) |item| {
            switch (item) {
                .import => |import_index| {
                    if (import_index >= module.resolved_import_ids.items.len) continue;
                    const import_id = module.resolved_import_ids.items[import_index];
                    const imported = self.core_ir.moduleById(import_id) orelse continue;
                    try self.collectScheduledUnits(imported);
                },
                .document => |document_index| {
                    if (document_index >= module.program.document_blocks.items.len) continue;
                    const block = module.program.document_blocks.items[document_index];
                    try self.appendDocumentStatementUnits(module, block.statement_start, block.statement_count);
                },
                .page => |page_index| {
                    if (page_index >= module.program.pages.items.len) continue;
                    try self.appendPageStatementUnits(module, module.program.pages.items[page_index]);
                },
            }
        }
    }

    fn appendDocumentStatementUnits(
        self: *BuildContext,
        module: *const core.SourceModule,
        statement_start: usize,
        statement_count: usize,
    ) !void {
        const sema = SemanticEnv.init(self.core_ir, null, self.functions).forModule(module.id);
        var analyzer = dependencies.Analyzer.init(self.allocator, &sema);
        defer analyzer.deinit();
        const statement_end = @min(statement_start + statement_count, module.program.document_statements.items.len);
        for (module.program.document_statements.items[statement_start..statement_end], statement_start..) |stmt, stmt_index| {
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
        self: *BuildContext,
        module: *const core.SourceModule,
        page: ast.PageDecl,
    ) !void {
        const page_id = try self.nextPageId(page.name);
        const sema = SemanticEnv.init(self.document, null, self.functions).forModule(module.id);
        var analyzer = dependencies.Analyzer.initWithScope(self.allocator, &sema, .{ .page = page_id });
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

    fn nextPageId(self: *BuildContext, name: []const u8) !core.NodeId {
        return switch (self.page_id_mode) {
            .create => try self.document.addPage(name),
            .synthetic => blk: {
                const id = std.math.maxInt(core.NodeId) - self.synthetic_page_count;
                self.synthetic_page_count += 1;
                break :blk id;
            },
        };
    }
};

fn validateScheduledUnits(ir: *core.Ir, units: []const ScheduledUnit) !void {
    for (units) |unit| {
        if (unit.summary.invalid_selection_mutation) |invalid| {
            const message = "InvalidSelectionMutation: primitive callbacks must not add objects or pages to the selection being iterated";
            try addUnitErrorDiagnostic(ir, unit, message);
            _ = invalid;
            return error.InvalidSelectionMutation;
        }
        if (unit.summary.reads_layout and unit.summary.writes_layout_input) {
            const message = "LayoutDependencyCycle: layout reads cannot feed object creation, content, properties, or constraints because layout is solved once";
            try addUnitErrorDiagnostic(ir, unit, message);
            return error.LayoutDependencyCycle;
        }
        if (unit.summary.reads_layout) {
            const message = "PostLayoutComputationUnsupported: layout-reading scheduled computations are not implemented yet";
            try addUnitErrorDiagnostic(ir, unit, message);
            return error.PostLayoutComputationUnsupported;
        }
    }
}

fn buildScheduleEdges(allocator: std.mem.Allocator, units: []const ScheduledUnit, edges: *std.ArrayList(ScheduleEdge)) !void {
    var edge_index = EdgeIndex.init(allocator);
    defer edge_index.deinit();

    for (units, 0..) |writer, writer_index| {
        if (writer.summary.writes.items.len == 0) continue;
        for (units, 0..) |reader, reader_index| {
            if (writer_index == reader_index) continue;
            if (reader.summary.reads.items.len == 0) continue;
            if (summaryWritesRead(writer.summary, reader.summary)) {
                try addScheduleEdge(allocator, edges, &edge_index, writer_index, reader_index, .dependency);
            }
        }
    }
    for (units, 0..) |left, left_index| {
        if (left.summary.writes.items.len == 0) continue;
        for (units[left_index + 1 ..], left_index + 1..) |right, right_index| {
            if (right.summary.writes.items.len == 0) continue;
            if (summariesWriteSameResource(left.summary, right.summary)) {
                try addWriteOrderEdge(allocator, units, edges, &edge_index, left_index, right_index);
            }
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

fn scheduleFromEdges(
    allocator: std.mem.Allocator,
    units: []const ScheduledUnit,
    edges: []const ScheduleEdge,
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

    var out = try allocator.alloc(usize, count);
    errdefer allocator.free(out);
    var produced: usize = 0;
    while (produced < count) {
        var best: ?usize = null;
        for (units, 0..) |unit, index| {
            if (done[index] or indegree[index] != 0) continue;
            if (best == null or unit.source_order < units[best.?].source_order) best = index;
        }
        const next = best orelse {
            var candidate: ?usize = null;
            for (units, 0..) |unit, index| {
                if (done[index] or indegree[index] == 0) continue;
                if (candidate == null or unit.source_order < units[candidate.?].source_order) candidate = index;
            }
            cycle_hint.* = candidate;
            return error.ScheduledDependencyCycle;
        };
        done[next] = true;
        out[produced] = next;
        produced += 1;
        for (adjacency.neighbors(next)) |to| {
            std.debug.assert(indegree[to] > 0);
            indegree[to] -= 1;
        }
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

fn buildAdjacency(allocator: std.mem.Allocator, unit_count: usize, edges: []const ScheduleEdge) !Adjacency {
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

fn summaryWritesRead(writer: dependencies.AccessSummary, reader: dependencies.AccessSummary) bool {
    for (writer.writes.items) |write| {
        for (reader.reads.items) |read| {
            if (summaryWritesResource(reader, write)) continue;
            if (write.intersects(read)) return true;
        }
    }
    return false;
}

fn summaryWritesResource(summary: dependencies.AccessSummary, resource: dependencies.Resource) bool {
    for (summary.writes.items) |write| {
        if (write.intersects(resource)) return true;
    }
    return false;
}

fn summariesWriteSameResource(left: dependencies.AccessSummary, right: dependencies.AccessSummary) bool {
    for (left.writes.items) |write| {
        for (right.writes.items) |right_write| {
            if (write.intersects(right_write)) return true;
        }
    }
    return false;
}

fn addWriteOrderEdge(
    allocator: std.mem.Allocator,
    units: []const ScheduledUnit,
    edges: *std.ArrayList(ScheduleEdge),
    edge_index: *EdgeIndex,
    left_index: usize,
    right_index: usize,
) !void {
    if (units[left_index].source_order <= units[right_index].source_order) {
        try addScheduleEdge(allocator, edges, edge_index, left_index, right_index, .write_order);
    } else {
        try addScheduleEdge(allocator, edges, edge_index, right_index, left_index, .write_order);
    }
}

fn addScheduleEdge(
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(ScheduleEdge),
    edge_index: *EdgeIndex,
    from: usize,
    to: usize,
    kind: ScheduleEdge.Kind,
) !void {
    const key = EdgeKey{ .from = from, .to = to };
    if (edge_index.get(key)) |edge_pos| {
        if (kind == .dependency) edges.items[edge_pos].kind = .dependency;
        return;
    }
    const edge_pos = edges.items.len;
    try edges.append(allocator, .{
        .from = from,
        .to = to,
        .kind = kind,
    });
    errdefer edges.items.len -= 1;
    try edge_index.putNoClobber(key, edge_pos);
}

pub fn scheduleGraphJson(allocator: std.mem.Allocator, ir: *const core.Ir, graph: *const ScheduleGraph) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);

    var root = try utils.json.Object.beginBuffer(allocator, &buffer);
    try root.intField("schema", 1);
    try root.stringField("kind", "ss-schedule-trace");
    try root.stringField("entry_path", ir.projectPath());

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
        try item.stringField("source", scheduledUnitSource(unit));
        try item.end();
    }
    try units.end();

    var edges = try root.arrayField("edges");
    for (graph.edges.items) |edge| {
        var item = try edges.objectItem();
        try item.intField("from", edge.from);
        try item.intField("to", edge.to);
        try item.enumTagField("kind", edge.kind);
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

fn scheduledUnitSource(unit: ScheduledUnit) []const u8 {
    if (unit.span.start > unit.span.end or unit.span.end > unit.source.len) return "";
    return std.mem.trim(u8, unit.source[unit.span.start..unit.span.end], " \t\r\n");
}

fn addUnitErrorDiagnostic(ir: *core.Ir, unit: ScheduledUnit, message: []const u8) !void {
    const origin = try unitOrigin(ir.allocator, unit);
    defer ir.allocator.free(origin);
    try ir.addValidationDiagnostic(.@"error", null, null, origin, .{
        .user_report = .{ .message = try ir.allocator.dupe(u8, message) },
    });
}

fn unitOrigin(allocator: std.mem.Allocator, unit: ScheduledUnit) ![]const u8 {
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
        error.ScheduledDependencyCycle => "ScheduledDependencyCycle: document evaluation dependencies contain a cycle",
        else => @errorName(err),
    };
}
