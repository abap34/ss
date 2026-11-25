const std = @import("std");
const utils = @import("utils");
const packages = @import("project").packages;
const loader = @import("../../modules/loader.zig");
const types = @import("types.zig");
const Import = @import("completion_position.zig").Import;

const max_entries = 2048;
const max_candidates = 512;

const Builder = struct {
    allocator: std.mem.Allocator,
    req: types.SourceRequest,
    edit_start: utils.source.Utf16Position,
    edit_end: utils.source.Utf16Position,
    path: Import,
    budget: types.QueryBudget,
    items: std.ArrayList(types.CompletionCandidate) = .empty,
    strings: std.ArrayList([]const u8) = .empty,
    incomplete: bool = false,

    fn deinit(self: *Builder) void {
        self.items.deinit(self.allocator);
        for (self.strings.items) |string| self.allocator.free(string);
        self.strings.deinit(self.allocator);
    }

    fn retain(self: *Builder, text: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.strings.append(self.allocator, owned);
        return owned;
    }

    fn exhausted(self: *Builder) bool {
        if (self.budget.expired() or self.items.items.len >= max_candidates) {
            self.incomplete = true;
            return true;
        }
        return false;
    }

    fn add(self: *Builder, name: []const u8, kind: types.CompletionKind) !void {
        if (!std.mem.startsWith(u8, name, self.path.prefix) or self.exhausted()) return;
        // Quotes and escapes would need a different source spelling. Never
        // suggest a path that cannot be inserted verbatim as an import spec.
        if (std.mem.indexOfAny(u8, name, "\"\\\r\n") != null) return;
        if (!self.path.quoted and std.mem.indexOfAny(u8, name, " \t") != null) return;
        for (self.items.items) |item| if (std.mem.eql(u8, item.label, name)) return;
        const label = try self.retain(name);
        const text = if (self.path.quoted and !self.path.closed and kind != .folder) blk: {
            const closed = try std.fmt.allocPrint(self.allocator, "{s}\"", .{name});
            defer self.allocator.free(closed);
            break :blk try self.retain(closed);
        } else label;
        try self.items.append(self.allocator, .{
            .label = label,
            .kind = kind,
            .detail = if (kind == .folder) "module directory" else "module",
            .text_edit = .{
                .start = self.edit_start,
                .end = self.edit_end,
                .text = text,
            },
        });
    }

    fn files(self: *Builder, io: std.Io, base: []const u8, relative: []const u8, spec_base: []const u8) !void {
        const slash = std.mem.lastIndexOfScalar(u8, relative, '/');
        const prefix = if (slash) |index| relative[0 .. index + 1] else "";
        const directory = try std.fs.path.resolve(self.allocator, &.{ base, prefix });
        defer self.allocator.free(directory);
        var dir = utils.fs.openDir(io, directory, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var iterator = dir.iterate();
        var visited: usize = 0;
        while (!self.exhausted()) {
            if (visited == max_entries) {
                self.incomplete = true;
                break;
            }
            const entry = (iterator.next(io) catch break) orelse break;
            visited += 1;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            const is_dir = entry.kind == .directory;
            if (!is_dir and !std.mem.endsWith(u8, entry.name, ".ss")) continue;
            if (!is_dir and std.mem.eql(u8, directory, std.fs.path.dirname(self.req.path) orelse ".") and std.mem.eql(u8, entry.name, std.fs.path.basename(self.req.path))) continue;
            const stem = if (is_dir) entry.name else entry.name[0 .. entry.name.len - 3];
            // Package submodule syntax excludes a file extension.
            if (spec_base.len != 0) {
                if (!packages.manifest.validRelativePath(stem)) continue;
                if (!is_dir and std.fs.path.extension(stem).len != 0) continue;
            }
            const name = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}{s}", .{ spec_base, prefix, stem, if (is_dir) "/" else "" });
            defer self.allocator.free(name);
            try self.add(name, if (is_dir) .folder else .module);
        }
    }

    fn packageImports(self: *Builder, io: std.Io, project_file: ?[]const u8) !void {
        if (!std.mem.startsWith(u8, "pkg:", self.path.prefix) and !std.mem.startsWith(u8, self.path.prefix, "pkg:")) return;
        const base = std.fs.path.dirname(self.req.path) orelse ".";
        var resolver = packages.resolve.Resolver.init(self.allocator, io, base, null);
        defer resolver.deinit();
        resolver.config_path = project_file;
        if (std.mem.indexOfScalar(u8, self.path.prefix, '/')) |slash| {
            const name = self.path.prefix[4..slash];
            const relative = self.path.prefix[slash + 1 ..];
            const trimmed = std.mem.trimEnd(u8, relative, "/");
            if (relative.len != 0 and !packages.manifest.validRelativePath(trimmed)) return;
            if (std.mem.indexOfScalar(u8, relative, '\\') != null or std.mem.indexOf(u8, relative, "//") != null) return;
            const source = resolver.packageSource(base, name) catch |err| return ignoreUnavailable(err);
            if (!self.exhausted()) try self.files(io, source.directory, relative, self.path.prefix[0 .. slash + 1]);
        } else {
            const names = resolver.dependencyNames(base) catch |err| return ignoreUnavailable(err);
            for (names) |name| {
                if (self.exhausted()) break;
                const spec = try std.fmt.allocPrint(self.allocator, "pkg:{s}/", .{name});
                defer self.allocator.free(spec);
                try self.add(spec[0 .. spec.len - 1], .module);
                try self.add(spec, .folder);
            }
        }
    }
};

pub fn complete(allocator: std.mem.Allocator, req: types.SourceRequest, path: Import, project_file: ?[]const u8, opts: types.QueryOptions) !types.CompletionResult {
    var builder = Builder{ .allocator = allocator, .req = req, .path = path, .edit_start = utils.source.utf16PositionAt(req.source, path.span.start), .edit_end = utils.source.utf16PositionAt(req.source, path.span.end), .budget = types.QueryBudget.start(opts) };
    defer builder.deinit();
    for (loader.standard_module_specs) |spec| {
        if (builder.exhausted()) break;
        try builder.add(spec, .module);
    }
    if (opts.io) |io| {
        if (!builder.exhausted()) try builder.packageImports(io, project_file);
        if (std.mem.indexOfScalar(u8, path.prefix, ':') == null and !builder.exhausted())
            try builder.files(io, std.fs.path.dirname(req.path) orelse ".", path.prefix, "");
    }
    if (builder.budget.canceled()) return .{ .items = try allocator.alloc(types.CompletionCandidate, 0) };
    std.mem.sort(types.CompletionCandidate, builder.items.items, {}, struct {
        fn less(_: void, a: types.CompletionCandidate, b: types.CompletionCandidate) bool {
            return std.mem.lessThan(u8, a.label, b.label);
        }
    }.less);
    const items = try builder.items.toOwnedSlice(allocator);
    errdefer allocator.free(items);
    return .{ .items = items, .owned_strings = try builder.strings.toOwnedSlice(allocator), .is_incomplete = builder.incomplete };
}

// Invalid or unavailable project/package data gives no package candidates. Other
// providers still contribute; allocation failures retain their normal contract.
fn ignoreUnavailable(err: anyerror) error{OutOfMemory}!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
}
