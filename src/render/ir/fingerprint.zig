const std = @import("std");

pub const Digest = [32]u8;

pub fn document(ir: anytype) Digest {
    var hash = Hash.init("ss-render-ir-document-v1");
    hash.integer(ir.schema_version);
    hash.integer(ir.resources.entries.len);
    for (ir.resources.entries) |resource| {
        hash.tag(resource.kind);
        hash.bytes(&resource.id);
    }
    hash.integer(ir.math.trees.len);
    for (ir.math.trees) |tree| {
        hash.integer(tree.id);
        hash.tag(tree.input_kind);
        hash.bytes(tree.source);
        hash.integer(tree.root);
        hash.integer(tree.nodes.len);
        for (tree.nodes) |node| {
            hash.integer(node.id);
            hash.tag(node.kind);
            hash.optionalBytes(node.text);
            hash.integer(node.children.len);
            for (node.children) |child| hash.integer(child);
        }
    }
    hash.optionalInteger(ir.semantics.root);
    hash.integer(ir.semantics.nodes.len);
    for (ir.semantics.nodes) |node| {
        hash.integer(node.id);
        hash.tag(node.role);
        hash.optionalInteger(node.heading_level);
        hash.optionalBytes(node.text);
        hash.optionalBytes(node.alt_text);
        hash.integer(node.children.len);
        for (node.children) |child| hash.integer(child);
        hash.integer(node.items.len);
        for (node.items) |item| hash.integer(item);
    }
    hash.integer(ir.pages.len);
    for (ir.pages) |*page_value| {
        const digest = pageDigest(page_value);
        hash.bytes(&digest);
    }
    return hash.final();
}

pub fn page(page_value: anytype) Digest {
    return pageDigest(page_value);
}

fn pageDigest(page_value: anytype) Digest {
    var hash = Hash.init("ss-render-ir-page-v1");
    hash.integer(page_value.page_id);
    hash.integer(page_value.index);
    hash.float(page_value.width);
    hash.float(page_value.height);
    hash.integer(page_value.items.items.len);
    for (page_value.items.items) |item| {
        hash.tag(item);
        hashHeader(&hash, item.header());
        switch (item) {
            .fill_rect => |value| {
                hashRect(&hash, value.rect);
                hashColor(&hash, value.color);
            },
            .stroke_line => |value| {
                hashPoint(&hash, value.start);
                hashPoint(&hash, value.end);
                hash.float(value.line_width);
                hashColor(&hash, value.color);
                hash.float(value.dash_on);
                hash.float(value.dash_off);
            },
            .rounded_rect => |value| {
                hashRect(&hash, value.rect);
                hash.float(value.radius);
                hashOptionalColor(&hash, value.fill);
                hashOptionalColor(&hash, value.stroke);
                hash.float(value.line_width);
            },
            .text => |value| hashText(&hash, value),
            .raster => |value| {
                hashRect(&hash, value.rect);
                hash.bytes(&value.resource);
            },
            .svg => |value| {
                hashRect(&hash, value.rect);
                hash.bytes(&value.resource);
                hashOptionalColor(&hash, value.tint);
            },
            .math => |value| {
                hashRect(&hash, value.rect);
                hash.integer(value.tree);
                hash.bytes(&value.pdf_resource);
                hash.integer(value.page_index);
                hash.tag(value.box);
            },
            .pdf_page => |value| {
                hashRect(&hash, value.rect);
                hash.bytes(&value.resource);
                hash.integer(value.page_index);
                hash.tag(value.box);
                hash.boolean(value.copy_annotations);
            },
        }
    }
    hash.integer(page_value.links.items.len);
    for (page_value.links.items) |link| {
        hash.tag(link.kind);
        hash.bytes(link.target);
        hashRect(&hash, link.rect);
    }
    hash.integer(page_value.destinations.items.len);
    for (page_value.destinations.items) |destination| {
        hash.bytes(destination.name);
        hashPoint(&hash, destination.point);
    }
    hash.integer(page_value.reading_order.len);
    for (page_value.reading_order) |semantic_id| hash.integer(semantic_id);
    return hash.final();
}

fn hashHeader(hash: *Hash, header: anytype) void {
    hash.integer(header.item_id);
    hash.optionalInteger(header.node_id);
    hash.optionalInteger(header.semantic_id);
    hashRect(hash, header.bounds);
    hashRect(hash, header.ink_bounds);
    hash.float(header.transform.xx);
    hash.float(header.transform.yx);
    hash.float(header.transform.xy);
    hash.float(header.transform.yy);
    hash.float(header.transform.x0);
    hash.float(header.transform.y0);
    if (header.clip) |clip| {
        hash.boolean(true);
        hash.tag(clip);
        switch (clip) {
            .rect => |rect| hashRect(hash, rect),
        }
    } else hash.boolean(false);
    hash.float(header.opacity);
    hash.integer(header.paint_index);
}

fn hashText(hash: *Hash, value: anytype) void {
    hash.float(value.x);
    hash.float(value.y);
    hash.float(value.width);
    hash.integer(value.font_weight);
    hash.tag(value.font_style);
    hash.tag(value.font_stretch);
    hash.float(value.font_size);
    hashColor(hash, value.color);
    hash.boolean(value.wrap);
    hash.boolean(value.preserve_color_glyphs);
    hash.bytes(value.layout.source_text);
    hashRect(hash, value.layout.logical_bounds);
    hashRect(hash, value.layout.ink_bounds);
    hash.integer(value.layout.lines.len);
    for (value.layout.lines) |line| {
        hashRange(hash, line.source);
        hashRange(hash, line.run_range);
        hash.float(line.baseline_y);
        hashRect(hash, line.logical_bounds);
        hashRect(hash, line.ink_bounds);
    }
    hash.integer(value.layout.runs.len);
    for (value.layout.runs) |run| {
        hashRange(hash, run.source);
        hashRange(hash, run.glyph_range);
        hashRange(hash, run.cluster_range);
        hash.float(run.x);
        hash.float(run.baseline_y);
        hash.float(run.advance);
        hash.bytes(run.font_family);
        if (run.font_resource) |resource| {
            hash.boolean(true);
            hash.bytes(&resource);
        } else hash.boolean(false);
        hash.integer(run.font_index);
        hash.bytes(run.font_postscript_name);
    }
    hash.integer(value.layout.clusters.len);
    for (value.layout.clusters) |cluster| {
        hashRange(hash, cluster.source);
        hashRange(hash, cluster.glyph_range);
        hash.float(cluster.x);
        hash.float(cluster.advance);
    }
    hash.integer(value.layout.glyphs.len);
    for (value.layout.glyphs) |glyph| {
        hash.integer(glyph.id);
        hash.integer(glyph.source_index);
        hash.float(glyph.offset_x);
        hash.float(glyph.offset_y);
        hash.float(glyph.advance_x);
        hash.float(glyph.advance_y);
    }
}

fn hashRange(hash: *Hash, range: anytype) void {
    hash.integer(range.start);
    hash.integer(range.end);
}

fn hashRect(hash: *Hash, rect: anytype) void {
    hash.float(rect.x);
    hash.float(rect.y);
    hash.float(rect.width);
    hash.float(rect.height);
}

fn hashPoint(hash: *Hash, point: anytype) void {
    hash.float(point.x);
    hash.float(point.y);
}

fn hashColor(hash: *Hash, color: anytype) void {
    hash.float(color.r);
    hash.float(color.g);
    hash.float(color.b);
}

fn hashOptionalColor(hash: *Hash, value: anytype) void {
    if (value) |color| {
        hash.boolean(true);
        hashColor(hash, color);
    } else hash.boolean(false);
}

const Hash = struct {
    state: std.crypto.hash.sha2.Sha256,

    fn init(domain: []const u8) Hash {
        var result = Hash{ .state = std.crypto.hash.sha2.Sha256.init(.{}) };
        result.bytes(domain);
        return result;
    }

    fn final(self: *Hash) Digest {
        var digest: Digest = undefined;
        self.state.final(&digest);
        return digest;
    }

    fn bytes(self: *Hash, value: []const u8) void {
        self.integer(value.len);
        self.state.update(value);
    }

    fn optionalBytes(self: *Hash, value: ?[]const u8) void {
        if (value) |bytes_value| {
            self.boolean(true);
            self.bytes(bytes_value);
        } else self.boolean(false);
    }

    fn boolean(self: *Hash, value: bool) void {
        self.state.update(if (value) &.{1} else &.{0});
    }

    fn integer(self: *Hash, value: anytype) void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, @intCast(value), .little);
        self.state.update(&buffer);
    }

    fn optionalInteger(self: *Hash, value: anytype) void {
        if (value) |integer_value| {
            self.boolean(true);
            self.integer(integer_value);
        } else self.boolean(false);
    }

    fn float(self: *Hash, value: anytype) void {
        const wide: f64 = @floatCast(value);
        self.integer(@as(u64, @bitCast(wide)));
    }

    fn tag(self: *Hash, value: anytype) void {
        self.bytes(@tagName(value));
    }
};
