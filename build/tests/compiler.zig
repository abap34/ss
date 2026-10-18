const std = @import("std");
const project = @import("../modules.zig");
const Suite = @import("support.zig").Suite;
const Module = std.Build.Module;
const createModule = project.createModule;
const import = project.import;

pub fn register(suite: Suite, modules: project.ProjectModules, compiler_mod: *Module) void {
    const ctx = suite.ctx;
    const value_contracts_spec_mod = createModule(ctx, "tests/eval/contracts/spec_tests.zig", &.{
        import("core", modules.core),
        import("ast", modules.ast),
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(value_contracts_spec_mod, .{ .name = "test-value-contracts", .description = "Check runtime value type contracts" });
    const display_spec_mod = createModule(ctx, "tests/eval/display/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(display_spec_mod, .{ .name = "test-display", .description = "Check typed display instantiation and evaluation" });

    const dump_spec_mod = createModule(ctx, "tests/compiler/dump/spec_tests.zig", &.{
        import("compiler", compiler_mod),
        import("utils", modules.utils),
    }, true);
    _ = suite.add(dump_spec_mod, .{ .name = "test-dump", .description = "Check typed placement inputs and display metadata in dumps" });

    const typed_query_spec_mod = createModule(ctx, "tests/eval/query/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(typed_query_spec_mod, .{ .name = "test-typed-query", .description = "Check typed placement queries and execution dependencies" });
    const execution_spec_mod = createModule(ctx, "tests/analysis/execution/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(execution_spec_mod, .{ .name = "test-execution-graph", .description = "Check execution graph state effects and diagnostics" });
    const eval_cancellation_spec_mod = createModule(ctx, "tests/eval/cancellation/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(eval_cancellation_spec_mod, .{ .name = "test-eval-cancellation", .description = "Run focused document evaluation cancellation tests" });
    const stdlib_cache_spec_mod = createModule(ctx, "tests/modules/stdlib_cache/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(stdlib_cache_spec_mod, .{ .name = "test-stdlib-cache", .description = "Run focused standard-library cache tests" });
    const module_exports_spec_mod = createModule(ctx, "tests/modules/exports/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(module_exports_spec_mod, .{ .name = "test-module-exports", .description = "Run focused selected import and re-export tests" });
    const module_loader_spec_mod = createModule(ctx, "tests/modules/loader/spec_tests.zig", &.{
        import("compiler", compiler_mod),
        import("utils", modules.utils),
    }, true);
    _ = suite.add(module_loader_spec_mod, .{ .name = "test-module-loader", .description = "Run focused module loader tests" });
    const declaration_spec_mod = createModule(ctx, "tests/compiler/declarations/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(declaration_spec_mod, .{ .name = "test-declarations", .description = "Run focused shared declaration index tests" });

    const nominal_spec_mod = createModule(ctx, "tests/compiler/nominal/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(nominal_spec_mod, .{ .name = "test-nominal-types", .description = "Run focused nominal type identity tests" });

    const inheritance_spec_mod = createModule(ctx, "tests/compiler/inheritance/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(inheritance_spec_mod, .{ .name = "test-inheritance", .description = "Run focused object inheritance tests" });
    const return_facts_mod = createModule(ctx, "tests/analysis/return_facts/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(return_facts_mod, .{ .name = "test-return-facts", .description = "Run focused argument-sensitive return inference tests" });
    const ownership_spec_mod = createModule(ctx, "tests/analysis/ownership/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(ownership_spec_mod, .{ .name = "test-analysis-ownership", .description = "Check analysis ownership under allocation failure" });
    const captures_spec_mod = createModule(ctx, "tests/analysis/captures/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(captures_spec_mod, .{ .name = "test-captures", .description = "Run focused lambda capture analysis tests" });
    const frames_spec_mod = createModule(ctx, "tests/eval/frames/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(frames_spec_mod, .{ .name = "test-eval-frames", .description = "Check evaluation call frame ownership and resource limits" });
    const environment_spec_mod = createModule(ctx, "tests/eval/environment/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(environment_spec_mod, .{ .name = "test-eval-environment", .description = "Run focused evaluation environment tests" });
    const resources_spec_mod = createModule(ctx, "tests/analysis/resources/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(resources_spec_mod, .{ .name = "test-resource-index", .description = "Run focused dependency resource index tests" });
    const binding_types_mod = createModule(ctx, "tests/compiler/bindings/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(binding_types_mod, .{ .name = "test-binding-types", .description = "Run focused checked binding type tests" });

    const constraints_spec_mod = createModule(ctx, "tests/compiler/constraints/spec_tests.zig", &.{
        import("compiler", compiler_mod),
    }, true);
    _ = suite.add(constraints_spec_mod, .{ .name = "test-constraint-registration", .description = "Check explicit constraint values and registration" });

    const compiler_semantics_support_mod = createModule(ctx, "tests/compiler/semantics/support.zig", &.{
        import("utils", modules.utils),
        import("compiler", compiler_mod),
    }, true);
    const compiler_semantics_mod = createModule(ctx, "tests/compiler/semantics/spec_tests.zig", &.{
        import("compiler_semantics", compiler_semantics_support_mod),
    }, true);
    _ = suite.add(compiler_semantics_mod, .{ .name = "test-compiler-semantics", .description = "Run focused compiler semantic tests" });
}
