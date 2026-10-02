const std = @import("std");
const project = @import("../modules.zig");
const native_pdf = @import("../native_pdf.zig");
const Suite = @import("support.zig").Suite;
const Step = std.Build.Step;
const createModule = project.createModule;
const import = project.import;

pub fn register(suite: Suite, modules: project.ProjectModules, build_options: *Step.Options) void {
    const ctx = suite.ctx;
    const b = ctx.b;
    const highlight_spans_mod = createModule(ctx, "src/render/compile/highlight_spans.zig", &.{
        import("utils", modules.utils),
    }, null);
    const highlight_spans_spec_mod = createModule(ctx, "tests/render/highlight/spans/spec_tests.zig", &.{
        import("highlight_spans", highlight_spans_mod),
        import("utils", modules.utils),
    }, null);
    _ = suite.add(highlight_spans_spec_mod, .{ .name = "test-highlight-spans", .description = "Run focused highlight boundary traversal tests" });
    const render_latex_mod = createModule(ctx, "src/render/compile/latex.zig", &.{}, null);
    const render_latex_spec_mod = createModule(ctx, "tests/render/latex/spec_tests.zig", &.{
        import("render_latex", render_latex_mod),
    }, null);
    _ = suite.add(render_latex_spec_mod, .{ .name = "test-render-latex", .description = "Run focused LaTeX document tests" });
    const latex_inputs_mod = createModule(ctx, "src/render/compile/latex_inputs.zig", &.{
        import("utils", modules.utils),
        import("render_resources", modules.render_resources),
    }, null);
    const latex_inputs_spec_mod = createModule(ctx, "tests/render/latex/inputs/spec_tests.zig", &.{
        import("latex_inputs", latex_inputs_mod),
        import("utils", modules.utils),
        import("render_resources", modules.render_resources),
    }, null);
    _ = suite.add(latex_inputs_spec_mod, .{ .name = "test-latex-inputs", .description = "Run focused TeX recorder and dependency manifest tests" });
    const render_pdf_document_mod = createModule(ctx, "src/render/pdf.zig", &.{
        import("pdf_backend", modules.pdf_backend),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("utils", modules.utils),
    }, true);
    const render_test_support_mod = createModule(ctx, "tests/render/support.zig", &.{
        import("core", modules.core),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_text", modules.render_text),
    }, true);
    const render_pdf_spec_mod = createModule(ctx, "tests/render/pdf/spec_tests.zig", &.{
        import("pdf_backend", modules.pdf_backend),
        import("pdf_document", render_pdf_document_mod),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, true);
    native_pdf.addHeaders(b, render_pdf_spec_mod);
    const run_render_pdf_spec_tests = suite.add(render_pdf_spec_mod, .{ .name = "test-render-pdf", .description = "Run focused native PDF renderer tests", .link_qpdf = true });
    run_render_pdf_spec_tests.step.dependOn(&suite.checks.qpdf_cli.step);
    const render_spec_mod = createModule(ctx, "tests/render/ir/spec_tests.zig", &.{
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, null);
    _ = suite.add(render_spec_mod, .{ .name = "test-render-ir", .description = "Run focused render IR tests", .link_qpdf = true });
    const render_html_mod = createModule(ctx, "src/render/html.zig", &.{
        import("core", modules.core),
        import("html_embeds", modules.html_embeds),
        import("render", modules.render),
        import("pdfjs_assets", modules.pdfjs_assets),
        import("utils", modules.utils),
    }, null);
    const render_html_spec_mod = createModule(ctx, "tests/render/html/spec_tests.zig", &.{
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_html", render_html_mod),
        import("render_resources", modules.render_resources),
        import("render_test_support", render_test_support_mod),
    }, null);
    _ = suite.add(render_html_spec_mod, .{ .name = "test-render-html", .description = "Run focused HTML renderer tests", .link_qpdf = true });
    const render_html_font_mod = createModule(ctx, "src/render/html/font.zig", &.{}, null);
    const render_html_font_spec_mod = createModule(ctx, "tests/render/html/font_spec_tests.zig", &.{
        import("render_html_font", render_html_font_mod),
    }, null);
    _ = suite.add(render_html_font_spec_mod, .{ .name = "test-render-html-font", .description = "Run focused HTML font extraction tests" });
    const render_compile_mod = createModule(ctx, "src/render/compile.zig", &.{
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_emitter", modules.render_emitter),
        import("render_resources", modules.render_resources),
        import("render_measurements", modules.render_measurements),
        import("render_text", modules.render_text),
        import("utils", modules.utils),
    }, null);
    render_compile_mod.addOptions("build_options", build_options);
    const render_compile_spec_mod = createModule(ctx, "tests/render/compile/spec_tests.zig", &.{
        import("ast", modules.ast),
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_compile", render_compile_mod),
        import("render_emitter", modules.render_emitter),
        import("render_resources", modules.render_resources),
        import("render_text", modules.render_text),
    }, null);
    _ = suite.add(render_compile_spec_mod, .{ .name = "test-render-compile", .description = "Run focused render compiler tests", .link_qpdf = true });
    const artifacts_mod = createModule(ctx, "src/render/compile/artifacts.zig", &.{
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("utils", modules.utils),
    }, null);
    artifacts_mod.addOptions("build_options", build_options);
    const artifacts_spec_mod = createModule(ctx, "tests/render/artifacts/spec_tests.zig", &.{
        import("artifacts", artifacts_mod),
        import("render_resources", modules.render_resources),
    }, null);
    _ = suite.add(artifacts_spec_mod, .{ .name = "test-render-artifacts", .description = "Run focused artifact production tests", .link_qpdf = true });
    const table_mod = createModule(ctx, "src/render/compile/table.zig", &.{
        import("core", modules.core),
        import("pdf_ffi", modules.pdf_ffi),
        import("render", modules.render),
        import("render_resources", modules.render_resources),
        import("render_text", modules.render_text),
        import("render_emitter", modules.render_emitter),
        import("utils", modules.utils),
    }, null);
    table_mod.addOptions("build_options", build_options);
    const table_spec_mod = createModule(ctx, "tests/render/table/spec_tests.zig", &.{
        import("table_layout", table_mod),
        import("core", modules.core),
        import("render_text", modules.render_text),
    }, null);
    _ = suite.add(table_spec_mod, .{ .name = "test-render-table", .description = "Run focused retained table layout tests", .link_qpdf = true });
    const paragraph_spec_mod = createModule(ctx, "tests/render/paragraph/spec_tests.zig", &.{
        import("pdf_ffi", modules.pdf_ffi),
        import("render_text", modules.render_text),
    }, true);
    _ = suite.add(paragraph_spec_mod, .{ .name = "test-render-paragraph", .description = "Run focused attributed paragraph layout tests" });
    const measurement_store_spec_mod = createModule(ctx, "tests/render/measurement_store/spec_tests.zig", &.{
        import("core", modules.core),
        import("render_measurements", modules.render_measurements),
    }, null);
    _ = suite.add(measurement_store_spec_mod, .{ .name = "test-render-measurements", .description = "Run focused measurement storage tests" });
    const font_environment_spec_mod = createModule(ctx, "tests/render/font_environment/spec_tests.zig", &.{
        import("pdf_ffi", modules.pdf_ffi),
        import("render_text", modules.render_text),
    }, true);
    native_pdf.addHeaders(b, font_environment_spec_mod);
    _ = suite.add(font_environment_spec_mod, .{ .name = "test-font-environment", .description = "Run isolated font environment invalidation tests" });
    const highlight_cache_spec_mod = createModule(ctx, "tests/render/highlight/cache/spec_tests.zig", &.{
        import("render_compile", render_compile_mod),
        import("utils", modules.utils),
    }, null);
    _ = suite.add(highlight_cache_spec_mod, .{ .name = "test-highlight-cache", .description = "Run focused highlight query and content cache tests" });
}
