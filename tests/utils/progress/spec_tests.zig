const std = @import("std");
const utils = @import("utils");

const Progress = utils.progress.Progress;

test "progress keeps one active stage and completes it with its original label" {
    var progress = Progress.disabled(3);

    progress.begin("Compile rendering");
    try std.testing.expectEqualStrings("Compile rendering", progress.active_label.?);
    progress.detail("artifacts", 1, 2);
    progress.complete();

    try std.testing.expectEqual(@as(usize, 1), progress.current);
    try std.testing.expectEqual(@as(?[]const u8, null), progress.active_label);
    try std.testing.expect(!progress.status_active);

    progress.step("Write output");
    try std.testing.expectEqual(@as(usize, 2), progress.current);
}

test "aborting an active stage clears it without reporting completion" {
    var progress = Progress.disabled(2);

    progress.begin("Parse source");
    progress.abort();

    try std.testing.expectEqual(@as(usize, 0), progress.current);
    try std.testing.expectEqual(@as(?[]const u8, null), progress.active_label);
    try std.testing.expect(!progress.status_active);

    progress.begin("Read inputs");
    progress.complete();
    try std.testing.expectEqual(@as(usize, 1), progress.current);
}
