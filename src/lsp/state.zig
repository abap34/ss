const std = @import("std");
const project = @import("../project.zig");
const analysis_completion = @import("../analysis/completion.zig");

pub const Snapshot = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    lsp: project.LspConfig = .{},
    preview: project.PreviewConfig = .{},
    page_guide: project.PageGuideConfig = .{},
    dump_json: ?[]u8 = null,
    completion_index: ?analysis_completion.Index = null,
    module_paths: std.ArrayList([]u8),

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        if (self.dump_json) |json| allocator.free(json);
        if (self.completion_index) |*index| index.deinit();
        for (self.module_paths.items) |path| allocator.free(path);
        self.module_paths.deinit(allocator);
    }

    pub fn coversPath(self: *const Snapshot, path: []const u8) bool {
        if (std.mem.eql(u8, self.entry_path, path)) return true;
        for (self.module_paths.items) |module_path| {
            if (std.mem.eql(u8, module_path, path)) return true;
        }
        return false;
    }
};

pub const CompletionCache = struct {
    entry_path: []u8,
    index: analysis_completion.Index,

    pub fn deinit(self: *CompletionCache, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        self.index.deinit();
    }
};

pub const DocumentCompletionCache = struct {
    source_hash: u64,
    index: analysis_completion.Index,

    pub fn deinit(self: *DocumentCompletionCache) void {
        self.index.deinit();
    }
};

pub fn deinitStringSet(allocator: std.mem.Allocator, set: *std.StringHashMap(void)) void {
    var iterator = set.iterator();
    while (iterator.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}

pub fn deinitCompletionIndexMap(allocator: std.mem.Allocator, map: *std.StringHashMap(DocumentCompletionCache)) void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit();
    }
    map.deinit();
}
