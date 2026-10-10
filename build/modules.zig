const std = @import("std");
const compat = @import("compat.zig");
const native_pdf = @import("native_pdf.zig");
const tree_sitter_build = @import("tree_sitter.zig");
const html = @import("html.zig");
const Module = std.Build.Module;
const Step = std.Build.Step;
const Import = Module.Import;

pub const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: compat.Optimize,
};

pub const ProjectModules = struct {
    utils: *Module,
    model: *Module,
    diagnostic: *Module,
    language_type: *Module,
    ast: *Module,
    stdlib_assets: *Module,
    fontawesome_assets: *Module,
    pdfjs_assets: *Module,
    html_embeds: *Module,
    project: *Module,
    core: *Module,
    render: *Module,
    render_resources: *Module,
    render_measurements: *Module,
    pdf_ffi: *Module,
    render_text: *Module,
    render_emitter: *Module,
    pdf_backend: *Module,
};

pub fn create(ctx: Context, build_options: *Step.Options, tree_sitter: tree_sitter_build.Bundle, tree_options: tree_sitter_build.CompileOptions) ProjectModules {
    const md4c_src = "third_party/md4c/src";
    const md4c_include = ctx.b.path(md4c_src);
    for ([_][]const u8{ md4c_src ++ "/md4c.c", md4c_src ++ "/md4c.h" }) |path| {
        compat.access(ctx.b, path) catch
            @panic(
                \\Bundled MD4C sources are missing from third_party/md4c/src.
                \\Restore the tracked third_party/md4c files and retry the build.
            );
    }
    const model_mod = createModule(ctx, "src/core/model.zig", &.{}, null);
    const keywords_mod = createModule(ctx, "src/syntax/keywords.zig", &.{}, null);
    const utils_mod = createModule(ctx, "src/utils/root.zig", &.{
        import("model", model_mod),
        import("syntax_keywords", keywords_mod),
    }, null);
    const language_type_mod = createModule(ctx, "src/language/type.zig", &.{
        import("model", model_mod),
    }, null);
    const ast_mod = createModule(ctx, "src/ast.zig", &.{
        import("model", model_mod),
        import("language_type", language_type_mod),
    }, null);
    const diagnostic_mod = createModule(ctx, "src/diagnostics.zig", &.{
        import("model", model_mod),
        import("ast", ast_mod),
        import("utils", utils_mod),
    }, null);
    const stdlib_assets_mod = createModule(ctx, "stdlib/embed.zig", &.{}, null);
    const fontawesome_assets_mod = createModule(ctx, "third_party/fontawesome-free/embed.zig", &.{}, null);
    const pdfjs_assets_mod = createModule(ctx, "third_party/pdfjs/embed.zig", &.{}, null);
    const html_embeds_mod = html.create(ctx.b, ctx.target, ctx.optimize);
    const md4c_abi = ctx.b.addTranslateC(.{
        .root_source_file = ctx.b.path("third_party/md4c/src/md4c.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    }).createModule();
    const toml_abi = ctx.b.addTranslateC(.{
        .root_source_file = ctx.b.path("third_party/tomlc17/tomlc17.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    }).createModule();
    const pdf_abi = ctx.b.addTranslateC(.{
        .root_source_file = ctx.b.path("src/render/pdf/backend.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    }).createModule();
    const project_mod = createModule(ctx, "src/project.zig", &.{
        import("utils", utils_mod),
    }, true);
    project_mod.addImport("toml_abi", toml_abi);
    project_mod.addIncludePath(ctx.b.path("third_party/tomlc17"));
    project_mod.addCSourceFile(.{
        .file = ctx.b.path("third_party/tomlc17/tomlc17.c"),
        .flags = &.{"-std=c17"},
    });
    const core_mod = createModule(ctx, "src/core.zig", &.{
        import("utils", utils_mod),
        import("ast", ast_mod),
        import("model", model_mod),
        import("language_type", language_type_mod),
        import("fontawesome_assets", fontawesome_assets_mod),
    }, true);
    core_mod.addImport("md4c_abi", md4c_abi);
    core_mod.addImport("pdf_abi", pdf_abi);
    core_mod.addOptions("build_options", build_options);
    const tree_sitter_abi = ctx.b.addTranslateC(.{
        .root_source_file = tree_sitter.root.path(ctx.b, "runtime/source/lib/include/tree_sitter/api.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
    core_mod.addImport("tree_sitter_abi", tree_sitter_abi.createModule());
    core_mod.addIncludePath(md4c_include);
    core_mod.addCSourceFiles(.{
        .root = ctx.b.path(md4c_src),
        .files = &.{"md4c.c"},
    });
    native_pdf.addSources(ctx.b, core_mod);
    tree_sitter_build.addSources(tree_options, core_mod, tree_sitter);

    const render_mod = createModule(ctx, "src/render/ir.zig", &.{
        import("core", core_mod),
    }, null);
    const render_measurements_mod = createModule(ctx, "src/render/compile/measurement_store.zig", &.{
        import("core", core_mod),
        import("utils", utils_mod),
    }, null);
    const pdf_ffi_mod = createModule(ctx, "src/render/pdf/ffi.zig", &.{}, true);
    pdf_ffi_mod.addImport("pdf_abi", pdf_abi);
    native_pdf.addHeaders(ctx.b, pdf_ffi_mod);
    const render_resources_mod = createModule(ctx, "src/render/compile/resources.zig", &.{
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
    }, true);
    const render_text_mod = createModule(ctx, "src/render/compile/text.zig", &.{
        import("core", core_mod),
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
        import("render_resources", render_resources_mod),
        import("utils", utils_mod),
    }, true);
    const render_emitter_mod = createModule(ctx, "src/render/compile/emitter.zig", &.{
        import("core", core_mod),
        import("render", render_mod),
        import("render_resources", render_resources_mod),
        import("render_text", render_text_mod),
    }, true);
    const pdf_backend_mod = createModule(ctx, "src/render/pdf/backend.zig", &.{
        import("core", core_mod),
        import("pdf_ffi", pdf_ffi_mod),
        import("render", render_mod),
    }, true);

    return .{
        .utils = utils_mod,
        .model = model_mod,
        .diagnostic = diagnostic_mod,
        .language_type = language_type_mod,
        .ast = ast_mod,
        .stdlib_assets = stdlib_assets_mod,
        .fontawesome_assets = fontawesome_assets_mod,
        .pdfjs_assets = pdfjs_assets_mod,
        .html_embeds = html_embeds_mod,
        .project = project_mod,
        .core = core_mod,
        .render = render_mod,
        .render_resources = render_resources_mod,
        .render_measurements = render_measurements_mod,
        .pdf_ffi = pdf_ffi_mod,
        .render_text = render_text_mod,
        .render_emitter = render_emitter_mod,
        .pdf_backend = pdf_backend_mod,
    };
}

pub fn createModule(
    ctx: Context,
    root_source_file: []const u8,
    imports: []const Import,
    link_libc: ?bool,
) *Module {
    return ctx.b.createModule(.{
        .root_source_file = ctx.b.path(root_source_file),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = imports,
        .link_libc = link_libc,
    });
}

pub fn import(name: []const u8, module: *Module) Import {
    return .{ .name = name, .module = module };
}

fn compilerImports(modules: ProjectModules) [13]Import {
    return .{
        import("ast", modules.ast),
        import("core", modules.core),
        import("diagnostic", modules.diagnostic),
        import("html_embeds", modules.html_embeds),
        import("language_type", modules.language_type),
        import("model", modules.model),
        import("pdfjs_assets", modules.pdfjs_assets),
        import("project", modules.project),
        import("render", modules.render),
        import("render_measurements", modules.render_measurements),
        import("render_text", modules.render_text),
        import("stdlib_assets", modules.stdlib_assets),
        import("utils", modules.utils),
    };
}

fn applicationImports(modules: ProjectModules) [17]Import {
    return compilerImports(modules) ++ [_]Import{
        import("pdf_backend", modules.pdf_backend),
        import("pdf_ffi", modules.pdf_ffi),
        import("render_emitter", modules.render_emitter),
        import("render_resources", modules.render_resources),
    };
}

pub fn createSyntaxModule(ctx: Context, modules: ProjectModules) *Module {
    const imports = [_]Import{ import("ast", modules.ast), import("core", modules.core), import("utils", modules.utils) };
    return createModule(ctx, "src/syntax.zig", &imports, true);
}

pub fn createAnalysisModule(ctx: Context, modules: ProjectModules) *Module {
    const imports = compilerImports(modules);
    return createModule(ctx, "src/analysis.zig", &imports, true);
}

pub fn createCompilerModule(ctx: Context, modules: ProjectModules) *Module {
    const imports = compilerImports(modules);
    return createModule(ctx, "src/compiler.zig", &imports, true);
}

pub fn createLspModule(ctx: Context, modules: ProjectModules) *Module {
    const imports = applicationImports(modules);
    return createModule(ctx, "src/lsp.zig", &imports, true);
}

pub fn createWatchModule(ctx: Context, modules: ProjectModules) *Module {
    const imports = applicationImports(modules);
    const module = createModule(ctx, "src/watch.zig", &imports, true);
    native_pdf.addHeaders(ctx.b, module);
    return module;
}

pub fn createAppModule(ctx: Context, modules: ProjectModules, build_options: *Step.Options) *Module {
    const imports = applicationImports(modules);
    const module = createModule(ctx, "src/app.zig", &imports, true);
    module.addOptions("build_options", build_options);
    return module;
}

pub fn createCliModule(ctx: Context, modules: ProjectModules, build_options: *Step.Options) *Module {
    const imports = applicationImports(modules);
    const module = createModule(ctx, "src/main.zig", &imports, true);
    module.addOptions("build_options", build_options);
    native_pdf.addHeaders(ctx.b, module);
    return module;
}
