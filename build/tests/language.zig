const project = @import("../modules.zig");
const Suite = @import("support.zig").Suite;
const createModule = project.createModule;
const import = project.import;

pub fn register(suite: Suite, modules: project.ProjectModules) void {
    const ctx = suite.ctx;
    const syntax_mod = project.createSyntaxModule(ctx, modules);
    _ = suite.add(syntax_mod, .{});
    const parser_spec_mod = createModule(ctx, "tests/syntax/parser/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("syntax", syntax_mod),
    }, true);
    _ = suite.add(parser_spec_mod, .{ .name = "test-parser", .description = "Run focused syntax parser tests" });
    const scanner_mod = createModule(ctx, "src/syntax/scanner.zig", &.{
        import("utils", modules.utils),
    }, null);
    const scanner_spec_mod = createModule(ctx, "tests/syntax/scanner/spec_tests.zig", &.{
        import("scanner", scanner_mod),
    }, null);
    _ = suite.add(scanner_spec_mod, .{ .name = "test-scanner", .description = "Run focused syntax scanner tests" });
    const language_type_spec_mod = createModule(ctx, "tests/language/type/spec_tests.zig", &.{
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, null);
    _ = suite.add(language_type_spec_mod, .{ .name = "test-language-type", .description = "Run focused language type tests" });
    const analysis_mod = project.createAnalysisModule(ctx, modules);
    _ = suite.add(analysis_mod, .{});
    suite.addFile("tests/analysis/types/spec_tests.zig", &.{
        import("core", modules.core),
        import("language_type", modules.language_type),
        import("analysis", analysis_mod),
    }, true);
    const analysis_query_spec_mod = createModule(ctx, "tests/analysis/query/spec_tests.zig", &.{
        import("analysis", analysis_mod),
        import("utils", modules.utils),
    }, true);
    _ = suite.add(analysis_query_spec_mod, .{ .name = "test-analysis-query", .description = "Run focused analysis query tests" });
    const analysis_snapshot_spec_mod = createModule(ctx, "tests/analysis/snapshot/spec_tests.zig", &.{
        import("analysis", analysis_mod),
        import("ast", modules.ast),
        import("core", modules.core),
        import("render_text", modules.render_text),
    }, true);
    _ = suite.add(analysis_snapshot_spec_mod, .{ .name = "test-analysis-snapshot", .description = "Run focused analysis snapshot tests" });
    const analysis_diagnostics_spec_mod = createModule(ctx, "tests/analysis/diagnostics/spec_tests.zig", &.{
        import("analysis", analysis_mod),
    }, true);
    _ = suite.add(analysis_diagnostics_spec_mod, .{ .name = "test-analysis-diagnostics", .description = "Run focused analysis diagnostic ownership tests" });
    const type_defs_mod = createModule(ctx, "src/language/type_defs.zig", &.{}, null);
    suite.addFile("tests/language/type/defs_spec_tests.zig", &.{
        import("type_defs", type_defs_mod),
    }, null);

    const registry_mod = createModule(ctx, "src/language/registry.zig", &.{
        import("core", modules.core),
        import("language_type", modules.language_type),
    }, null);
    const registry_spec_mod = createModule(ctx, "tests/language/registry/spec_tests.zig", &.{
        import("core", modules.core),
        import("model", modules.model),
        import("language_type", modules.language_type),
        import("registry", registry_mod),
    }, true);
    _ = suite.add(registry_spec_mod, .{ .name = "test-language-registry", .description = "Run focused language registry tests" });
}
