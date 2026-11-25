const std = @import("std");
const packages = @import("project").packages;
const utils = @import("utils");
const terminal = @import("terminal.zig");

const Style = struct {
    heading: []const u8 = "",
    name: []const u8 = "",
    success: []const u8 = "",
    warning: []const u8 = "",
    secondary: []const u8 = "",
    reset: []const u8 = "",

    fn stdout() Style {
        if (!terminal.useColor(.stdout)) return .{};
        return .{
            .heading = "\x1b[1m",
            .name = "\x1b[36m",
            .success = "\x1b[32m",
            .warning = "\x1b[33m",
            .secondary = "\x1b[2m",
            .reset = "\x1b[0m",
        };
    }
};

// Inspection shares the importer's lock validation and fetched-source check.
// It does not acquire the fetch lock, create cache directories, or invoke Git.
pub fn run(a: std.mem.Allocator, io: std.Io, root: []const u8, config_path: []const u8) !void {
    const text = try utils.fs.readFileAlloc(io, a, config_path);
    defer a.free(text);
    var manifest = try packages.manifest.Manifest.parse(a, text);
    defer manifest.deinit();
    var locked = packages.lock.read(a, io, root) catch |err| switch (err) {
        error.MissingPackageLock => null,
        else => return err,
    };
    defer if (locked) |*file| file.deinit();

    var output = std.Io.Writer.Allocating.init(a);
    defer output.deinit();
    const writer = &output.writer;
    const s = Style.stdout();
    const dependencies = manifest.data.dependencies;
    if (dependencies.len == 0) {
        try writer.writeAll("No dependencies declared.\n");
    } else {
        try writer.print("{s}Dependencies in ss.toml:{s}\n", .{ s.heading, s.reset });
        for (dependencies) |dependency| {
            try writer.print("  {s}{s}{s} {s}({s}){s}", .{ s.name, dependency.name, s.reset, s.secondary, dependency.source.git, s.reset });
            inline for (.{ "tag", "branch", "rev" }) |field| {
                if (@field(dependency.source, field)) |value| try writer.print(" {s}={s}", .{ field, value });
            }
            try writer.writeByte('\n');
        }
    }
    if (locked) |file| {
        const data = file.value;
        const current = packages.lock.matches(data.dependencies, dependencies);
        try writer.print("{s}ss.lock:{s} {s}{s}{s}\n", .{ s.heading, s.reset, if (current) s.success else s.warning, if (current) "up to date" else "out of date; run 'ss fetch'", s.reset });
        if (data.packages.len > 0) try writer.print("{s}Packages in ss.lock:{s}\n", .{ s.heading, s.reset });
        var missing: usize = 0;
        for (data.packages) |package| {
            const directory = try packages.lock.sourcePath(a, root, package.id);
            defer a.free(directory);
            const fetched = try packages.git.ready(a, io, directory, package.commit, null);
            if (!fetched) missing += 1;
            const direct = for (data.dependencies) |edge| {
                if (std.mem.eql(u8, edge.package, package.id)) break true;
            } else false;
            try writer.print("  {s}{s}{s}", .{ s.name, package.name, s.reset });
            try writer.print("{s}@{s}{s}  {s}  ", .{ s.secondary, package.commit[0..12], s.reset, if (direct) "direct" else "transitive" });
            try writer.print("{s}{s}{s}\n", .{ if (fetched) s.success else s.warning, if (fetched) "fetched" else "not fetched", s.reset });
            try writer.print("    {s}{s}{s}\n", .{ s.secondary, package.git, s.reset });
        }
        if (missing > 0 and current) try writer.writeAll("Run 'ss fetch --locked' to restore missing packages.\n");
    } else {
        try writer.print("{s}ss.lock:{s} {s}{s}{s}\n", .{ s.heading, s.reset, if (dependencies.len == 0) s.secondary else s.warning, if (dependencies.len == 0) "not needed" else "missing; run 'ss fetch'", s.reset });
    }
    try utils.io.writeStdoutAll(output.written());
}
