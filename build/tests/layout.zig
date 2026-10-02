const project = @import("../modules.zig");
const Suite = @import("support.zig").Suite;
const createModule = project.createModule;
const import = project.import;

pub fn register(suite: Suite, modules: project.ProjectModules) void {
    const ctx = suite.ctx;
    const document_state_spec_mod = createModule(ctx, "tests/core/document_state/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    _ = suite.add(document_state_spec_mod, .{ .name = "test-document-state", .description = "Run focused document state tests" });
    const markdown_spec_mod = createModule(ctx, "tests/core/markdown/spec_tests.zig", &.{
        import("core", modules.core),
    }, true);
    _ = suite.add(markdown_spec_mod, .{ .name = "test-core-markdown", .description = "Run focused Markdown parsing tests" });
    const value_text_spec_mod = createModule(ctx, "tests/core/value_text/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
        import("language_type", modules.language_type),
    }, true);
    _ = suite.add(value_text_spec_mod, .{ .name = "test-value-text", .description = "Run focused tagged property value tests" });
    const layout_partition_spec_mod = createModule(ctx, "tests/layout/partition/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
    }, true);
    _ = suite.add(layout_partition_spec_mod, .{ .name = "test-layout-partition", .description = "Run focused page partition tests" });
    const layout_graph_spec_mod = createModule(ctx, "tests/layout/graph/spec_tests.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
        import("ast", modules.ast),
        import("model", modules.model),
        import("language_type", modules.language_type),
    }, true);
    _ = suite.add(layout_graph_spec_mod, .{ .name = "test-layout", .description = "Run focused layout graph and solver tests" });
    const layout_conflicts_spec_mod = createModule(ctx, "tests/layout/conflicts/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
    }, true);
    _ = suite.add(layout_conflicts_spec_mod, .{ .name = "test-layout-conflicts", .description = "Run focused layout conflict report tests" });
}
