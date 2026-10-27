const std = @import("std");
const utils = @import("utils");
const protocol = @import("protocol.zig");

pub fn received(message: *const std.json.Value, revision: u64) utils.profile.Task {
    if (!utils.profile.isRecording() or message.* != .object) return .{};
    const object = &message.object;
    const method = protocol.stringField(object, "method");
    const version = blk: {
        const params = protocol.objectFieldObject(object, "params") orelse break :blk null;
        const document = protocol.objectFieldObject(params, "textDocument") orelse break :blk null;
        break :blk protocol.intField(document, "version");
    };
    const request: u64 = if (utils.json.fieldValue(object, "id")) |id| switch (id.*) {
        .integer => |value| @as(u64, @bitCast(value)) & std.math.maxInt(i64),
        .string => |value| std.hash.Wyhash.hash(0, value) & std.math.maxInt(i64),
        else => 0,
    } else 0;
    return utils.profile.Task.enqueue(profileMethod(method), .{ .parent = 0, .revision = revision, .version = version, .request = request });
}

fn profileMethod(method: ?[]const u8) []const u8 {
    const name = method orelse return "lsp.other";
    for ([_][]const u8{ "exit", "initialize", "shutdown", "ss/deleteComponent", "ss/editLineGeometry", "ss/editShapeBounds", "ss/editorClose", "ss/editorResources", "ss/editorSnapshot", "ss/iconCatalog", "ss/insertIcon", "ss/insertShape", "ss/layoutConflicts", "ss/layoutEdit", "ss/projectInfo", "ss/projectSettings", "ss/shapeStyleEdit", "textDocument/colorPresentation", "textDocument/completion", "textDocument/definition", "textDocument/didChange", "textDocument/didClose", "textDocument/didOpen", "textDocument/didSave", "textDocument/documentColor", "textDocument/documentSymbol", "textDocument/foldingRange", "textDocument/hover", "textDocument/semanticTokens/full", "workspace/didChangeWatchedFiles", "ss/profile" }) |known| {
        if (std.mem.eql(u8, name, known)) return known;
    }
    return "lsp.other";
}
