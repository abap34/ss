const std = @import("std");
const utils = @import("utils");
const manifest = @import("manifest.zig");
const lock = @import("lock.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    environment: *const std.process.Environ.Map,

    pub fn acquire(self: Client) !std.Io.File {
        const path = try std.fs.path.join(self.allocator, &.{ self.root, ".ss-cache", "packages.lock" });
        defer self.allocator.free(path);
        try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
        return std.Io.Dir.cwd().createFile(self.io, path, .{ .read = true, .truncate = false, .lock = .exclusive });
    }

    pub fn resolve(self: Client, source: manifest.Source) ![]const u8 {
        try manifest.validateSource(source);
        const repository = try self.repositoryPath(source.git);
        defer self.allocator.free(repository);
        try self.initialize(repository);
        const selector = if (source.tag) |tag|
            try std.fmt.allocPrint(self.allocator, "refs/tags/{s}", .{tag})
        else if (source.branch) |branch|
            try std.fmt.allocPrint(self.allocator, "refs/heads/{s}", .{branch})
        else
            try self.allocator.dupe(u8, source.rev orelse "HEAD");
        defer self.allocator.free(selector);
        try self.command(&.{ "--git-dir", repository, "fetch", "--no-tags", "--", source.git, selector });
        const bytes = try self.output(&.{ "--git-dir", repository, "rev-parse", "--verify", "FETCH_HEAD^{commit}" });
        defer self.allocator.free(bytes);
        const commit = std.mem.trim(u8, bytes, "\r\n ");
        try self.retain(repository, commit);
        return self.allocator.dupe(u8, commit);
    }

    pub fn ensure(self: Client, url: []const u8, commit: []const u8) ![]u8 {
        var buffer: [64]u8 = undefined;
        const destination = try lock.sourcePath(self.allocator, self.root, lock.identity(url, commit, &buffer));
        errdefer self.allocator.free(destination);
        if (try ready(self.allocator, self.io, destination, commit, null)) return destination;
        const repository = try self.repositoryPath(url);
        defer self.allocator.free(repository);
        try self.initialize(repository);
        const commit_spec = try std.fmt.allocPrint(self.allocator, "{s}^{{commit}}", .{commit});
        defer self.allocator.free(commit_spec);
        // Fetch only when this exact locked object is absent locally.
        const existing = self.output(&.{ "--git-dir", repository, "rev-parse", "--verify", "--quiet", commit_spec }) catch |err| switch (err) {
            error.GitCommandFailed => null,
            else => return err,
        };
        if (existing) |bytes| self.allocator.free(bytes) else {
            try self.command(&.{ "--git-dir", repository, "fetch", "--no-tags", "--", url, commit });
        }
        try self.retain(repository, commit);
        var random: [8]u8 = undefined;
        std.Io.random(self.io, &random);
        const suffix = std.fmt.bytesToHex(random, .lower);
        const staging = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{s}", .{ destination, suffix });
        defer self.allocator.free(staging);
        defer std.Io.Dir.cwd().deleteTree(self.io, staging) catch {};
        try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(destination).?);
        try self.command(&.{ "clone", "--no-checkout", "--shared", "--", repository, staging });
        try self.command(&.{ "-C", staging, "checkout", "--detach", "--force", commit });
        const submodules = try std.fs.path.join(self.allocator, &.{ staging, ".gitmodules" });
        defer self.allocator.free(submodules);
        if (try utils.fs.fileExists(self.allocator, submodules)) return error.PackageSubmodulesUnsupported;
        const marker = try std.fs.path.join(self.allocator, &.{ staging, ".git", "ss-commit" });
        defer self.allocator.free(marker);
        try utils.fs.writeFile(self.io, marker, commit);
        // Incomplete snapshots are never published to readers.
        try std.Io.Dir.cwd().deleteTree(self.io, destination);
        try std.Io.Dir.cwd().rename(staging, std.Io.Dir.cwd(), destination, self.io);
        return destination;
    }

    fn retain(self: Client, repository: []const u8, commit: []const u8) !void {
        const reference = try std.fmt.allocPrint(self.allocator, "refs/ss/commits/{s}", .{commit});
        defer self.allocator.free(reference);
        try self.command(&.{ "--git-dir", repository, "update-ref", reference, commit });
    }

    fn initialize(self: Client, repository: []const u8) !void {
        const head = try std.fs.path.join(self.allocator, &.{ repository, "HEAD" });
        defer self.allocator.free(head);
        if (try utils.fs.fileExists(self.allocator, head)) return;
        try std.Io.Dir.cwd().createDirPath(self.io, repository);
        try self.command(&.{ "init", "--bare", repository });
    }

    fn repositoryPath(self: Client, url: []const u8) ![]u8 {
        var buffer: [64]u8 = undefined;
        return std.fs.path.join(self.allocator, &.{ self.root, ".ss-cache", "packages", "repos", lock.identity(url, "", &buffer) });
    }

    fn command(self: Client, args: []const []const u8) !void {
        self.allocator.free(try self.output(args));
    }

    fn output(self: Client, args: []const []const u8) ![]u8 {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{ "git", "-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never", "-c", "credential.interactive=false" });
        try argv.appendSlice(self.allocator, &.{ "-c", "protocol.allow=never" });
        inline for (.{ "http", "https", "ssh", "git", "file" }) |protocol| {
            try argv.appendSlice(self.allocator, &.{ "-c", "protocol." ++ protocol ++ ".allow=always" });
        }
        try argv.appendSlice(self.allocator, args);
        const result = utils.process.runWithEnvironment(self.allocator, self.io, argv.items, .{ .path = self.root }, self.environment) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };
        defer self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        self.allocator.free(result.stdout);
        if (result.stderr.len != 0) std.debug.print("git: {s}\n", .{result.stderr});
        return error.GitCommandFailed;
    }
};

pub fn ready(a: std.mem.Allocator, io: std.Io, directory: []const u8, commit: []const u8, inputs: ?*utils.FileInputs) !bool {
    const marker = try std.fs.path.join(a, &.{ directory, ".git", "ss-commit" });
    defer a.free(marker);
    if (inputs) |observed| try observed.record(".", marker, .file);
    const bytes = utils.fs.readFileAllocLimited(io, a, marker, .limited(65)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer a.free(bytes);
    if (inputs) |observed| try observed.recordContents(marker, bytes);
    return std.mem.eql(u8, bytes, commit);
}
