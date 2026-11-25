const std = @import("std");
const utils = @import("utils");
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

    fn files(self: *Builder, io: std.Io) !void {
        const slash = std.mem.lastIndexOfScalar(u8, self.path.prefix, '/');
        const prefix = if (slash) |index| self.path.prefix[0 .. index + 1] else "";
        const base = std.fs.path.dirname(self.req.path) orelse ".";
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
            if (!is_dir and prefix.len == 0 and std.mem.eql(u8, entry.name, std.fs.path.basename(self.req.path))) continue;
            const stem = if (is_dir) entry.name else entry.name[0 .. entry.name.len - 3];
            const name = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ prefix, stem, if (is_dir) "/" else "" });
            defer self.allocator.free(name);
            try self.add(name, if (is_dir) .folder else .module);
        }
    }
};

pub fn complete(allocator: std.mem.Allocator, req: types.SourceRequest, path: Import, opts: types.QueryOptions) !types.CompletionResult {
    var builder = Builder{ .allocator = allocator, .req = req, .path = path, .edit_start = utils.source.utf16PositionAt(req.source, path.span.start), .edit_end = utils.source.utf16PositionAt(req.source, path.span.end), .budget = types.QueryBudget.start(opts) };
    defer builder.deinit();
    for (loader.standard_module_specs) |spec| {
        if (builder.exhausted()) break;
        try builder.add(spec, .module);
    }
    if (std.mem.indexOfScalar(u8, path.prefix, ':') == null and !builder.exhausted()) {
        if (opts.io) |io| try builder.files(io);
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
