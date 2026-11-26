const std = @import("std");
const utils = @import("utils");
const input = @import("input.zig");

pub const Options = struct {
    user: ?[]const u8 = null,
    host: ?[]const u8 = null,
    disabled: bool = false,
};

pub const Setup = struct {
    url: []const u8,
    existing_repository: bool,
    add_origin: bool,
};

pub const Git = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: *const std.process.Environ.Map,

    pub fn prepare(self: Git, directory: []const u8, name: []const u8, options: Options) !?Setup {
        if (options.disabled) return null;
        const host = options.host orelse "github.com";
        try validateHost(host);
        if (options.user) |user| try validateUser(user);
        const dot_git = try std.fs.path.join(self.allocator, &.{ directory, ".git" });
        const existing = try utils.fs.fileExists(self.allocator, dot_git);
        const origin = if (existing) try self.config(&.{ "-C", directory, "config", "--local", "--get-all", "remote.origin.url" }) else null;
        // Explicit options request a particular URL; inferred defaults never replace an origin.
        if (origin != null and options.user == null and options.host == null)
            return .{ .url = origin.?, .existing_repository = true, .add_origin = false };
        const configured_user = if (options.user == null and std.ascii.eqlIgnoreCase(host, "github.com"))
            try self.config(&.{ "config", "--global", "--get", "github.user" })
        else
            null;
        const user = options.user orelse configured_user orelse try self.promptUser(host);
        try validateUser(user);
        const url = try std.fmt.allocPrint(self.allocator, "https://{s}/{s}/{s}.ss", .{ host, user, name });
        if (origin) |current| {
            if (!std.mem.eql(u8, current, url)) {
                std.debug.print("init: origin already exists: {s}; leaving it unchanged\n", .{current});
                return error.InitOriginExists;
            }
        } else {
            _ = try self.command(&.{"--version"});
        }
        return .{ .url = url, .existing_repository = existing, .add_origin = origin == null };
    }

    fn promptUser(self: Git, host: []const u8) ![]const u8 {
        if (std.c.isatty(0) != 1) {
            std.debug.print("init: repository owner is not configured; use --user NAME or --no-git in non-interactive mode\n", .{});
            return error.MissingGitUser;
        }
        var buffer: [512]u8 = undefined;
        while (true) {
            std.debug.print("Repository owner on {s} (empty to cancel): ", .{host});
            const line = input.readLine(&buffer) catch |err| switch (err) {
                error.EndOfStream => return error.InitCancelled,
                error.InputTooLong => {
                    std.debug.print("Owner name is too long.\n", .{});
                    continue;
                },
                else => return err,
            };
            const user = std.mem.trim(u8, line, " \t\r");
            if (user.len == 0) return error.InitCancelled;
            validateUser(user) catch {
                std.debug.print("Enter a user or organization name, using letters, digits, '.', '_' or '-'.\n", .{});
                continue;
            };
            return self.allocator.dupe(u8, user);
        }
    }

    pub fn apply(self: Git, directory: []const u8, setup: Setup) !void {
        if (!setup.existing_repository) _ = try self.command(&.{ "init", "--quiet", "--", directory });
        if (setup.add_origin) _ = try self.command(&.{ "-C", directory, "remote", "add", "origin", setup.url });
    }

    fn config(self: Git, args: []const []const u8) !?[]const u8 {
        const result = try self.run(args);
        if (result.term == .exited and result.term.exited == 1) return null;
        try check(result);
        const value = std.mem.trim(u8, result.stdout, "\r\n ");
        return if (value.len == 0) null else value;
    }

    fn command(self: Git, args: []const []const u8) ![]const u8 {
        const result = try self.run(args);
        try check(result);
        return result.stdout;
    }

    fn run(self: Git, args: []const []const u8) !std.process.RunResult {
        var argv = std.ArrayList([]const u8).empty;
        try argv.appendSlice(self.allocator, &.{ "git", "-c", "core.hooksPath=/dev/null" });
        try argv.appendSlice(self.allocator, args);
        return utils.process.runWithEnvironment(self.allocator, self.io, argv.items, .inherit, self.environment) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };
    }

    fn check(result: std.process.RunResult) !void {
        if (result.term == .exited and result.term.exited == 0) return;
        if (result.stderr.len != 0) std.debug.print("git: {s}\n", .{result.stderr});
        return error.GitCommandFailed;
    }
};

fn validateUser(user: []const u8) !void {
    var parts = std.mem.splitScalar(u8, user, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or !std.ascii.isAlphanumeric(part[0]) or
            std.mem.indexOfNone(u8, part, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != null)
            return error.InvalidGitUser;
    }
}

fn validateHost(host: []const u8) !void {
    if (host.len == 0 or std.mem.indexOfNone(u8, host, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:") != null)
        return error.InvalidGitHost;
    const colon = std.mem.indexOfScalar(u8, host, ':');
    const hostname = if (colon) |i| host[0..i] else host;
    if (colon) |i| {
        const port = std.fmt.parseInt(u16, host[i + 1 ..], 10) catch return error.InvalidGitHost;
        if (port == 0) return error.InvalidGitHost;
    }
    var labels = std.mem.splitScalar(u8, hostname, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1]))
            return error.InvalidGitHost;
    }
}
