const std = @import("std");
const core = @import("core");
const Type = @import("ast").Type;
const TypeInfo = @import("types.zig").TypeInfo;

pub const Key = struct {
    function: core.FunctionKey,
    arguments: []const TypeInfo,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init((core.FunctionKeyContext{}).hash(key.function));
        std.hash.autoHash(&hasher, key.arguments.len);
        for (key.arguments) |argument| {
            // Full type equality below handles recursive structure and normalized parameters.
            std.hash.autoHash(&hasher, argument.ty.kind);
            std.hash.autoHash(&hasher, argument.ty.nominal_module_id);
            std.hash.autoHash(&hasher, argument.ty.param_module_id);
            std.hash.autoHash(&hasher, if (argument.object_class) |id| @as(?u32, id.module_id) else null);
            hashString(&hasher, if (argument.object_class) |id| id.name else null);
            hashString(&hasher, argument.string_literal);
            std.hash.autoHash(&hasher, if (argument.hole) |hole| @as(?u32, hole.hole_id) else null);
            std.hash.autoHash(&hasher, argument.function_labels.len);
            for (argument.function_labels) |label| hashString(&hasher, label);
        }
        return hasher.final();
    }

    pub fn eql(_: KeyContext, left: Key, right: Key) bool {
        if (!(core.FunctionKeyContext{}).eql(left.function, right.function)) return false;
        if (left.arguments.len != right.arguments.len) return false;
        for (left.arguments, right.arguments) |a, b| {
            if (!Type.eql(a.ty, b.ty) or !core.NominalId.optionalEql(a.object_class, b.object_class) or
                !stringEql(a.string_literal, b.string_literal) or a.function_labels.len != b.function_labels.len)
            {
                return false;
            }
            if ((a.hole == null) != (b.hole == null)) return false;
            if (a.hole) |hole| {
                if (hole.hole_id != b.hole.?.hole_id or (hole.expected == null) != (b.hole.?.expected == null)) return false;
                if (hole.expected) |expected| {
                    if (!Type.eql(expected, b.hole.?.expected.?)) return false;
                }
            }
            for (a.function_labels, b.function_labels) |a_label, b_label| {
                if (!std.mem.eql(u8, a_label, b_label)) return false;
            }
        }
        return true;
    }

    fn hashString(hasher: *std.hash.Wyhash, value: ?[]const u8) void {
        std.hash.autoHash(hasher, value != null);
        if (value) |text| {
            std.hash.autoHash(hasher, text.len);
            hasher.update(text);
        }
    }

    fn stringEql(a: ?[]const u8, b: ?[]const u8) bool {
        if ((a == null) != (b == null)) return false;
        return if (a) |value| std.mem.eql(u8, value, b.?) else true;
    }
};

// Entries borrow types and facts from one immutable analysis generation.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    results: std.HashMap(Key, TypeInfo, KeyContext, std.hash_map.default_max_load_percentage),
    visiting: std.HashMap(core.FunctionKey, void, core.FunctionKeyContext, std.hash_map.default_max_load_percentage),
    body_analyses: usize = 0,
    cache_hits: usize = 0,
    recursive_calls: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .results = .init(allocator),
            .visiting = .init(allocator),
        };
    }

    pub fn deinit(self: *Cache) void {
        var keys = self.results.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.arguments);
        self.results.deinit();
        self.visiting.deinit();
    }

    pub fn get(self: *Cache, key: Key) ?TypeInfo {
        const result = self.results.get(key) orelse return null;
        self.cache_hits += 1;
        return result;
    }

    pub fn put(self: *Cache, key: Key, result: TypeInfo) !void {
        const arguments = try self.allocator.dupe(TypeInfo, key.arguments);
        errdefer self.allocator.free(arguments);
        try self.results.putNoClobber(.{ .function = key.function, .arguments = arguments }, result);
    }
};
