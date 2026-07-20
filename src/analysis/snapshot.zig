const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const editor_snapshot = @import("../editor/snapshot.zig");
const project = @import("../project.zig");

const diagnostics = @import("diagnostics.zig");
const hole_facts = @import("hole_facts.zig");
const declarations = @import("../language/declarations.zig");
const registry = @import("../language/registry.zig");
const module_loader = @import("../modules/loader.zig");
const module_index = @import("module_index.zig");
const analysis_pipeline = @import("pipeline.zig");
const execution = @import("execution.zig");
const query_completion = @import("query/completion.zig");
const query_definition = @import("query/definition.zig");
const query_folding = @import("query/folding.zig");
const query_hover = @import("query/hover.zig");
const query_signature = @import("query/signature.zig");
const query_symbols = @import("query/symbols.zig");
const query_types = @import("query/types.zig");
const semantic_types = @import("types.zig");
const syntax_hole = @import("../syntax/hole.zig");
const syntax = @import("../syntax.zig");
const utils = @import("utils");

pub const SourceRequest = query_types.SourceRequest;
pub const QueryOptions = query_types.QueryOptions;
pub const HoverInfo = query_types.HoverInfo;
pub const DefinitionTarget = query_types.DefinitionTarget;
pub const CompletionCandidate = query_types.CompletionCandidate;
pub const CompletionKind = query_types.CompletionKind;
pub const CompletionResult = query_types.CompletionResult;
pub const SourceSet = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    overlay: module_loader.SourceOverlay,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) SourceSet {
        return .{
            .allocator = allocator,
            .io = io,
            .overlay = module_loader.SourceOverlay.init(allocator),
        };
    }

    pub fn deinit(self: *SourceSet) void {
        self.overlay.deinit();
    }

    pub fn put(self: *SourceSet, path: []const u8, text: []const u8) !void {
        try self.overlay.put(path, text);
    }

    pub fn readFileAlloc(self: *const SourceSet, path: []const u8) ![]u8 {
        if (self.overlay.get(path)) |text| return self.allocator.dupe(u8, text);
        return utils.fs.readFileAlloc(self.io, self.allocator, path);
    }
};

pub const LayoutHookOutput = struct {
    editor: ?editor_snapshot.Output = null,
};

pub const LayoutHook = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, state: *core.DocumentState, graph: *const execution.ExecutionGraph) anyerror!LayoutHookOutput,
    on_error: ?*const fn (context: *anyopaque, state: *core.DocumentState, err: anyerror) anyerror!void = null,
};

pub const Options = struct {
    generation: u64 = 0,
    project: ProjectOptions = .{},
    layout_hook: ?LayoutHook = null,
    cancellation: ?utils.Cancellation = null,
    embedded_cache: ?*module_loader.EmbeddedSyntaxCache = null,

    fn checkCanceled(self: Options) !void {
        if (self.cancellation) |cancellation| try cancellation.check();
    }
};

pub const ProjectFacts = struct {
    entry_path: []u8 = &.{},
    asset_base_dir: []u8 = &.{},
    module_paths: [][]u8 = &.{},
    lsp: project.LspConfig = .{},
    wysiwyg: project.WysiwygConfig = .{},
    page_guide: project.PageGuideConfig = .{},

    pub fn deinit(self: *ProjectFacts, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        for (self.module_paths) |path| allocator.free(path);
        allocator.free(self.module_paths);
        self.* = .{};
    }
};

pub const ProjectOptions = struct {
    lsp: project.LspConfig = .{},
    wysiwyg: project.WysiwygConfig = .{},
    page_guide: project.PageGuideConfig = .{},
};

pub const ModuleFact = struct {
    id: core.SourceModuleId,
    kind: core.SourceModuleKind,
    spec: []u8,
    path: ?[]u8,
    source: []u8,
    imports: []ImportFact = &.{},
    implicit_import_ids: []core.SourceModuleId = &.{},
    function_scopes: []ScopeFact = &.{},
    page_scopes: []ScopeFact = &.{},
    symbols: []query_symbols.Symbol = &.{},
    folding_ranges: []query_folding.Range = &.{},
};

pub const ScopeFact = struct {
    name: []u8,
    start: usize,
    end: usize,
};

pub const ImportFact = struct {
    spec: []u8,
    spec_span: ast.Span,
    alias: ?[]u8 = null,
    unqualified: bool = false,
    alias_span: ?ast.Span = null,
    module_id: ?core.SourceModuleId = null,
};

pub const TypeDefinitionKind = enum {
    record,
    object,
    enum_type,
};

pub const TypeDefinition = struct {
    name: []u8,
    kind: TypeDefinitionKind,
    module_id: core.SourceModuleId,
    line: usize,
    column: usize,
    length: usize,
};

pub const ValueBindingKind = enum {
    function,
    constant,
};

pub const ValueBinding = struct {
    name: []u8,
    kind: ValueBindingKind,
    module_id: ?core.SourceModuleId,
    signature: []u8,
    type_label: []u8,
    documentation: []u8,
    primitive: bool = false,
};

pub const VariableBinding = struct {
    name: []u8,
    type_label: []u8,
    object_class: ?[]u8 = null,
    module_id: core.SourceModuleId,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]u8 = null,
    span_start: usize,
    span_end: usize,
    visible_start: usize,
    visible_end: usize,
};

pub const RoleBinding = struct {
    name: []u8,
    type_label: []u8,
    module_id: core.SourceModuleId,
};

pub const ClassFact = struct {
    name: []u8,
    base: ?[]u8 = null,
    module_id: core.SourceModuleId,
};

pub const FieldFact = struct {
    name: []u8,
    class_name: []u8,
    type_label: []u8,
    module_id: core.SourceModuleId,
    name_span: ?ast.Span = null,
};

pub const RecordFact = struct {
    name: []u8,
    module_id: core.SourceModuleId,
};

pub const RecordFieldFact = struct {
    name: []u8,
    record_name: []u8,
    type_label: []u8,
    module_id: core.SourceModuleId,
    name_span: ?ast.Span = null,
};

pub const EnumCaseFact = struct {
    name: []u8,
    enum_name: []u8,
    module_id: core.SourceModuleId,
    name_span: ?ast.Span = null,
};

pub const LayoutOutput = struct {
    conflicts_json: []u8,
    report: core.layout.conflicts.Report,
    editor: ?editor_snapshot.Output = null,

    pub fn fromDocumentState(allocator: std.mem.Allocator, state: *core.DocumentState, owned_editor: ?editor_snapshot.Output) !LayoutOutput {
        var editor = owned_editor;
        errdefer if (editor) |*value| value.deinit();
        const conflicts_json = try core.layout.conflicts.toJson(allocator, state);
        errdefer allocator.free(conflicts_json);
        return .{
            .conflicts_json = conflicts_json,
            .report = try core.layout.conflicts.Report.init(allocator, state),
            .editor = editor,
        };
    }

    pub fn deinit(self: *LayoutOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.conflicts_json);
        self.report.deinit();
        if (self.editor) |*value| value.deinit();
    }
};

pub const AnalysisSnapshot = struct {
    allocator: std.mem.Allocator,
    generation: u64 = 0,
    project: ProjectFacts = .{},
    modules: []ModuleFact = &.{},
    module_order: []core.SourceModuleId = &.{},
    holes: []syntax_hole.Hole = &.{},
    definitions: []core.Definition = &.{},
    type_definitions: []TypeDefinition = &.{},
    value_bindings: []ValueBinding = &.{},
    variable_bindings: []VariableBinding = &.{},
    role_bindings: []RoleBinding = &.{},
    classes: []ClassFact = &.{},
    fields: []FieldFact = &.{},
    records: []RecordFact = &.{},
    record_fields: []RecordFieldFact = &.{},
    enum_cases: []EnumCaseFact = &.{},
    layout_output: ?LayoutOutput = null,
    diagnostics: diagnostics.DiagnosticBag,

    pub fn fromDocumentState(
        allocator: std.mem.Allocator,
        state: *core.DocumentState,
        declaration_index: *const declarations.DeclarationIndex,
        diagnostic_bag: diagnostics.DiagnosticBag,
        holes: ?*const syntax_hole.Result,
        project_facts: ProjectFacts,
    ) !AnalysisSnapshot {
        var snapshot = AnalysisSnapshot{
            .allocator = allocator,
            .diagnostics = diagnostic_bag,
            .project = project_facts,
        };
        errdefer snapshot.deinit();

        snapshot.diagnostics.sortByPath();
        snapshot.modules = try cloneModules(allocator, state.modules.items);
        snapshot.module_order = try allocator.dupe(core.SourceModuleId, state.module_order.items);
        snapshot.holes = if (holes) |hole_table| try cloneHoles(allocator, hole_table.holes) else &.{};
        snapshot.definitions = try cloneDefinitions(allocator, state.definitions.items);
        snapshot.type_definitions = try collectTypeDefinitions(allocator, state);
        snapshot.value_bindings = try collectValueBindings(allocator, state);
        snapshot.variable_bindings = try collectVariableBindings(allocator, state, declaration_index);
        snapshot.role_bindings = try collectRoleBindings(allocator, declaration_index.roles.items);
        snapshot.classes = try collectClasses(allocator, declaration_index.classes.items);
        snapshot.fields = try collectFields(allocator, declaration_index.fields.items);
        snapshot.records = try collectRecords(allocator, declaration_index.records.items);
        snapshot.record_fields = try collectRecordFields(allocator, declaration_index.record_fields.items);
        snapshot.enum_cases = try collectEnumCases(allocator, declaration_index.types.items);
        return snapshot;
    }

    pub fn fromDiagnostics(
        allocator: std.mem.Allocator,
        diagnostic_bag: diagnostics.DiagnosticBag,
        project_facts: ProjectFacts,
    ) AnalysisSnapshot {
        var snapshot = AnalysisSnapshot{
            .allocator = allocator,
            .diagnostics = diagnostic_bag,
            .project = project_facts,
        };
        snapshot.diagnostics.sortByPath();
        return snapshot;
    }

    pub fn deinit(self: *AnalysisSnapshot) void {
        self.project.deinit(self.allocator);
        for (self.modules) |module| {
            self.allocator.free(module.spec);
            if (module.path) |path| self.allocator.free(path);
            self.allocator.free(module.source);
            deinitImports(self.allocator, module.imports);
            self.allocator.free(module.implicit_import_ids);
            deinitScopes(self.allocator, module.function_scopes);
            deinitScopes(self.allocator, module.page_scopes);
            query_symbols.deinit(self.allocator, module.symbols);
            self.allocator.free(module.folding_ranges);
        }
        self.allocator.free(self.modules);
        self.allocator.free(self.module_order);
        for (self.holes) |*hole| hole.deinit(self.allocator);
        self.allocator.free(self.holes);
        for (self.definitions) |definition| {
            self.allocator.free(definition.name);
            if (definition.file) |file| self.allocator.free(file);
            if (definition.scope_name) |scope_name| self.allocator.free(scope_name);
        }
        self.allocator.free(self.definitions);
        for (self.type_definitions) |definition| self.allocator.free(definition.name);
        self.allocator.free(self.type_definitions);
        deinitValueBindings(self.allocator, self.value_bindings);
        deinitVariableBindings(self.allocator, self.variable_bindings);
        deinitRoleBindings(self.allocator, self.role_bindings);
        deinitClasses(self.allocator, self.classes);
        deinitFields(self.allocator, self.fields);
        deinitRecords(self.allocator, self.records);
        deinitRecordFields(self.allocator, self.record_fields);
        deinitEnumCases(self.allocator, self.enum_cases);
        if (self.layout_output) |*layout| layout.deinit(self.allocator);
        self.diagnostics.deinit();
        self.* = .{
            .allocator = self.allocator,
            .diagnostics = diagnostics.DiagnosticBag.init(self.allocator),
        };
    }

    pub fn moduleById(self: *const AnalysisSnapshot, module_id: core.SourceModuleId) ?ModuleFact {
        for (self.modules) |module| {
            if (module.id == module_id) return module;
        }
        return null;
    }

    pub fn moduleForPath(self: *const AnalysisSnapshot, path: []const u8) ?ModuleFact {
        for (self.modules) |module| {
            const module_path = module.path orelse continue;
            if (std.mem.eql(u8, module_path, path)) return module;
        }
        return null;
    }

    pub fn typeDefinition(self: *const AnalysisSnapshot, kind: TypeDefinitionKind, name: []const u8, module_id: core.SourceModuleId) ?TypeDefinition {
        for (self.type_definitions) |definition| {
            if (definition.kind != kind) continue;
            if (definition.module_id != module_id) continue;
            if (!std.mem.eql(u8, definition.name, name)) continue;
            return definition;
        }
        return null;
    }

    pub fn coversPath(self: *const AnalysisSnapshot, path: []const u8) bool {
        if (std.mem.eql(u8, self.project.entry_path, path)) return true;
        for (self.project.module_paths) |module_path| {
            if (std.mem.eql(u8, module_path, path)) return true;
        }
        return false;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    sources: *const SourceSet,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    options: Options,
) !AnalysisSnapshot {
    try options.checkCanceled();
    var diagnostic_bag = diagnostics.DiagnosticBag.init(allocator);
    var diagnostics_moved = false;
    defer if (!diagnostics_moved) diagnostic_bag.deinit();
    var layout_output: ?LayoutOutput = null;
    defer if (layout_output) |*facts| facts.deinit(allocator);

    var entry_source = sources.readFileAlloc(entry_path) catch |err| {
        try addBuildDiagnostic(&diagnostic_bag, entry_path, "", .@"error", "ProjectReadFailed", "ProjectReadFailed: could not read {s}: {s}", .{ entry_path, @errorName(err) }, null);
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved);
    };
    options.checkCanceled() catch |err| {
        allocator.free(entry_source);
        return err;
    };

    const parse_result = syntax.parseRecoveringWithSourceName(allocator, entry_source, entry_path) catch |err| {
        const diagnostic = syntax.lastParseDiagnostic();
        var message_buf: [256]u8 = undefined;
        const message = if (diagnostic) |diag|
            utils.err.formatParseDiagnostic(&message_buf, diag)
        else
            utils.err.formatParseFailureWithoutDiagnostic(&message_buf, err);
        try diagnostic_bag.add(entry_path, entry_source, .@"error", @errorName(err), message, if (diagnostic) |diag| .{
            .start = diag.span.start,
            .end = diag.span.end,
        } else null, null);
        allocator.free(entry_source);
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved);
    };
    var program = parse_result.module;
    var parse_holes = parse_result.holes;
    options.checkCanceled() catch |err| {
        program.deinit(allocator);
        parse_holes.deinit(allocator);
        allocator.free(entry_source);
        return err;
    };

    var load_diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer load_diagnostics.deinit();
    var index = module_index.load(allocator, sources.io, asset_base_dir, program, .{
        .overlay = &sources.overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
        .recovering = true,
        .embedded_cache = options.embedded_cache,
    }) catch |err| {
        try diagnostic_bag.addSyntaxHoles(entry_path, entry_source, parse_holes);
        try addLoadDiagnostics(&diagnostic_bag, &load_diagnostics);
        if (load_diagnostics.items.items.len != 0) {
            const span = module_loader.importFailureSpan(allocator, sources.io, asset_base_dir, &program, &sources.overlay, &load_diagnostics);
            try diagnostic_bag.add(entry_path, entry_source, .@"error", "ImportFailed", "ImportFailed: imported module failed to load", span, null);
        } else if (err == error.UnknownImport) {
            if (try module_loader.findUnknownImportReport(allocator, sources.io, asset_base_dir, program, &sources.overlay)) |found| {
                var report = found;
                defer report.deinit(allocator);
                try diagnostic_bag.add(entry_path, entry_source, .@"error", "UnknownImport", report.message, .{
                    .start = report.span.start,
                    .end = report.span.end,
                }, null);
            }
        } else {
            try addBuildDiagnostic(&diagnostic_bag, entry_path, entry_source, .@"error", @errorName(err), "ProjectLoadFailed: {s}", .{@errorName(err)}, null);
        }
        program.deinit(allocator);
        parse_holes.deinit(allocator);
        allocator.free(entry_source);
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved);
    };
    defer index.deinit();
    options.checkCanceled() catch |err| {
        program.deinit(allocator);
        parse_holes.deinit(allocator);
        allocator.free(entry_source);
        return err;
    };

    var state = analysis_pipeline.buildDocumentStateWithOptions(allocator, entry_path, asset_base_dir, &entry_source, &program, &index, .{
        .allow_diagnostics = true,
        .parse_holes = parse_holes,
    }) catch |err| {
        try addBuildDiagnostic(&diagnostic_bag, entry_path, entry_source, .@"error", @errorName(err), "BuildFailed: {s}", .{@errorName(err)}, null);
        program.deinit(allocator);
        parse_holes.deinit(allocator);
        if (entry_source.len != 0) allocator.free(entry_source);
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved);
    };
    defer parse_holes.deinit(allocator);
    defer state.deinit();
    try options.checkCanceled();

    var execution_graph = analysis_pipeline.analyzeDocumentStateWithMode(allocator, &state, .evaluation) catch |err| switch (err) {
        error.DiagnosticsFailed => null,
        else => return err,
    };
    defer if (execution_graph) |*graph| graph.deinit();
    try options.checkCanceled();
    var fallback_declarations: ?declarations.DeclarationIndex = null;
    defer if (fallback_declarations) |*index_value| index_value.deinit();
    const declaration_index: *const declarations.DeclarationIndex = if (execution_graph) |*graph|
        &graph.declarations
    else blk: {
        fallback_declarations = try declarations.build(allocator, &state);
        break :blk &fallback_declarations.?;
    };
    try hole_facts.populateExpectedTypes(allocator, &state, declaration_index, &parse_holes);
    try options.checkCanceled();
    try diagnostic_bag.addDocumentState(&state);
    try options.checkCanceled();
    if (!diagnostic_bag.hasErrors()) {
        if (options.layout_hook) |hook| {
            if (execution_graph) |*graph| {
                try options.checkCanceled();
                if (hook.run(hook.context, &state, graph)) |result| {
                    layout_output = try LayoutOutput.fromDocumentState(allocator, &state, result.editor);
                    try diagnostic_bag.addDocumentState(&state);
                } else |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    error.ConstraintConflict,
                    error.NegativeFrameSize,
                    => {
                        if (hook.on_error) |on_error| {
                            try on_error(hook.context, &state, err);
                            layout_output = try LayoutOutput.fromDocumentState(allocator, &state, null);
                        } else {
                            try addBuildDiagnostic(&diagnostic_bag, entry_path, state.projectSource(), .@"error", @errorName(err), "BuildFailed: {s}", .{@errorName(err)}, null);
                        }
                    },
                    else => {
                        try diagnostic_bag.addDocumentState(&state);
                        if (!diagnostic_bag.hasErrors()) {
                            try addBuildDiagnostic(&diagnostic_bag, entry_path, state.projectSource(), .@"error", @errorName(err), "BuildFailed: {s}", .{@errorName(err)}, null);
                        }
                    },
                }
            } else {
                try addBuildDiagnostic(&diagnostic_bag, entry_path, state.projectSource(), .@"error", "ScheduleBuildFailed", "ScheduleBuildFailed: evaluation schedule was not available", .{}, null);
            }
        }
    }
    try options.checkCanceled();

    const module_paths = try collectModulePaths(allocator, &state);
    try options.checkCanceled();
    const project_facts = try initProjectFacts(allocator, entry_path, asset_base_dir, module_paths, options.project);
    diagnostics_moved = true;
    const snapshot_facts_start = utils.measure_profile.start();
    var snapshot = try AnalysisSnapshot.fromDocumentState(allocator, &state, declaration_index, diagnostic_bag, &parse_holes, project_facts);
    utils.measure_profile.recordAnalysis(.snapshot_facts, snapshot_facts_start);
    snapshot.generation = options.generation;
    snapshot.layout_output = layout_output;
    layout_output = null;
    return snapshot;
}

fn finishDiagnosticSnapshot(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    generation: u64,
    options: ProjectOptions,
    diagnostic_bag: *diagnostics.DiagnosticBag,
    diagnostics_moved: *bool,
) !AnalysisSnapshot {
    var project_facts = try initProjectFacts(allocator, entry_path, asset_base_dir, &.{}, options);
    errdefer project_facts.deinit(allocator);
    var snapshot = AnalysisSnapshot.fromDiagnostics(allocator, diagnostic_bag.*, project_facts);
    snapshot.generation = generation;
    diagnostics_moved.* = true;
    return snapshot;
}

fn initProjectFacts(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    module_paths: [][]u8,
    options: ProjectOptions,
) !ProjectFacts {
    var facts = ProjectFacts{
        .module_paths = module_paths,
        .lsp = options.lsp,
        .wysiwyg = options.wysiwyg,
        .page_guide = options.page_guide,
    };
    errdefer facts.deinit(allocator);
    facts.entry_path = try allocator.dupe(u8, entry_path);
    facts.asset_base_dir = try allocator.dupe(u8, asset_base_dir);
    return facts;
}

fn addLoadDiagnostics(bag: *diagnostics.DiagnosticBag, load_diagnostics: *const module_loader.LoadDiagnostics) !void {
    for (load_diagnostics.items.items) |item| {
        try bag.add(item.path, item.source, item.severity, item.code, item.message, item.span, null);
    }
}

fn addBuildDiagnostic(
    bag: *diagnostics.DiagnosticBag,
    path: []const u8,
    text: []const u8,
    severity: diagnostics.Severity,
    code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
    span: ?utils.source.ByteSpan,
) !void {
    const message = try std.fmt.allocPrint(bag.allocator, fmt, args);
    defer bag.allocator.free(message);
    try bag.add(path, text, severity, code, message, span, null);
}

fn collectModulePaths(allocator: std.mem.Allocator, state: *const core.DocumentState) ![][]u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }
    for (state.modules.items) |module| {
        const module_path = module.path orelse continue;
        if (seen.contains(module_path)) continue;
        try seen.put(module_path, {});
        try out.append(allocator, try allocator.dupe(u8, module_path));
    }
    return out.toOwnedSlice(allocator);
}

pub fn completeAt(
    allocator: std.mem.Allocator,
    snapshot: *const AnalysisSnapshot,
    req: SourceRequest,
    opts: QueryOptions,
) !CompletionResult {
    return query_completion.at(allocator, snapshot, req, opts);
}

pub fn hoverAt(
    allocator: std.mem.Allocator,
    snapshot: *const AnalysisSnapshot,
    req: SourceRequest,
    opts: QueryOptions,
) !?HoverInfo {
    return query_hover.at(allocator, snapshot, req, opts);
}

pub fn definitionAt(
    allocator: std.mem.Allocator,
    snapshot: *const AnalysisSnapshot,
    req: SourceRequest,
    opts: QueryOptions,
) ![]DefinitionTarget {
    return query_definition.at(allocator, snapshot, req, opts);
}

pub fn documentSymbols(snapshot: *const AnalysisSnapshot, path: []const u8) []const query_symbols.Symbol {
    const module = snapshot.moduleForPath(path) orelse return &.{};
    return module.symbols;
}

pub fn foldingRanges(snapshot: *const AnalysisSnapshot, path: []const u8) []const query_folding.Range {
    const module = snapshot.moduleForPath(path) orelse return &.{};
    return module.folding_ranges;
}

pub fn sourceForPath(snapshot: *const AnalysisSnapshot, path: []const u8) ?[]const u8 {
    const module = snapshot.moduleForPath(path) orelse return null;
    return module.source;
}

pub fn diagnosticsForPath(snapshot: *const AnalysisSnapshot, path: []const u8) []const diagnostics.Diagnostic {
    return snapshot.diagnostics.itemsForPath(path);
}

fn cloneDefinitions(allocator: std.mem.Allocator, definitions: []const core.Definition) ![]core.Definition {
    var out = std.ArrayList(core.Definition).empty;
    errdefer {
        for (out.items) |definition| {
            allocator.free(definition.name);
            if (definition.file) |file| allocator.free(file);
            if (definition.scope_name) |scope_name| allocator.free(scope_name);
        }
        out.deinit(allocator);
    }
    for (definitions) |definition| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, definition.name),
            .line = definition.line,
            .column = definition.column,
            .length = definition.length,
            .span_start = definition.span_start,
            .span_end = definition.span_end,
            .visible_start = definition.visible_start,
            .visible_end = definition.visible_end,
            .kind = definition.kind,
            .module_id = definition.module_id,
            .file = if (definition.file) |file| try allocator.dupe(u8, file) else null,
            .scope_kind = definition.scope_kind,
            .scope_name = if (definition.scope_name) |scope_name| try allocator.dupe(u8, scope_name) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneHoles(allocator: std.mem.Allocator, holes: []const syntax_hole.Hole) ![]syntax_hole.Hole {
    var out = std.ArrayList(syntax_hole.Hole).empty;
    errdefer {
        for (out.items) |*hole| hole.deinit(allocator);
        out.deinit(allocator);
    }
    for (holes) |hole| {
        try out.append(allocator, .{
            .id = hole.id,
            .kind = hole.kind,
            .span = hole.span,
            .expected = hole.expected,
            .expected_type = if (hole.expected_type) |ty| try ty.clone(allocator) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneModules(allocator: std.mem.Allocator, modules: []const core.SourceModule) ![]ModuleFact {
    var out = std.ArrayList(ModuleFact).empty;
    errdefer {
        for (out.items) |module| {
            allocator.free(module.spec);
            if (module.path) |path| allocator.free(path);
            allocator.free(module.source);
            deinitImports(allocator, module.imports);
            allocator.free(module.implicit_import_ids);
            deinitScopes(allocator, module.function_scopes);
            deinitScopes(allocator, module.page_scopes);
            query_symbols.deinit(allocator, module.symbols);
            allocator.free(module.folding_ranges);
        }
        out.deinit(allocator);
    }
    for (modules) |module| {
        const spec = try allocator.dupe(u8, module.spec);
        errdefer allocator.free(spec);
        const path = if (module.path) |path| try allocator.dupe(u8, path) else null;
        errdefer if (path) |owned_path| allocator.free(owned_path);
        const source_copy = try allocator.dupe(u8, module.source);
        errdefer allocator.free(source_copy);
        const imports = try cloneImports(allocator, module);
        errdefer deinitImports(allocator, imports);
        const implicit_import_ids = try allocator.dupe(core.SourceModuleId, module.implicit_import_ids.items);
        errdefer allocator.free(implicit_import_ids);
        const function_scopes = try cloneFunctionScopes(allocator, module);
        errdefer deinitScopes(allocator, function_scopes);
        const page_scopes = try clonePageScopes(allocator, module);
        errdefer deinitScopes(allocator, page_scopes);
        const symbols = try query_symbols.collect(allocator, module.source, module.syntax);
        errdefer query_symbols.deinit(allocator, symbols);
        const folding_ranges = try query_folding.collect(allocator, module.source, module.syntax);
        errdefer allocator.free(folding_ranges);

        const fact = ModuleFact{
            .id = module.id,
            .kind = module.kind,
            .spec = spec,
            .path = path,
            .source = source_copy,
            .imports = imports,
            .implicit_import_ids = implicit_import_ids,
            .function_scopes = function_scopes,
            .page_scopes = page_scopes,
            .symbols = symbols,
            .folding_ranges = folding_ranges,
        };
        try out.append(allocator, fact);
    }
    return out.toOwnedSlice(allocator);
}

fn cloneFunctionScopes(allocator: std.mem.Allocator, module: core.SourceModule) ![]ScopeFact {
    var out = std.ArrayList(ScopeFact).empty;
    errdefer {
        deinitScopeItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (module.syntax.functions.items) |func| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, func.name),
            .start = func.span.start,
            .end = func.span.end,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn clonePageScopes(allocator: std.mem.Allocator, module: core.SourceModule) ![]ScopeFact {
    var out = std.ArrayList(ScopeFact).empty;
    errdefer {
        deinitScopeItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (module.syntax.pages.items) |page| {
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, page.name),
            .start = page.span.start,
            .end = page.span.end,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitScopes(allocator: std.mem.Allocator, scopes: []ScopeFact) void {
    deinitScopeItems(allocator, scopes);
    allocator.free(scopes);
}

fn deinitScopeItems(allocator: std.mem.Allocator, scopes: []ScopeFact) void {
    for (scopes) |scope| allocator.free(scope.name);
}

fn deinitImports(allocator: std.mem.Allocator, imports: []ImportFact) void {
    for (imports) |import_fact| {
        allocator.free(import_fact.spec);
        if (import_fact.alias) |alias| allocator.free(alias);
    }
    allocator.free(imports);
}

fn cloneImports(allocator: std.mem.Allocator, module: core.SourceModule) ![]ImportFact {
    var out = std.ArrayList(ImportFact).empty;
    errdefer {
        for (out.items) |import_fact| {
            allocator.free(import_fact.spec);
            if (import_fact.alias) |alias| allocator.free(alias);
        }
        out.deinit(allocator);
    }
    for (module.syntax.imports.items, 0..) |import_decl, import_index| {
        try out.append(allocator, .{
            .spec = try allocator.dupe(u8, import_decl.spec),
            .spec_span = import_decl.spec_span,
            .alias = if (import_decl.mode.alias) |alias| try allocator.dupe(u8, alias) else null,
            .unqualified = import_decl.mode.unqualified,
            .alias_span = import_decl.alias_span,
            .module_id = if (import_index < module.resolved_import_ids.items.len) module.resolved_import_ids.items[import_index] else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn collectTypeDefinitions(allocator: std.mem.Allocator, state: *const core.DocumentState) ![]TypeDefinition {
    var out = std.ArrayList(TypeDefinition).empty;
    errdefer {
        for (out.items) |definition| allocator.free(definition.name);
        out.deinit(allocator);
    }
    for (state.module_order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        for (module.syntax.records.items) |decl| try appendTypeDefinition(allocator, &out, module.*, .record, decl.name, decl.name_span);
        for (module.syntax.objects.items) |decl| try appendTypeDefinition(allocator, &out, module.*, .object, decl.name, decl.name_span);
        for (module.syntax.types.items) |decl| try appendTypeDefinition(allocator, &out, module.*, .enum_type, decl.name, decl.name_span);
    }
    return out.toOwnedSlice(allocator);
}

fn appendTypeDefinition(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(TypeDefinition),
    module: core.SourceModule,
    kind: TypeDefinitionKind,
    name: []const u8,
    name_span: ?ast.Span,
) !void {
    const span = name_span orelse return;
    const source_location = utils.source.locationAt(module.source, span.start);
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .module_id = module.id,
        .line = source_location.line,
        .column = source_location.column,
        .length = @max(span.end, span.start) - span.start,
    });
}

fn collectValueBindings(allocator: std.mem.Allocator, state: *core.DocumentState) ![]ValueBinding {
    var out = std.ArrayList(ValueBinding).empty;
    errdefer {
        deinitValueBindingItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (registry.primitiveDescriptors()) |descriptor| {
        if (valueNameExists(state, descriptor.name)) continue;
        const signature: []u8 = @constCast(try query_signature.formatPrimitiveSignature(allocator, descriptor));
        errdefer allocator.free(signature);
        const type_label: []u8 = @constCast(if (registry.primitiveResultType(descriptor)) |ty|
            try ty.formatAlloc(allocator)
        else
            try allocator.dupe(u8, "dependent"));
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, descriptor.name),
            .kind = .function,
            .module_id = null,
            .signature = signature,
            .type_label = type_label,
            .documentation = try allocator.dupe(u8, descriptor.summary),
            .primitive = true,
        });
    }
    var function_iterator = state.functions.iterator();
    while (function_iterator.next()) |entry| {
        const func = entry.value_ptr.*;
        const signature: []u8 = @constCast(try query_signature.formatUserSignature(allocator, func.name, func));
        errdefer allocator.free(signature);
        const type_label: []u8 = @constCast(try func.result_type.formatAlloc(allocator));
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, func.name),
            .kind = .function,
            .module_id = entry.key_ptr.module_id,
            .signature = signature,
            .type_label = type_label,
            .documentation = try allocator.dupe(u8, ""),
        });
    }
    var constant_iterator = state.constants.iterator();
    while (constant_iterator.next()) |entry| {
        const constant_decl = entry.value_ptr.*;
        const signature: []u8 = @constCast(try query_signature.formatConstSignature(allocator, constant_decl.name, constant_decl));
        errdefer allocator.free(signature);
        const type_label: []u8 = @constCast(try constant_decl.value_type.formatAlloc(allocator));
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, constant_decl.name),
            .kind = .constant,
            .module_id = entry.key_ptr.module_id,
            .signature = signature,
            .type_label = type_label,
            .documentation = try allocator.dupe(u8, ""),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitValueBindings(allocator: std.mem.Allocator, bindings: []ValueBinding) void {
    deinitValueBindingItems(allocator, bindings);
    allocator.free(bindings);
}

fn deinitValueBindingItems(allocator: std.mem.Allocator, bindings: []ValueBinding) void {
    for (bindings) |binding| {
        allocator.free(binding.name);
        allocator.free(binding.signature);
        allocator.free(binding.type_label);
        allocator.free(binding.documentation);
    }
}

fn valueNameExists(state: *const core.DocumentState, name: []const u8) bool {
    var function_iterator = state.functions.iterator();
    while (function_iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    var constant_iterator = state.constants.iterator();
    while (constant_iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    return false;
}

fn collectVariableBindings(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    declaration_index: *const declarations.DeclarationIndex,
) ![]VariableBinding {
    var out = std.ArrayList(VariableBinding).empty;
    errdefer {
        deinitVariableBindingItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (state.modules.items) |module| {
        if (module.path == null) continue;
        var infos = try analysis_pipeline.collectScopedVariableInfoFromModule(allocator, state, declaration_index, module.syntax, module.id, module.source.len);
        defer infos.deinit(allocator);
        for (infos.items) |entry| {
            const type_label: []u8 = @constCast(try semantic_types.typeInfoLabelAlloc(allocator, entry.info));
            errdefer allocator.free(type_label);
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .type_label = type_label,
                .object_class = if (entry.info.object_class) |class_name| try allocator.dupe(u8, class_name) else null,
                .module_id = entry.module_id,
                .scope_kind = entry.scope_kind,
                .scope_name = if (entry.scope_name) |scope_name| try allocator.dupe(u8, scope_name) else null,
                .span_start = entry.span_start,
                .span_end = entry.span_end,
                .visible_start = entry.visible_start,
                .visible_end = entry.visible_end,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn deinitVariableBindings(allocator: std.mem.Allocator, bindings: []VariableBinding) void {
    deinitVariableBindingItems(allocator, bindings);
    allocator.free(bindings);
}

fn deinitVariableBindingItems(allocator: std.mem.Allocator, bindings: []VariableBinding) void {
    for (bindings) |binding| {
        allocator.free(binding.name);
        allocator.free(binding.type_label);
        if (binding.object_class) |class_name| allocator.free(class_name);
        if (binding.scope_name) |scope_name| allocator.free(scope_name);
    }
}

fn collectRoleBindings(allocator: std.mem.Allocator, roles: []const declarations.RoleDescriptor) ![]RoleBinding {
    var out = std.ArrayList(RoleBinding).empty;
    errdefer {
        deinitRoleBindingItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (roles) |role| try out.append(allocator, .{
        .name = try allocator.dupe(u8, role.name),
        .type_label = try allocator.dupe(u8, role.class_name),
        .module_id = role.module_id,
    });
    return out.toOwnedSlice(allocator);
}

fn deinitRoleBindings(allocator: std.mem.Allocator, bindings: []RoleBinding) void {
    deinitRoleBindingItems(allocator, bindings);
    allocator.free(bindings);
}

fn deinitRoleBindingItems(allocator: std.mem.Allocator, bindings: []RoleBinding) void {
    for (bindings) |binding| {
        allocator.free(binding.name);
        allocator.free(binding.type_label);
    }
}

fn collectClasses(allocator: std.mem.Allocator, classes: []const declarations.ClassDescriptor) ![]ClassFact {
    var out = std.ArrayList(ClassFact).empty;
    errdefer {
        deinitClassItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (classes) |item| try out.append(allocator, .{
        .name = try allocator.dupe(u8, item.name),
        .base = if (item.base) |base| try allocator.dupe(u8, base) else null,
        .module_id = item.module_id,
    });
    return out.toOwnedSlice(allocator);
}

fn deinitClasses(allocator: std.mem.Allocator, classes: []ClassFact) void {
    deinitClassItems(allocator, classes);
    allocator.free(classes);
}

fn deinitClassItems(allocator: std.mem.Allocator, classes: []ClassFact) void {
    for (classes) |item| {
        allocator.free(item.name);
        if (item.base) |base| allocator.free(base);
    }
}

fn collectFields(allocator: std.mem.Allocator, fields: []const declarations.FieldDescriptor) ![]FieldFact {
    var out = std.ArrayList(FieldFact).empty;
    errdefer {
        deinitFieldItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (fields) |item| {
        const type_label = try item.value_type.formatAlloc(allocator);
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .class_name = try allocator.dupe(u8, item.class_name),
            .type_label = @constCast(type_label),
            .module_id = item.module_id,
            .name_span = item.name_span,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitFields(allocator: std.mem.Allocator, fields: []FieldFact) void {
    deinitFieldItems(allocator, fields);
    allocator.free(fields);
}

fn deinitFieldItems(allocator: std.mem.Allocator, fields: []FieldFact) void {
    for (fields) |item| {
        allocator.free(item.name);
        allocator.free(item.class_name);
        allocator.free(item.type_label);
    }
}

fn collectRecords(allocator: std.mem.Allocator, records: []const declarations.RecordDescriptor) ![]RecordFact {
    var out = std.ArrayList(RecordFact).empty;
    errdefer {
        deinitRecordItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (records) |item| try out.append(allocator, .{
        .name = try allocator.dupe(u8, item.name),
        .module_id = item.module_id,
    });
    return out.toOwnedSlice(allocator);
}

fn deinitRecords(allocator: std.mem.Allocator, records: []RecordFact) void {
    deinitRecordItems(allocator, records);
    allocator.free(records);
}

fn deinitRecordItems(allocator: std.mem.Allocator, records: []RecordFact) void {
    for (records) |item| allocator.free(item.name);
}

fn collectRecordFields(allocator: std.mem.Allocator, fields: []const declarations.RecordFieldDescriptor) ![]RecordFieldFact {
    var out = std.ArrayList(RecordFieldFact).empty;
    errdefer {
        deinitRecordFieldItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (fields) |item| {
        const type_label = try item.value_type.formatAlloc(allocator);
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .record_name = try allocator.dupe(u8, item.record_name),
            .type_label = @constCast(type_label),
            .module_id = item.module_id,
            .name_span = item.name_span,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitRecordFields(allocator: std.mem.Allocator, fields: []RecordFieldFact) void {
    deinitRecordFieldItems(allocator, fields);
    allocator.free(fields);
}

fn deinitRecordFieldItems(allocator: std.mem.Allocator, fields: []RecordFieldFact) void {
    for (fields) |item| {
        allocator.free(item.name);
        allocator.free(item.record_name);
        allocator.free(item.type_label);
    }
}

fn collectEnumCases(allocator: std.mem.Allocator, types: []const declarations.TypeDescriptor) ![]EnumCaseFact {
    var out = std.ArrayList(EnumCaseFact).empty;
    errdefer {
        deinitEnumCaseItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (types) |item| {
        for (item.cases) |case_decl| try out.append(allocator, .{
            .name = try allocator.dupe(u8, case_decl.name),
            .enum_name = try allocator.dupe(u8, item.name),
            .module_id = item.module_id,
            .name_span = case_decl.name_span,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn deinitEnumCases(allocator: std.mem.Allocator, cases: []EnumCaseFact) void {
    deinitEnumCaseItems(allocator, cases);
    allocator.free(cases);
}

fn deinitEnumCaseItems(allocator: std.mem.Allocator, cases: []EnumCaseFact) void {
    for (cases) |item| {
        allocator.free(item.name);
        allocator.free(item.enum_name);
    }
}
