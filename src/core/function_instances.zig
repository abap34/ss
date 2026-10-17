const std = @import("std");
const ast = @import("ast");
const model = @import("model");

pub const Key = struct {
    definition: model.FunctionKey,
    arguments: []const ast.Type,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u64 {
        var hasher = std.hash.Wyhash.init((model.FunctionKeyContext{}).hash(key.definition));
        std.hash.autoHash(&hasher, key.arguments.len);
        for (key.arguments) |argument| argument.hashInto(&hasher);
        return hasher.final();
    }

    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        if (!a.definition.eql(b.definition) or a.arguments.len != b.arguments.len) return false;
        for (a.arguments, b.arguments) |left, right| if (!ast.Type.eql(left, right)) return false;
        return true;
    }
};

pub const Instance = struct {
    key: Key,
    declaration: ast.FunctionDecl,
    status: enum { checking, checked, failed } = .checking,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(*Instance) = .empty,
    index: std.HashMap(Key, u32, KeyContext, std.hash_map.default_max_load_percentage),
    call_targets: std.AutoHashMap(u64, model.FunctionKey),
    next_call_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .index = .init(allocator), .call_targets = .init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        self.index.deinit();
        self.call_targets.deinit();
        for (self.entries.items) |entry| {
            for (entry.key.arguments) |argument| {
                var owned = argument;
                owned.deinit(self.allocator);
            }
            self.allocator.free(entry.key.arguments);
            entry.declaration.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn find(self: *const Store, key: Key) ?*Instance {
        return self.entries.items[self.index.get(key) orelse return null];
    }

    pub fn isChecking(self: *const Store, definition: model.FunctionKey) bool {
        for (self.entries.items) |entry| {
            if (entry.status == .checking and entry.key.definition.eql(definition)) return true;
        }
        return false;
    }

    /// Takes ownership of declaration only on success; argument types are cloned.
    pub fn add(self: *Store, key: Key, declaration: ast.FunctionDecl) !*Instance {
        const arguments = try self.allocator.alloc(ast.Type, key.arguments.len);
        errdefer self.allocator.free(arguments);
        var initialized: usize = 0;
        errdefer for (arguments[0..initialized]) |*argument| argument.deinit(self.allocator);
        for (key.arguments, arguments) |argument, *copy| {
            copy.* = try argument.clone(self.allocator);
            initialized += 1;
        }
        const entry = try self.allocator.create(Instance);
        errdefer self.allocator.destroy(entry);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const id: u32 = @intCast(self.entries.items.len);
        entry.* = .{ .key = .{ .definition = key.definition, .arguments = arguments }, .declaration = declaration };
        entry.declaration.instance_id = id;
        try self.index.put(entry.key, id);
        self.entries.appendAssumeCapacity(entry);
        return entry;
    }
};
