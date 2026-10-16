const std = @import("std");
const state = @import("lsp").state;
const allocation_testing = @import("allocation_testing");
const testing = std.testing;

fn entry(allocator: std.mem.Allocator, path: []const u8) !state.AnalysisEntry {
    return .{
        .snapshot = state.AnalysisSnapshot.fromDiagnostics(allocator, .init(allocator), .{ .entry_path = try allocator.dupe(u8, path) }),
        .diagnostics = .init(allocator),
        .watched_revision = 0,
    };
}

fn exerciseStore(allocator: std.mem.Allocator) !void {
    var store = state.AnalysisStore{};
    defer store.deinit(allocator);
    var first = try entry(allocator, "first.ss");
    var first_owned = true;
    defer if (first_owned) first.deinit();
    try first.diagnostics.add("first.ss", "bad", .@"error", "InvalidType", "bad type", null);
    try store.put(allocator, first);
    first_owned = false;
    var second = try entry(allocator, "second.ss");
    var second_owned = true;
    defer if (second_owned) second.deinit();
    try second.diagnostics.appendFrom(&store.entries.items[0].diagnostics);
    try second.diagnostics.appendFrom(&store.entries.items[0].diagnostics);
    try testing.expectEqual(@as(usize, 1), second.diagnostics.items.items.len);
    try store.put(allocator, second);
    second_owned = false;
    var replacement = try entry(allocator, "first.ss");
    var replacement_owned = true;
    defer if (replacement_owned) replacement.deinit();
    try store.put(allocator, replacement);
    replacement_owned = false;
    try testing.expectEqual(@as(usize, 2), store.entries.items.len);
    store.remove("first.ss");
    try testing.expectEqual(@as(usize, 1), store.entries.items.len);
    try testing.expectEqualStrings("second.ss", store.entries.items[0].snapshot.project.entry_path);
}

test "LSP analysis entries and copied diagnostics retain ownership on failure" {
    try allocation_testing.checkAllAllocationFailures(testing.allocator, exerciseStore, .{});
}
