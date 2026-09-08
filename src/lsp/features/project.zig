const std = @import("std");
const project_config = @import("project");
const utils = @import("utils");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const protocol = @import("../protocol.zig");
const lsp_state = @import("../state.zig");

const ProjectFacts = analysis_snapshot.ProjectFacts;

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.AnalysisProvider,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    if (try protocol.docPathFromParams(ctx.allocator, params)) |doc_path| {
        defer ctx.allocator.free(doc_path);
        var owned_snapshot: ?lsp_state.AnalysisSnapshot = null;
        defer if (owned_snapshot) |*snapshot| snapshot.deinit();
        const snapshot = try ctx.provider.forDocument(doc_path, &owned_snapshot) orelse return try json(ctx.allocator, null);
        return try json(ctx.allocator, &snapshot.project);
    }
    return try json(ctx.allocator, if (ctx.provider.current) |snapshot| &snapshot.project else null);
}

pub fn json(allocator: std.mem.Allocator, project: ?*const ProjectFacts) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '{');
    if (project) |facts| {
        try out.appendSlice(allocator, "\"entryPath\":");
        try protocol.appendJsonString(allocator, &out, facts.entry_path);
        try out.appendSlice(allocator, ",\"assetBaseDir\":");
        try protocol.appendJsonString(allocator, &out, facts.asset_base_dir);
        try out.appendSlice(allocator, ",\"localModules\":[");
        for (facts.module_paths, 0..) |path, i| {
            if (i != 0) try out.append(allocator, ',');
            try protocol.appendJsonString(allocator, &out, path);
        }
        try out.append(allocator, ']');
        try out.appendSlice(allocator, ",\"settings\":");
        try appendSettings(allocator, &out, facts.lsp, facts.wysiwyg, facts.page_guide);
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

pub fn settingsResult(allocator: std.mem.Allocator, io: std.Io, params: ?protocol.JsonValue) ![]const u8 {
    var project_file: ?[]const u8 = null;
    if (params) |value| {
        if (value != .object) return error.InvalidParams;
        if (value.object.get("projectFile")) |field| {
            if (field != .null) {
                if (field != .string or !std.fs.path.isAbsolute(field.string) or
                    std.mem.indexOfScalar(u8, field.string, 0) != null) return error.InvalidParams;
                project_file = field.string;
            }
        }
    }
    var config: ?project_config.Config = null;
    defer if (config) |*value| value.deinit(allocator);
    var failure: ?anyerror = null;
    if (project_file) |path| {
        config = project_config.loadFile(allocator, io, path) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => blk: {
                failure = err;
                break :blk null;
            },
        };
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"schema\":1,\"entryPath\":");
    if (config) |value| try protocol.appendJsonString(allocator, &out, value.entry) else try out.appendSlice(allocator, "null");
    try out.appendSlice(allocator, ",\"settings\":");
    try appendSettings(
        allocator,
        &out,
        if (config) |value| value.lsp else .{},
        if (config) |value| value.wysiwyg else .{},
        if (config) |value| value.page_guide else .{},
    );
    if (failure) |err| {
        var reason: [256]u8 = undefined;
        try out.appendSlice(allocator, ",\"error\":{\"code\":");
        try protocol.appendJsonString(allocator, &out, @errorName(err));
        try out.appendSlice(allocator, ",\"message\":");
        try protocol.appendJsonString(allocator, &out, project_config.configErrorMessage(err) orelse utils.err.formatErrorReason(&reason, err));
        try out.append(allocator, '}');
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendSettings(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    lsp: project_config.LspConfig,
    wysiwyg: project_config.WysiwygConfig,
    page_guide: project_config.PageGuideConfig,
) !void {
    try out.appendSlice(allocator, "{\"lsp\":");
    try appendSettingsGroup(allocator, out, lsp);
    try out.appendSlice(allocator, ",\"wysiwyg\":");
    try appendSettingsGroup(allocator, out, wysiwyg);
    try out.appendSlice(allocator, ",\"pageGuide\":");
    try appendSettingsGroup(allocator, out, page_guide);
    try out.append(allocator, '}');
}

fn appendSettingsGroup(allocator: std.mem.Allocator, out: *std.ArrayList(u8), settings: anytype) !void {
    try out.append(allocator, '{');
    inline for (std.meta.fields(@TypeOf(settings)), 0..) |field, i| {
        if (i != 0) try out.append(allocator, ',');
        const name = comptime blk: {
            var key_name: []const u8 = "";
            var uppercase = false;
            for (field.name) |byte| {
                if (byte == '_') {
                    uppercase = true;
                } else {
                    key_name = key_name ++ [_]u8{if (uppercase) std.ascii.toUpper(byte) else byte};
                    uppercase = false;
                }
            }
            break :blk key_name;
        };
        try protocol.appendJsonString(allocator, out, name);
        try out.append(allocator, ':');
        switch (field.type) {
            bool => try protocol.appendBool(allocator, out, @field(settings, field.name)),
            u64 => try protocol.appendInt(allocator, out, @field(settings, field.name)),
            else => @compileError("Unsupported project setting type"),
        }
    }
    try out.append(allocator, '}');
}
