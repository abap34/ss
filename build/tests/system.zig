const std = @import("std");
const project = @import("../modules.zig");
const native_pdf = @import("../native_pdf.zig");
const steps = @import("../steps.zig");
const Suite = @import("support.zig").Suite;
const Step = std.Build.Step;
const createModule = project.createModule;
const import = project.import;
const addFocusedTestStep = steps.focused;

pub fn register(suite: Suite, modules: project.ProjectModules, build_options: *Step.Options, exe: *Step.Compile) void {
    const ctx = suite.ctx;
    const b = ctx.b;
    const test_step = suite.all;
    const fs_spec_mod = createModule(ctx, "tests/utils/fs/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    _ = suite.add(fs_spec_mod, .{ .name = "test-fs", .description = "Run focused filesystem I/O tests" });
    const tree_cache_spec_mod = createModule(ctx, "tests/utils/tree_sitter_cache/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    _ = suite.add(tree_cache_spec_mod, .{ .name = "test-tree-sitter-cache", .description = "Run focused tree-sitter cache lease tests" });
    const tree_cache_worker = b.addExecutable(.{
        .name = "ss-tree-sitter-cache-worker",
        .root_module = createModule(ctx, "tests/build/tree_sitter/cache_worker.zig", &.{import("utils", modules.utils)}, true),
    });
    const tree_build_tests = steps.node(b, &suite.checks.node.step, "tests/build/tree_sitter/spec.mjs", tree_cache_worker.getEmittedBin());
    test_step.dependOn(&tree_build_tests.step);
    addFocusedTestStep(b, "test-tree-sitter-build", "Run isolated and concurrent tree-sitter preparation tests", &tree_build_tests.step);
    suite.addFile("tests/utils/json/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const cache_reference_mod = createModule(ctx, "tests/utils/render_cache/reference_spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const run_cache_reference_tests = suite.add(cache_reference_mod, .{});
    const cache_pruning_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/cache/pruning/spec.mjs", exe.getEmittedBin());
    const cache_test_step = b.step("test-render-cache", "Run focused render cache reference and pruning tests");
    cache_test_step.dependOn(&run_cache_reference_tests.step);
    cache_test_step.dependOn(&cache_pruning_spec.step);
    test_step.dependOn(cache_test_step);
    const editor_resource_mod = createModule(ctx, "src/editor/resource_clients.zig", &.{
        import("utils", modules.utils),
    }, true);
    const editor_resource_spec_mod = createModule(ctx, "tests/editor/resources/spec_tests.zig", &.{
        import("editor_resources", editor_resource_mod),
        import("utils", modules.utils),
    }, true);
    const run_editor_resource_tests = suite.add(editor_resource_spec_mod, .{});
    cache_test_step.dependOn(&run_editor_resource_tests.step);
    const progress_spec_mod = createModule(ctx, "tests/utils/progress/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    const run_progress_spec_tests = suite.add(progress_spec_mod, .{});
    const progress_runtime_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/progress/spec.mjs", exe.getEmittedBin());
    test_step.dependOn(&progress_runtime_spec.step);
    const progress_test_step = b.step("test-progress", "Run focused progress display tests");
    progress_test_step.dependOn(&run_progress_spec_tests.step);
    progress_test_step.dependOn(&progress_runtime_spec.step);
    const project_spec_mod = createModule(ctx, "tests/project/config/spec_tests.zig", &.{
        import("project", modules.project),
        import("utils", modules.utils),
    }, null);
    _ = suite.add(project_spec_mod, .{ .name = "test-project", .description = "Run focused project configuration tests" });
    const project_settings_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/lsp/project_settings/spec.mjs", exe.getEmittedBin());
    test_step.dependOn(&project_settings_spec.step);
    addFocusedTestStep(b, "test-project-settings", "Run normalized project settings protocol tests", &project_settings_spec.step);
    const app_output_app_mod = project.createAppModule(ctx, modules, build_options);
    const app_output_spec_mod = createModule(ctx, "tests/app/output/spec_tests.zig", &.{
        import("app", app_output_app_mod),
        import("utils", modules.utils),
    }, true);
    native_pdf.addHeaders(b, app_output_spec_mod);
    _ = suite.add(app_output_spec_mod, .{ .name = "test-app-output", .description = "Run focused application output safety tests", .link_qpdf = true });
    const watch_mod = project.createWatchModule(ctx, modules);
    const watch_spec_mod = createModule(ctx, "tests/watch/fingerprint/spec_tests.zig", &.{
        import("watch", watch_mod),
        import("utils", modules.utils),
    }, true);
    _ = suite.add(watch_spec_mod, .{ .name = "test-watch", .description = "Run focused watch dependency tests" });
    const watch_inputs_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/watch/inputs/spec.mjs", exe.getEmittedBin());
    test_step.dependOn(&watch_inputs_spec.step);
    addFocusedTestStep(b, "test-watch-inputs", "Run focused observed watch input tests", &watch_inputs_spec.step);
    const watch_latex_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/watch/latex/spec.mjs", exe.getEmittedBin());
    test_step.dependOn(&watch_latex_spec.step);
    addFocusedTestStep(b, "test-watch-latex", "Run focused TeX dependency and watch recovery tests", &watch_latex_spec.step);
    const watch_configuration_spec = steps.node(b, &suite.checks.node.step, "tests/runtime/watch/configuration/spec.mjs", exe.getEmittedBin());
    test_step.dependOn(&watch_configuration_spec.step);
    addFocusedTestStep(b, "test-watch-configuration", "Run focused watch configuration reload tests", &watch_configuration_spec.step);
    const file_inputs_mod = createModule(ctx, "tests/utils/file_inputs/spec_tests.zig", &.{
        import("utils", modules.utils),
    }, true);
    _ = suite.add(file_inputs_mod, .{ .name = "test-file-inputs", .description = "Run focused filesystem input ownership tests" });
}
