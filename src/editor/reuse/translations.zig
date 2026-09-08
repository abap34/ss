const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const editor_snapshot = @import("../snapshot.zig");

pub const CollectedTranslations = struct {
    report: ?core.layout.conflicts.Report,
    translations: []editor_snapshot.Translation,

    pub fn deinit(self: *CollectedTranslations, allocator: std.mem.Allocator) void {
        if (self.report) |*report| report.deinit();
        allocator.free(self.translations);
        self.report = null;
        self.translations = &.{};
    }

    pub fn takeReport(self: *CollectedTranslations) core.layout.conflicts.Report {
        const report = self.report orelse unreachable;
        self.report = null;
        return report;
    }
};

pub fn collectTranslations(
    allocator: std.mem.Allocator,
    state: *core.DocumentState,
    previous: *const core.layout.conflicts.Report,
) !?CollectedTranslations {
    var current = try core.layout.conflicts.Report.init(allocator, state);
    var current_owned = true;
    defer if (current_owned) current.deinit();
    if (current.failure_count != 0 or
        current.pages.len != previous.pages.len or
        current.objects.len != previous.objects.len)
    {
        return null;
    }

    const tolerance: f32 = core.layout.graph.ConstraintTolerance;
    for (current.pages) |page| {
        const old = previous.pageById(page.id) orelse return null;
        if (@abs(page.width - old.width) > tolerance or
            @abs(page.height - old.height) > tolerance)
        {
            return null;
        }
    }

    var translations = std.ArrayList(editor_snapshot.Translation).empty;
    defer translations.deinit(allocator);
    for (current.objects) |object| {
        const old = previous.objectById(object.id) orelse return null;
        if (object.page_id != old.page_id or
            @abs(object.width - old.width) > tolerance or
            @abs(object.height - old.height) > tolerance)
        {
            return null;
        }
        const x = object.x - old.x;
        const y = old.y - object.y;
        if (@abs(x) <= tolerance and @abs(y) <= tolerance) continue;
        try translations.append(allocator, .{
            .node_id = object.id,
            .x = x,
            .y = y,
        });
    }
    const owned_translations = try translations.toOwnedSlice(allocator);
    current_owned = false;
    return .{
        .report = current,
        .translations = owned_translations,
    };
}

pub fn hasExternalRenderDependency(
    pages: *const core.prepared.PreparedPages,
    highlight_languages: []const utils.highlight.Language,
) bool {
    for (highlight_languages) |language| {
        if (!isBuiltinHighlightQuery(language.query)) return true;
    }
    for (pages.pages) |page| {
        for (page.objects) |object| {
            for (object.latex_preamble) |entry| {
                if (entry.source == .file) return true;
            }
            switch (object.render.kind) {
                .raster_asset => return true,
                .vector_asset => {
                    if (core.fontawesome.parseSource(object.content) == null) return true;
                },
                else => {},
            }
            for (object.asset_deps) |dependency| switch (dependency.kind) {
                .vector_pdf, .raster_asset => return true,
                else => {},
            };
        }
    }
    return false;
}

fn isBuiltinHighlightQuery(query: []const u8) bool {
    for (utils.highlight.builtin_languages) |language| {
        if (std.mem.eql(u8, language.query, query)) return true;
    }
    return false;
}

pub fn translationPatchPreservesRenderedOutput(
    state: *core.DocumentState,
    pages: *const core.prepared.PreparedPages,
    translations: []const editor_snapshot.Translation,
    highlight_languages: []const utils.highlight.Language,
) bool {
    if (state.has_external_evaluation_inputs or
        hasExternalRenderDependency(pages, highlight_languages))
    {
        return false;
    }

    for (state.nodes.items) |*node| {
        if (node.kind != .object or !node.attached or node.discarded) continue;
        const render = core.render_policy.resolve(state, node);
        if (render.kind != .connector and render.connector == null) continue;
        if (hasTranslationForNode(translations, node.id)) return false;
        if (render.connector) |connector| {
            if (hasTranslationForNode(translations, connector.source) or
                hasTranslationForNode(translations, connector.target))
            {
                return false;
            }
        }
    }

    for (pages.pages) |page| {
        for (page.objects) |object| {
            if (!hasTranslationForNode(translations, object.node_id)) continue;
            if (object.render.vector_path) |path| {
                if (vectorFillUsesPageSpace(path.fill)) return false;
                if (path.marker_start) |marker| {
                    if (vectorFillUsesPageSpace(marker.fill)) return false;
                }
                if (path.marker_end) |marker| {
                    if (vectorFillUsesPageSpace(marker.fill)) return false;
                }
            }
            // Link and destination annotations have no node id, so they
            // cannot follow their owning object through a node translation.
            if (object.link_id) |link_id| {
                if (link_id.len != 0) return false;
            }
            if (preparedObjectHasLink(object)) return false;
        }
    }
    return true;
}

fn vectorFillUsesPageSpace(fill: core.render_policy.VectorFillPaint) bool {
    if (fill.space == .page) return true;
    if (fill.pattern) |pattern| return pattern.space == .page;
    return false;
}

fn hasTranslationForNode(
    translations: []const editor_snapshot.Translation,
    node_id: core.NodeId,
) bool {
    for (translations) |translation| {
        if (translation.node_id == node_id) return true;
    }
    return false;
}

fn preparedObjectHasLink(object: core.prepared.PreparedObject) bool {
    if (object.text_layout) |layout| {
        if (markdownLinesHaveLink(layout.lines.items)) return true;
    }
    if (object.markdown_doc) |document| {
        if (markdownBlocksHaveLink(document.blocks.items)) return true;
    }
    return false;
}

fn markdownBlocksHaveLink(blocks: []const *core.markdown.Block) bool {
    for (blocks) |block| {
        switch (block.kind) {
            .paragraph, .heading, .code_block => if (block.paragraph) |paragraph| {
                if (markdownLinesHaveLink(paragraph.lines.items)) return true;
            },
            .block_quote => if (block.quote) |quote| {
                if (markdownBlocksHaveLink(quote.blocks.items)) return true;
            },
            .bullet_list, .ordered_list => if (block.list) |list| {
                for (list.items.items) |item| {
                    if (markdownBlocksHaveLink(item.blocks.items)) return true;
                }
            },
            .table => if (block.table) |table| {
                for (table.rows.items) |row| {
                    for (row.cells.items) |cell| {
                        if (markdownLinesHaveLink(cell.lines.items)) return true;
                    }
                }
            },
        }
    }
    return false;
}

fn markdownLinesHaveLink(lines: []const core.markdown.Line) bool {
    for (lines) |line| {
        for (line.runs.items) |inline_run| {
            if (inline_run.kind == .link or inline_run.url != null) return true;
        }
    }
    return false;
}
