const std = @import("std");

const JsonValue = std.json.Value;
pub const JsonObject = std.json.ObjectMap;
const JsonArray = std.json.Array;

pub const RequestContext = struct {
    target: []u8,
    doc_path: []u8,
    source: []const u8,
    offset: usize,

    pub fn deinit(self: *RequestContext, allocator: std.mem.Allocator) void {
        allocator.free(self.target);
        allocator.free(self.doc_path);
    }
};

const SourceScope = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
};

pub fn bestVisibleVariable(allocator: std.mem.Allocator, root: *const JsonObject, target: []const u8, context: *const RequestContext) ?*const JsonObject {
    var best: ?*const JsonObject = null;
    var best_rank: usize = 0;
    if (arrayFieldObject(root, "variables")) |variables| for (variables.items) |*item| if (item.* == .object) {
        const object = &item.object;
        if (!std.mem.eql(u8, stringField(object, "name") orelse "", target)) continue;
        if (!variableVisibleAt(allocator, root, object, context)) continue;
        const rank = visibleRank(object);
        if (best == null or rank >= best_rank) {
            best = object;
            best_rank = rank;
        }
    };
    return best;
}

pub fn isBestVisibleVariable(allocator: std.mem.Allocator, root: *const JsonObject, item: *const JsonObject, context: *const RequestContext) bool {
    const name = stringField(item, "name") orelse return false;
    const best = bestVisibleVariable(allocator, root, name, context) orelse return false;
    return best == item;
}

pub fn variableVisibleAt(allocator: std.mem.Allocator, root: *const JsonObject, item: *const JsonObject, context: *const RequestContext) bool {
    return itemMatchesRequest(allocator, root, item, context) and scopeMatchesRequest(allocator, root, item, context) and itemRangeContains(item, context.offset);
}

pub fn bestVisibleDefinition(allocator: std.mem.Allocator, root: *const JsonObject, target: []const u8, context: *const RequestContext) ?*const JsonObject {
    var best: ?*const JsonObject = null;
    var best_rank: usize = 0;
    if (arrayFieldObject(root, "definitions")) |definitions| for (definitions.items) |*item| if (item.* == .object) {
        const object = &item.object;
        if (!std.mem.eql(u8, stringField(object, "kind") orelse "", "variable")) continue;
        if (!std.mem.eql(u8, stringField(object, "name") orelse "", target)) continue;
        if (!variableVisibleAt(allocator, root, object, context)) continue;
        const rank = visibleRank(object);
        if (best == null or rank >= best_rank) {
            best = object;
            best_rank = rank;
        }
    };
    return best;
}

fn itemRangeContains(item: *const JsonObject, offset: usize) bool {
    const start = usizeField(item, "visibleStart") orelse 0;
    const end = usizeField(item, "visibleEnd") orelse std.math.maxInt(usize);
    return offset >= start and offset <= end;
}

fn visibleRank(item: *const JsonObject) usize {
    return usizeField(item, "spanStart") orelse usizeField(item, "visibleStart") orelse 0;
}

pub fn usizeField(object: *const JsonObject, key: []const u8) ?usize {
    const value = intField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn itemMatchesRequest(allocator: std.mem.Allocator, root: *const JsonObject, item: *const JsonObject, context: *const RequestContext) bool {
    if (stringField(item, "file")) |file| return samePath(allocator, file, context.doc_path);
    const module_id = intField(item, "moduleId") orelse return true;
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |module| if (module == .object) {
        if ((intField(&module.object, "id") orelse -1) != module_id) continue;
        const path = stringField(&module.object, "path") orelse return true;
        return samePath(allocator, path, context.doc_path);
    };
    return true;
}

fn scopeMatchesRequest(allocator: std.mem.Allocator, root: *const JsonObject, item: *const JsonObject, context: *const RequestContext) bool {
    const item_kind = stringField(item, "scopeKind") orelse return true;
    const request_scope = requestScope(allocator, root, context);
    if (!std.mem.eql(u8, item_kind, request_scope.kind)) return false;
    const item_name = stringField(item, "scopeName");
    if (request_scope.name) |name| return std.mem.eql(u8, item_name orelse @as([]const u8, ""), name);
    return item_name == null;
}

fn requestScope(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) SourceScope {
    const module = requestModule(allocator, root, context) orelse return .{ .kind = "document" };
    const program = objectFieldObject(module, "program") orelse return .{ .kind = "document" };
    if (arrayFieldObject(program, "functions")) |functions| for (functions.items) |item| if (item == .object) {
        if (!spanContains(&item.object, context.offset)) continue;
        return .{
            .kind = "function",
            .name = stringField(&item.object, "name"),
        };
    };
    if (arrayFieldObject(program, "pages")) |pages| for (pages.items) |item| if (item == .object) {
        if (!spanContains(&item.object, context.offset)) continue;
        return .{
            .kind = "page",
            .name = stringField(&item.object, "name"),
        };
    };
    return .{ .kind = "document" };
}

fn requestModule(allocator: std.mem.Allocator, root: *const JsonObject, context: *const RequestContext) ?*const JsonObject {
    if (arrayFieldObject(root, "modules")) |modules| for (modules.items) |*module| if (module.* == .object) {
        const path = stringField(&module.object, "path") orelse continue;
        if (samePath(allocator, path, context.doc_path)) return &module.object;
    };
    return null;
}

fn spanContains(item: *const JsonObject, offset: usize) bool {
    const span = objectFieldObject(item, "span") orelse return false;
    const start = usizeField(span, "start") orelse return false;
    const end = usizeField(span, "end") orelse return false;
    return offset >= start and offset <= end;
}

pub fn stringField(object: *const JsonObject, key: []const u8) ?[]const u8 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return if (value.* == .string) value.string else null;
}

pub fn intField(object: *const JsonObject, key: []const u8) ?i64 {
    const value = @constCast(object).getPtr(key) orelse return null;
    return switch (value.*) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => null,
    };
}

fn objectFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonObject {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .object) return null;
    return &child.object;
}

fn arrayFieldObject(object: *const JsonObject, key: []const u8) ?*const JsonArray {
    const child = @constCast(object).getPtr(key) orelse return null;
    if (child.* != .array) return null;
    return &child.array;
}

fn samePath(allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = absolutePath(allocator, left) catch return false;
    defer allocator.free(a);
    const b = absolutePath(allocator, right) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}

fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len) == null) return error.CurrentWorkingDirectoryUnavailable;
    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse return error.NameTooLong;
    return allocator.dupe(u8, buffer[0..len]);
}
