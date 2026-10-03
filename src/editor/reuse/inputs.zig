const std = @import("std");
const utils = @import("utils");
const resources = @import("render_resources");

pub fn observer(cache: *resources.SourceCache) utils.FileInputs.Observer {
    return .{ .context = cache, .capture = capture };
}

fn capture(context: *anyopaque, path: []const u8, kind: utils.file_inputs.Kind) !u64 {
    if (kind != .file) return 0;
    const cache: *resources.SourceCache = @ptrCast(@alignCast(context));
    const fingerprint = cache.fileFingerprint(path) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return 0,
    };
    return observation(fingerprint);
}

fn observation(fingerprint: resources.FileFingerprint) u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(&.{@intFromBool(fingerprint.present)});
    hash.update(std.mem.asBytes(&fingerprint.digest));
    return hash.final();
}

/// Modules were read before evaluation installed the observer. Compare their
/// captured disk contents with the source actually parsed for this generation.
pub fn recordSource(inputs: *utils.FileInputs, path: []const u8, source: []const u8) !void {
    try inputs.record(".", path, .file);
    const expected = observation(.{ .present = true, .digest = std.hash.Wyhash.hash(0, source) });
    for (inputs.ordered.items) |input| {
        if (std.mem.eql(u8, input.path, path)) {
            if (input.observation != expected) inputs.observations_complete = false;
            return;
        }
    }
    inputs.observations_complete = false;
}

pub fn matches(inputs: *const utils.FileInputs, cache: *resources.SourceCache) !bool {
    if (!inputs.observations_complete) return false;
    for (inputs.ordered.items) |input| {
        if (input.kind != .file) return false;
        const previous = input.observation orelse return false;
        if (previous == 0) return false;
        const current = try capture(cache, input.path, input.kind);
        if (current != previous) return false;
    }
    return true;
}

pub fn recordHighlightQueries(inputs: *utils.FileInputs, languages: []const utils.highlight.Language) !void {
    for (languages) |language| {
        if (!std.mem.startsWith(u8, language.query, "builtin:")) try inputs.record(".", language.query, .file);
    }
}
