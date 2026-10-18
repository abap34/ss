const core = @import("core");
const json = @import("utils").json;
const layout = @import("layout.zig");

pub fn writeField(object: *json.Object, name: []const u8, value: core.Value) !void {
    var field = try object.objectField(name);
    try write(&field, value);
    try field.end();
}

// References remain identities. Following placements or closure environments here
// would duplicate document state and could introduce cycles into the dump.
fn write(object: *json.Object, value: core.Value) anyerror!void {
    try object.stringField("kind", switch (value) {
        .boolean => "bool",
        .enum_case => "enum",
        else => @tagName(value),
    });
    switch (value) {
        .none, .void => {},
        .string => |text| try object.stringField("value", text),
        .number => |number| try object.floatField("value", number, "{d}"),
        .boolean => |boolean| try object.boolField("value", boolean),
        .document, .page, .object => |id| try object.intField("id", id),
        .enum_case => |case| {
            try object.stringField("type", case.enum_name);
            try object.optionalIntField("module", case.module_id);
            try object.stringField("case", case.case_name);
        },
        .record => |record| {
            try core.type_json.writeField(object, "type", record.ty);
            var fields = try object.arrayField("fields");
            for (record.fields.items) |field| {
                var item = try fields.objectItem();
                try item.stringField("name", field.name);
                try item.boolField("explicit", field.explicit);
                try writeField(&item, "value", field.value);
                try item.end();
            }
            try fields.end();
        },
        .group => |group| {
            try core.type_json.writeField(object, "type", group.ty);
            var children = try object.arrayField("children");
            for (group.children.items) |child| {
                var item = try children.objectItem();
                try write(&item, child);
                try item.end();
            }
            try children.end();
        },
        .selection => |selection| {
            try object.enumTagField("item_kind", selection.item_tag);
            var ids = try object.arrayField("ids");
            for (selection.ids.items) |id| try ids.intItem(id);
            try ids.end();
        },
        .function => |function| {
            try object.stringField("name", function.name);
            try object.intField("module", function.module_id);
            try object.optionalIntField("closure", function.closure_id);
        },
        .anchor => |anchor| {
            try object.enumTagField("target_kind", anchor);
            switch (anchor) {
                .page => |target| {
                    try object.intField("id", target.page_id);
                    try object.enumTagField("anchor", target.anchor);
                },
                .node => |target| {
                    try object.intField("id", target.node_id);
                    try object.enumTagField("anchor", target.anchor);
                },
            }
            try object.floatField("offset", anchor.offset(), "{d}");
        },
        .constraints => |constraints| try layout.writeConstraintsField(object, constraints.items.items),
        .path => |path| {
            var commands = try object.arrayField("commands");
            for (path.commands) |command| {
                var item = try commands.objectItem();
                try item.enumTagField("verb", command);
                switch (command) {
                    .move_to, .line_to => |point| try writePoint(&item, "point", point),
                    .cubic_to => |cubic| {
                        try writePoint(&item, "control1", cubic.control1);
                        try writePoint(&item, "control2", cubic.control2);
                        try writePoint(&item, "end", cubic.end);
                    },
                    .close => {},
                }
                try item.end();
            }
            try commands.end();
        },
    }
}

fn writePoint(object: *json.Object, key: []const u8, point: core.PathPoint) !void {
    var field = try object.objectField(key);
    try field.floatField("x", point.x, "{d}");
    try field.floatField("y", point.y, "{d}");
    try field.end();
}
