const std = @import("std");
const project = @import("../modules.zig");
const Suite = @import("support.zig").Suite;
const Module = std.Build.Module;
const createModule = project.createModule;
const import = project.import;

pub fn register(suite: Suite, modules: project.ProjectModules, compiler_mod: *Module) void {
    const ctx = suite.ctx;
    const b = ctx.b;
    const completion_spec_mod = createModule(ctx, "tests/lsp/completion/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    const run_completion_spec_tests = suite.add(completion_spec_mod, .{});
    const completion_step = b.step("test-completion", "Run focused analysis and LSP completion tests");
    completion_step.dependOn(&run_completion_spec_tests.step);
    const completion_api = project.createLspModule(ctx, modules);
    const completion_response_mod = createModule(ctx, "tests/lsp/completion/response_spec_tests.zig", &.{
        import("lsp", completion_api),
    }, true);
    const run_completion_response_tests = suite.add(completion_response_mod, .{});
    completion_step.dependOn(&run_completion_response_tests.step);
    const source_index_mod = createModule(ctx, "tests/utils/source/index_spec_tests.zig", &.{
        import("utils", modules.utils),
    }, null);
    const run_source_index_tests = suite.add(source_index_mod, .{});
    const lsp_positions_mod = createModule(ctx, "tests/lsp/source_positions/spec_tests.zig", &.{
        import("lsp", completion_api),
    }, true);
    const run_lsp_positions_tests = suite.add(lsp_positions_mod, .{});
    const source_positions_step = b.step("test-source-positions", "Run focused source position and document update tests");
    source_positions_step.dependOn(&run_source_index_tests.step);
    source_positions_step.dependOn(&run_lsp_positions_tests.step);
    const editor_edit_mod = createModule(ctx, "src/editor/edit.zig", &.{
        import("model", modules.model),
        import("utils", modules.utils),
    }, null);
    const editor_edit_spec_mod = createModule(ctx, "tests/editor/edit/spec_tests.zig", &.{
        import("editor_edit", editor_edit_mod),
    }, null);
    _ = suite.add(editor_edit_spec_mod, .{ .name = "test-editor-edit", .description = "Run focused WYSIWYG source edit tests" });
    const generated_edit_spec_mod = createModule(ctx, "tests/editor/edit/generated/spec_tests.zig", &.{
        import("editor_edit", editor_edit_mod),
    }, null);
    _ = suite.add(generated_edit_spec_mod, .{ .name = "test-editor-generated", .description = "Run focused generated edit validation and ownership tests" });
    const editor_icons_mod = createModule(ctx, "src/editor/icons.zig", &.{
        import("core", modules.core),
        import("utils", modules.utils),
    }, true);
    const editor_icons_spec_mod = createModule(ctx, "tests/editor/icons/catalog_spec_tests.zig", &.{
        import("core", modules.core),
        import("editor_icons", editor_icons_mod),
    }, true);
    _ = suite.add(editor_icons_spec_mod, .{ .name = "test-icons", .description = "Run focused bundled icon catalog tests" });
}
