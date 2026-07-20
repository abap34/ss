const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

pub const Index = struct {
    module_graph: module_loader.ModuleGraph,
    constants: core.ConstMap,
    functions: core.FunctionMap,

    pub fn deinit(self: *Index) void {
        self.constants.deinit();
        self.functions.deinit();
        self.module_graph.deinit();
    }
};

pub const LoadOptions = struct {
    overlay: ?*const module_loader.SourceOverlay = null,
    diagnostics: ?*module_loader.LoadDiagnostics = null,
    print_diagnostics: bool = true,
    recovering: bool = false,
    embedded_cache: ?*module_loader.EmbeddedSyntaxCache = null,
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: []const u8,
    project_syntax: ast.Module,
    options: LoadOptions,
) !Index {
    const measure_start = utils.measure_profile.start();
    defer utils.measure_profile.recordAnalysis(.module_index, measure_start);
    const module_graph = try module_loader.loadGraphWithOptions(allocator, io, base_dir, project_syntax, .{
        .overlay = options.overlay,
        .diagnostics = options.diagnostics,
        .print_diagnostics = options.print_diagnostics,
        .recovering = options.recovering,
        .embedded_cache = options.embedded_cache,
    });
    var index = Index{
        .module_graph = module_graph,
        .constants = core.ConstMap.init(allocator),
        .functions = core.FunctionMap.init(allocator),
    };
    errdefer index.deinit();

    for (index.module_graph.module_order.items) |module_id| {
        const module = moduleById(index.module_graph.modules.items, module_id) orelse continue;
        try appendConstants(&index.constants, module.syntax, module.id);
        try appendFunctions(&index.functions, module.syntax, module.id);
    }
    try appendConstants(&index.constants, project_syntax, 0);
    try appendFunctions(&index.functions, project_syntax, 0);
    return index;
}

fn moduleById(modules: []const core.SourceModule, module_id: core.SourceModuleId) ?core.SourceModule {
    for (modules) |module| if (module.id == module_id) return module;
    return null;
}

fn appendFunctions(functions: *core.FunctionMap, program: ast.Module, module_id: core.SourceModuleId) !void {
    for (program.functions.items) |function| {
        try functions.put(core.functionKey(module_id, function.name), function);
    }
}

fn appendConstants(constants: *core.ConstMap, program: ast.Module, module_id: core.SourceModuleId) !void {
    for (program.constants.items) |constant| {
        try constants.put(core.constKey(module_id, constant.name), constant);
    }
}
