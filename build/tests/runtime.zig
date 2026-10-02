const std = @import("std");
const steps = @import("../steps.zig");
const Suite = @import("support.zig").Suite;
const Step = std.Build.Step;
const addFocusedTestStep = steps.focused;

const Spec = struct {
    path: []const u8,
    name: ?[]const u8 = null,
    description: []const u8 = "",
};

pub fn register(suite: Suite, exe: *Step.Compile) void {
    const b = suite.ctx.b;
    const test_step = suite.all;
    const specs = [_]Spec{
        .{ .path = "tests/editor/build-status/spec.mjs" },
        .{ .path = "tests/editor/component-width/spec.mjs" },
        .{ .path = "tests/editor/deletion/spec.mjs" },
        .{ .path = "tests/editor/locks/spec.mjs" },
        .{ .path = "tests/editor/navigation/spec.mjs" },
        .{ .path = "tests/editor/shapes/spec.mjs" },
        .{ .path = "tests/editor/icons/webview_spec.mjs" },
        .{ .path = "tests/editor/edit_queue/spec.mjs" },
        .{ .path = "tests/editor/translation/spec.mjs" },
        .{ .path = "tests/runtime/cli_diagnostics_runtime_spec.mjs" },
        .{ .path = "tests/runtime/completion_runtime_spec.mjs" },
        .{ .path = "tests/runtime/debug_runtime_spec.mjs" },
        .{ .path = "tests/runtime/doctor_runtime_spec.mjs" },
        .{ .path = "tests/runtime/editor/diagnostics/spec.mjs" },
        .{ .path = "tests/runtime/editor/deletion/spec.mjs" },
        .{ .path = "tests/runtime/editor/empty/spec.mjs" },
        .{ .path = "tests/runtime/editor/icons/spec.mjs" },
        .{ .path = "tests/runtime/editor/names/spec.mjs" },
        .{ .path = "tests/runtime/editor/relations/spec.mjs" },
        .{ .path = "tests/runtime/editor/shapes/spec.mjs" },
        .{ .path = "tests/runtime/editor/spec.mjs" },
        .{ .path = "tests/runtime/layout/composition/spec.mjs", .name = "test-layout-composition", .description = "Run focused layout composition semantics tests" },
        .{ .path = "tests/runtime/layout/frame_too_small_spec.mjs" },
        .{ .path = "tests/runtime/layout/measurement_spec.mjs" },
        .{ .path = "tests/runtime/layout/text-wrapping/spec.mjs" },
        .{ .path = "tests/runtime/layout/vflow/policy_spec.mjs" },
        .{ .path = "tests/runtime/layout/hflow/spec.mjs", .name = "test-layout-hflow", .description = "Run horizontal flow policy tests" },
        .{ .path = "tests/runtime/layout/practical/spec.mjs", .name = "test-layout-practical", .description = "Check synthetic practical layouts and editor updates" },
        .{ .path = "tests/runtime/lsp/cancellation/spec.mjs" },
        .{ .path = "tests/runtime/lsp/diagnostics/spec.mjs" },
        .{ .path = "tests/runtime/lsp/diagnostics/layout_spec.mjs" },
        .{ .path = "tests/runtime/lsp/generated_edit/spec.mjs" },
        .{ .path = "tests/runtime/lsp/manual_wysiwyg/spec.mjs" },
        .{ .path = "tests/runtime/lsp/protocol/spec.mjs" },
        .{ .path = "tests/runtime/lsp/render_cancellation/spec.mjs" },
        .{ .path = "tests/runtime/lsp_completion_runtime_spec.mjs" },
        .{ .path = "tests/runtime/lsp_editor_runtime_spec.mjs" },
        .{ .path = "tests/runtime/markdown_table_alignment_runtime_spec.mjs" },
        .{ .path = "tests/runtime/math_pdf_runtime_spec.mjs" },
        .{ .path = "tests/runtime/math_scaling_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render_page_bounds_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render_cache_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render_diagnostics_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render/html/spec.mjs" },
        .{ .path = "tests/runtime/render/markdown_underline/spec.mjs" },
        .{ .path = "tests/runtime/render/vector_shapes/spec.mjs" },
        .{ .path = "tests/runtime/stdlib_wrappers_runtime_spec.mjs" },
        .{ .path = "tests/runtime/syntax/blocks/spec.mjs", .name = "test-block-syntax", .description = "Check block string expressions and CLI/LSP diagnostics" },
        .{ .path = "tests/runtime/syntax/formatting/spec.mjs", .name = "test-syntax-formatting", .description = "Compare generated formatting variants through evaluation and layout" },
        .{ .path = "tests/runtime/theme/spec.mjs" },
    };
    for (specs) |spec| {
        const run = steps.node(b, &suite.checks.node.step, spec.path, exe.getEmittedBin());
        test_step.dependOn(&run.step);
        if (spec.name) |name| steps.focused(b, name, spec.description, &run.step);
    }

    const vscode_tests = b.addSystemCommand(&.{ "npm", "test" });
    vscode_tests.setName("npm test (editor/vscode)");
    vscode_tests.setCwd(b.path("editor/vscode"));
    vscode_tests.stdio = .inherit;
    vscode_tests.step.dependOn(&suite.checks.vscode_packages.step);
    test_step.dependOn(&vscode_tests.step);

    const project_settings_tests = steps.node(b, &suite.checks.node.step, "tests/editor/vscode/project_config/spec.mjs", null);
    project_settings_tests.step.dependOn(&suite.checks.vscode_packages.step);
    addFocusedTestStep(b, "test-editor-project-settings", "Run focused editor project settings cache tests", &project_settings_tests.step);

    const editor_view_tests = steps.node(b, &suite.checks.node.step, "tests/editor/vscode/view/spec.mjs", null);
    editor_view_tests.step.dependOn(&suite.checks.vscode_packages.step);
    addFocusedTestStep(b, "test-editor-view", "Run focused editor view resource tests", &editor_view_tests.step);
    addSmokeChecks(b, test_step, exe);
}

fn addSmokeChecks(b: *std.Build, test_step: *Step, exe: *Step.Compile) void {
    const smoke_check_files = [_][]const u8{
        "stdlib/core/classes.ss",
        "stdlib/core/components.ss",
        "stdlib/core/generated.ss",
        "stdlib/core/layout.ss",
        "stdlib/core/objects.ss",
        "stdlib/core/paths.ss",
        "stdlib/core/fills.ss",
        "stdlib/core/shapes.ss",
        "stdlib/core/connectors.ss",
        "stdlib/core/render.ss",
        "stdlib/core/selectors.ss",
        "stdlib/core/utils.ss",
        "stdlib/themes/academic.ss",
        "stdlib/themes/base.ss",
        "stdlib/themes/default.ss",
        "stdlib/themes/pop.ss",
    };

    for (smoke_check_files) |path| {
        const smoke_check = b.addRunArtifact(exe);
        smoke_check.addArgs(&.{ "check", path });
        test_step.dependOn(&smoke_check.step);
    }
}
