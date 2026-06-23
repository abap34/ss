const std = @import("std");
const ast = @import("ast");
const core = @import("core");

const semantic_env = @import("../language/env.zig");

const SemanticEnv = semantic_env.SemanticEnv;

const NameResolutionKey = struct {
    module_id: core.SourceModuleId,
    qualifier: ?[]const u8,
    name: []const u8,
};

const NameResolutionKeyContext = struct {
    pub fn hash(_: NameResolutionKeyContext, key: NameResolutionKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.module_id));
        if (key.qualifier) |qualifier| {
            hasher.update(&.{1});
            hasher.update(qualifier);
        } else {
            hasher.update(&.{0});
        }
        hasher.update(key.name);
        return hasher.final();
    }

    pub fn eql(_: NameResolutionKeyContext, left: NameResolutionKey, right: NameResolutionKey) bool {
        if (left.module_id != right.module_id) return false;
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (left.qualifier == null or right.qualifier == null) return left.qualifier == null and right.qualifier == null;
        return std.mem.eql(u8, left.qualifier.?, right.qualifier.?);
    }
};

const FunctionResolutionMap = std.HashMap(NameResolutionKey, ?semantic_env.ResolvedFunction, NameResolutionKeyContext, std.hash_map.default_max_load_percentage);
const ConstResolutionMap = std.HashMap(NameResolutionKey, ?semantic_env.ResolvedConst, NameResolutionKeyContext, std.hash_map.default_max_load_percentage);

pub const NameResolutionCache = struct {
    functions: FunctionResolutionMap,
    constants: ConstResolutionMap,

    pub fn init(allocator: std.mem.Allocator) NameResolutionCache {
        return .{
            .functions = FunctionResolutionMap.init(allocator),
            .constants = ConstResolutionMap.init(allocator),
        };
    }

    pub fn deinit(self: *NameResolutionCache) void {
        self.constants.deinit();
        self.functions.deinit();
    }

    pub fn reserve(self: *NameResolutionCache, ir: *const core.Ir) !void {
        try self.functions.ensureTotalCapacity(@intCast(ir.functions.count() * 2));
        try self.constants.ensureTotalCapacity(@intCast(ir.constants.count() * 2));
    }

    pub fn resolvedFunction(self: *NameResolutionCache, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedFunction {
        const key = resolutionKey(sema, callee);
        if (self.functions.get(key)) |cached| return cached;
        const resolved = sema.resolvedFunction(callee);
        try self.functions.put(key, resolved);
        return resolved;
    }

    pub fn resolvedConst(self: *NameResolutionCache, sema: *const SemanticEnv, callee: ast.CallableName) !?semantic_env.ResolvedConst {
        const key = resolutionKey(sema, callee);
        if (self.constants.get(key)) |cached| return cached;
        const resolved = sema.resolvedConst(callee);
        try self.constants.put(key, resolved);
        return resolved;
    }
};

fn resolutionKey(sema: *const SemanticEnv, callee: ast.CallableName) NameResolutionKey {
    return .{
        .module_id = sema.module_id,
        .qualifier = callee.qualifier,
        .name = callee.name,
    };
}
