const std = @import("std");
const syntax = @import("../syntax.zig");
const utils = @import("utils");
const loader = @import("../modules/loader.zig");

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
    var diagnostics = loader.LoadDiagnostics.init(allocator);
    defer diagnostics.deinit();
    var includes = loader.IncludeLoader{ .io = io, .diagnostics = &diagnostics };
    var module = syntax.parseWithOptions(allocator, source, path, .{ .failure = &failure, .include_resolver = includes.resolver() }) catch |err| {
        if (err == error.OutOfMemory) return err;
        @import("../app/diagnostics.zig").printLoadDiagnostics(&diagnostics);
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
