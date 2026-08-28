const std = @import("std");
const utils = @import("utils");

const help = @import("help.zig");

pub const Shell = enum {
    bash,
    zsh,
    fish,

    pub fn parse(text: []const u8) ?Shell {
        if (std.mem.eql(u8, text, "bash")) return .bash;
        if (std.mem.eql(u8, text, "zsh")) return .zsh;
        if (std.mem.eql(u8, text, "fish")) return .fish;
        return null;
    }

    fn label(self: Shell) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
        };
    }
};

pub const Options = struct {
    shell: Shell,
    print: bool = false,
    yes: bool = false,
};

const InstallPlan = struct {
    shell: Shell,
    script_path: []const u8,
    zshrc_path: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, shell: Shell) !InstallPlan {
        return switch (shell) {
            .bash => .{
                .shell = shell,
                .script_path = try bashCompletionPath(allocator),
            },
            .zsh => blk: {
                const script_path = try zshCompletionPath(allocator);
                errdefer allocator.free(script_path);
                break :blk .{
                    .shell = shell,
                    .script_path = script_path,
                    .zshrc_path = try zshrcPath(allocator),
                };
            },
            .fish => .{
                .shell = shell,
                .script_path = try fishCompletionPath(allocator),
            },
        };
    }

    fn deinit(self: *InstallPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.script_path);
        if (self.zshrc_path) |path| allocator.free(path);
        self.* = undefined;
    }
};

const zsh_marker_start = "# >>> ss completion >>>";
const zsh_completion_init =
    \\# >>> ss completion >>>
    \\if [[ -d "$HOME/.zsh/completions" ]]; then
    \\  fpath=("$HOME/.zsh/completions" $fpath)
    \\fi
    \\autoload -Uz compinit
    \\compinit
    \\# <<< ss completion <<<
    \\
;

pub fn run(io: std.Io, allocator: std.mem.Allocator, options: Options) !void {
    const script_text = help.completionScript(options.shell.label()) orelse return error.UnknownCompletionShell;
    if (options.print) {
        try utils.io.writeStdoutAll(script_text);
        return;
    }

    var plan = try InstallPlan.init(allocator, options.shell);
    defer plan.deinit(allocator);

    try printPlan(io, allocator, &plan, script_text);
    if (!options.yes and !try confirm()) {
        std.debug.print("completion install cancelled\n", .{});
        return;
    }

    try install(io, allocator, &plan, script_text);
}

fn printPlan(io: std.Io, allocator: std.mem.Allocator, plan: *const InstallPlan, script_text: []const u8) !void {
    const script_state = try existingState(io, allocator, plan.script_path, script_text);
    std.debug.print("Install ss {s} completion:\n", .{plan.shell.label()});
    printAction(script_state, plan.script_path);
    if (plan.zshrc_path) |path| {
        const rc_state = try zshrcState(io, allocator, path);
        printAction(rc_state, path);
    }
}

fn printAction(state: ExistingState, path: []const u8) void {
    switch (state) {
        .missing => std.debug.print("  create {s}\n", .{path}),
        .stale => std.debug.print("  update {s}\n", .{path}),
        .current => std.debug.print("  already current {s}\n", .{path}),
    }
}

fn install(io: std.Io, allocator: std.mem.Allocator, plan: *const InstallPlan, script_text: []const u8) !void {
    try writeFileWithParents(io, plan.script_path, script_text);
    if (plan.zshrc_path) |path| try ensureZshInitBlock(io, allocator, path);
    std.debug.print("completion installed for {s}\n", .{plan.shell.label()});
}

fn confirm() !bool {
    std.debug.print("Proceed? [y/N] ", .{});
    var buffer: [32]u8 = undefined;
    const line = readStdinLine(&buffer) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes");
}

fn readStdinLine(buffer: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buffer.len) {
        var byte: [1]u8 = undefined;
        const n = std.c.read(0, &byte, 1);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (len == 0) return error.EndOfStream;
            break;
        }
        buffer[len] = byte[0];
        len += 1;
        if (byte[0] == '\n') break;
    }
    return buffer[0..len];
}

const ExistingState = enum {
    missing,
    stale,
    current,
};

fn existingState(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !ExistingState {
    const existing = readFileOrNull(io, allocator, path) catch |err| switch (err) {
        error.IsDir => return .stale,
        else => return err,
    };
    const text = existing orelse return .missing;
    defer allocator.free(text);
    if (std.mem.eql(u8, text, expected)) return .current;
    return .stale;
}

fn zshrcState(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !ExistingState {
    const maybe_existing = try readFileOrNull(io, allocator, path);
    const existing = maybe_existing orelse return .missing;
    defer allocator.free(existing);
    if (std.mem.indexOf(u8, existing, zsh_marker_start) != null) return .current;
    return .stale;
}

fn ensureZshInitBlock(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const existing = try readFileOrNull(io, allocator, path);
    defer if (existing) |text| allocator.free(text);
    if (existing) |text| {
        if (std.mem.indexOf(u8, text, zsh_marker_start) != null) return;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, text);
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, zsh_completion_init);
        const owned = try out.toOwnedSlice(allocator);
        defer allocator.free(owned);
        try writeFileWithParents(io, path, owned);
        return;
    }
    try writeFileWithParents(io, path, zsh_completion_init);
}

fn writeFileWithParents(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn readFileOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return utils.fs.readFileAlloc(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn bashCompletionPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try dataHome(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "bash-completion", "completions", "ss" });
}

fn zshCompletionPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".zsh", "completions", "_ss" });
}

fn zshrcPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".zshrc" });
}

fn fishCompletionPath(allocator: std.mem.Allocator) ![]const u8 {
    const base = try configHome(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "fish", "completions", "ss.fish" });
}

fn dataHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try envOwned(allocator, "XDG_DATA_HOME")) |path| return path;
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".local", "share" });
}

fn configHome(allocator: std.mem.Allocator) ![]const u8 {
    if (try envOwned(allocator, "XDG_CONFIG_HOME")) |path| return path;
    const home = try homeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config" });
}

fn homeDir(allocator: std.mem.Allocator) ![]const u8 {
    return (try envOwned(allocator, "HOME")) orelse error.HomeNotSet;
}

fn envOwned(allocator: std.mem.Allocator, name: [:0]const u8) !?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    const text = std.mem.span(value);
    if (text.len == 0) return null;
    return try allocator.dupe(u8, text);
}
