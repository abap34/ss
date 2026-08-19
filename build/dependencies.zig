const std = @import("std");

const Step = std.Build.Step;

pub const Checks = struct {
    executable: *Step.Compile,
    native_pdf: *Step.Run,
    node: *Step.Run,
    qpdf_cli: *Step.Run,
    vscode_packages: *Step.Run,
    visual_test_packages: *Step.Run,
};

pub const Options = struct {
    pkg_config: []const u8,
    cpp: []const u8,
    minimum_qpdf_version: []const u8,
};

pub fn create(b: *std.Build, options: Options) Checks {
    const module = b.createModule(.{
        .root_source_file = b.path("build/dependency_check.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const executable = b.addExecutable(.{
        .name = "ss-build-dependency-check",
        .root_module = module,
    });

    const native_pdf = b.addRunArtifact(executable);
    native_pdf.setName("check native PDF build dependencies");
    native_pdf.addArgs(&.{ "native-pdf", options.pkg_config, options.cpp, options.minimum_qpdf_version });

    const node = b.addRunArtifact(executable);
    node.setName("check Node.js test dependency");
    node.addArg("node");

    const qpdf_cli = b.addRunArtifact(executable);
    qpdf_cli.setName("check qpdf test dependency");
    qpdf_cli.addArg("qpdf-cli");

    const vscode_packages = b.addRunArtifact(executable);
    vscode_packages.setName("check VS Code extension packages");
    vscode_packages.addArgs(&.{
        "node-modules",
        "editor/vscode",
        "esbuild/package.json",
        "typescript/package.json",
        "@types/node/package.json",
        "@types/vscode/package.json",
        "vscode-languageclient/package.json",
    });
    vscode_packages.setCwd(b.path("."));
    vscode_packages.step.dependOn(&node.step);

    const visual_test_packages = b.addRunArtifact(executable);
    visual_test_packages.setName("check visual test packages");
    visual_test_packages.addArgs(&.{ "node-modules", "tests/visual", "playwright/package.json", "pngjs/package.json" });
    visual_test_packages.setCwd(b.path("."));
    visual_test_packages.step.dependOn(&node.step);

    return .{
        .executable = executable,
        .native_pdf = native_pdf,
        .node = node,
        .qpdf_cli = qpdf_cli,
        .vscode_packages = vscode_packages,
        .visual_test_packages = visual_test_packages,
    };
}
