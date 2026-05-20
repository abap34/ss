const std = @import("std");
const utils = @import("utils");

pub const Config = struct {
    path: []u8,
    dir: []u8,
    entry: []u8,
    asset_base_dir: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.dir);
        allocator.free(self.entry);
        allocator.free(self.asset_base_dir);
    }
};

pub const Resolved = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    project_file: ?[]u8 = null,
    project_dir: ?[]u8 = null,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        if (self.project_file) |path| allocator.free(path);
        if (self.project_dir) |dir| allocator.free(dir);
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: ?[]const u8,
    project_arg: ?[]const u8,
    asset_base_arg: ?[]const u8,
) !Resolved {
    var config: ?Config = if (project_arg) |arg|
        try loadProjectArgument(allocator, io, arg)
    else
        try discover(allocator, io, ".");
    defer if (config) |*cfg| cfg.deinit(allocator);

    const entry_path = if (input_path) |input|
        try absolutePath(allocator, input)
    else if (config) |cfg|
        try allocator.dupe(u8, cfg.entry)
    else
        try absolutePath(allocator, "demo/01-language-tour.ss");
    errdefer allocator.free(entry_path);

    const asset_base_dir = if (asset_base_arg) |asset_base|
        try absolutePath(allocator, asset_base)
    else if (input_path != null) blk: {
        if (config) |cfg| break :blk try allocator.dupe(u8, cfg.asset_base_dir);
        break :blk try dirnameAlloc(allocator, entry_path);
    } else if (config) |cfg|
        try allocator.dupe(u8, cfg.asset_base_dir)
    else
        try dirnameAlloc(allocator, entry_path);
    errdefer allocator.free(asset_base_dir);

    return .{
        .entry_path = entry_path,
        .asset_base_dir = asset_base_dir,
        .project_file = if (config) |cfg| try allocator.dupe(u8, cfg.path) else null,
        .project_dir = if (config) |cfg| try allocator.dupe(u8, cfg.dir) else null,
    };
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !?Config {
    var current = try absolutePath(allocator, start_dir);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "ss.toml" });
        defer allocator.free(candidate);
        if (utils.fs.fileExists(allocator, candidate)) {
            return try loadFile(allocator, io, candidate);
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

pub fn loadProjectArgument(allocator: std.mem.Allocator, io: std.Io, arg: []const u8) !Config {
    const absolute = try absolutePath(allocator, arg);
    defer allocator.free(absolute);
    const path = if (std.mem.endsWith(u8, absolute, ".toml"))
        try allocator.dupe(u8, absolute)
    else
        try std.fs.path.join(allocator, &.{ absolute, "ss.toml" });
    defer allocator.free(path);
    return try loadFile(allocator, io, path);
}

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const source = try utils.fs.readFileAlloc(io, allocator, path);
    defer allocator.free(source);
    return parseSource(allocator, path, source);
}

pub fn parseSource(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !Config {
    const dir = try dirnameAlloc(allocator, path);
    errdefer allocator.free(dir);

    const raw_entry = parseProjectString(source, "entry") orelse return error.MissingProjectEntry;
    const raw_asset_base = parseProjectString(source, "asset_base_dir");
    const entry = try resolveAgainst(allocator, dir, raw_entry);
    errdefer allocator.free(entry);
    const asset_base_dir = if (raw_asset_base) |value|
        try resolveAgainst(allocator, dir, value)
    else
        try dirnameAlloc(allocator, entry);
    errdefer allocator.free(asset_base_dir);

    return .{
        .path = try allocator.dupe(u8, path),
        .dir = dir,
        .entry = entry,
        .asset_base_dir = asset_base_dir,
    };
}

fn parseProjectString(source: []const u8, key: []const u8) ?[]const u8 {
    var in_project = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const comment_start = std.mem.indexOfScalar(u8, line_raw, '#') orelse line_raw.len;
        const line = std.mem.trim(u8, line_raw[0..comment_start], " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_project = std.mem.eql(u8, line, "[project]");
            continue;
        }
        if (!in_project) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, name, key)) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
        return value[1 .. value.len - 1];
    }
    return null;
}

fn resolveAgainst(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ base, path });
}

pub fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len) == null) return error.CurrentWorkingDirectoryUnavailable;
    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse return error.NameTooLong;
    return allocator.dupe(u8, buffer[0..len]);
}

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return absolutePath(allocator, dir);
}
