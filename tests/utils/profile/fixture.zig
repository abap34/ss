const std = @import("std");
const profile = @import("utils").profile;

pub fn main(init: std.process.Init) !void {
    if (!profile.available) return error.ProfilingUnavailable;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.InvalidArguments;
    var session = try profile.Session.init(allocator, init.io, args[1], 1024, .{ .command = "fixture" });
    defer session.deinit();
    profile.activate(&session);
    defer profile.deactivate();
    {
        var operation = profile.Operation.begin("shared-starts", .{});
        defer operation.finish();
        const shared = profile.start();
        wait();
        profile.recordAnalysis(.semantics_call_graph, shared);
        wait();
        profile.recordAnalysis(.static_semantics, shared);

        const first = profile.start();
        wait();
        const second = profile.start();
        wait();
        profile.recordAnalysis(.module_graph, first);
        wait();
        profile.recordAnalysis(.module_index, second);
    }
    try session.write(true);
}

fn wait() void {
    const started = profile.timestamp();
    while (profile.timestamp() - started < 100_000) std.atomic.spinLoopHint();
}
