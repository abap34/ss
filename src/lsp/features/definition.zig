const std = @import("std");
const build_options = @import("build_options");

const analysis_snapshot = @import("../../analysis/snapshot.zig");
const project = @import("../../project.zig");
const utils = @import("utils");
const protocol = @import("../protocol.zig");
const query_budget = @import("../query_budget.zig");
const lsp_state = @import("../state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    provider: *lsp_state.SnapshotProvider,
    documents: *lsp_state.DocumentStore,
};

pub fn result(ctx: *Context, params: ?protocol.JsonValue) ![]const u8 {
    var position = try lsp_state.requestPosition(ctx.allocator, ctx.documents, params) orelse return nullJson(ctx.allocator);
    defer position.deinit(ctx.allocator);
    var owned_snapshot: ?lsp_state.Snapshot = null;
    defer if (owned_snapshot) |*snapshot| snapshot.deinit();
    const snapshot = try ctx.provider.forDocument(position.doc_path, &owned_snapshot) orelse return nullJson(ctx.allocator);
    if (!lsp_state.featureEnabledForSnapshot(snapshot, .definition)) return nullJson(ctx.allocator);
    const targets = try analysis_snapshot.definitionAt(ctx.allocator, snapshot, .{
        .path = position.doc_path,
        .source = position.source,
        .offset = position.offset,
        .source_version = snapshot.generation,
    }, .{ .budget_ms = query_budget.definition_ms });
    defer ctx.allocator.free(targets);
    return json(ctx.allocator, targets);
}

pub fn nullJson(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "null");
}

pub fn json(allocator: std.mem.Allocator, targets: []const analysis_snapshot.DefinitionTarget) ![]const u8 {
    if (targets.len == 0) return nullJson(allocator);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (targets) |target| {
        _ = try appendTarget(allocator, &out, target, &first);
    }
    if (first) {
        out.deinit(allocator);
        return nullJson(allocator);
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn appendTarget(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    target: analysis_snapshot.DefinitionTarget,
    first: *bool,
) !bool {
    var owned_path: ?[]u8 = null;
    defer if (owned_path) |path| allocator.free(path);
    const path = if (target.path) |path|
        path
    else if (target.module_spec) |spec| blk: {
        owned_path = try stdModulePath(allocator, spec);
        break :blk owned_path orelse return false;
    } else return false;

    const uri = try protocol.uriFromPath(allocator, path);
    defer allocator.free(uri);
    if (!first.*) try out.append(allocator, ',');
    first.* = false;
    try protocol.appendLocationObject(
        allocator,
        out,
        uri,
        target.line,
        target.character,
        target.end_line,
        target.end_character,
    );
    return true;
}

fn stdModulePath(allocator: std.mem.Allocator, spec: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, spec, "std:")) return null;
    const module_name = spec["std:".len..];
    if (module_name.len == 0 or std.mem.indexOfScalar(u8, module_name, '\\') != null) return null;
    const relative = try std.fmt.allocPrint(allocator, "{s}.ss", .{module_name});
    defer allocator.free(relative);
    if (try stdModulePathFromEnv(allocator, relative)) |path| return path;
    if (try stdModulePathFromRoot(allocator, build_options.source_stdlib_dir, relative)) |path| return path;
    if (try stdModulePathFromRoot(allocator, build_options.installed_stdlib_dir, relative)) |path| return path;
    return stdModulePathFromRoot(allocator, "stdlib", relative);
}

fn stdModulePathFromEnv(allocator: std.mem.Allocator, relative: []const u8) !?[]u8 {
    const raw = std.c.getenv("SS_STDLIB_DIR") orelse return null;
    const root = std.mem.span(raw);
    return stdModulePathFromRoot(allocator, root, relative);
}

fn stdModulePathFromRoot(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) !?[]u8 {
    if (root.len == 0) return null;
    const joined = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(joined);
    const absolute = try project.absolutePath(allocator, joined);
    errdefer allocator.free(absolute);
    if (utils.fs.fileExists(allocator, absolute)) return absolute;
    allocator.free(absolute);
    return null;
}
