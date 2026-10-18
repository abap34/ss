const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const editor_snapshot = @import("../editor/snapshot.zig");
const ReuseInputs = @import("../render/layout/inputs.zig").Inputs;
const project = @import("project");

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

pub const SyntaxStorage = @import("snapshot/syntax.zig").Storage;
pub const TypeStorage = @import("snapshot/types.zig").Storage;
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
        if (try self.overlay.get(path)) |text| return self.allocator.dupe(u8, text);
        return utils.fs.readFileAlloc(self.io, self.allocator, path);
    }
};

pub const LayoutHookOutput = struct {
    reuse_inputs: ?ReuseInputs = null,
    editor: ?editor_snapshot.Output = null,
    conflicts_json: ?[]u8 = null,
    report: ?core.layout.conflicts.Report = null,

    pub fn deinit(self: *LayoutHookOutput, allocator: std.mem.Allocator) void {
        if (self.editor) |*value| value.deinit();
        if (self.conflicts_json) |value| allocator.free(value);
        if (self.report) |*value| value.deinit();
        if (self.reuse_inputs) |*value| value.deinit(allocator);
        self.* = .{};
    }
};

pub const LayoutHook = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, state: *core.DocumentState, graph: *const execution.ExecutionGraph) anyerror!LayoutHookOutput,
    on_error: ?*const fn (context: *anyopaque, state: *core.DocumentState, layouts: *const core.layout.Document, err: anyerror) anyerror!void = null,
};

pub const Options = struct {
    generation: u64 = 0,
    project: ProjectOptions = .{},
    layout_hook: ?LayoutHook = null,
    cancellation: ?utils.Cancellation = null,
    embedded_cache: ?*module_loader.EmbeddedSyntaxCache = null,
    retain_layout_inputs: bool = false,
    retain_evaluated_layout_state: bool = false,

    fn checkCanceled(self: Options) !void {
        if (self.cancellation) |cancellation| try cancellation.check();
    }
};

pub const RetainedLayoutInputs = struct {
    state: core.DocumentState,
    graph: execution.ExecutionGraph,
    diagnostic_count: usize,

    pub fn deinit(self: *RetainedLayoutInputs) void {
        self.graph.deinit();
        self.state.deinit();
        self.* = undefined;
    }
};

pub const RetainedLayoutState = struct {
    state: core.DocumentState,
    reuse_inputs: ?ReuseInputs = null,

    pub fn deinit(self: *RetainedLayoutState) void {
        if (self.reuse_inputs) |*value| value.deinit(self.state.allocator);
        self.state.deinit();
        self.* = undefined;
    }
};

pub const ProjectFacts = struct {
    entry_path: []u8 = &.{},
    asset_base_dir: []u8 = &.{},
    module_paths: [][]u8 = &.{},
    highlight: utils.highlight.Config = .{},
    lsp: project.LspConfig = .{},
    wysiwyg: project.WysiwygConfig = .{},
    page_guide: project.PageGuideConfig = .{},
    cache: utils.render_cache.Config = .{},

    pub fn init(allocator: std.mem.Allocator, entry_path: []const u8, asset_base_dir: []const u8, options: ProjectOptions) !ProjectFacts {
        var facts = ProjectFacts{
            .lsp = options.lsp,
            .wysiwyg = options.wysiwyg,
            .page_guide = options.page_guide,
            .cache = options.cache,
        };
        errdefer facts.deinit(allocator);
        facts.highlight = try options.highlight.clone(allocator);
        facts.entry_path = try allocator.dupe(u8, entry_path);
        facts.asset_base_dir = try allocator.dupe(u8, asset_base_dir);
        return facts;
    }

    pub fn fromDocumentState(allocator: std.mem.Allocator, state: *const core.DocumentState, entry_path: []const u8, asset_base_dir: []const u8, options: Options) !ProjectFacts {
        var facts = try init(allocator, entry_path, asset_base_dir, options.project);
        errdefer facts.deinit(allocator);
        facts.module_paths = try collectModulePaths(allocator, state);
        try options.checkCanceled();
        return facts;
    }

    pub fn deinit(self: *ProjectFacts, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        for (self.module_paths) |path| allocator.free(path);
        allocator.free(self.module_paths);
        self.highlight.deinit(allocator);
        self.* = .{};
    }
};

pub const ProjectOptions = struct {
    highlight: utils.highlight.Config = .{},
    lsp: project.LspConfig = .{},
    wysiwyg: project.WysiwygConfig = .{},
    page_guide: project.PageGuideConfig = .{},
    cache: utils.render_cache.Config = .{},
};

pub const ModuleFact = struct {
    id: core.SourceModuleId,
    kind: core.SourceModuleKind,
    spec: []u8,
    path: ?[]u8,
    source: []u8,
    line_index: utils.source.LineIndex,
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
    alias: ?[]const u8 = null,
    unqualified: bool = false,
    selected: []const ast.ImportDecl.SelectedName = &.{},
    alias_span: ?ast.Span = null,
    module_id: ?core.SourceModuleId = null,
};

pub const TypeDefinitionKind = enum {
    record,
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
    value_type: ast.Type = ast.Type.any,
    callable_type: ?ast.Type = null,
    type_parameter_count: usize = 0,
    declaration_start: usize = 0,
    name: []u8,
    kind: ValueBindingKind,
    module_id: ?core.SourceModuleId,
    signature: []u8,
    type_label: []u8,
    documentation: []u8,
    primitive: bool = false,
};

pub const VariableBinding = struct {
    value_type: ast.Type = ast.Type.any,
    name: []u8,
    type_label: []u8,
    module_id: core.SourceModuleId,
    scope_kind: core.DefinitionScopeKind,
    scope_name: ?[]u8 = null,
    span_start: usize,
    span_end: usize,
    visible_start: usize,
    visible_end: usize,
};

pub const RecordFact = struct {
    name: []u8,
    module_id: core.SourceModuleId,
    type_parameter_count: usize = 0,
    declaration_start: usize = 0,
};

pub const RecordFieldFact = struct {
    value_type: ast.Type = ast.Type.any,
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

    pub fn fromDocumentState(
        allocator: std.mem.Allocator,
        state: *core.DocumentState,
        layouts: *const core.layout.Document,
        owned_editor: ?editor_snapshot.Output,
        owned_conflicts_json: ?[]u8,
    ) !LayoutOutput {
        return try fromDocumentStateWithOwnedReport(
            allocator,
            state,
            layouts,
            null,
            owned_editor,
            owned_conflicts_json,
        );
    }

    pub fn fromDocumentStateWithOwnedReport(
        allocator: std.mem.Allocator,
        state: *core.DocumentState,
        layouts: *const core.layout.Document,
        owned_report: ?core.layout.conflicts.Report,
        owned_editor: ?editor_snapshot.Output,
        owned_conflicts_json: ?[]u8,
    ) !LayoutOutput {
        var report = owned_report;
        errdefer if (report) |*value| value.deinit();
        var editor = owned_editor;
        errdefer if (editor) |*value| value.deinit();
        const conflicts_json = owned_conflicts_json orelse try core.layout.conflicts.toJson(allocator, state, layouts);
        errdefer allocator.free(conflicts_json);
        if (report == null) report = try core.layout.conflicts.Report.init(allocator, state, layouts);
        const transferred_report = report.?;
        report = null;
        return .{
            .conflicts_json = conflicts_json,
            .report = transferred_report,
            .editor = editor,
        };
    }

    pub fn deinit(self: *LayoutOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.conflicts_json);
        self.report.deinit();
        if (self.editor) |*value| value.deinit();
    }
};

const DeclarationLookup = std.HashMapUnmanaged(core.FunctionKey, usize, core.FunctionKeyContext, std.hash_map.default_max_load_percentage);

pub const HoleFact = struct {
    module_id: core.SourceModuleId,
    id: ast.HoleId,
    kind: syntax_hole.HoleKind,
    span: ast.Span,
    expected: syntax_hole.ExpectedSyntax,
    expected_type: ?ast.Type,
};

pub const AnalysisSnapshot = struct {
    settings_module_id: ?core.SourceModuleId = null,
    syntax_storage: ?SyntaxStorage = null,
    type_storage: ?TypeStorage = null,
    allocator: std.mem.Allocator,
    generation: u64 = 0,
    project: ProjectFacts = .{},
    modules: []ModuleFact = &.{},
    module_order: []core.SourceModuleId = &.{},
    holes: []HoleFact = &.{},
    definitions: []core.Definition = &.{},
    type_definitions: []TypeDefinition = &.{},
    value_bindings: []ValueBinding = &.{},
    value_binding_index: DeclarationLookup = .empty,
    value_definition_index: DeclarationLookup = .empty,
    type_definition_index: DeclarationLookup = .empty,
    variable_bindings: []VariableBinding = &.{},
    records: []RecordFact = &.{},
    record_fields: []RecordFieldFact = &.{},
    enum_cases: []EnumCaseFact = &.{},
    layout_output: ?LayoutOutput = null,
    retained_layout_inputs: ?RetainedLayoutInputs = null,
    retained_layout_state: ?RetainedLayoutState = null,
    diagnostics: diagnostics.DiagnosticBag,

    pub fn fromDocumentState(
        allocator: std.mem.Allocator,
        state: *core.DocumentState,
        declaration_index: *const declarations.DeclarationIndex,
        diagnostic_bag: diagnostics.DiagnosticBag,
        holes: ?[]const syntax_hole.ModuleResult,
        project_facts: ProjectFacts,
    ) !AnalysisSnapshot {
        var snapshot = AnalysisSnapshot{
            .allocator = allocator,
            .diagnostics = diagnostic_bag,
            .project = project_facts,
        };
        errdefer snapshot.deinit();

        snapshot.settings_module_id = declaration_index.settings_module_id;
        snapshot.diagnostics.sortByPath();
        snapshot.modules = try cloneModules(allocator, state.modules.entries.items);
        snapshot.module_order = try allocator.dupe(core.SourceModuleId, state.modules.order.items);
        snapshot.definitions = try cloneDefinitions(allocator, state.source_map.definitions.items);
        snapshot.type_definitions = try collectTypeDefinitions(allocator, state);
        snapshot.type_storage = TypeStorage.init(allocator);
        const type_storage = &snapshot.type_storage.?;
        snapshot.holes = if (holes) |tables| try cloneHoles(allocator, type_storage, tables) else &.{};
        snapshot.value_bindings = try collectValueBindings(allocator, type_storage, state);
        snapshot.variable_bindings = try collectVariableBindings(allocator, type_storage, state);
        snapshot.records = try collectRecords(allocator, declaration_index.records.items);
        snapshot.record_fields = try collectRecordFields(allocator, type_storage, declaration_index.record_fields.items);
        snapshot.enum_cases = try collectEnumCases(allocator, declaration_index.types.items);
        try snapshot.indexDeclarations();
        return snapshot;
    }

    fn indexDeclarations(self: *AnalysisSnapshot) !void {
        for (self.value_bindings, 0..) |binding, index| {
            const module_id = binding.module_id orelse continue;
            const entry = try self.value_binding_index.getOrPut(self.allocator, core.functionKey(module_id, binding.name));
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
        for (self.definitions, 0..) |definition, index| {
            if (definition.kind == .variable) continue;
            const entry = try self.value_definition_index.getOrPut(self.allocator, core.functionKey(definition.module_id, definition.name));
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
        for (self.type_definitions, 0..) |definition, index| {
            const entry = try self.type_definition_index.getOrPut(self.allocator, core.functionKey(definition.module_id, definition.name));
            if (!entry.found_existing) entry.value_ptr.* = index;
        }
    }

    pub fn valueBindingInModule(self: *const AnalysisSnapshot, module_id: core.SourceModuleId, name: []const u8) ?ValueBinding {
        return self.value_bindings[self.value_binding_index.get(core.functionKey(module_id, name)) orelse return null];
    }

    pub fn valueDefinitionInModule(self: *const AnalysisSnapshot, module_id: core.SourceModuleId, name: []const u8) ?core.Definition {
        return self.definitions[self.value_definition_index.get(core.functionKey(module_id, name)) orelse return null];
    }

    pub fn typeDefinitionInModule(self: *const AnalysisSnapshot, module_id: core.SourceModuleId, name: []const u8) ?TypeDefinition {
        return self.type_definitions[self.type_definition_index.get(core.functionKey(module_id, name)) orelse return null];
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

    pub fn syntaxForSource(self: *const AnalysisSnapshot, path: []const u8, source: []const u8) ?*const ast.Module {
        return if (self.syntax_storage) |*storage| storage.forSource(path, source) else null;
    }

    pub fn updateSyntax(self: *AnalysisSnapshot, path: []const u8, source: []const u8, cancellation: ?utils.Cancellation) !void {
        if (self.syntax_storage) |*storage| try storage.replace(path, source, cancellation);
    }

    pub fn deinit(self: *AnalysisSnapshot) void {
        if (self.syntax_storage) |*storage| storage.deinit();
        if (self.type_storage) |*storage| storage.deinit();
        self.project.deinit(self.allocator);
        for (self.modules) |module| {
            module.line_index.deinit(self.allocator);
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
        self.allocator.free(self.holes);
        for (self.definitions) |definition| {
            self.allocator.free(definition.name);
            if (definition.file) |file| self.allocator.free(file);
            if (definition.scope_name) |scope_name| self.allocator.free(scope_name);
        }
        self.allocator.free(self.definitions);
        for (self.type_definitions) |definition| self.allocator.free(definition.name);
        self.allocator.free(self.type_definitions);
        self.value_binding_index.deinit(self.allocator);
        self.value_definition_index.deinit(self.allocator);
        self.type_definition_index.deinit(self.allocator);
        deinitValueBindings(self.allocator, self.value_bindings);
        deinitVariableBindings(self.allocator, self.variable_bindings);
        deinitRecords(self.allocator, self.records);
        deinitRecordFields(self.allocator, self.record_fields);
        deinitEnumCases(self.allocator, self.enum_cases);
        if (self.layout_output) |*layout| layout.deinit(self.allocator);
        if (self.retained_layout_inputs) |*inputs| inputs.deinit();
        if (self.retained_layout_state) |*retained| retained.deinit();
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

    pub fn completeRetainedLayout(
        self: *AnalysisSnapshot,
        hook: LayoutHook,
        cancellation: ?utils.Cancellation,
    ) !bool {
        if (self.retained_layout_inputs == null) return false;
        if (cancellation) |value| try value.check();
        var inputs = self.retained_layout_inputs.?;
        self.retained_layout_inputs = null;
        var state_retained = false;
        defer {
            inputs.graph.deinit();
            if (!state_retained) inputs.state.deinit();
        }

        if (hook.run(hook.context, &inputs.state, &inputs.graph)) |result| {
            var reuse_inputs = result.reuse_inputs;
            defer if (reuse_inputs) |*value| value.deinit(self.allocator);
            const retain_state = result.editor != null;
            self.layout_output = try LayoutOutput.fromDocumentStateWithOwnedReport(
                self.allocator,
                &inputs.state,
                if (reuse_inputs) |*value| &value.layouts else &.{},
                result.report,
                result.editor,
                result.conflicts_json,
            );
            if (reuse_inputs) |*value| {
                try diagnostics.addLayoutResult(&self.diagnostics, &inputs.state, &value.layouts);
                value.layouts.validate() catch |err| {
                    if (hook.on_error) |on_error| {
                        if (value.layouts.failureCount() > 0 or !self.diagnostics.hasErrors())
                            try on_error(hook.context, &inputs.state, &value.layouts, err);
                    } else if (!self.diagnostics.hasErrors()) {
                        try addBuildFailureDiagnostic(&self.diagnostics, self.project.entry_path, inputs.state.projectSource(), err, null);
                    }
                };
            }
            try diagnostics.addDocumentStateFrom(&self.diagnostics, &inputs.state, inputs.diagnostic_count);
            if (retain_state) {
                self.retained_layout_state = .{ .state = inputs.state, .reuse_inputs = reuse_inputs };
                reuse_inputs = null;
                state_retained = true;
            }
        } else |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConstraintConflict,
            error.NegativeFrameSize,
            => {
                if (hook.on_error) |on_error| {
                    try on_error(hook.context, &inputs.state, &.{}, err);
                    self.layout_output = try LayoutOutput.fromDocumentState(self.allocator, &inputs.state, &.{}, null, null);
                } else {
                    try addBuildFailureDiagnostic(&self.diagnostics, self.project.entry_path, inputs.state.projectSource(), err, null);
                }
            },
            else => {
                try diagnostics.addDocumentStateFrom(&self.diagnostics, &inputs.state, inputs.diagnostic_count);
                if (!self.diagnostics.hasErrors()) {
                    try addBuildFailureDiagnostic(&self.diagnostics, self.project.entry_path, inputs.state.projectSource(), err, null);
                }
            },
        }
        self.diagnostics.sortByPath();
        if (cancellation) |value| try value.check();
        return true;
    }
};

pub fn build(
    allocator: std.mem.Allocator,
    sources: *const SourceSet,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    options: Options,
) !AnalysisSnapshot {
    var syntax_storage = SyntaxStorage.init(allocator);
    errdefer syntax_storage.deinit();
    var snapshot = try buildWithSyntax(allocator, sources, entry_path, asset_base_dir, options, &syntax_storage);
    snapshot.syntax_storage = syntax_storage;
    return snapshot;
}

fn buildWithSyntax(
    allocator: std.mem.Allocator,
    sources: *const SourceSet,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    options: Options,
    syntax_storage: *SyntaxStorage,
) !AnalysisSnapshot {
    try options.checkCanceled();
    var diagnostic_bag = diagnostics.DiagnosticBag.init(allocator);
    var diagnostics_moved = false;
    defer if (!diagnostics_moved) diagnostic_bag.deinit();

    var inputs = try loadSnapshotInputs(allocator, sources, entry_path, asset_base_dir, options, syntax_storage, &diagnostic_bag) orelse
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved, syntax_storage);
    defer inputs.deinit(allocator);
    if (!try inputs.analyze(allocator, options, &diagnostic_bag)) {
        return finishDiagnosticSnapshot(allocator, entry_path, asset_base_dir, options.generation, options.project, &diagnostic_bag, &diagnostics_moved, syntax_storage);
    }
    try inputs.solveLayout(allocator, options, &diagnostic_bag);
    return inputs.finish(allocator, entry_path, asset_base_dir, options, &diagnostic_bag, &diagnostics_moved);
}

// Owns the intermediate results until the snapshot takes the requested state.
const SnapshotInputs = struct {
    state: ?core.DocumentState,
    parse_holes: []syntax_hole.ModuleResult,
    execution_graph: ?execution.ExecutionGraph = null,
    analyzed_diagnostic_count: usize = 0,
    layout_output: ?LayoutOutput = null,
    reuse_inputs: ?ReuseInputs = null,

    fn deinit(self: *SnapshotInputs, allocator: std.mem.Allocator) void {
        if (self.layout_output) |*value| value.deinit(allocator);
        if (self.reuse_inputs) |*value| value.deinit(allocator);
        if (self.execution_graph) |*value| value.deinit();
        for (self.parse_holes) |*table| table.result.deinit(allocator);
        allocator.free(self.parse_holes);
        if (self.state) |*value| value.deinit();
    }

    fn analyze(self: *SnapshotInputs, allocator: std.mem.Allocator, options: Options, diagnostic_bag: *diagnostics.DiagnosticBag) !bool {
        const state = &self.state.?;
        state.runtime.analysis_cancellation = options.cancellation;
        defer state.runtime.analysis_cancellation = null;
        try options.checkCanceled();
        const diagnostic_count_before_analysis = state.diagnostics.entries.items.len;
        var analysis_failed = false;
        self.execution_graph = analysis_pipeline.analyzeDocumentStateWithMode(allocator, state, .evaluation) catch |err| blk: {
            if (err == error.Canceled) return err;
            if (err != error.DiagnosticsFailed and state.diagnostics.entries.items.len == diagnostic_count_before_analysis) {
                try addBuildFailureDiagnostic(diagnostic_bag, state.projectPath(), state.projectSource(), err, null);
                analysis_failed = true;
            }
            break :blk null;
        };
        try options.checkCanceled();
        if (analysis_failed) {
            try diagnostics.addDocumentStateFrom(diagnostic_bag, state, 0);
            return false;
        }
        const declaration_index = state.declaration_index;
        try hole_facts.populateExpectedTypes(allocator, state, declaration_index, self.parse_holes);
        try options.checkCanceled();
        try diagnostics.addDocumentStateFrom(diagnostic_bag, state, 0);
        self.analyzed_diagnostic_count = state.diagnostics.entries.items.len;
        return true;
    }

    fn solveLayout(self: *SnapshotInputs, allocator: std.mem.Allocator, options: Options, diagnostic_bag: *diagnostics.DiagnosticBag) !void {
        const state = &self.state.?;
        try options.checkCanceled();
        if (!diagnostic_bag.hasErrors()) {
            if (options.layout_hook) |hook| {
                if (self.execution_graph) |*graph| {
                    try options.checkCanceled();
                    if (hook.run(hook.context, state, graph)) |result| {
                        self.reuse_inputs = result.reuse_inputs;
                        self.layout_output = try LayoutOutput.fromDocumentStateWithOwnedReport(
                            allocator,
                            state,
                            if (self.reuse_inputs) |*value| &value.layouts else &.{},
                            result.report,
                            result.editor,
                            result.conflicts_json,
                        );
                        if (self.reuse_inputs) |*value| {
                            try diagnostics.addLayoutResult(diagnostic_bag, state, &value.layouts);
                            value.layouts.validate() catch |err| {
                                if (hook.on_error) |on_error| {
                                    if (value.layouts.failureCount() > 0 or !diagnostic_bag.hasErrors())
                                        try on_error(hook.context, state, &value.layouts, err);
                                } else if (!diagnostic_bag.hasErrors()) {
                                    try addBuildFailureDiagnostic(diagnostic_bag, state.projectPath(), state.projectSource(), err, null);
                                }
                            };
                        }
                        try diagnostics.addDocumentStateFrom(diagnostic_bag, state, self.analyzed_diagnostic_count);
                    } else |err| switch (err) {
                        error.Canceled => return error.Canceled,
                        error.ConstraintConflict,
                        error.NegativeFrameSize,
                        => {
                            if (hook.on_error) |on_error| {
                                try on_error(hook.context, state, &.{}, err);
                                self.layout_output = try LayoutOutput.fromDocumentState(allocator, state, &.{}, null, null);
                            } else {
                                try addBuildFailureDiagnostic(diagnostic_bag, state.projectPath(), state.projectSource(), err, null);
                            }
                        },
                        else => {
                            try diagnostics.addDocumentStateFrom(diagnostic_bag, state, self.analyzed_diagnostic_count);
                            if (!diagnostic_bag.hasErrors()) {
                                try addBuildFailureDiagnostic(diagnostic_bag, state.projectPath(), state.projectSource(), err, null);
                            }
                        },
                    }
                } else {
                    try addBuildDiagnostic(diagnostic_bag, state.projectPath(), state.projectSource(), .@"error", "ScheduleBuildFailed", "ScheduleBuildFailed: evaluation schedule was not available", .{}, null);
                }
            }
        }
        try options.checkCanceled();
    }

    fn finish(self: *SnapshotInputs, allocator: std.mem.Allocator, entry_path: []const u8, asset_base_dir: []const u8, options: Options, diagnostic_bag: *diagnostics.DiagnosticBag, diagnostics_moved: *bool) !AnalysisSnapshot {
        const state = &self.state.?;
        const project_facts = try ProjectFacts.fromDocumentState(allocator, state, entry_path, asset_base_dir, options);
        diagnostics_moved.* = true;
        const snapshot_facts_start = utils.measure_profile.start();
        var snapshot = try AnalysisSnapshot.fromDocumentState(allocator, state, state.declaration_index, diagnostic_bag.*, self.parse_holes, project_facts);
        utils.measure_profile.recordAnalysis(.snapshot_facts, snapshot_facts_start);
        snapshot.generation = options.generation;
        snapshot.layout_output = self.layout_output;
        self.layout_output = null;
        if (options.retain_layout_inputs and snapshot.layout_output == null and self.execution_graph != null and !snapshot.diagnostics.hasErrors()) {
            snapshot.retained_layout_inputs = .{
                .state = state.*,
                .graph = self.execution_graph.?,
                .diagnostic_count = self.analyzed_diagnostic_count,
            };
            self.execution_graph = null;
            self.state = null;
        } else if (options.retain_evaluated_layout_state and
            snapshot.layout_output != null and
            snapshot.layout_output.?.editor != null and
            !snapshot.diagnostics.hasErrors())
        {
            snapshot.retained_layout_state = .{ .state = state.*, .reuse_inputs = self.reuse_inputs };
            self.reuse_inputs = null;
            self.state = null;
        }
        return snapshot;
    }
};

fn loadSnapshotInputs(
    allocator: std.mem.Allocator,
    sources: *const SourceSet,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    options: Options,
    syntax_storage: *SyntaxStorage,
    diagnostic_bag: *diagnostics.DiagnosticBag,
) !?SnapshotInputs {
    var source = try readSnapshotSource(sources, entry_path, diagnostic_bag) orelse return null;
    defer allocator.free(source);
    try options.checkCanceled();
    var parsed = try parseSnapshotSource(allocator, source, entry_path, options, diagnostic_bag) orelse return null;
    defer parsed.deinit(allocator);
    try syntax_storage.capture(entry_path, source, parsed.module);
    try options.checkCanceled();

    var index = try loadSnapshotModules(allocator, sources, entry_path, source, &parsed, options, diagnostic_bag) orelse return null;
    defer index.deinit();
    try options.checkCanceled();
    for (index.module_graph.modules.items) |module| {
        if (module.path) |path| try syntax_storage.capture(path, module.source, module.syntax);
    }
    var state = analysis_pipeline.buildDocumentStateWithOptions(allocator, entry_path, asset_base_dir, &source, &parsed.module, &index, .{
        .parse_holes = parsed.holes,
    }) catch |err| {
        if (err == error.Canceled) return err;
        try addBuildFailureDiagnostic(diagnostic_bag, entry_path, source, err, null);
        return null;
    };
    errdefer state.deinit();
    const tables = try allocator.alloc(syntax_hole.ModuleResult, index.module_graph.recovery_holes.items.len + 1);
    tables[0] = .{ .module_id = state.modules.project_id, .result = parsed.holes };
    @memcpy(tables[1..], index.module_graph.recovery_holes.items);
    index.module_graph.recovery_holes.clearRetainingCapacity();
    parsed.holes = .{ .holes = &.{}, .diagnostics = &.{} };
    return .{ .state = state, .parse_holes = tables };
}

fn readSnapshotSource(sources: *const SourceSet, entry_path: []const u8, diagnostic_bag: *diagnostics.DiagnosticBag) !?[]u8 {
    return sources.readFileAlloc(entry_path) catch |err| {
        if (err == error.Canceled) return err;
        var message_buf: [512]u8 = undefined;
        try diagnostic_bag.add(
            entry_path,
            "",
            .@"error",
            "ProjectReadFailed",
            utils.err.formatPathFailure(&message_buf, "ProjectReadFailed", "read project entry", entry_path, err),
            null,
            null,
        );
        return null;
    };
}

fn parseSnapshotSource(allocator: std.mem.Allocator, entry_source: []const u8, entry_path: []const u8, options: Options, diagnostic_bag: *diagnostics.DiagnosticBag) !?syntax.ParseResult {
    var parse_failure: syntax.ParseFailure = .{};
    return syntax.parseRecoveringWithOptions(allocator, entry_source, entry_path, .{ .failure = &parse_failure, .cancellation = options.cancellation }) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        const diagnostic = parse_failure.diagnostic;
        var message_buf: [256]u8 = undefined;
        const message = if (diagnostic) |diag|
            utils.err.formatParseDiagnostic(&message_buf, diag)
        else
            utils.err.formatParseFailureWithoutDiagnostic(&message_buf, err);
        try diagnostic_bag.add(entry_path, entry_source, .@"error", utils.err.parseDiagnosticCode(err), message, if (diagnostic) |diag| .{
            .start = diag.span.start,
            .end = diag.span.end,
        } else null, null);
        return null;
    };
}

fn loadSnapshotModules(allocator: std.mem.Allocator, sources: *const SourceSet, entry_path: []const u8, entry_source: []const u8, parsed: *const syntax.ParseResult, options: Options, diagnostic_bag: *diagnostics.DiagnosticBag) !?module_index.Index {
    const program = parsed.module;
    const parse_holes = parsed.holes;
    var load_diagnostics = module_loader.LoadDiagnostics.init(allocator);
    defer load_diagnostics.deinit();
    const import_base_dir = std.fs.path.dirname(entry_path) orelse ".";
    var index = module_index.load(allocator, sources.io, import_base_dir, program, .{
        .overlay = &sources.overlay,
        .diagnostics = &load_diagnostics,
        .print_diagnostics = false,
        .recovering = true,
        .embedded_cache = options.embedded_cache,
        .cancellation = options.cancellation,
    }) catch |err| {
        if (err == error.Canceled) return err;
        if (err != error.DiagnosticsFailed and err != error.UnknownImport and !module_loader.isImportReadFailure(err)) return err;
        try diagnostics.addSyntaxHoles(diagnostic_bag, entry_path, entry_source, parse_holes);
        try addLoadDiagnostics(diagnostic_bag, &load_diagnostics);
        if (err == error.DiagnosticsFailed) {
            if (load_diagnostics.items.items.len != 0) {
                const span = try module_loader.importFailureSpan(allocator, sources.io, import_base_dir, &program, &sources.overlay, &load_diagnostics);
                try diagnostic_bag.add(entry_path, entry_source, .@"error", "ImportFailed", "ImportFailed: imported module failed to load", span, null);
            } else {
                try addBuildFailureDiagnostic(diagnostic_bag, entry_path, entry_source, err, null);
            }
        } else if (err == error.UnknownImport) {
            if (try module_loader.findUnknownImportReport(allocator, sources.io, import_base_dir, program, &sources.overlay)) |found| {
                var report = found;
                defer report.deinit(allocator);
                try diagnostic_bag.add(entry_path, entry_source, .@"error", "UnknownImport", report.message, .{
                    .start = report.span.start,
                    .end = report.span.end,
                }, null);
            }
        } else {
            if (try module_loader.findImportReadFailureReport(allocator, sources.io, import_base_dir, program, &sources.overlay, err)) |found| {
                var report = found;
                defer report.deinit(allocator);
                try diagnostic_bag.add(entry_path, entry_source, .@"error", "ImportReadFailed", report.message, .{
                    .start = report.span.start,
                    .end = report.span.end,
                }, null);
            } else {
                try addBuildFailureDiagnostic(diagnostic_bag, entry_path, entry_source, err, null);
            }
        }
        return null;
    };
    errdefer index.deinit();
    try addLoadDiagnostics(diagnostic_bag, &load_diagnostics);
    if (load_diagnostics.hasErrors()) {
        const span = try module_loader.importFailureSpan(allocator, sources.io, import_base_dir, &program, &sources.overlay, &load_diagnostics);
        try diagnostic_bag.add(entry_path, entry_source, .@"error", "ImportFailed", "ImportFailed: imported module contains syntax errors", span, null);
    }
    return index;
}

fn finishDiagnosticSnapshot(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    asset_base_dir: []const u8,
    generation: u64,
    options: ProjectOptions,
    diagnostic_bag: *diagnostics.DiagnosticBag,
    diagnostics_moved: *bool,
    syntax_storage: *const SyntaxStorage,
) !AnalysisSnapshot {
    // Local syntax remains useful even when loading an import failed. Build
    // source facts without trying to resolve missing imports or evaluate code.
    for (syntax_storage.trees.items) |tree| {
        if (!std.mem.eql(u8, tree.path, entry_path)) continue;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var state = try core.DocumentState.init(scratch, try scratch.dupe(u8, asset_base_dir), try scratch.dupe(u8, entry_path), try scratch.dupe(u8, tree.source), try tree.module.clone(scratch));
        defer state.deinit();
        try @import("index.zig").populateDocumentStateAnalysis(scratch, &state);
        for (state.projectSyntax().functions.items) |func| try state.functions.put(core.functionDeclarationKey(state.modules.project_id, func), func);
        for (state.projectSyntax().constants.items) |decl| try state.constants.declarations.put(core.constKey(state.modules.project_id, decl.name), decl);
        const facts = try ProjectFacts.fromDocumentState(allocator, &state, entry_path, asset_base_dir, .{ .project = options });
        diagnostics_moved.* = true;
        var snapshot = try AnalysisSnapshot.fromDocumentState(allocator, &state, state.declaration_index, diagnostic_bag.*, null, facts);
        snapshot.generation = generation;
        return snapshot;
    }
    const project_facts = try ProjectFacts.init(allocator, entry_path, asset_base_dir, options);
    var snapshot = AnalysisSnapshot.fromDiagnostics(allocator, diagnostic_bag.*, project_facts);
    snapshot.generation = generation;
    diagnostics_moved.* = true;
    return snapshot;
}

fn addLoadDiagnostics(bag: *diagnostics.DiagnosticBag, load_diagnostics: *const module_loader.LoadDiagnostics) !void {
    try bag.appendFrom(load_diagnostics);
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

fn addBuildFailureDiagnostic(
    bag: *diagnostics.DiagnosticBag,
    path: []const u8,
    text: []const u8,
    err: anyerror,
    span: ?utils.source.ByteSpan,
) !void {
    if (err == error.Canceled) return err;
    var message_buf: [512]u8 = undefined;
    try bag.add(
        path,
        text,
        .@"error",
        "BuildFailed",
        utils.err.formatBuildFailure(&message_buf, err),
        span,
        null,
    );
}

fn collectModulePaths(allocator: std.mem.Allocator, state: *const core.DocumentState) ![][]u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }
    for (state.modules.entries.items) |module| {
        const module_path = module.path orelse continue;
        if (seen.contains(module_path)) continue;
        try seen.put(module_path, {});
        const owned = try allocator.dupe(u8, module_path);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
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

fn cloneHoles(allocator: std.mem.Allocator, storage: *TypeStorage, tables: []const syntax_hole.ModuleResult) ![]HoleFact {
    var out = std.ArrayList(HoleFact).empty;
    errdefer out.deinit(allocator);
    for (tables) |table| for (table.result.holes) |hole| {
        try out.append(allocator, .{
            .module_id = table.module_id,
            .id = hole.id,
            .kind = hole.kind,
            .span = hole.span,
            .expected = hole.expected,
            .expected_type = if (hole.expected_type) |ty| try storage.retain(ty) else null,
        });
    };
    return out.toOwnedSlice(allocator);
}

fn cloneModules(allocator: std.mem.Allocator, modules: []const core.SourceModule) ![]ModuleFact {
    var out = std.ArrayList(ModuleFact).empty;
    errdefer {
        for (out.items) |module| {
            module.line_index.deinit(allocator);
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
        const line_index = try module.line_index.clone(allocator, source_copy);
        errdefer line_index.deinit(allocator);
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
        const folding_ranges = try query_folding.collect(allocator, module.line_index, module.syntax);
        errdefer allocator.free(folding_ranges);

        const fact = ModuleFact{
            .id = module.id,
            .kind = module.kind,
            .spec = spec,
            .path = path,
            .source = source_copy,
            .line_index = line_index,
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

fn deinitImportItems(allocator: std.mem.Allocator, imports: []const ImportFact) void {
    for (imports) |import_fact| {
        allocator.free(import_fact.spec);
        var mode = ast.ImportDecl.Mode{ .alias = import_fact.alias, .selected = import_fact.selected };
        mode.deinit(allocator);
    }
}

fn deinitImports(allocator: std.mem.Allocator, imports: []ImportFact) void {
    deinitImportItems(allocator, imports);
    allocator.free(imports);
}

fn cloneImports(allocator: std.mem.Allocator, module: core.SourceModule) ![]ImportFact {
    var out = std.ArrayList(ImportFact).empty;
    errdefer {
        deinitImportItems(allocator, out.items);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, module.syntax.imports.items.len);
    for (module.syntax.imports.items, 0..) |import_decl, import_index| {
        const spec = try allocator.dupe(u8, import_decl.spec);
        errdefer allocator.free(spec);
        const mode = try import_decl.mode.clone(allocator);
        out.appendAssumeCapacity(.{
            .spec = spec,
            .spec_span = import_decl.spec_span,
            .alias = mode.alias,
            .unqualified = mode.unqualified,
            .selected = mode.selected,
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
    for (state.modules.order.items) |module_id| {
        const module = state.moduleById(module_id) orelse continue;
        for (module.syntax.records.items) |decl| try appendTypeDefinition(allocator, &out, module.*, .record, decl.name, decl.name_span);
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
    const source_location = module.line_index.locationAt(span.start);
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .kind = kind,
        .module_id = module.id,
        .line = source_location.line,
        .column = source_location.column,
        .length = @max(span.end, span.start) - span.start,
    });
}

fn collectValueBindings(allocator: std.mem.Allocator, type_storage: *TypeStorage, state: *core.DocumentState) ![]ValueBinding {
    var out = std.ArrayList(ValueBinding).empty;
    errdefer {
        deinitValueBindingItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (registry.primitiveDescriptors()) |descriptor| {
        if (valueNameExists(state, descriptor.name)) continue;
        const retained_type = try type_storage.retain(registry.primitiveResultType(descriptor) orelse ast.Type.any);
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
            .value_type = retained_type,
        });
    }
    var function_iterator = state.functions.iterator();
    while (function_iterator.next()) |entry| {
        const func = entry.value_ptr.*;
        if (func.instance_id != null or func.isDisplay()) continue;
        const retained_type = try type_storage.retain(func.result_type);
        const parameters = try allocator.alloc(ast.Type, func.params.items.len);
        defer allocator.free(parameters);
        for (parameters, func.params.items) |*ty, param| ty.* = param.ty;
        var callable_type = try ast.Type.functionType(allocator, parameters, func.result_type);
        defer callable_type.deinit(allocator);
        const retained_callable = try type_storage.retain(callable_type);
        const signature: []u8 = @constCast(try query_signature.formatUserSignature(allocator, func.name, func));
        errdefer allocator.free(signature);
        const type_label: []u8 = @constCast(try func.result_type.formatAlloc(allocator));
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, func.name),
            .value_type = retained_type,
            .kind = .function,
            .callable_type = retained_callable,
            .type_parameter_count = func.type_params.items.len,
            .declaration_start = func.span.start,
            .module_id = entry.key_ptr.module_id,
            .signature = signature,
            .type_label = type_label,
            .documentation = try allocator.dupe(u8, ""),
        });
    }
    var constant_iterator = state.constants.declarations.iterator();
    while (constant_iterator.next()) |entry| {
        const constant_decl = entry.value_ptr.*;
        const retained_type = try type_storage.retain(constant_decl.value_type);
        const signature: []u8 = @constCast(try query_signature.formatConstSignature(allocator, constant_decl.name, constant_decl));
        errdefer allocator.free(signature);
        const type_label: []u8 = @constCast(try constant_decl.value_type.formatAlloc(allocator));
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, constant_decl.name),
            .value_type = retained_type,
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
    var constant_iterator = state.constants.declarations.iterator();
    while (constant_iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.name, name)) return true;
    }
    return false;
}

fn collectVariableBindings(
    allocator: std.mem.Allocator,
    type_storage: *TypeStorage,
    state: *const core.DocumentState,
) ![]VariableBinding {
    var out = std.ArrayList(VariableBinding).empty;
    errdefer {
        deinitVariableBindingItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (state.source_map.definitions.items) |definition| {
        if (definition.kind != .variable) continue;
        const known_info = state.bindingTypeAt(definition.module_id, definition.span_start);
        const info: @TypeOf(known_info.?) = known_info orelse .{ .ty = ast.Type.any };
        const retained_type = try type_storage.retain(info.ty);
        const type_label: []u8 = if (known_info != null) @constCast(try semantic_types.typeInfoLabelAlloc(allocator, .{ .ty = info.ty })) else try allocator.dupe(u8, "unknown");
        errdefer allocator.free(type_label);
        const name = try allocator.dupe(u8, definition.name);
        errdefer allocator.free(name);
        const scope_name = if (definition.scope_name) |scope_name| try allocator.dupe(u8, scope_name) else null;
        errdefer if (scope_name) |value| allocator.free(value);
        try out.append(allocator, .{
            .name = name,
            .type_label = type_label,
            .value_type = retained_type,
            .module_id = definition.module_id,
            .scope_kind = definition.scope_kind,
            .scope_name = scope_name,
            .span_start = definition.span_start,
            .span_end = definition.span_end,
            .visible_start = definition.visible_start,
            .visible_end = definition.visible_end,
        });
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
        if (binding.scope_name) |scope_name| allocator.free(scope_name);
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
        .type_parameter_count = item.decl.type_params.items.len,
        .declaration_start = item.decl.span.start,
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

fn collectRecordFields(allocator: std.mem.Allocator, type_storage: *TypeStorage, fields: []const declarations.RecordFieldDescriptor) ![]RecordFieldFact {
    var out = std.ArrayList(RecordFieldFact).empty;
    errdefer {
        deinitRecordFieldItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (fields) |item| {
        const retained_type = try type_storage.retain(item.value_type);
        const type_label = try item.value_type.formatAlloc(allocator);
        errdefer allocator.free(type_label);
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, item.name),
            .record_name = try allocator.dupe(u8, item.record_name),
            .type_label = @constCast(type_label),
            .value_type = retained_type,
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
