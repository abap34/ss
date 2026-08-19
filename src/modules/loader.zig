const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const syntax = @import("../syntax/parse.zig");
const syntax_hole = @import("../syntax/hole.zig");
const names = @import("../language/names.zig");
const stdlib_assets = @import("stdlib_assets");
const utils = @import("utils");
const error_report = utils.err;
const source = utils.source;

const max_module_bytes = 256 * 1024;
const implicit_prelude_spec = "std:core/prelude";

pub const SourceOverlay = struct {
    allocator: std.mem.Allocator,
    by_path: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) SourceOverlay {
        return .{
            .allocator = allocator,
            .by_path = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SourceOverlay) void {
        var iterator = self.by_path.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.by_path.deinit();
    }

    pub fn put(self: *SourceOverlay, path: []const u8, text: []const u8) !void {
        const absolute = try std.fs.path.resolve(self.allocator, &.{path});
        errdefer self.allocator.free(absolute);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        if (self.by_path.fetchRemove(absolute)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.by_path.put(absolute, owned_text);
    }

    pub fn get(self: *const SourceOverlay, path: []const u8) !?[]const u8 {
        const absolute = try std.fs.path.resolve(self.allocator, &.{path});
        defer self.allocator.free(absolute);
        return self.by_path.get(absolute);
    }
};

const EmbeddedModule = struct {
    spec: []const u8,
    source: []const u8,
};

const embedded_modules = [_]EmbeddedModule{
    .{ .spec = "std:core/prelude", .source = stdlib_assets.core_prelude },
    .{ .spec = "std:core/classes", .source = stdlib_assets.core_classes },
    .{ .spec = "std:core/layout", .source = stdlib_assets.core_layout },
    .{ .spec = "std:core/objects", .source = stdlib_assets.core_objects },
    .{ .spec = "std:core/paths", .source = stdlib_assets.core_paths },
    .{ .spec = "std:core/fills", .source = stdlib_assets.core_fills },
    .{ .spec = "std:core/shapes", .source = stdlib_assets.core_shapes },
    .{ .spec = "std:core/connectors", .source = stdlib_assets.core_connectors },
    .{ .spec = "std:core/render", .source = stdlib_assets.core_render },
    .{ .spec = "std:core/selectors", .source = stdlib_assets.core_selectors },
    .{ .spec = "std:core/utils", .source = stdlib_assets.core_utils },
    .{ .spec = "std:core/generated", .source = stdlib_assets.core_generated },
    .{ .spec = "std:core/components", .source = stdlib_assets.core_components },
    .{ .spec = "std:themes/base", .source = stdlib_assets.themes_base },
    .{ .spec = "std:themes/default", .source = stdlib_assets.themes_default },
    .{ .spec = "std:themes/academic", .source = stdlib_assets.themes_academic },
    .{ .spec = "std:themes/pop", .source = stdlib_assets.themes_pop },
};

pub const EmbeddedSyntaxCache = struct {
    arena: std.heap.ArenaAllocator,
    modules: [embedded_modules.len]?ast.Module = [_]?ast.Module{null} ** embedded_modules.len,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator) EmbeddedSyntaxCache {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *EmbeddedSyntaxCache) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn parsedModuleCount(self: *EmbeddedSyntaxCache) usize {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.modules) |maybe_module| if (maybe_module != null) {
            count += 1;
        };
        return count;
    }

    fn cloneModule(self: *EmbeddedSyntaxCache, allocator: std.mem.Allocator, index: usize, failure: *syntax.ParseFailure) !ast.Module {
        failure.* = .{};
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
        if (self.modules[index] == null) {
            const parse_start = utils.measure_profile.start();
            defer utils.measure_profile.recordAnalysis(.embedded_parse, parse_start);
            self.modules[index] = try syntax.parseWithSourceNameAndFailure(
                self.arena.allocator(),
                embedded_modules[index].source,
                embedded_modules[index].spec,
                failure,
            );
        }
        const clone_start = utils.measure_profile.start();
        defer utils.measure_profile.recordAnalysis(.embedded_clone, clone_start);
        return try self.modules[index].?.clone(allocator);
    }
};

pub const ModuleGraph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(core.SourceModule),
    module_order: std.ArrayList(core.SourceModuleId),
    project_implicit_import_ids: std.ArrayList(core.SourceModuleId),
    project_import_ids: std.ArrayList(core.SourceModuleId),

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.project_implicit_import_ids.deinit(self.allocator);
        self.project_import_ids.deinit(self.allocator);
    }
};

pub const LoadDiagnostic = struct {
    path: []u8,
    source: []u8,
    severity: core.DiagnosticSeverity,
    code: []u8,
    message: []u8,
    span: ?source.ByteSpan,

    pub fn deinit(self: *LoadDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.source);
        allocator.free(self.code);
        allocator.free(self.message);
    }
};

pub const LoadDiagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(LoadDiagnostic),

    pub fn init(allocator: std.mem.Allocator) LoadDiagnostics {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *LoadDiagnostics) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn add(
        self: *LoadDiagnostics,
        path: []const u8,
        text: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?source.ByteSpan,
    ) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_code = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(owned_code);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);
        try self.items.append(self.allocator, .{
            .path = owned_path,
            .source = owned_text,
            .severity = severity,
            .code = owned_code,
            .message = owned_message,
            .span = span,
        });
    }
};

pub const LoadOptions = struct {
    overlay: ?*const SourceOverlay = null,
    diagnostics: ?*LoadDiagnostics = null,
    print_diagnostics: bool = true,
    recovering: bool = false,
    embedded_cache: ?*EmbeddedSyntaxCache = null,
};

pub fn loadGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    project_module: ast.Module,
) !ModuleGraph {
    return loadGraphWithOverlay(allocator, io, project_dir, project_module, null);
}

pub fn loadGraphWithOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    project_module: ast.Module,
    overlay: ?*const SourceOverlay,
) !ModuleGraph {
    return loadGraphWithOptions(allocator, io, project_dir, project_module, .{ .overlay = overlay });
}

pub fn loadGraphWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    project_module: ast.Module,
    options: LoadOptions,
) !ModuleGraph {
    const measure_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.module_graph, measure_start);
    var builder = Builder{
        .allocator = allocator,
        .io = io,
        .overlay = options.overlay,
        .diagnostics = options.diagnostics,
        .print_diagnostics = options.print_diagnostics,
        .recovering = options.recovering,
        .embedded_cache = options.embedded_cache,
        .modules = std.ArrayList(core.SourceModule).empty,
        .by_key = std.StringHashMap(core.SourceModuleId).init(allocator),
        .state_by_id = std.AutoHashMap(core.SourceModuleId, VisitState).init(allocator),
        .next_id = 1,
    };
    defer builder.deinit();

    var graph = ModuleGraph{
        .allocator = allocator,
        .modules = .empty,
        .module_order = .empty,
        .project_implicit_import_ids = .empty,
        .project_import_ids = .empty,
    };
    errdefer graph.deinit();

    if (shouldProjectImplicitlyImportPrelude(project_dir)) {
        const prelude_id = try builder.loadImport(project_dir, implicit_prelude_spec);
        try graph.project_implicit_import_ids.append(allocator, prelude_id);
    }

    for (project_module.imports.items) |import_decl| {
        const module_id = try builder.loadImport(project_dir, import_decl.spec);
        try graph.project_import_ids.append(allocator, module_id);
    }

    var seen = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
    defer seen.deinit();
    for (graph.project_implicit_import_ids.items) |module_id| {
        try builder.appendPostOrder(module_id, &graph.module_order, &seen);
    }
    for (graph.project_import_ids.items) |module_id| {
        try builder.appendPostOrder(module_id, &graph.module_order, &seen);
    }

    graph.modules = try builder.takeModules();
    return graph;
}

pub fn formatUnknownImportMessage(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_spec: []const u8,
) ![]u8 {
    if (std.mem.startsWith(u8, import_spec, "std:")) {
        return std.fmt.allocPrint(
            allocator,
            "UnknownImport: stdlib module was not found: {s}",
            .{import_spec},
        );
    }
    const resolved = try resolveExplicitPathForMessage(allocator, base_dir, import_spec);
    defer allocator.free(resolved);
    return std.fmt.allocPrint(
        allocator,
        "UnknownImport: module file was not found: {s}",
        .{resolved},
    );
}

pub fn isImportReadFailure(err: anyerror) bool {
    return err != error.FileNotFound and error_report.isFileSystemError(err);
}

pub fn formatImportReadFailureMessage(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_spec: []const u8,
    err: anyerror,
) ![]u8 {
    const resolved = try resolveExplicitPathForMessage(allocator, base_dir, import_spec);
    defer allocator.free(resolved);
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => std.fmt.allocPrint(
            allocator,
            "ImportReadFailed: module file is not readable: {s}",
            .{resolved},
        ),
        error.FileTooBig, error.FileTooLarge, error.StreamTooLong => std.fmt.allocPrint(
            allocator,
            "ImportReadFailed: module file exceeds the {d}-byte limit: {s}",
            .{ max_module_bytes, resolved },
        ),
        error.IsDir => std.fmt.allocPrint(
            allocator,
            "ImportReadFailed: module path is a directory: {s}",
            .{resolved},
        ),
        error.NotDir => std.fmt.allocPrint(
            allocator,
            "ImportReadFailed: a module path component is not a directory: {s}",
            .{resolved},
        ),
        else => blk: {
            if (!isImportReadFailure(err)) return error.UnexpectedImportReadFailure;
            var reason_buf: [256]u8 = undefined;
            break :blk std.fmt.allocPrint(
                allocator,
                "ImportReadFailed: could not read module file {s}: {s}",
                .{ resolved, error_report.formatErrorReason(&reason_buf, err) },
            );
        },
    };
}

pub const UnknownImportReport = struct {
    message: []u8,
    span: ast.Span,

    pub fn deinit(self: *UnknownImportReport, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub fn findUnknownImportReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    program: ast.Module,
    overlay: ?*const SourceOverlay,
) !?UnknownImportReport {
    for (program.imports.items) |import_decl| {
        const resolved = resolveImport(allocator, io, base_dir, import_decl.spec, overlay) catch |err| switch (err) {
            error.UnknownImport => {
                return .{
                    .message = try formatUnknownImportMessage(allocator, base_dir, import_decl.spec),
                    .span = import_decl.span,
                };
            },
            else => return err,
        };
        freeResolvedModule(allocator, resolved);
    }
    return null;
}

pub fn findImportReadFailureReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    program: ast.Module,
    overlay: ?*const SourceOverlay,
    expected_error: anyerror,
) !?UnknownImportReport {
    for (program.imports.items) |import_decl| {
        const resolved = resolveImport(allocator, io, base_dir, import_decl.spec, overlay) catch |err| {
            if (err != expected_error) return err;
            return .{
                .message = try formatImportReadFailureMessage(allocator, base_dir, import_decl.spec, err),
                .span = import_decl.span,
            };
        };
        freeResolvedModule(allocator, resolved);
    }
    return null;
}

pub fn importFailureSpan(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    program: *const ast.Module,
    overlay: ?*const SourceOverlay,
    diagnostics: *const LoadDiagnostics,
) !?source.ByteSpan {
    for (diagnostics.items.items) |diagnostic| {
        for (program.imports.items) |import_decl| {
            if (try importMatchesDiagnosticPath(allocator, io, base_dir, import_decl.spec, diagnostic.path, overlay)) {
                return .{ .start = import_decl.span.start, .end = import_decl.span.end };
            }
        }
    }
    return null;
}

fn importMatchesDiagnosticPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    import_spec: []const u8,
    diagnostic_path: []const u8,
    overlay: ?*const SourceOverlay,
) !bool {
    const resolved = resolveImport(allocator, io, base_dir, import_spec, overlay) catch |err| switch (err) {
        error.UnknownImport => return false,
        else => return err,
    };
    defer freeResolvedModule(allocator, resolved);
    if (resolved.path) |path| {
        return std.mem.eql(u8, path, diagnostic_path);
    }
    return std.mem.eql(u8, resolved.spec, diagnostic_path);
}

const VisitState = enum {
    visiting,
    done,
};

const ResolvedModule = struct {
    key: []u8,
    path: ?[]u8,
    source: []u8,
    spec: []u8,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    overlay: ?*const SourceOverlay,
    diagnostics: ?*LoadDiagnostics,
    print_diagnostics: bool,
    recovering: bool,
    embedded_cache: ?*EmbeddedSyntaxCache,
    modules: std.ArrayList(core.SourceModule),
    by_key: std.StringHashMap(core.SourceModuleId),
    state_by_id: std.AutoHashMap(core.SourceModuleId, VisitState),
    next_id: core.SourceModuleId,

    fn deinit(self: *Builder) void {
        var key_iterator = self.by_key.keyIterator();
        while (key_iterator.next()) |key| self.allocator.free(key.*);
        self.by_key.deinit();
        self.state_by_id.deinit();
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
    }

    fn addDiagnostic(
        self: *Builder,
        path: []const u8,
        text: []const u8,
        severity: core.DiagnosticSeverity,
        code: []const u8,
        message: []const u8,
        span: ?source.ByteSpan,
    ) !void {
        if (self.diagnostics) |diagnostics| {
            try diagnostics.add(path, text, severity, code, message, span);
        }
    }

    fn addParseFailureDiagnostic(self: *Builder, path: []const u8, text: []const u8, err: anyerror, diagnostic: ?syntax.ParseDiagnostic) !void {
        var message_buf: [256]u8 = undefined;
        const message = if (diagnostic) |diag|
            error_report.formatParseDiagnostic(&message_buf, diag)
        else
            error_report.formatParseFailureWithoutDiagnostic(&message_buf, err);
        try self.addDiagnostic(path, text, .@"error", @errorName(err), message, if (diagnostic) |diag| .{ .start = diag.span.start, .end = diag.span.end } else null);
        if (self.print_diagnostics) {
            error_report.printParseError(path, text, err, diagnostic);
        }
    }

    fn addParseHoleDiagnostics(self: *Builder, path: []const u8, text: []const u8, hole_diagnostics: []const syntax_hole.Diagnostic) !void {
        for (hole_diagnostics) |diagnostic| {
            const expected = diagnostic.expected orelse "syntax";
            const found = diagnostic.found orelse "unknown";
            const message = try std.fmt.allocPrint(
                self.allocator,
                "ParseHole: expected {s}, found {s}",
                .{ expected, found },
            );
            defer self.allocator.free(message);
            try self.addDiagnostic(path, text, .@"error", @errorName(diagnostic.err), message, .{
                .start = diagnostic.span.start,
                .end = diagnostic.span.end,
            });
        }
    }

    fn takeModules(self: *Builder) !std.ArrayList(core.SourceModule) {
        const out = self.modules;
        self.modules = .empty;
        return out;
    }

    fn loadImport(self: *Builder, importer_dir: []const u8, import_spec: []const u8) anyerror!core.SourceModuleId {
        const resolved = try resolveImport(self.allocator, self.io, importer_dir, import_spec, self.overlay);
        defer freeResolvedModule(self.allocator, resolved);
        return try self.loadResolved(.library, resolved);
    }

    fn loadResolved(self: *Builder, kind: core.SourceModuleKind, resolved: ResolvedModule) anyerror!core.SourceModuleId {
        if (self.by_key.get(resolved.key)) |existing_id| {
            return existing_id;
        }

        const module_id = self.next_id;
        self.next_id += 1;

        const text = try self.allocator.dupe(u8, resolved.source);
        var owns_source = true;
        errdefer if (owns_source) self.allocator.free(text);
        const parse_path = resolved.path orelse resolved.spec;
        const cached_index = if (self.embedded_cache != null and resolved.path == null) embeddedModuleIndex(resolved.spec) else null;
        var parse_failure: syntax.ParseFailure = .{};
        const module_syntax = if (cached_index) |index| self.embedded_cache.?.cloneModule(self.allocator, index, &parse_failure) catch |err| {
            if (err == error.OutOfMemory) return err;
            try self.addParseFailureDiagnostic(parse_path, text, err, parse_failure.diagnostic);
            return error.DiagnosticsFailed;
        } else blk: {
            const parse_start = utils.measure_profile.start();
            defer utils.measure_profile.recordAnalysis(if (embeddedModuleIndex(resolved.spec) != null) .embedded_parse else .module_parse, parse_start);
            break :blk if (self.recovering) recover: {
                var result = syntax.parseRecoveringWithSourceNameAndFailure(self.allocator, text, parse_path, &parse_failure) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.addParseFailureDiagnostic(parse_path, text, err, parse_failure.diagnostic);
                    return error.DiagnosticsFailed;
                };
                errdefer result.module.deinit(self.allocator);
                defer result.holes.deinit(self.allocator);
                try self.addParseHoleDiagnostics(parse_path, text, result.holes.diagnostics);
                break :recover result.module;
            } else syntax.parseWithSourceNameAndFailure(self.allocator, text, parse_path, &parse_failure) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.addParseFailureDiagnostic(parse_path, text, err, parse_failure.diagnostic);
                return error.DiagnosticsFailed;
            };
        };
        var owns_module_syntax = true;
        errdefer if (owns_module_syntax) {
            var cleanup = module_syntax;
            cleanup.deinit(self.allocator);
        };
        if (kind == .project) unreachable;

        const key = try self.allocator.dupe(u8, resolved.key);
        var owns_key = true;
        errdefer if (owns_key) self.allocator.free(key);
        try self.by_key.put(key, module_id);
        owns_key = false;

        const spec = try self.allocator.dupe(u8, resolved.spec);
        var owns_spec = true;
        errdefer if (owns_spec) self.allocator.free(spec);
        const path = if (resolved.path) |path_value| try self.allocator.dupe(u8, path_value) else null;
        var owns_path = path != null;
        errdefer if (owns_path) if (path) |owned_path| self.allocator.free(owned_path);

        try self.modules.append(self.allocator, .{
            .id = module_id,
            .kind = kind,
            .spec = spec,
            .path = path,
            .source = text,
            .syntax = module_syntax,
            .implicit_import_ids = .empty,
            .resolved_import_ids = .empty,
        });
        owns_source = false;
        owns_module_syntax = false;
        owns_spec = false;
        owns_path = false;

        const importer_base_dir = if (path) |module_path| std.fs.path.dirname(module_path) orelse "." else ".";
        if (shouldImplicitlyImportPrelude(kind, spec)) {
            const import_id = try self.loadImport(importer_base_dir, implicit_prelude_spec);
            const module = self.moduleByIdMutable(module_id).?;
            try module.implicit_import_ids.append(self.allocator, import_id);
        }
        for (module_syntax.imports.items) |import_decl| {
            const import_id = self.loadImport(importer_base_dir, import_decl.spec) catch |err| {
                if (err == error.UnknownImport) {
                    const message = try formatUnknownImportMessage(self.allocator, importer_base_dir, import_decl.spec);
                    defer self.allocator.free(message);
                    try self.addDiagnostic(path orelse spec, text, .@"error", "UnknownImport", message, .{ .start = import_decl.span.start, .end = import_decl.span.end });
                    if (self.print_diagnostics) {
                        error_report.print(.{
                            .path = path orelse spec,
                            .source = text,
                            .severity = .@"error",
                            .message = message,
                            .span = .{ .start = import_decl.span.start, .end = import_decl.span.end },
                        });
                    }
                    return error.DiagnosticsFailed;
                }
                if (isImportReadFailure(err)) {
                    const message = try formatImportReadFailureMessage(self.allocator, importer_base_dir, import_decl.spec, err);
                    defer self.allocator.free(message);
                    try self.addDiagnostic(path orelse spec, text, .@"error", "ImportReadFailed", message, .{ .start = import_decl.span.start, .end = import_decl.span.end });
                    if (self.print_diagnostics) {
                        error_report.print(.{
                            .path = path orelse spec,
                            .source = text,
                            .severity = .@"error",
                            .message = message,
                            .span = .{ .start = import_decl.span.start, .end = import_decl.span.end },
                        });
                    }
                    return error.DiagnosticsFailed;
                }
                return err;
            };
            const module = self.moduleByIdMutable(module_id).?;
            try module.resolved_import_ids.append(self.allocator, import_id);
        }

        try self.state_by_id.put(module_id, .done);
        return module_id;
    }

    fn moduleByIdMutable(self: *Builder, id: core.SourceModuleId) ?*core.SourceModule {
        for (self.modules.items) |*module| {
            if (module.id == id) return module;
        }
        return null;
    }

    fn appendPostOrder(
        self: *Builder,
        module_id: core.SourceModuleId,
        order: *std.ArrayList(core.SourceModuleId),
        seen: *std.AutoHashMap(core.SourceModuleId, void),
    ) !void {
        if (seen.contains(module_id)) return;
        const gop = try self.state_by_id.getOrPut(module_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .visiting;
        } else if (gop.value_ptr.* == .visiting) {
            return error.ImportCycle;
        } else if (gop.value_ptr.* == .done and seen.contains(module_id)) {
            return;
        } else {
            gop.value_ptr.* = .visiting;
        }

        const module = self.moduleByIdMutable(module_id) orelse return error.UnknownImport;
        for (module.implicit_import_ids.items) |import_id| {
            if (self.state_by_id.get(import_id)) |state| {
                if (state == .visiting) {
                    try self.reportImportCycle(module, null);
                    return error.DiagnosticsFailed;
                }
            }
            try self.appendPostOrder(import_id, order, seen);
        }
        for (module.resolved_import_ids.items, 0..) |import_id, import_index| {
            if (self.state_by_id.get(import_id)) |state| {
                if (state == .visiting) {
                    try self.reportImportCycle(module, import_index);
                    return error.DiagnosticsFailed;
                }
            }
            try self.appendPostOrder(import_id, order, seen);
        }
        gop.value_ptr.* = .done;
        try seen.put(module_id, {});
        try order.append(self.allocator, module_id);
    }

    fn reportImportCycle(self: *Builder, module: *const core.SourceModule, import_index: ?usize) !void {
        const path = module.path orelse module.spec;
        const span: ?source.ByteSpan = if (import_index) |index| blk: {
            if (index >= module.syntax.imports.items.len) break :blk null;
            const import_span = module.syntax.imports.items[index].span;
            break :blk .{ .start = import_span.start, .end = import_span.end };
        } else null;
        const message = "ImportCycle: import graph contains a cycle";
        try self.addDiagnostic(path, module.source, .@"error", "ImportCycle", message, span);
        if (!self.print_diagnostics) return;
        error_report.print(.{
            .path = path,
            .source = module.source,
            .severity = .@"error",
            .message = message,
            .span = span,
        });
    }
};

fn shouldImplicitlyImportPrelude(kind: core.SourceModuleKind, spec: []const u8) bool {
    if (kind == .project) return true;
    return !std.mem.startsWith(u8, spec, "std:core/");
}

fn embeddedModuleIndex(spec: []const u8) ?usize {
    for (embedded_modules, 0..) |module, index| {
        if (std.mem.eql(u8, module.spec, spec)) return index;
    }
    return null;
}

fn shouldProjectImplicitlyImportPrelude(project_dir: []const u8) bool {
    const base = std.fs.path.basename(project_dir);
    if (!std.mem.eql(u8, base, "core")) return true;
    const parent = std.fs.path.dirname(project_dir) orelse return true;
    return !std.mem.eql(u8, std.fs.path.basename(parent), "stdlib");
}

fn resolveImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    importer_dir: []const u8,
    import_spec: []const u8,
    overlay: ?*const SourceOverlay,
) !ResolvedModule {
    if (std.mem.startsWith(u8, import_spec, "std:")) {
        return (try resolveStdModule(allocator, import_spec)) orelse error.UnknownImport;
    }
    const path = try resolveExplicitPath(allocator, importer_dir, import_spec);
    errdefer allocator.free(path);
    const module_text = if (overlay) |source_overlay|
        if (try source_overlay.get(path)) |text|
            try allocator.dupe(u8, text)
        else
            readModuleFile(allocator, io, path) catch |err| switch (err) {
                error.FileNotFound => return error.UnknownImport,
                else => return err,
            }
    else
        readModuleFile(allocator, io, path) catch |err| switch (err) {
            error.FileNotFound => return error.UnknownImport,
            else => return err,
        };
    errdefer allocator.free(module_text);
    const key = try allocator.dupe(u8, path);
    errdefer allocator.free(key);
    const spec = try allocator.dupe(u8, import_spec);
    errdefer allocator.free(spec);
    return .{
        .key = key,
        .path = path,
        .source = module_text,
        .spec = spec,
    };
}

fn freeResolvedModule(allocator: std.mem.Allocator, resolved: ResolvedModule) void {
    allocator.free(resolved.key);
    if (resolved.path) |path| allocator.free(path);
    allocator.free(resolved.source);
    allocator.free(resolved.spec);
}

fn resolveStdModule(allocator: std.mem.Allocator, spec: []const u8) !?ResolvedModule {
    for (embedded_modules) |module| {
        if (std.mem.eql(u8, module.spec, spec)) {
            const key = try allocator.dupe(u8, spec);
            errdefer allocator.free(key);
            const module_source = try allocator.dupe(u8, module.source);
            errdefer allocator.free(module_source);
            const owned_spec = try allocator.dupe(u8, spec);
            return .{
                .key = key,
                .path = null,
                .source = module_source,
                .spec = owned_spec,
            };
        }
    }
    return null;
}

fn resolveExplicitPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    spec: []const u8,
) ![]u8 {
    const normalized = try specWithDefaultExtension(allocator, spec);
    defer allocator.free(normalized);
    if (std.fs.path.isAbsolute(normalized)) return allocator.dupe(u8, normalized);
    return std.fs.path.resolve(allocator, &.{ base_dir, normalized });
}

fn resolveExplicitPathForMessage(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    spec: []const u8,
) ![]u8 {
    return resolveExplicitPath(allocator, base_dir, spec);
}

fn specWithDefaultExtension(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    return names.importPathWithDefaultExtension(allocator, spec);
}

fn readModuleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_module_bytes));
}

fn tryReadModuleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[]u8 {
    return readModuleFile(allocator, io, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}
