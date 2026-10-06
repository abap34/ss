const std = @import("std");
const compat = @import("compat.zig");

pub const installed_stdlib_subdir = "share/ss/stdlib";

pub fn create(b: *std.Build) *std.Build.Step.Options {
    compat.externalConfigureInput(b);
    const release_version = readReleaseVersion(b) catch @panic("release/VERSION must contain the release version.");
    const default_version = b.fmt("{s}-dev", .{release_version});
    const version = b.option([]const u8, "version", "Version string reported by `ss --version`") orelse default_version;
    const commit = b.option([]const u8, "commit", "Source commit reported by `ss --version`") orelse detectGitCommit(b) orelse "unknown";
    const uncommitted_changes = detectUncommittedChanges(b);
    const source_stdlib_dir = compat.pathFromRoot(b, "stdlib");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption([]const u8, "commit", commit);
    build_options.addOption([]const u8, "uncommitted_changes", uncommitted_changes);
    build_options.addOption([]const u8, "source_stdlib_dir", source_stdlib_dir);
    build_options.addOption([]const u8, "installed_stdlib_subdir", installed_stdlib_subdir);
    return build_options;
}

fn detectGitCommit(b: *std.Build) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "rev-parse", "--short", "HEAD" },
        .cwd = .{ .path = compat.pathFromRoot(b, ".") },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return b.allocator.dupe(u8, trimmed) catch null;
}

fn detectUncommittedChanges(b: *std.Build) []const u8 {
    const has_changes = detectGitUncommittedChanges(b) orelse return "unknown";
    return if (has_changes) "yes" else "no";
}

fn detectGitUncommittedChanges(b: *std.Build) ?bool {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = .{ .path = compat.pathFromRoot(b, ".") },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(1024),
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn readReleaseVersion(b: *std.Build) ![]const u8 {
    const raw = try compat.readFile(b, "release/VERSION", .limited(64));
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyVersion;
    return trimmed;
}
