const std = @import("std");

pub const Digest = [32]u8;

pub fn document(ir: anytype) Digest {
    var hash = Hash.init("ss-render-ir-document-v1");
    hash.integer(ir.schema_version);
    hash.integer(ir.resources.entries.len);
    for (ir.resources.entries) |resource| {
        hash.tag(resource.kind);
        hash.bytes(&resource.id);
        hashResourceMetadata(&hash, resource.metadata);
    }
    hash.integer(ir.fonts.instances.len);
    for (ir.fonts.instances) |font| {
        hash.bytes(&font.id);
        hash.bytes(&font.resource);
        hash.integer(font.face_index);
        hash.bytes(font.family);
        hash.bytes(font.postscript_name);
        hash.integer(font.weight);
        hash.tag(font.style);
        hash.tag(font.stretch);
        hash.float(font.ascent_ratio);
        hash.float(font.descent_ratio);
        hash.float(font.line_gap_ratio);
        hash.float(font.underline_position_ratio);
        hash.float(font.underline_thickness_ratio);
        hash.float(font.strikethrough_position_ratio);
        hash.float(font.strikethrough_thickness_ratio);
        if (font.math) |constants| {
            hash.boolean(true);
            inline for (std.meta.fields(@TypeOf(constants))) |field| hash.float(@field(constants, field.name));
        } else hash.boolean(false);
        hash.integer(font.variations.len);
        for (font.variations) |variation| {
            hash.bytes(&variation.tag);
            hash.float(variation.value);
        }
        hash.integer(font.features.len);
        for (font.features) |feature| {
            hash.bytes(&feature.tag);
            hash.integer(feature.value);
        }
        hash.boolean(font.synthetic_bold);
        hash.boolean(font.synthetic_italic);
        hash.boolean(font.family_substitution);
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
        hash.optionalBoolean(node.list_ordered);
        hash.optionalInteger(node.list_start);
        hash.optionalBytes(node.text);
        hash.optionalBytes(node.alt_text);
        hash.optionalBytes(node.language);
        hash.optionalBytes(node.code_language);
        hash.optionalInteger(node.math_tree);
        hash.optionalTag(node.link_kind);
        hash.optionalBytes(node.link_target);
        hash.integer(node.children.len);
        for (node.children) |child| hash.integer(child);
        hash.integer(node.items.len);
        for (node.items) |item| hash.integer(item);
    }
    hash.integer(ir.pages.len);
    for (ir.pages) |*page_value| {
        const digest = pageDigest(page_value, true);
        hash.bytes(&digest);
    }
    return hash.final();
}

fn hashResourceMetadata(hash: *Hash, metadata: anytype) void {
    hash.tag(metadata);
    switch (metadata) {
        .font => |value| hash.boolean(value.collection),
        .raster => |value| {
            hash.integer(value.pixel_width);
            hash.integer(value.pixel_height);
            hash.integer(value.oriented_width);
            hash.integer(value.oriented_height);
            hash.tag(value.orientation);
            hash.tag(value.color_space);
            hash.boolean(value.has_alpha);
            hash.tag(value.interpolation);
        },
        .svg => |value| {
            hash.float(value.width);
            hash.float(value.height);
            if (value.view_box) |view_box| {
                hash.boolean(true);
                hash.float(view_box.x);
                hash.float(view_box.y);
                hash.float(view_box.width);
                hash.float(view_box.height);
            } else hash.boolean(false);
            hash.tag(value.alignment);
            hash.tag(value.scale);
        },
        .pdf, .math_pdf => |value| {
            hash.boolean(value.encrypted);
            hash.boolean(value.has_javascript);
            hash.integer(value.pages.len);
            for (value.pages) |page_metadata| {
                hashPdfBox(hash, page_metadata.media);
                hashPdfBox(hash, page_metadata.crop);
                hashPdfBox(hash, page_metadata.bleed);
                hashPdfBox(hash, page_metadata.trim);
                hashPdfBox(hash, page_metadata.art);
                hash.float(page_metadata.user_unit);
                hash.integer(page_metadata.rotation);
                hash.integer(page_metadata.annotation_count);
                hash.boolean(page_metadata.has_unsafe_annotations);
            }
        },
    }
}

fn hashPdfBox(hash: *Hash, box: anytype) void {
    hash.float(box.left);
    hash.float(box.bottom);
    hash.float(box.right);
    hash.float(box.top);
}

pub fn page(page_value: anytype) Digest {
    return pageDigest(page_value, false);
}

fn pageDigest(page_value: anytype, comptime include_metadata: bool) Digest {
    var hash = Hash.init("ss-render-ir-page-v1");
    if (include_metadata) {
        hash.integer(page_value.page_id);
        hash.integer(page_value.index);
        hash.bytes(page_value.name);
    }
    hash.float(page_value.width);
    hash.float(page_value.height);
    hash.integer(page_value.items.items.len);
    for (page_value.items.items) |item| {
        hash.tag(item);
        hashHeader(&hash, item.header(), include_metadata);
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
            .vector_path => |value| {
                hashPathCommands(&hash, value.commands);
                hashFill(&hash, value.fill);
                hash.boolean(value.stroke != null);
                if (value.stroke) |stroke| hashStroke(&hash, stroke);
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
                if (include_metadata) hash.integer(value.tree);
                hash.tag(value.content);
                switch (value.content) {
                    .structured => |structured| {
                        hashColor(&hash, structured.color);
                        const layout = structured.layout;
                        hash.float(layout.width);
                        hash.float(layout.height);
                        hash.float(layout.baseline);
                        hash.integer(layout.elements.len);
                        for (layout.elements) |element| {
                            hash.tag(element);
                            switch (element) {
                                .text => |text| {
                                    if (include_metadata) hash.integer(text.node);
                                    hash.float(text.x);
                                    hash.float(text.y);
                                    hash.float(text.font_size);
                                    hashTextLayout(&hash, text.layout);
                                },
                                .rule => |rule| {
                                    if (include_metadata) hash.integer(rule.node);
                                    hashRect(&hash, rule.rect);
                                },
                            }
                        }
                    },
                    .raw_pdf => |raw| {
                        hash.bytes(&raw.resource);
                        hash.integer(raw.page_index);
                        hash.tag(raw.box);
                    },
                }
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
    if (include_metadata) {
        hash.integer(page_value.reading_order.len);
        for (page_value.reading_order) |semantic_id| hash.integer(semantic_id);
    }
    return hash.final();
}

fn hashPathCommands(hash: *Hash, commands: anytype) void {
    hash.integer(commands.len);
    for (commands) |command| {
        hash.tag(command);
        switch (command) {
            .move_to, .line_to => |point| hashPoint(hash, point),
            .cubic_to => |cubic| {
                hashPoint(hash, cubic.control1);
                hashPoint(hash, cubic.control2);
                hashPoint(hash, cubic.end);
            },
            .close => {},
        }
    }
}

fn hashFill(hash: *Hash, fill: anytype) void {
    hash.tag(fill.base);
    switch (fill.base) {
        .none => {},
        .solid => |color| hashColor(hash, color),
        .linear => |gradient| {
            hashPoint(hash, gradient.start);
            hashPoint(hash, gradient.end);
            hashStops(hash, gradient.stops);
            hash.tag(gradient.spread);
        },
        .radial => |gradient| {
            hashPoint(hash, gradient.start_center);
            hash.float(gradient.start_radius);
            hashPoint(hash, gradient.end_center);
            hash.float(gradient.end_radius);
            hashStops(hash, gradient.stops);
            hash.tag(gradient.spread);
        },
    }
    hash.boolean(fill.overlay != null);
    if (fill.overlay) |pattern| {
        hashPathCommands(hash, pattern.commands);
        hash.float(pattern.cell_width);
        hash.float(pattern.cell_height);
        hashTransform(hash, pattern.transform);
        hashOptionalColor(hash, pattern.fill);
        hash.boolean(pattern.stroke != null);
        if (pattern.stroke) |stroke| hashStroke(hash, stroke);
    }
    hash.tag(fill.rule);
    hash.float(fill.opacity);
}

fn hashStops(hash: *Hash, stops: anytype) void {
    hash.integer(stops.len);
    for (stops) |stop| {
        hash.float(stop.offset);
        hashColor(hash, stop.color);
    }
}

fn hashStroke(hash: *Hash, stroke: anytype) void {
    hashColor(hash, stroke.color);
    hash.float(stroke.width);
    hash.tag(stroke.cap);
    hash.tag(stroke.join);
    hash.float(stroke.miter_limit);
    hash.integer(stroke.dash.len);
    for (stroke.dash) |entry| hash.float(entry);
    hash.float(stroke.dash_offset);
}

fn hashHeader(hash: *Hash, header: anytype, comptime include_metadata: bool) void {
    if (include_metadata) {
        hash.integer(header.item_id);
        hash.optionalInteger(header.node_id);
        if (header.source) |source| {
            hash.boolean(true);
            hash.integer(source.module_id);
            hash.integer(source.start);
            hash.integer(source.end);
        } else hash.boolean(false);
        hash.optionalInteger(header.semantic_id);
        hashRect(hash, header.bounds);
        hashRect(hash, header.ink_bounds);
        hash.integer(header.paint_index);
    }
    hashTransform(hash, header.transform);
    if (header.clip) |clip| {
        hash.boolean(true);
        hash.tag(clip);
        switch (clip) {
            .rect => |rect| hashRect(hash, rect),
        }
    } else hash.boolean(false);
    hash.float(header.opacity);
    hash.tag(header.blend_mode);
}

fn hashTransform(hash: *Hash, transform: anytype) void {
    hash.float(transform.xx);
    hash.float(transform.yx);
    hash.float(transform.xy);
    hash.float(transform.yy);
    hash.float(transform.x0);
    hash.float(transform.y0);
}

fn hashText(hash: *Hash, value: anytype) void {
    hash.float(value.x);
    hash.float(value.y);
    hash.float(value.width);
    hash.float(value.font_size);
    hashColor(hash, value.color);
    hashTextLayout(hash, value.layout);
}

fn hashTextLayout(hash: *Hash, layout: anytype) void {
    hash.bytes(layout.source_text);
    hashRect(hash, layout.logical_bounds);
    hashRect(hash, layout.ink_bounds);
    hash.integer(layout.lines.len);
    for (layout.lines) |line| {
        hashRange(hash, line.source);
        hashRange(hash, line.run_range);
        hash.float(line.baseline_y);
        hashRect(hash, line.logical_bounds);
        hashRect(hash, line.ink_bounds);
    }
    hash.integer(layout.runs.len);
    for (layout.runs) |run| {
        hashRange(hash, run.source);
        hashRange(hash, run.glyph_range);
        hashRange(hash, run.cluster_range);
        hash.float(run.x);
        hash.float(run.baseline_y);
        hash.float(run.advance);
        hash.bytes(&run.font_instance);
        hash.bytes(run.language);
        hash.tag(run.direction);
        hash.integer(run.bidi_level);
    }
    hash.integer(layout.clusters.len);
    for (layout.clusters) |cluster| {
        hashRange(hash, cluster.source);
        hashRange(hash, cluster.glyph_range);
        hash.float(cluster.x);
        hash.float(cluster.baseline_y);
        hash.float(cluster.advance_x);
        hash.float(cluster.advance_y);
        hashRect(hash, cluster.logical_bounds);
        hashRect(hash, cluster.ink_bounds);
    }
    hash.integer(layout.glyphs.len);
    for (layout.glyphs) |glyph| {
        hash.integer(glyph.id);
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

    fn optionalBoolean(self: *Hash, value: ?bool) void {
        if (value) |boolean_value| {
            self.boolean(true);
            self.boolean(boolean_value);
        } else self.boolean(false);
    }

    fn optionalTag(self: *Hash, value: anytype) void {
        if (value) |tag_value| {
            self.boolean(true);
            self.tag(tag_value);
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
