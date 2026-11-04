const std = @import("std");
const syntax = @import("../syntax.zig");
const utils = @import("utils");

pub fn run(io: std.Io, allocator: std.mem.Allocator, input: []const u8, output: ?[]const u8) !void {
    const path = try utils.fs.absolutePath(io, allocator, input);
    defer allocator.free(path);
    const source = utils.fs.readFileAlloc(io, allocator, path) catch |err| {
        var buffer: [4096]u8 = undefined;
        std.debug.print("{s}\n", .{utils.err.formatPathFailure(&buffer, "InputReadFailed", "read input", path, err)});
        return error.InvalidUsage;
    };
    defer allocator.free(source);
    var failure: syntax.ParseFailure = .{};
    var module = syntax.parseWithSourceNameAndFailure(allocator, source, path, &failure) catch |err| {
        if (err == error.OutOfMemory) return err;
        utils.err.printParseError(path, source, err, failure.diagnostic);
        return error.InvalidUsage;
    };
    defer module.deinit(allocator);
    const text = try syntax.printExpandedAlloc(allocator, module);
    defer allocator.free(text);
    if (output) |target| {
        utils.fs.writeFile(io, target, text) catch |err| {
            var buffer: [4096]u8 = undefined;
            std.debug.print("{s}\n", .{utils.err.formatPathFailure(&buffer, "OutputWriteFailed", "write output", target, err)});
            return error.InvalidUsage;
        };
    } else try utils.io.writeStdoutAll(text);
}
