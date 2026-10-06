const std = @import("std");
const project = @import("../modules.zig");
const native_pdf = @import("../native_pdf.zig");
const steps = @import("../steps.zig");
const Step = std.Build.Step;
const createModule = project.createModule;
const import = project.import;
const addFocusedTestStep = steps.focused;

const dependencies = @import("../dependencies.zig");
const qpdf = @import("../qpdf.zig");

pub fn register(ctx: project.Context, modules: project.ProjectModules, build_options: *Step.Options, exe: std.Build.LazyPath, checks: dependencies.Checks, bridge: qpdf.Bridge) void {
    const b = ctx.b;
    const app_mod = project.createAppModule(ctx, modules, build_options);
    const driver_mod = createModule(ctx, "tests/visual/render/driver.zig", &.{
        import("app", app_mod),
        import("utils", modules.utils),
    }, true);
    native_pdf.addHeaders(b, driver_mod);
    qpdf.link(bridge, b, driver_mod, ctx.target, .installed);
    const driver = b.addExecutable(.{ .name = "ss-render-parity-driver", .root_module = driver_mod });
    const driver_file = qpdf.runnable(b, bridge, driver);

    const parity = steps.node(b, &checks.node.step, "tests/visual/render/spec.mjs", driver_file);
    parity.step.dependOn(&checks.visual_test_packages.step);
    const parity_step = b.step("test-render-parity", "Compare PDF and HTML pixels locally");
    parity_step.dependOn(&parity.step);

    const practical = steps.node(b, &checks.node.step, "tests/visual/render/spec.mjs", null);
    practical.addArg("--practical");
    practical.addFileArg(driver_file);
    practical.step.dependOn(&checks.visual_test_packages.step);
    addFocusedTestStep(b, "test-layout-practical-visual", "Compare PDF and HTML for synthetic practical layouts", &practical.step);

    const navigation = steps.node(b, &checks.node.step, "tests/visual/render/navigation/spec.mjs", driver_file);
    navigation.step.dependOn(&checks.visual_test_packages.step);
    const navigation_step = b.step("test-render-html-navigation", "Inspect standalone HTML page navigation locally");
    navigation_step.dependOn(&navigation.step);

    const pdf_runtime = steps.node(b, &checks.node.step, "tests/visual/render/pdf/runtime_spec.mjs", null);
    pdf_runtime.step.dependOn(&checks.visual_test_packages.step);
    const pdf_runtime_step = b.step("test-render-pdf-runtime", "Inspect PDF image loading and cancellation locally");
    pdf_runtime_step.dependOn(&pdf_runtime.step);

    const full = steps.node(b, &checks.node.step, "tests/visual/render/spec.mjs", null);
    full.addArg("--full");
    full.addFileArg(driver_file);
    full.step.dependOn(&checks.visual_test_packages.step);
    const full_step = b.step("test-render-parity-full", "Compare the extended PDF and HTML fixture set locally");
    full_step.dependOn(&full.step);

    const behavior = steps.node(b, &checks.node.step, "tests/visual/render/behavior/spec.mjs", exe);
    behavior.step.dependOn(&checks.visual_test_packages.step);
    const behavior_step = b.step("test-render-behavior", "Inspect rendered PDF behavior locally with Chromium");
    behavior_step.dependOn(&behavior.step);

    const presentation_build = steps.node(b, &checks.node.step, "editor/vscode/scripts/build.js", null);
    presentation_build.step.dependOn(&checks.vscode_packages.step);
    const presentation = steps.node(b, &checks.node.step, "tests/visual/presentation/spec.mjs", exe);
    presentation.step.dependOn(&presentation_build.step);
    presentation.step.dependOn(&checks.visual_test_packages.step);
    addFocusedTestStep(b, "test-presentation", "Exercise the CLI and shared presentation controls", &presentation.step);

    const editor_ui = steps.node(b, &checks.node.step, "tests/visual/editor/spec.mjs", null);
    editor_ui.step.dependOn(&checks.visual_test_packages.step);
    editor_ui.step.dependOn(&checks.vscode_packages.step);
    const editor_ui_step = b.step("test-editor-ui", "Exercise VS Code editor webview interactions locally with Chromium");
    editor_ui_step.dependOn(&editor_ui.step);
}
