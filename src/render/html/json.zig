const std = @import("std");
const scene = @import("../scene.zig");

pub fn appendDisplay(allocator: std.mem.Allocator, out: *std.ArrayList(u8), document: *const scene.Document) !void {
    try out.appendSlice(allocator, "{\"schemaVersion\":1,\"coordinateSpace\":{\"unit\":\"pt\",\"origin\":\"page-top-left\",\"xAxis\":\"right\",\"yAxis\":\"down\"},\"resources\":[");
    for (document.resources.items, 0..) |resource, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendResource(allocator, out, resource);
    }
    try out.appendSlice(allocator, "],\"pages\":[");
    for (document.pages.items, 0..) |page, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendPage(allocator, out, page);
    }
    try out.appendSlice(allocator, "]}");
}

pub fn appendEmptyDisplay(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "{\"schemaVersion\":1,\"coordinateSpace\":{\"unit\":\"pt\",\"origin\":\"page-top-left\",\"xAxis\":\"right\",\"yAxis\":\"down\"},\"resources\":[],\"pages\":[]}");
}

fn appendResource(allocator: std.mem.Allocator, out: *std.ArrayList(u8), resource: scene.Resource) !void {
    try out.appendSlice(allocator, "{\"id\":");
    try appendInt(allocator, out, resource.id);
    try out.appendSlice(allocator, ",\"kind\":");
    try appendJsonString(allocator, out, resource.kind.name());
    try out.appendSlice(allocator, ",\"path\":");
    try appendJsonString(allocator, out, resource.path);
    try out.appendSlice(allocator, ",\"intrinsicWidth\":");
    try appendFloat(allocator, out, resource.intrinsic_width);
    try out.appendSlice(allocator, ",\"intrinsicHeight\":");
    try appendFloat(allocator, out, resource.intrinsic_height);
    try out.appendSlice(allocator, ",\"tintable\":");
    try appendBool(allocator, out, resource.tintable);
    try out.append(allocator, '}');
}

fn appendPage(allocator: std.mem.Allocator, out: *std.ArrayList(u8), page: scene.Page) !void {
    try out.appendSlice(allocator, "{\"pageId\":");
    try appendInt(allocator, out, page.page_id);
    try out.appendSlice(allocator, ",\"index\":");
    try appendInt(allocator, out, page.index + 1);
    try out.appendSlice(allocator, ",\"frame\":");
    try appendFrame(allocator, out, page.frame);
    try out.appendSlice(allocator, ",\"items\":[");
    for (page.items.items, 0..) |item, index| {
        if (index != 0) try out.append(allocator, ',');
        try appendItem(allocator, out, item);
    }
    try out.appendSlice(allocator, "]}");
}

fn appendItem(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: scene.Item) !void {
    switch (item) {
        .shape => |shape| try appendShapeItem(allocator, out, shape),
        .text => |text| try appendTextItem(allocator, out, text),
        .resource => |resource| try appendResourceItem(allocator, out, resource),
    }
}

fn appendShapeItem(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: scene.ShapeItem) !void {
    try out.appendSlice(allocator, "{\"type\":\"shape\",\"nodeId\":");
    try appendInt(allocator, out, item.node_id orelse 0);
    try out.appendSlice(allocator, ",\"frame\":");
    try appendFrame(allocator, out, item.frame);
    try out.appendSlice(allocator, ",\"fill\":");
    try appendColorOrNull(allocator, out, item.fill);
    try out.appendSlice(allocator, ",\"stroke\":");
    try appendColorOrNull(allocator, out, item.stroke);
    try out.appendSlice(allocator, ",\"lineWidth\":");
    try appendFloat(allocator, out, item.line_width);
    try out.appendSlice(allocator, ",\"radius\":");
    try appendFloat(allocator, out, item.radius);
    try out.appendSlice(allocator, ",\"dash\":");
    if (item.dash) |dash| {
        try out.append(allocator, '[');
        try appendFloat(allocator, out, dash.on);
        try out.append(allocator, ',');
        try appendFloat(allocator, out, dash.off);
        try out.append(allocator, ']');
    } else {
        try out.appendSlice(allocator, "null");
    }
    try out.append(allocator, '}');
}

fn appendTextItem(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: scene.TextItem) !void {
    try out.appendSlice(allocator, "{\"type\":\"text\",\"nodeId\":");
    try appendInt(allocator, out, item.node_id);
    try out.appendSlice(allocator, ",\"frame\":");
    try appendFrame(allocator, out, item.frame);
    try out.appendSlice(allocator, ",\"lines\":[");
    var first_line = true;
    for (item.lines.items) |line| {
        if (!first_line) try out.append(allocator, ',');
        first_line = false;
        try out.appendSlice(allocator, "{\"baselineY\":");
        try appendFloat(allocator, out, line.baseline_y);
        try out.appendSlice(allocator, ",\"lineHeight\":");
        try appendFloat(allocator, out, line.line_height);
        try out.appendSlice(allocator, ",\"spans\":[");
        for (line.spans.items, 0..) |span, span_index| {
            if (span_index != 0) try out.append(allocator, ',');
            try appendTextSpan(allocator, out, span);
        }
        try out.appendSlice(allocator, "]}");
    }
    try out.appendSlice(allocator, "]}");
}

fn appendTextSpan(allocator: std.mem.Allocator, out: *std.ArrayList(u8), span: scene.TextSpan) !void {
    switch (span) {
        .glyphs => |glyphs| {
            try out.appendSlice(allocator, "{\"kind\":\"glyphs\",\"x\":");
            try appendFloat(allocator, out, glyphs.x);
            try out.appendSlice(allocator, ",\"text\":");
            try appendJsonString(allocator, out, glyphs.text);
            try out.appendSlice(allocator, ",\"fontFamily\":");
            try appendJsonString(allocator, out, glyphs.font.family);
            try out.appendSlice(allocator, ",\"fontWeight\":");
            try appendInt(allocator, out, glyphs.font.weight);
            try out.appendSlice(allocator, ",\"fontStyle\":");
            try appendJsonString(allocator, out, @tagName(glyphs.font.style));
            try out.appendSlice(allocator, ",\"fontSize\":");
            try appendFloat(allocator, out, glyphs.font_size);
            try out.appendSlice(allocator, ",\"color\":");
            try appendColorOrNull(allocator, out, glyphs.color);
            try out.appendSlice(allocator, ",\"linkUrl\":");
            if (glyphs.link_url) |url| try appendJsonString(allocator, out, url) else try out.appendSlice(allocator, "null");
            try out.appendSlice(allocator, ",\"strikethrough\":");
            try appendBool(allocator, out, glyphs.strikethrough);
            try out.append(allocator, '}');
        },
        .resource => |resource| {
            try out.appendSlice(allocator, "{\"kind\":\"resource\",\"x\":");
            try appendFloat(allocator, out, resource.x);
            try out.appendSlice(allocator, ",\"y\":");
            try appendFloat(allocator, out, resource.y);
            try out.appendSlice(allocator, ",\"width\":");
            try appendFloat(allocator, out, resource.width);
            try out.appendSlice(allocator, ",\"height\":");
            try appendFloat(allocator, out, resource.height);
            try out.appendSlice(allocator, ",\"resourceId\":");
            try appendInt(allocator, out, resource.resource_id);
            try out.appendSlice(allocator, ",\"tint\":");
            try appendColorOrNull(allocator, out, resource.tint);
            try out.appendSlice(allocator, ",\"linkUrl\":");
            if (resource.link_url) |url| try appendJsonString(allocator, out, url) else try out.appendSlice(allocator, "null");
            try out.append(allocator, '}');
        },
    }
}

fn appendResourceItem(allocator: std.mem.Allocator, out: *std.ArrayList(u8), item: scene.ResourceItem) !void {
    try out.appendSlice(allocator, "{\"type\":\"resource\",\"nodeId\":");
    try appendInt(allocator, out, item.node_id);
    try out.appendSlice(allocator, ",\"resourceId\":");
    try appendInt(allocator, out, item.resource_id);
    try out.appendSlice(allocator, ",\"frame\":");
    try appendFrame(allocator, out, item.frame);
    try out.appendSlice(allocator, ",\"tint\":");
    try appendColorOrNull(allocator, out, item.tint);
    try out.appendSlice(allocator, ",\"clip\":");
    try appendBool(allocator, out, item.clip);
    try out.append(allocator, '}');
}

fn appendFrame(allocator: std.mem.Allocator, out: *std.ArrayList(u8), frame: scene.Frame) !void {
    try out.appendSlice(allocator, "{\"x\":");
    try appendFloat(allocator, out, frame.x);
    try out.appendSlice(allocator, ",\"y\":");
    try appendFloat(allocator, out, frame.y);
    try out.appendSlice(allocator, ",\"width\":");
    try appendFloat(allocator, out, frame.width);
    try out.appendSlice(allocator, ",\"height\":");
    try appendFloat(allocator, out, frame.height);
    try out.append(allocator, '}');
}

fn appendColorOrNull(allocator: std.mem.Allocator, out: *std.ArrayList(u8), maybe: ?scene.Color) !void {
    const color = maybe orelse {
        try out.appendSlice(allocator, "null");
        return;
    };
    try out.append(allocator, '[');
    try appendFloat(allocator, out, color.r);
    try out.append(allocator, ',');
    try appendFloat(allocator, out, color.g);
    try out.append(allocator, ',');
    try appendFloat(allocator, out, color.b);
    try out.append(allocator, ']');
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const escaped = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(escaped);
    try out.appendSlice(allocator, escaped);
}

fn appendInt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendFloat(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: f32) !void {
    const text = try std.fmt.allocPrint(allocator, "{d:.4}", .{value});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendBool(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: bool) !void {
    try out.appendSlice(allocator, if (value) "true" else "false");
}
