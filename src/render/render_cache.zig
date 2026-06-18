const std = @import("std");
const scene = @import("scene.zig");
const cache_key = @import("cache").key;

pub const page_pdf_cache_version = "ss-scene-page-pdf-v1";
pub const deck_cache_version = "ss-scene-deck-v1";

pub fn deckId(allocator: std.mem.Allocator, document: *const scene.Document, cache_id: ?[]const u8) ![]u8 {
    var key = cache_key.Builder{};
    key.string(deck_cache_version);
    if (cache_id) |id| {
        key.string("explicit");
        key.string(id);
    } else {
        key.string("document");
        key.putUsize(document.pages.items.len);
        for (document.pages.items) |page| {
            key.putU64(page.page_id);
            key.string(page.label);
        }
    }
    return cache_key.directoryName(allocator, "deck", key.finish());
}

pub fn pageHash(document: *const scene.Document, page: *const scene.Page) u64 {
    var key = cache_key.Builder{};
    key.string(page_pdf_cache_version);
    key.putU64(page.page_id);
    key.putUsize(page.index);
    hashFrame(&key, page.frame);
    key.putUsize(page.items.items.len);
    for (page.items.items) |item| hashItem(&key, document, item);
    return key.finish();
}

pub fn pagePath(allocator: std.mem.Allocator, pages_dir: []const u8, page_index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/page-{d:0>4}.pdf", .{ pages_dir, page_index + 1 });
}

fn hashItem(key: *cache_key.Builder, document: *const scene.Document, item: scene.Item) void {
    switch (item) {
        .shape => |shape| {
            key.string("shape");
            key.putBool(shape.node_id != null);
            if (shape.node_id) |id| key.putU64(id);
            hashFrame(key, shape.frame);
            hashOptionalColor(key, shape.fill);
            hashOptionalColor(key, shape.stroke);
            key.putF32(shape.line_width);
            key.putF32(shape.radius);
            key.putBool(shape.dash != null);
            if (shape.dash) |dash| {
                key.putF32(dash.on);
                key.putF32(dash.off);
            }
            key.putBool(shape.clip);
        },
        .text => |text| {
            key.string("text");
            key.putU64(text.node_id);
            hashFrame(key, text.frame);
            key.putBool(text.clip);
            key.putUsize(text.lines.items.len);
            for (text.lines.items) |line| {
                key.putF32(line.baseline_y);
                key.putF32(line.line_height);
                key.putUsize(line.spans.items.len);
                for (line.spans.items) |span| hashTextSpan(key, document, span);
            }
        },
        .resource => |resource| {
            key.string("resource");
            key.putU64(resource.node_id);
            key.putU32(resource.resource_id);
            hashResourceReference(key, document, resource.resource_id);
            hashFrame(key, resource.frame);
            hashOptionalColor(key, resource.tint);
            key.putBool(resource.clip);
            key.optionalString(resource.link_id);
        },
    }
}

fn hashTextSpan(key: *cache_key.Builder, document: *const scene.Document, span: scene.TextSpan) void {
    switch (span) {
        .glyphs => |glyphs| {
            key.string("glyphs");
            key.putF32(glyphs.x);
            key.string(glyphs.text);
            key.string(glyphs.font.family);
            key.putU32(glyphs.font.weight);
            key.putU32(@intFromEnum(glyphs.font.style));
            key.putU32(@intFromEnum(glyphs.font.stretch));
            key.putF32(glyphs.font_size);
            hashColor(key, glyphs.color);
            key.optionalString(glyphs.link_url);
            key.putBool(glyphs.strikethrough);
        },
        .resource => |resource| {
            key.string("inline-resource");
            key.putF32(resource.x);
            key.putF32(resource.y);
            key.putF32(resource.width);
            key.putF32(resource.height);
            key.putU32(resource.resource_id);
            hashResourceReference(key, document, resource.resource_id);
            hashOptionalColor(key, resource.tint);
            key.optionalString(resource.link_url);
        },
    }
}

fn hashResourceReference(key: *cache_key.Builder, document: *const scene.Document, id: scene.ResourceId) void {
    key.putBool(document.resourceById(id) != null);
    const resource = document.resourceById(id) orelse return;
    key.putU32(id);
    key.string(@tagName(resource.kind));
    key.string(resource.logical_key);
    key.string(resource.path);
    key.putF32(resource.intrinsic_width);
    key.putF32(resource.intrinsic_height);
    key.putBool(resource.tintable);
}

fn hashFrame(key: *cache_key.Builder, frame: scene.Frame) void {
    key.putF32(frame.x);
    key.putF32(frame.y);
    key.putF32(frame.width);
    key.putF32(frame.height);
}

fn hashOptionalColor(key: *cache_key.Builder, maybe: ?scene.Color) void {
    key.putBool(maybe != null);
    if (maybe) |color| hashColor(key, color);
}

fn hashColor(key: *cache_key.Builder, color: scene.Color) void {
    key.putF32(color.r);
    key.putF32(color.g);
    key.putF32(color.b);
}
