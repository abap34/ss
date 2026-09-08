const std = @import("std");
const utils = @import("utils");
const resources = @import("render_resources");

pub const read_limit = 8 * 1024 * 1024;
pub const Input = struct {
    path: []const u8,
    fingerprint: resources.FileFingerprint,
};
pub const Manifest = struct {
    version: u32 = 1,
    inputs: []const Input,
};
pub const Parsed = std.json.Parsed(Manifest);

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: ?*resources.SourceCache = null,
    observed: ?*utils.FileInputs = null,

    pub fn fingerprint(self: Context, path: []const u8) !resources.FileFingerprint {
        if (self.observed) |inputs| try inputs.record(".", path, .file);
        if (self.cache) |cache| return cache.fileFingerprint(path);
        var cache = resources.SourceCache.init(self.allocator, self.io);
        defer cache.deinit();
        return cache.fileFingerprint(path);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    var parsed = std.json.parseFromSlice(Manifest, allocator, text, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidPdfCache,
    };
    errdefer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.inputs.len == 0) return error.InvalidPdfCache;
    var previous: ?[]const u8 = null;
    for (parsed.value.inputs) |input| {
        if (!std.fs.path.isAbsolute(input.path) or std.mem.indexOfScalar(u8, input.path, 0) != null) return error.InvalidPdfCache;
        if (previous) |path| if (std.mem.order(u8, path, input.path) != .lt) return error.InvalidPdfCache;
        previous = input.path;
    }
    return parsed;
}

pub fn matches(ctx: Context, inputs: []const Input) !bool {
    var valid = true;
    // Visit every input even after a mismatch so failed builds retain all known
    // dependencies, including missing files that may subsequently be restored.
    for (inputs) |input| {
        const current = try ctx.fingerprint(input.path);
        valid = valid and current.present == input.fingerprint.present and current.digest == input.fingerprint.digest;
    }
    return valid;
}

pub fn digest(inputs: []const Input) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (inputs) |input| hashInput(&hasher, input.path, input.fingerprint);
    return hasher.final();
}

pub fn hashInput(hasher: *std.hash.Wyhash, path: []const u8, value: resources.FileFingerprint) void {
    const length: u64 = path.len;
    hasher.update(std.mem.asBytes(&length));
    hasher.update(path);
    hasher.update(&.{@intFromBool(value.present)});
    hasher.update(std.mem.asBytes(&value.digest));
}

/// The recorder reports opened files and generated outputs. Resolve PWD changes
/// and remove all outputs, including files read back by TeX during the same run.
pub fn recorderPaths(allocator: std.mem.Allocator, contents: []const u8, working_directory: []const u8, generated_directory: []const u8) ![][]const u8 {
    var reads = utils.FileInputs.init(allocator);
    defer reads.deinit();
    var outputs = utils.FileInputs.init(allocator);
    defer outputs.deinit();
    var directory: []const u8 = working_directory;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "PWD ")) {
            if (!std.fs.path.isAbsolute(line[4..])) return error.InvalidLatexRecorder;
            directory = line[4..];
        } else if (std.mem.startsWith(u8, line, "INPUT ")) {
            if (line.len > 6) try reads.record(directory, line[6..], .file);
        } else if (std.mem.startsWith(u8, line, "OUTPUT ")) {
            if (line.len > 7) try outputs.record(directory, line[7..], .file);
        }
    }
    const generated = try std.fs.path.resolve(allocator, &.{generated_directory});
    defer allocator.free(generated);
    var result = std.ArrayList([]const u8).empty;
    errdefer {
        for (result.items) |path| allocator.free(path);
        result.deinit(allocator);
    }
    for (reads.items()) |input| {
        if (outputs.paths.contains(input.path) or withinDirectory(generated, input.path)) continue;
        try result.ensureUnusedCapacity(allocator, 1);
        result.appendAssumeCapacity(try allocator.dupe(u8, input.path));
    }
    return result.toOwnedSlice(allocator);
}

fn withinDirectory(directory: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, directory, path) or
        (std.mem.startsWith(u8, path, directory) and path.len > directory.len and std.fs.path.isSep(path[directory.len]));
}

pub fn capture(ctx: Context, paths: []const []const u8) ![]Input {
    const result = try ctx.allocator.alloc(Input, paths.len);
    errdefer ctx.allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |input| ctx.allocator.free(input.path);
    for (paths, result) |path, *input| {
        const value = try ctx.fingerprint(path);
        input.* = .{ .path = try ctx.allocator.dupe(u8, path), .fingerprint = value };
        initialized += 1;
    }
    return result;
}

pub fn free(allocator: std.mem.Allocator, inputs: []const Input) void {
    for (inputs) |input| allocator.free(input.path);
    allocator.free(inputs);
}

/// Fatal TeX file diagnostics also identify inputs that could not be opened and
/// therefore are absent from the recorder. Keep those paths for watch recovery.
pub fn recordMissingInputs(observed: *utils.FileInputs, contents: []const u8, working_directory: []const u8) !void {
    for ([_][]const u8{ "File ", "I can't find file " }) |prefix| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, contents, cursor, prefix)) |start| {
            const quoted = start + prefix.len;
            cursor = quoted;
            if (quoted >= contents.len or (contents[quoted] != '`' and contents[quoted] != '\'')) continue;
            const end = std.mem.indexOfScalarPos(u8, contents, quoted + 1, '\'') orelse continue;
            cursor = end + 1;
            if (std.mem.eql(u8, prefix, "File ") and !std.mem.startsWith(u8, contents[cursor..], " not found")) continue;
            var path = std.ArrayList(u8).empty;
            defer path.deinit(observed.allocator);
            for (contents[quoted + 1 .. end]) |byte| {
                if (byte != '\n' and byte != '\r') try path.append(observed.allocator, byte);
            }
            if (path.items.len == 0) continue;
            try observed.record(working_directory, path.items, .file);
            if (std.fs.path.extension(path.items).len == 0) {
                try path.appendSlice(observed.allocator, ".tex");
                try observed.record(working_directory, path.items, .file);
            }
        }
    }
}
