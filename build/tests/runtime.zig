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

pub fn register(suite: Suite, exe: std.Build.LazyPath) void {
    const b = suite.ctx.b;
    const test_step = suite.all;
    const specs = [_]Spec{
        .{ .path = "tests/runtime/stdlib/spec.mjs", .name = "test-stdlib", .description = "Check public standard-library construction and placement contracts" },
        .{ .path = "tests/runtime/assets/typed_icon_spec.mjs", .name = "test-typed-icon", .description = "Check immutable icon inputs, catalog validation, composition, and rendering" },
        .{ .path = "tests/runtime/assets/typed_pdf_spec.mjs", .name = "test-typed-pdf", .description = "Check typed PDF inputs, page selection, and rendering" },
        .{ .path = "tests/runtime/code/typed_display_spec.mjs", .name = "test-typed-code", .description = "Check immutable code display inputs and syntax highlighting" },
        .{ .path = "tests/runtime/layout/composition/typed_spec.mjs", .name = "test-typed-composition", .description = "Check immutable composition operators, spacing, and equal cells" },
        .{ .path = "tests/runtime/layout/group/spec.mjs", .name = "test-typed-group", .description = "Check typed group ownership, bounds, and rendering" },
        .{ .path = "tests/runtime/math/typed_display_spec.mjs", .name = "test-typed-latex", .description = "Check immutable LaTeX bodies, configuration, and rendering" },
        .{ .path = "tests/runtime/graphics/path/typed_spec.mjs", .name = "test-typed-path", .description = "Check immutable vector paths, dimensions, composition, and rendering" },
        .{ .path = "tests/runtime/math/formula/spec.mjs", .name = "test-typed-math", .description = "Check typed formula construction, composition, and rendering" },
        .{ .path = "tests/runtime/document/typed_page_numbers_spec.mjs", .name = "test-typed-document", .description = "Check typed page numbers, contents, and references in a multi-page document" },
        .{ .path = "tests/runtime/data/csv/spec.mjs", .name = "test-csv", .description = "Check CSV parsing, table rendering, and editor inputs" },
        .{ .path = "tests/editor/build-status/spec.mjs" },
        .{ .path = "tests/editor/component-width/spec.mjs" },
        .{ .path = "tests/editor/deletion/spec.mjs" },
        .{ .path = "tests/editor/locks/spec.mjs" },
        .{ .path = "tests/editor/navigation/spec.mjs" },
        .{ .path = "tests/editor/shapes/spec.mjs" },
        .{ .path = "tests/editor/snapping/spec.mjs", .name = "test-editor-snapping", .description = "Check object alignment snapping and hysteresis" },
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
        .{ .path = "tests/runtime/lsp/analysis/sharing_spec.mjs", .name = "test-lsp-analysis-sharing", .description = "Check semantic query sharing and deferred layout" },
        .{ .path = "tests/runtime/lsp/cancellation/spec.mjs" },
        .{ .path = "tests/runtime/lsp/diagnostics/spec.mjs" },
        .{ .path = "tests/runtime/lsp/diagnostics/multiple_spec.mjs", .name = "test-lsp-multiple-documents", .description = "Check diagnostics across independent entries and shared imports" },
        .{ .path = "tests/runtime/lsp/diagnostics/layout_spec.mjs" },
        .{ .path = "tests/runtime/lsp/generated_edit/spec.mjs" },
        .{ .path = "tests/runtime/lsp/generated_edit/reuse_spec.mjs" },
        .{ .path = "tests/runtime/lsp/manual_wysiwyg/spec.mjs" },
        .{ .path = "tests/runtime/lsp/protocol/spec.mjs" },
        .{ .path = "tests/runtime/lsp/render_cancellation/spec.mjs" },
        .{ .path = "tests/runtime/lsp_completion_runtime_spec.mjs" },
        .{ .path = "tests/runtime/lsp_editor_runtime_spec.mjs" },
        .{ .path = "tests/runtime/markdown_table_alignment_runtime_spec.mjs" },
        .{ .path = "tests/runtime/math_pdf_runtime_spec.mjs" },
        .{ .path = "tests/runtime/math_scaling_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render/math/spec.mjs", .name = "test-math-sizing", .description = "Check inherited math sizing and explicit width fitting" },
        .{ .path = "tests/runtime/render_page_bounds_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render_cache_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render_diagnostics_runtime_spec.mjs" },
        .{ .path = "tests/runtime/render/html/spec.mjs" },
        .{ .path = "tests/runtime/render/semantics/spec.mjs", .name = "test-semantic-html", .description = "Check declared semantics in HTML output" },
        .{ .path = "tests/runtime/render/markdown_underline/spec.mjs" },
        .{ .path = "tests/runtime/render/vector_shapes/spec.mjs" },
        .{ .path = "tests/runtime/stdlib_wrappers_runtime_spec.mjs" },
        .{ .path = "tests/runtime/syntax/blocks/spec.mjs", .name = "test-block-syntax", .description = "Check block string expressions and CLI/LSP diagnostics" },
        .{ .path = "tests/runtime/syntax/formatting/spec.mjs", .name = "test-syntax-formatting", .description = "Compare generated formatting variants through evaluation and layout" },
        .{ .path = "tests/runtime/theme/spec.mjs" },
    };
    for (specs) |spec| {
        const run = steps.node(b, &suite.checks.node.step, spec.path, exe);
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
    addStdlibChecks(b, test_step, exe);
}

fn addStdlibChecks(b: *std.Build, test_step: *Step, exe: std.Build.LazyPath) void {
    const stdlib_step = b.step("test-stdlib-modules", "Check every embedded standard-library module");
    for (@import("../../stdlib/embed.zig").modules) |module| {
        const check = steps.runExecutable(b, exe);
        check.addArgs(&.{ "check", "--quiet", module.path });
        stdlib_step.dependOn(&check.step);
    }
    test_step.dependOn(stdlib_step);
}
