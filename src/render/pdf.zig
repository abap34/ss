const std = @import("std");
const core = @import("core");

const Allocator = std.mem.Allocator;

pub fn renderDocumentToPdf(allocator: Allocator, io: std.Io, engine: *core.Engine) ![]const u8 {
    const json = try engine.dumpJsonToString(allocator);
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
    const script_path = "src/render/pdf_backend.py";
    const asset_base_dir = if (engine.asset_base_dir.len == 0) "." else engine.asset_base_dir;

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
