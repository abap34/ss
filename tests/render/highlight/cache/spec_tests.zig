const std = @import("std");
const render_compile = @import("render_compile");
const utils = @import("utils");
const testing = std.testing;
const Cache = render_compile.HighlightCache;
const Failure = render_compile.HighlightFailure;

fn language(name: []const u8, parser: []const u8, query: []const u8) utils.highlight.Language {
    return .{ .name = @constCast(name), .parser = @constCast(parser), .query = @constCast(query) };
}

test "highlight cache: equal content and parser-query aliases reuse compiled work" {
    var cache = Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const languages = [_]utils.highlight.Language{
        language("python", "python", "builtin:python"),
        language("alias", "python", "builtin:python"),
    };
    var failure: Failure = .none;
    const content = "def hello(value):\n  return value + 1\n";
    var first = try cache.highlight(&languages, "python", content, &failure);
    defer first.deinit();
    try testing.expect(first.segments().len > 1);
    const copy = try testing.allocator.dupe(u8, content);
    defer testing.allocator.free(copy);
    var second = try cache.highlight(&languages, "alias", copy, &failure);
    defer second.deinit();
    try testing.expectEqual(first.segments().ptr, second.segments().ptr);
    var changed = try cache.highlight(&languages, "python", "def other():\n  return 2\n", &failure);
    defer changed.deinit();
    const stats = cache.stats();
    try testing.expectEqual(@as(usize, 1), stats.query_compilations);
    try testing.expectEqual(@as(usize, 2), stats.content_analyses);
}

const query_root = ".ss-cache/test-highlight-query-generations";
const query_path = query_root ++ "/query.scm";

test "highlight cache: changed query bytes and parser identities invalidate results" {
    std.Io.Dir.cwd().deleteTree(testing.io, query_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, query_root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, query_root);
    var cache = Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const languages = [_]utils.highlight.Language{
        language("python", "python", query_path),
        language("javascript", "javascript", query_path),
    };
    var failure: Failure = .none;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = query_path, .data = "(identifier) @number" });
    var first = try cache.highlight(&languages, "python", "hello", &failure);
    defer first.deinit();
    try testing.expectEqual(utils.highlight.CaptureRole.number, first.segments()[0].role.?);
    // The replacement has the same byte count as the original query.
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = query_path, .data = "(identifier) @string" });
    var changed = try cache.highlight(&languages, "python", "hello", &failure);
    defer changed.deinit();
    try testing.expectEqual(utils.highlight.CaptureRole.string, changed.segments()[0].role.?);
    var different_parser = try cache.highlight(&languages, "javascript", "hello", &failure);
    defer different_parser.deinit();
    try testing.expectEqual(@as(usize, 3), cache.stats().query_compilations);
    try testing.expectEqual(@as(usize, 3), cache.stats().content_analyses);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = query_path, .data = "(" });
    try testing.expectError(error.TreeSitterQueryFailed, cache.highlight(&languages, "python", "hello", &failure));
    try testing.expect(failure == .query_invalid);
    try testing.expectEqualStrings(query_path, failure.query_invalid.path);
    try std.Io.Dir.cwd().deleteFile(testing.io, query_path);
    try testing.expectError(error.FileNotFound, cache.highlight(&languages, "python", "hello", &failure));
    try testing.expect(failure == .query_read);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = query_path, .data = "(identifier) @number" });
    var restored = try cache.highlight(&languages, "python", "hello", &failure);
    defer restored.deinit();
    try testing.expectEqual(first.segments().ptr, restored.segments().ptr);
    try testing.expectEqual(@as(usize, 3), cache.stats().query_compilations);
}

test "highlight cache: eviction and clearing preserve active results" {
    var cache = Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    cache.limits.queries = 1;
    cache.limits.contents = 1;
    const languages = [_]utils.highlight.Language{
        language("python", "python", "builtin:python"),
        language("javascript", "javascript", "builtin:javascript"),
    };
    var failure: Failure = .none;
    var retained = try cache.highlight(&languages, "python", "return 1", &failure);
    defer retained.deinit();
    const first_role = retained.segments()[0].role;
    const first_pointer = retained.segments().ptr;
    var replacement = try cache.highlight(&languages, "javascript", "return 2", &failure);
    defer replacement.deinit();
    try testing.expectEqual(@as(usize, 1), cache.stats().query_entries);
    try testing.expectEqual(@as(usize, 1), cache.stats().content_entries);
    cache.clear();
    const stats = cache.stats();
    try testing.expectEqual(@as(usize, 0), stats.query_entries);
    try testing.expectEqual(@as(usize, 0), stats.content_entries);
    try testing.expectEqual(@as(usize, 0), stats.query_bytes);
    try testing.expectEqual(@as(usize, 0), stats.content_bytes);
    try testing.expectEqual(first_pointer, retained.segments().ptr);
    try testing.expectEqual(first_role, retained.segments()[0].role);
}

test "highlight cache: results exceeding retention budgets remain usable" {
    var cache = Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    cache.limits.query_bytes = 1;
    cache.limits.content_bytes = 1;
    const languages = [_]utils.highlight.Language{language("python", "python", "builtin:python")};
    var failure: Failure = .none;
    var result = try cache.highlight(&languages, "python", "return 1", &failure);
    defer result.deinit();
    try testing.expect(result.segments().len > 1);
    try testing.expectEqual(@as(usize, 0), cache.stats().query_entries);
    try testing.expectEqual(@as(usize, 0), cache.stats().content_entries);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var cache = Cache.init(allocator, testing.io);
    defer cache.deinit();
    const languages = [_]utils.highlight.Language{language("python", "python", "builtin:python")};
    var failure: Failure = .none;
    var first = try cache.highlight(&languages, "python", "return 1", &failure);
    defer first.deinit();
    var second = try cache.highlight(&languages, "python", "return 2", &failure);
    defer second.deinit();
    var reused = try cache.highlight(&languages, "python", "return 1", &failure);
    defer reused.deinit();
    cache.clear();
}

test "highlight cache: allocation failures release queries results and partial publication" {
    try testing.checkAllAllocationFailures(testing.allocator, exerciseAllocationFailures, .{});
}

const Worker = struct {
    cache: *Cache,
    failed: bool = false,

    fn run(self: *Worker) void {
        self.exercise() catch {
            self.failed = true;
        };
    }

    fn exercise(self: *Worker) !void {
        const languages = [_]utils.highlight.Language{language("python", "python", "builtin:python")};
        var failure: Failure = .none;
        for (0..32) |_| {
            var result = try self.cache.highlight(&languages, "python", "return 1", &failure);
            defer result.deinit();
            try testing.expect(result.segments().len > 1);
        }
    }
};

test "highlight cache: concurrent callers publish one retained result per key" {
    var cache = Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    var first = Worker{ .cache = &cache };
    var second = Worker{ .cache = &cache };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    var first_joined = false;
    defer if (!first_joined) first_thread.join();
    const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
    second_thread.join();
    first_thread.join();
    first_joined = true;
    // Both joins must finish before inspecting worker state or deinitializing.
    try testing.expect(!first.failed and !second.failed);
    try testing.expectEqual(@as(usize, 1), cache.stats().query_entries);
    try testing.expectEqual(@as(usize, 1), cache.stats().content_entries);
}
