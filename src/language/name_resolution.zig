const std = @import("std");
const ast = @import("ast");
const core = @import("core");

pub const Name = struct {
    qualifier: ?[]const u8 = null,
    name: []const u8,
};

pub const OpenImport = struct {
    unqualified: bool,
    selected: []const ast.ImportDecl.SelectedName = &.{},
    module_id: ?core.SourceModuleId,

    fn selects(self: OpenImport, name: []const u8, resolver: anytype) bool {
        for (self.selected) |item| {
            if (!shouldContinue(resolver)) return false;
            if (std.mem.eql(u8, item.name, name)) return true;
        }
        return false;
    }
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

    fn push(self: *ModuleVisitStack, module_id: core.SourceModuleId) bool {
        for (self.items[0..self.len]) |item| if (item == module_id) return false;
        if (self.len >= self.items.len) return false;
        self.items[self.len] = module_id;
        self.len += 1;
        return true;
    }

    fn pop(self: *ModuleVisitStack) void {
        self.len -= 1;
    }
};

pub fn resolve(comptime Resolved: type, resolver: anytype, current_module_id: core.SourceModuleId, name: Name) Resolution(Resolved) {
    if (!shouldContinue(resolver)) return .unknown;
    if (name.qualifier) |alias| {
        const module_id = resolver.resolveAlias(current_module_id, alias) orelse return .{ .unknown_alias = alias };
        return resolveExport(Resolved, resolver, module_id, name.name);
    }

    var stack = ModuleVisitStack{};
    switch (resolveInModule(Resolved, resolver, current_module_id, name.name, .open, &stack)) {
        .found => |resolved| return .{ .found = resolved },
        else => {},
    }
    var index = resolver.implicitImportCount(current_module_id);
    while (index > 0) {
        if (!shouldContinue(resolver)) return .unknown;
        index -= 1;
        const imported_id = resolver.implicitImport(current_module_id, index) orelse continue;
        switch (resolveInModule(Resolved, resolver, imported_id, name.name, .open, &stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    return .unknown;
}

/// A module exports its declarations and explicitly selected imported names.
/// Resolution returns the original declaration, including its defining module.
pub fn resolveExport(comptime Resolved: type, resolver: anytype, module_id: core.SourceModuleId, name: []const u8) Resolution(Resolved) {
    var stack = ModuleVisitStack{};
    return resolveInModule(Resolved, resolver, module_id, name, .exports, &stack);
}

const Visibility = enum { exports, open };

fn resolveInModule(
    comptime Resolved: type,
    resolver: anytype,
    module_id: core.SourceModuleId,
    name: []const u8,
    visibility: Visibility,
    stack: *ModuleVisitStack,
) Resolution(Resolved) {
    if (!shouldContinue(resolver) or !stack.push(module_id)) return .unknown;
    defer stack.pop();
    if (resolver.findInModule(module_id, name)) |resolved| return .{ .found = resolved };

    // Selected imports create local bindings, ahead of names from open imports.
    var index = resolver.explicitImportCount(module_id);
    while (index > 0) {
        if (!shouldContinue(resolver)) return .unknown;
        index -= 1;
        const import_info = resolver.explicitImport(module_id, index) orelse continue;
        if (!import_info.selects(name, resolver)) continue;
        const imported_id = import_info.module_id orelse continue;
        switch (resolveInModule(Resolved, resolver, imported_id, name, .exports, stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    if (visibility == .exports) return .unknown;

    index = resolver.explicitImportCount(module_id);
    while (index > 0) {
        if (!shouldContinue(resolver)) return .unknown;
        index -= 1;
        const import_info = resolver.explicitImport(module_id, index) orelse continue;
        if (!import_info.unqualified) continue;
        const imported_id = import_info.module_id orelse continue;
        switch (resolveInModule(Resolved, resolver, imported_id, name, .open, stack)) {
            .found => |resolved| return .{ .found = resolved },
            else => {},
        }
    }
    return .unknown;
}

fn shouldContinue(resolver: anytype) bool {
    if (@hasDecl(@TypeOf(resolver), "shouldContinue")) return resolver.shouldContinue();
    return true;
}
