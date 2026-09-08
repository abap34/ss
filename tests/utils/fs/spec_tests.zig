const std = @import("std");
const utils = @import("utils");

const testing = std.testing;

const ReadCancellation = struct {
    checks: usize = 0,
    cancel_at: usize,

    fn canceled(context: *const anyopaque) bool {
        const self: *ReadCancellation = @ptrCast(@alignCast(@constCast(context)));
        self.checks += 1;
        return self.checks >= self.cancel_at;
    }
};

fn canceledRead(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
    return error.Canceled;
}

test "utils fs: bounded reads enforce limits and release canceled results" {
    const root = ".ss-cache/test-fs-bounded-read";
    const path = root ++ "/input.txt";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = "contents" });
    const contents = try utils.fs.readFileAllocLimited(testing.io, testing.allocator, path, .limited(9));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("contents", contents);
    try testing.expectError(error.StreamTooLong, utils.fs.readFileAllocLimited(testing.io, testing.allocator, path, .limited(8)));
    for ([_]usize{ 1, 2 }) |cancel_at| {
        var counter = ReadCancellation{ .cancel_at = cancel_at };
        try testing.expectError(error.Canceled, utils.fs.readFileAllocWithOptions(testing.io, testing.allocator, path, .{
            .limit = .limited(9),
            .cancellation = .{ .context = &counter, .is_canceled = ReadCancellation.canceled },
        }));
        try testing.expectEqual(cancel_at, counter.checks);
    }
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = canceledRead;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    try testing.expectError(error.Canceled, utils.fs.readFileAllocLimited(io, testing.allocator, path, .limited(9)));
}

const FileVisitor = struct {
    files: usize = 0,
    bytes: u64 = 0,

    pub fn visit(self: *FileVisitor, path: []const u8, stat: std.Io.File.Stat) !void {
        try testing.expect(!std.fs.path.isAbsolute(path));
        self.files += 1;
        self.bytes += stat.size;
    }
};

test "utils fs: shared directory traversal counts nested files and skips directory symlinks" {
    const root = ".ss-cache/test-fs-directory-stats";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root ++ "/nested/deep");
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/a", .data = "abc" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/nested/deep/b", .data = "defgh" });
    if (@import("builtin").os.tag != .windows) {
        try std.Io.Dir.cwd().symLink(testing.io, "nested", root ++ "/alias", .{ .is_directory = true });
        try std.Io.Dir.cwd().symLink(testing.io, "missing", root ++ "/broken", .{});
    }
    var visitor = FileVisitor{};
    const stats = try utils.fs.walkFiles(testing.io, testing.allocator, root, &visitor);
    try testing.expectEqual(@as(usize, 2), stats.files);
    try testing.expectEqual(@as(usize, 2), stats.directories);
    try testing.expectEqual(@as(u64, 8), stats.bytes);
    try testing.expectEqual(stats.files, visitor.files);
    try testing.expectEqual(stats.bytes, visitor.bytes);
    try testing.expectEqualDeep(stats, try utils.fs.directoryStats(testing.io, testing.allocator, root));
    try testing.expectEqualDeep(stats, try utils.tree_sitter_cache.stats(testing.io, testing.allocator, root));
    try testing.expectEqualDeep(utils.fs.DirectoryStats{}, try utils.fs.directoryStats(testing.io, testing.allocator, root ++ "/missing"));
}

fn canceledStat(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
    return error.Canceled;
}

test "utils fs: directory traversal propagates cancellation during leaf inspection" {
    const root = ".ss-cache/test-fs-directory-cancellation";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/a", .data = "a" });
    var vtable = testing.io.vtable.*;
    vtable.dirStatFile = canceledStat;
    const io = std.Io{ .userdata = testing.io.userdata, .vtable = &vtable };
    try testing.expectError(error.Canceled, utils.fs.directoryStats(io, testing.allocator, root));
}

fn writeTmpFile(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8, data: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    return path;
}

test "utils fs spec: file existence checks preserve allocation failures" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, utils.fs.fileExists(failing.allocator(), "missing"));
}

test "utils fs spec: file existence checks distinguish present and missing paths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const present = try writeTmpFile(allocator, tmp, "present.txt", "present");
    defer allocator.free(present);
    const missing = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/missing.txt", .{tmp.sub_path[0..]});
    defer allocator.free(missing);

    try testing.expect(try utils.fs.fileExists(allocator, present));
    try testing.expect(!try utils.fs.fileExists(allocator, missing));
}

test "utils fs spec: file existence checks preserve symbolic link cycles" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/loop", .{tmp.sub_path[0..]});
    defer allocator.free(path);
    try std.Io.Dir.cwd().symLink(testing.io, "loop", path, .{});

    try testing.expectError(error.SymLinkLoop, utils.fs.fileExists(allocator, path));
}

test "utils fs spec: path operations distinguish missing paths from non-directory ancestors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const blocker = try writeTmpFile(allocator, tmp, "blocker", "not a directory");
    defer allocator.free(blocker);
    const blocked_path = try std.fs.path.join(allocator, &.{ blocker, "missing", "child.txt" });
    defer allocator.free(blocked_path);
    const missing_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/missing/child.txt", .{tmp.sub_path[0..]});
    defer allocator.free(missing_path);

    try testing.expectError(error.NotDir, utils.fs.statFile(testing.io, blocked_path));
    try testing.expectError(error.NotDir, utils.fs.openDir(testing.io, blocked_path, .{}));
    try testing.expectError(error.NotDir, utils.fs.readFileAlloc(testing.io, allocator, blocked_path));

    try testing.expectError(error.FileNotFound, utils.fs.statFile(testing.io, missing_path));
    try testing.expectError(error.FileNotFound, utils.fs.openDir(testing.io, missing_path, .{}));
    try testing.expectError(error.FileNotFound, utils.fs.readFileAlloc(testing.io, allocator, missing_path));
}

test "utils fs spec: file writes atomically replace existing contents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "output.json", "old contents");
    defer allocator.free(path);

    try utils.fs.writeFile(testing.io, path, "new contents");

    const contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .unlimited);
    defer allocator.free(contents);
    try testing.expectEqualStrings("new contents", contents);
}

test "utils fs spec: file writes replace symlinks without changing their targets" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const target = try writeTmpFile(allocator, tmp, "target.json", "protected contents");
    defer allocator.free(target);
    const output = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/output.json", .{tmp.sub_path[0..]});
    defer allocator.free(output);
    try std.Io.Dir.cwd().symLink(testing.io, "target.json", output, .{});

    try utils.fs.writeFile(testing.io, output, "new contents");

    const target_contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, target, allocator, .unlimited);
    defer allocator.free(target_contents);
    try testing.expectEqualStrings("protected contents", target_contents);
    const output_contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, output, allocator, .unlimited);
    defer allocator.free(output_contents);
    try testing.expectEqualStrings("new contents", output_contents);
}

test "utils fs spec: file write failures preserve existing contents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "output.json", "old contents");
    defer allocator.free(path);
    var vtable = testing.io.vtable.*;
    vtable.operate = failFileWrites;
    const injected_io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };

    try testing.expectError(error.NoSpaceLeft, utils.fs.writeFile(injected_io, path, "new contents"));
    try expectFileContents(allocator, path, "old contents");
    try expectEntryCount(tmp.dir, 1);
}

test "utils fs spec: file publication failures preserve existing contents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "output.json", "old contents");
    defer allocator.free(path);
    var vtable = testing.io.vtable.*;
    vtable.dirRename = failRenames;
    const injected_io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };

    try testing.expectError(error.AccessDenied, utils.fs.writeFile(injected_io, path, "new contents"));
    try expectFileContents(allocator, path, "old contents");
    try expectEntryCount(tmp.dir, 1);
}

fn expectFileContents(allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const contents = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .unlimited);
    defer allocator.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

fn expectEntryCount(dir: std.Io.Dir, expected: usize) !void {
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(testing.io)) |_| count += 1;
    try testing.expectEqual(expected, count);
}

fn failFileWrites(
    userdata: ?*anyopaque,
    operation: std.Io.Operation,
) std.Io.Cancelable!std.Io.Operation.Result {
    return switch (operation) {
        .file_write_streaming => .{ .file_write_streaming = error.NoSpaceLeft },
        else => testing.io.vtable.operate(userdata, operation),
    };
}

fn failRenames(
    _: ?*anyopaque,
    _: std.Io.Dir,
    _: []const u8,
    _: std.Io.Dir,
    _: []const u8,
) std.Io.Dir.RenameError!void {
    return error.AccessDenied;
}

test "utils fs spec: SVG image dimensions use explicit size attributes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "explicit.svg",
        \\<svg xmlns="http://www.w3.org/2000/svg" width="640px" height="360">
        \\</svg>
    );
    defer allocator.free(path);

    const dimensions = try utils.fs.readImageDimensions(allocator, path);
    try testing.expectEqual(@as(f32, 640), dimensions.width);
    try testing.expectEqual(@as(f32, 360), dimensions.height);
}

test "utils fs spec: SVG image dimensions fall back to viewBox" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try writeTmpFile(allocator, tmp, "viewbox.svg",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 256">
        \\</svg>
    );
    defer allocator.free(path);

    const dimensions = try utils.fs.readImageDimensions(allocator, path);
    try testing.expectEqual(@as(f32, 512), dimensions.width);
    try testing.expectEqual(@as(f32, 256), dimensions.height);
}

test "utils fs spec: image dimension reads preserve directory errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(path);

    try testing.expectError(error.IsDir, utils.fs.readImageDimensions(allocator, path));
}
