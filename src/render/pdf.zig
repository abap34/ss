const std = @import("std");
const core = @import("core");
const dump = @import("../dump.zig");
const utils = @import("utils");

const Allocator = std.mem.Allocator;
const fs_utils = utils.fs;

const embedded_runtime_version = "pdf-runtime-v1";

const EmbeddedResource = struct {
    relative_path: []const u8,
    bytes: []const u8,
};

const embedded_resources = [_]EmbeddedResource{
    .{ .relative_path = "src/render/pdf_backend.py", .bytes = @embedFile("pdf_backend.py") },
    .{ .relative_path = "stdlib/highlighters/python_keywords.py", .bytes = @embedFile("../stdlib/highlighters/python_keywords.py") },
    .{ .relative_path = "third_party/fonts/fetch.py", .bytes = @embedFile("../embedded_fonts/fetch.py") },
    .{ .relative_path = "third_party/fonts/NotoSansJP-Regular.ttf", .bytes = @embedFile("../embedded_fonts/NotoSansJP-Regular.ttf") },
    .{ .relative_path = "third_party/fonts/NotoSansJP-Bold.ttf", .bytes = @embedFile("../embedded_fonts/NotoSansJP-Bold.ttf") },
    .{ .relative_path = "third_party/fonts/NotoSansJP-Black.ttf", .bytes = @embedFile("../embedded_fonts/NotoSansJP-Black.ttf") },
    .{ .relative_path = "third_party/fonts/NotoSansMono-Regular.ttf", .bytes = @embedFile("../embedded_fonts/NotoSansMono-Regular.ttf") },
    .{ .relative_path = "third_party/fonts/NotoSansMono-Bold.ttf", .bytes = @embedFile("../embedded_fonts/NotoSansMono-Bold.ttf") },
    .{ .relative_path = "third_party/fonts/NotoEmoji-Regular.ttf", .bytes = @embedFile("../embedded_fonts/NotoEmoji-Regular.ttf") },
};

pub fn renderDocumentToPdf(allocator: Allocator, io: std.Io, ir: *core.Ir) ![]const u8 {
    const json = try dump.toOwnedString(allocator, ir);
    const cache_dir = ".ss-cache/render";
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);

    const hash = std.hash.Wyhash.hash(0, json);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{x}.json", .{ cache_dir, hash });
    const pdf_path = try std.fmt.allocPrint(allocator, "{s}/{x}.pdf", .{ cache_dir, hash });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = json_path,
        .data = json,
        .flags = .{ .truncate = true },
    });

    const python = try findPythonExecutable(allocator, io);
    const runtime_root = try ensureEmbeddedRuntime(allocator, io);
    defer allocator.free(runtime_root);
    const script_path = try std.fs.path.join(allocator, &.{ runtime_root, "src/render/pdf_backend.py" });
    defer allocator.free(script_path);
    const asset_base_dir = if (ir.asset_base_dir.len == 0) "." else ir.asset_base_dir;

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            python,
            script_path,
            json_path,
            pdf_path,
            asset_base_dir,
        },
    });
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("pdf backend failed\nstdout:\n{s}\nstderr:\n{s}\n", .{ result.stdout, result.stderr });
                return error.PdfBackendFailed;
            }
        },
        else => return error.PdfBackendFailed,
    }

    return std.Io.Dir.cwd().readFileAlloc(io, pdf_path, allocator, .unlimited);
}

fn ensureEmbeddedRuntime(allocator: Allocator, io: std.Io) ![]u8 {
    const root = try std.fmt.allocPrint(allocator, ".ss-cache/runtime/{s}", .{embedded_runtime_version});
    errdefer allocator.free(root);

    try std.Io.Dir.cwd().createDirPath(io, root);
    for (embedded_resources) |resource| {
        const full_path = try std.fs.path.join(allocator, &.{ root, resource.relative_path });
        defer allocator.free(full_path);

        if (fs_utils.fileExists(allocator, full_path)) continue;

        const dir_path = std.fs.path.dirname(full_path) orelse ".";
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = full_path,
            .data = resource.bytes,
            .flags = .{ .truncate = true },
        });
    }
    return root;
}

fn findPythonExecutable(allocator: Allocator, io: std.Io) ![]const u8 {
    const env_candidates = [_][:0]const u8{
        "SS_PYTHON",
        "PYTHON",
        "PYTHON_EXECUTABLE",
    };
    for (env_candidates) |name| {
        if (envOwned(allocator, name)) |exe| {
            if (exe.len == 0) continue;
            if (try isUsablePython(allocator, io, exe)) return exe;
            std.debug.print(
                "{s}={s} is not a usable Python for the PDF backend; it must import fpdf, pypdf, fontTools, and PIL.\n",
                .{ name, exe },
            );
            return error.PythonExecutableUnusable;
        }
    }

    const path_candidates = [_][]const u8{
        "python3",
        "python",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    };
    for (path_candidates) |exe| {
        if (try isUsablePython(allocator, io, exe)) return exe;
    }

    std.debug.print(
        "Could not find a usable Python for the PDF backend. Set SS_PYTHON to a Python executable with fpdf, pypdf, fontTools, and Pillow installed.\n",
        .{},
    );
    return error.PythonExecutableNotFound;
}

fn envOwned(allocator: Allocator, name: [:0]const u8) ?[]u8 {
    const raw = std.c.getenv(name) orelse return null;
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}

fn isUsablePython(allocator: Allocator, io: std.Io, exe: []const u8) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{
            exe,
            "-c",
            "import fpdf, pypdf, fontTools, PIL",
        },
    }) catch return false;

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
