const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const syntax = @import("../syntax/parse.zig");
const stdlib_assets = @import("stdlib_assets");
const utils = @import("utils");
const error_report = utils.err;

const max_module_bytes = 256 * 1024;

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

    pub fn put(self: *SourceOverlay, path: []const u8, source: []const u8) !void {
        const absolute = try std.fs.path.resolve(self.allocator, &.{path});
        errdefer self.allocator.free(absolute);
        const text = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(text);
        if (self.by_path.fetchRemove(absolute)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        try self.by_path.put(absolute, text);
    }

    pub fn get(self: *const SourceOverlay, path: []const u8) ?[]const u8 {
        const absolute = std.fs.path.resolve(self.allocator, &.{path}) catch return null;
        defer self.allocator.free(absolute);
        return self.by_path.get(absolute);
    }
};

const EmbeddedModule = struct {
    spec: []const u8,
    source: []const u8,
};

const embedded_modules = [_]EmbeddedModule{
    .{ .spec = "std:core/classes", .source = stdlib_assets.core_classes },
    .{ .spec = "std:core/layout", .source = stdlib_assets.core_layout },
    .{ .spec = "std:core/objects", .source = stdlib_assets.core_objects },
    .{ .spec = "std:core/render", .source = stdlib_assets.core_render },
    .{ .spec = "std:core/selectors", .source = stdlib_assets.core_selectors },
    .{ .spec = "std:core/generated", .source = stdlib_assets.core_generated },
    .{ .spec = "std:core/components", .source = stdlib_assets.core_components },
    .{ .spec = "std:themes/base", .source = stdlib_assets.themes_base },
    .{ .spec = "std:themes/default", .source = stdlib_assets.themes_default },
    .{ .spec = "std:themes/academic", .source = stdlib_assets.themes_academic },
    .{ .spec = "std:themes/pop", .source = stdlib_assets.themes_pop },
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    modules: std.ArrayList(core.SourceModule),
    module_order: std.ArrayList(core.SourceModuleId),
    project_import_ids: std.ArrayList(core.SourceModuleId),

    pub fn deinit(self: *Graph) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.modules.deinit(self.allocator);
        self.module_order.deinit(self.allocator);
        self.project_import_ids.deinit(self.allocator);
    }
};

pub fn loadGraph(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    project_program: ast.Program,
) !Graph {
    return loadGraphWithOverlay(allocator, io, project_dir, project_program, null);
}

pub fn loadGraphWithOverlay(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_dir: []const u8,
    project_program: ast.Program,
    overlay: ?*const SourceOverlay,
) !Graph {
    var builder = Builder{
        .allocator = allocator,
        .io = io,
        .overlay = overlay,
        .modules = std.ArrayList(core.SourceModule).empty,
        .by_key = std.StringHashMap(core.SourceModuleId).init(allocator),
        .state_by_id = std.AutoHashMap(core.SourceModuleId, VisitState).init(allocator),
        .next_id = 1,
    };
    defer builder.deinit();

    var graph = Graph{
        .allocator = allocator,
        .modules = .empty,
        .module_order = .empty,
        .project_import_ids = .empty,
    };
    errdefer graph.deinit();

    for (project_program.imports.items) |import_decl| {
        const module_id = try builder.loadImport(project_dir, import_decl.spec);
        try graph.project_import_ids.append(allocator, module_id);
    }

    var seen = std.AutoHashMap(core.SourceModuleId, void).init(allocator);
    defer seen.deinit();
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
    if (looksLikePath(import_spec)) {
        const resolved = try resolveExplicitPath(allocator, base_dir, import_spec);
        defer allocator.free(resolved);
        return std.fmt.allocPrint(
            allocator,
            "UnknownImport: module file was not found: {s}",
            .{resolved},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "UnknownImport: module '{s}' was not found. imports must use std:... or explicit paths relative to {s}",
        .{ import_spec, base_dir },
    );
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

        const source = try self.allocator.dupe(u8, resolved.source);
        var owns_source = true;
        errdefer if (owns_source) self.allocator.free(source);
        const parse_path = resolved.path orelse resolved.spec;
        const program = syntax.parseWithSourceName(self.allocator, source, parse_path) catch |err| {
            error_report.printParseError(parse_path, source, err, syntax.lastDiagnostic());
            return err;
        };
        var owns_program = true;
        errdefer if (owns_program) {
            var cleanup = program;
            cleanup.deinit(self.allocator);
        };
        if (kind == .project) unreachable;

        const key = try self.allocator.dupe(u8, resolved.key);
        errdefer self.allocator.free(key);
        try self.by_key.put(key, module_id);

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
            .source = source,
            .program = program,
            .resolved_import_ids = .empty,
        });
        owns_source = false;
        owns_program = false;
        owns_spec = false;
        owns_path = false;

        const importer_base_dir = if (path) |module_path| std.fs.path.dirname(module_path) orelse "." else ".";
        for (program.imports.items) |import_decl| {
            const import_id = self.loadImport(importer_base_dir, import_decl.spec) catch |err| {
                if (err == error.UnknownImport) {
                    const message = try formatUnknownImportMessage(self.allocator, importer_base_dir, import_decl.spec);
                    defer self.allocator.free(message);
                    error_report.print(.{
                        .path = path orelse spec,
                        .source = source,
                        .severity = .@"error",
                        .message = message,
                        .span = .{ .start = import_decl.span.start, .end = import_decl.span.end },
                    });
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
        for (module.resolved_import_ids.items) |import_id| {
            try self.appendPostOrder(import_id, order, seen);
        }
        gop.value_ptr.* = .done;
        try seen.put(module_id, {});
        try order.append(self.allocator, module_id);
    }
};

fn resolveImport(
    allocator: std.mem.Allocator,
    io: std.Io,
    importer_dir: []const u8,
    import_spec: []const u8,
    overlay: ?*const SourceOverlay,
) !ResolvedModule {
    if (std.mem.startsWith(u8, import_spec, "std:")) {
        return resolveStdModule(allocator, import_spec) orelse error.UnknownImport;
    }
    if (!looksLikePath(import_spec)) return error.UnknownImport;

    const path = try resolveExplicitPath(allocator, importer_dir, import_spec);
    errdefer allocator.free(path);
    const source = if (overlay) |source_overlay|
        if (source_overlay.get(path)) |text|
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
    return .{
        .key = try allocator.dupe(u8, path),
        .path = path,
        .source = source,
        .spec = try allocator.dupe(u8, import_spec),
    };
}

fn freeResolvedModule(allocator: std.mem.Allocator, resolved: ResolvedModule) void {
    allocator.free(resolved.key);
    if (resolved.path) |path| allocator.free(path);
    allocator.free(resolved.source);
    allocator.free(resolved.spec);
}

fn resolveStdModule(allocator: std.mem.Allocator, spec: []const u8) ?ResolvedModule {
    for (embedded_modules) |module| {
        if (std.mem.eql(u8, module.spec, spec)) {
            return .{
                .key = allocator.dupe(u8, spec) catch return null,
                .path = null,
                .source = allocator.dupe(u8, module.source) catch return null,
                .spec = allocator.dupe(u8, spec) catch return null,
            };
        }
    }
    return null;
}

fn looksLikePath(spec: []const u8) bool {
    return std.mem.indexOfScalar(u8, spec, '/') != null or
        std.mem.indexOfScalar(u8, spec, '\\') != null or
        std.mem.endsWith(u8, spec, ".ss");
}

fn resolveExplicitPath(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    spec: []const u8,
) ![]u8 {
    if (std.fs.path.isAbsolute(spec)) return allocator.dupe(u8, spec);
    return std.fs.path.resolve(allocator, &.{ base_dir, spec });
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
