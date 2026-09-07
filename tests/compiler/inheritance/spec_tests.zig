const std = @import("std");
const compiler = @import("compiler");
const core = compiler.core;
const testing = std.testing;

fn documentFromSource(source: []const u8) !core.DocumentState {
    const allocator = testing.allocator;
    var owned_source = try allocator.dupe(u8, source);
    defer allocator.free(owned_source);
    var syntax = try compiler.syntax.parseWithSourceName(allocator, owned_source, "inheritance-spec.ss");
    defer syntax.deinit(allocator);
    var index = compiler.analysis.ModuleIndex{
        .module_graph = .{
            .allocator = allocator,
            .modules = .empty,
            .module_order = .empty,
            .project_implicit_import_ids = .empty,
            .project_import_ids = .empty,
        },
        .constants = core.ConstMap.init(allocator),
        .functions = core.FunctionMap.init(allocator),
    };
    defer index.deinit();
    return compiler.analysis.buildDocumentState(allocator, "inheritance-spec.ss", ".", &owned_source, &syntax, &index);
}

fn expectCycle(source: []const u8, members: []const []const u8) !void {
    var state = try documentFromSource(source);
    defer state.deinit();
    try testing.expectError(error.InvalidType, compiler.analysis.analyzeDocumentState(testing.allocator, &state));

    var cycle_diagnostics: usize = 0;
    for (state.diagnostics.items) |diagnostic| {
        const message = switch (diagnostic.data) {
            .user_report => |report| report.message,
            else => continue,
        };
        if (!std.mem.startsWith(u8, message, "ObjectInheritanceCycle:")) continue;
        cycle_diagnostics += 1;
    }
    try testing.expectEqual(members.len, cycle_diagnostics);
    for (members) |name| {
        for (state.projectModule().syntax.objects.items) |decl| {
            if (!std.mem.eql(u8, name, decl.name)) continue;
            const expected_origin = try std.fmt.allocPrint(testing.allocator, "path:inheritance-spec.ss:bytes:{d}-{d}", .{ decl.span.start, decl.span.end });
            defer testing.allocator.free(expected_origin);
            var found = false;
            for (state.diagnostics.items) |diagnostic| {
                if (diagnostic.origin) |origin| {
                    if (std.mem.eql(u8, origin, expected_origin)) found = true;
                }
            }
            try testing.expect(found);
        }
    }
}

test "inheritance spec: unused self inheritance is rejected at its declaration" {
    try expectCycle(
        \\type Recursive = object {
        \\  base = Recursive
        \\}
        \\page main
        \\end
    , &.{"Recursive"});
}

test "inheritance spec: mutually recursive bases report every cycle member" {
    try expectCycle(
        \\type Child = object {
        \\  base = First
        \\}
        \\type First = object {
        \\  base = Second
        \\}
        \\type Second = object {
        \\  base = First
        \\}
    , &.{ "First", "Second" });
}

test "inheritance spec: unvalidated cyclic fields terminate in analysis and core" {
    var state = try documentFromSource(
        \\type First = object {
        \\  base = Second
        \\  roles = ["recursive"]
        \\  value: Number = 42
        \\}
        \\type Second = object {
        \\  base = First
        \\}
    );
    defer state.deinit();
    var index = try compiler.declarations.build(testing.allocator, &state);
    defer index.deinit();
    try testing.expect(index.field(.{ .module_id = 0, .name = "Second" }, "missing") == null);
    try testing.expect(index.field(.{ .module_id = 0, .name = "Second" }, "value") != null);

    const node = core.Node{ .id = 0, .kind = .object, .name = "recursive", .role = "recursive" };
    try testing.expect(try core.fields.get(testing.allocator, &state, &node, "missing") == null);
    var value = (try core.fields.get(testing.allocator, &state, &node, "value")).?;
    defer value.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 42), value.value.number);
}

test "inheritance spec: long acyclic base chains preserve inherited defaults" {
    var source = std.ArrayList(u8).empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator,
        \\type Base0 = object {
        \\  value: Number = 42
        \\}
        \\
    );
    for (1..65) |id| {
        const declaration = try std.fmt.allocPrint(testing.allocator, "type Base{d} = object {{\n  base = Base{d}\n}}\n", .{ id, id - 1 });
        defer testing.allocator.free(declaration);
        try source.appendSlice(testing.allocator, declaration);
    }
    try source.appendSlice(testing.allocator,
        \\type Leaf = object {
        \\  base = Base64
        \\  roles = ["leaf"]
        \\}
    );
    var state = try documentFromSource(source.items);
    defer state.deinit();
    try compiler.analysis.analyzeDocumentState(testing.allocator, &state);
    var index = try compiler.declarations.build(testing.allocator, &state);
    defer index.deinit();
    try testing.expectEqualStrings("Base0", index.field(.{ .module_id = 0, .name = "Leaf" }, "value").?.class_name);
    const node = core.Node{ .id = 0, .kind = .object, .name = "leaf", .role = "leaf" };
    var value = (try core.fields.get(testing.allocator, &state, &node, "value")).?;
    defer value.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 42), value.value.number);
}
