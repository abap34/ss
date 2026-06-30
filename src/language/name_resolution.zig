const core = @import("core");

pub const Name = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

pub const OpenImport = struct {
    unqualified: bool,
    module_id: ?core.SourceModuleId,
};

pub fn Resolution(comptime Resolved: type) type {
    return union(enum) {
        found: Resolved,
        unknown,
        unknown_alias: []const u8,
    };
}

const ModuleVisitStack = struct {
    items: [256]core.SourceModuleId = undefined,
    len: usize = 0,

    fn contains(self: *const ModuleVisitStack, module_id: core.SourceModuleId) bool {
        for (self.items[0..self.len]) |item| {
            if (item == module_id) return true;
        }
        return false;
    }

    fn push(self: *ModuleVisitStack, module_id: core.SourceModuleId) bool {
        if (self.contains(module_id) or self.len >= self.items.len) return false;
        self.items[self.len] = module_id;
        self.len += 1;
        return true;
    }

    fn pop(self: *ModuleVisitStack) void {
        if (self.len > 0) self.len -= 1;
    }
};

pub fn resolve(comptime Resolved: type, resolver: anytype, current_module_id: core.SourceModuleId, name: Name) Resolution(Resolved) {
    if (name.qualifier) |alias| {
        const module_id = resolver.resolveAlias(current_module_id, alias) orelse return .{ .unknown_alias = alias };
        return if (resolver.findInModule(module_id, name.name)) |resolved|
            .{ .found = resolved }
        else
            .unknown;
    }

    if (resolver.findInModule(current_module_id, name.name)) |resolved| return .{ .found = resolved };

    switch (resolveExplicitOpen(Resolved, resolver, current_module_id, name.name)) {
        .found => |resolved| return .{ .found = resolved },
        else => {},
    }
    switch (resolveImplicitOpen(Resolved, resolver, current_module_id, name.name)) {
        .found => |resolved| return .{ .found = resolved },
        else => return .unknown,
    }
}

fn resolveExplicitOpen(comptime Resolved: type, resolver: anytype, module_id: core.SourceModuleId, name: []const u8) Resolution(Resolved) {
    var index = resolver.explicitImportCount(module_id);
    while (index > 0) {
        index -= 1;
        const import_info = resolver.explicitImport(module_id, index) orelse continue;
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        var stack = ModuleVisitStack{};
        switch (resolveOpenInModule(Resolved, resolver, imported_id, name, &stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    return .unknown;
}

fn resolveImplicitOpen(comptime Resolved: type, resolver: anytype, module_id: core.SourceModuleId, name: []const u8) Resolution(Resolved) {
    var index = resolver.implicitImportCount(module_id);
    while (index > 0) {
        index -= 1;
        const imported_id = resolver.implicitImport(module_id, index) orelse continue;
        var stack = ModuleVisitStack{};
        switch (resolveOpenInModule(Resolved, resolver, imported_id, name, &stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    return .unknown;
}

fn resolveOpenInModule(
    comptime Resolved: type,
    resolver: anytype,
    module_id: core.SourceModuleId,
    name: []const u8,
    stack: *ModuleVisitStack,
) Resolution(Resolved) {
    if (!stack.push(module_id)) return .unknown;
    defer stack.pop();

    if (resolver.findInModule(module_id, name)) |resolved| return .{ .found = resolved };

    var index = resolver.explicitImportCount(module_id);
    while (index > 0) {
        index -= 1;
        const import_info = resolver.explicitImport(module_id, index) orelse continue;
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        switch (resolveOpenInModule(Resolved, resolver, imported_id, name, stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    return .unknown;
}
