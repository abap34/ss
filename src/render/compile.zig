const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const declarations = @import("../language/declarations.zig");
const semantic_env = @import("../language/env.zig");
const input = @import("input.zig");
const scene = @import("scene.zig");
const html_render = @import("html.zig");
const text_layout = @import("text/layout.zig");
const markdown_layout = @import("text/markdown.zig");
const highlight = @import("text/highlight.zig");
const artifacts = @import("artifacts.zig");
const atoms = @import("text/atoms.zig");

pub const Target = @import("target.zig").Target;

pub const Options = struct {
    target: Target,
    io: std.Io,
    cache_dir: []const u8 = artifacts.default_cache_dir,
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub const HtmlDisplayOptions = struct {
    cache_dir: []const u8 = artifacts.default_cache_dir,
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub fn sceneFromIr(allocator: std.mem.Allocator, ir: *core.Ir, options: Options) !scene.Document {
    var declaration_index = try declarations.build(allocator, ir);
    defer declaration_index.deinit();
    const sema = semantic_env.SemanticEnv.init(ir, &declaration_index, &ir.functions);

    var document_input = try input.build(allocator, ir, &sema);
    defer document_input.deinit(allocator);
    const artifact_context = artifacts.Context{
        .allocator = allocator,
        .io = options.io,
        .asset_base_dir = document_input.asset_base_dir,
        .cache_dir = options.cache_dir,
    };
    return sceneFromInput(allocator, &document_input, artifact_context, options.highlight_languages);
}

pub fn appendHtmlDisplayFromIr(allocator: std.mem.Allocator, out: *std.ArrayList(u8), io: std.Io, ir: *core.Ir, options: HtmlDisplayOptions) !void {
    var document = try sceneFromIr(allocator, ir, .{
        .target = .html,
        .io = io,
        .cache_dir = options.cache_dir,
        .highlight_languages = options.highlight_languages,
    });
    defer document.deinit(allocator);
    try html_render.appendDisplayFromScene(allocator, out, &document);
}

pub fn appendEmptyHtmlDisplay(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try html_render.appendEmptyDisplay(allocator, out);
}

const SceneBuildContext = struct {
    document: *scene.Document,
    artifacts: artifacts.Context,
    highlighting: highlight.Context,
};

fn sceneFromInput(
    allocator: std.mem.Allocator,
    document_input: *const input.DocumentInput,
    artifact_context: artifacts.Context,
    highlight_languages: []const utils.highlight.Language,
) !scene.Document {
    var document = scene.Document{};
    errdefer document.deinit(allocator);
    var build_context = SceneBuildContext{
        .document = &document,
        .artifacts = artifact_context,
        .highlighting = .{
            .io = artifact_context.io,
            .languages = highlight_languages,
        },
    };

    for (document_input.pages.items) |page_input| {
        var page = scene.Page{
            .page_id = page_input.page_id,
            .index = page_input.index,
            .label = page_input.label,
            .frame = toTopLeftPageFrame(page_input.frame),
        };
        errdefer page.deinit(allocator);

        if (page_input.background) |fill| {
            try page.items.append(allocator, .{ .shape = .{
                .node_id = page_input.page_id,
                .frame = page.frame,
                .fill = fill,
            } });
        }

        for (page_input.objects.items) |object| {
            try appendObjectItems(allocator, &build_context, &page, page_input, object);
        }

        try document.pages.append(allocator, page);
    }

    return document;
}

fn appendObjectItems(
    allocator: std.mem.Allocator,
    context: *SceneBuildContext,
    page: *scene.Page,
    page_input: input.PageInput,
    object: input.ObjectInput,
) !void {
    const object_frame = toTopLeftFrame(page_input.frame, object.frame);
    if (object.render.rule.stroke) |stroke| {
        try page.items.append(allocator, .{ .shape = .{
            .node_id = object.node_id,
            .frame = .{
                .x = object_frame.x,
                .y = object_frame.y + @max(object_frame.height / 2.0, 1.5),
                .width = object_frame.width,
                .height = object.render.rule.line_width,
            },
            .stroke = stroke,
            .line_width = object.render.rule.line_width,
            .dash = object.render.rule.dash,
        } });
    }
    if (object.render.chrome.fill != null or object.render.chrome.stroke != null) {
        try page.items.append(allocator, .{ .shape = .{
            .node_id = object.node_id,
            .frame = object_frame,
            .fill = object.render.chrome.fill,
            .stroke = object.render.chrome.stroke,
            .line_width = object.render.chrome.line_width,
            .radius = object.render.chrome.radius,
        } });
    }

    const content_frame = contentFrameForRender(object_frame, object.render);
    switch (object.render.kind) {
        .text => if (object.render.text) |text| try appendTextObject(allocator, context, page, object, content_frame, text),
        .code => if (object.render.text) |text| {
            var code_text = text;
            code_text.font = text.code_font;
            const code_paint = object.render.code orelse defaultCodePaint(code_text.color);
            var item = try text_layout.plainTextItemWithOptions(allocator, object.node_id, content_frame, object.content, code_text, .{
                .font = code_text.code_font,
                .color = code_paint.plain,
                .font_size = code_text.font_size,
                .line_height = code_text.line_height,
                .wrap = false,
                .preserve_leading_space = true,
                .highlighting = .{
                    .context = context.highlighting,
                    .code = code_paint,
                },
            });
            errdefer item.deinit(allocator);
            try page.items.append(allocator, .{ .text = item });
        },
        .vector_math => try appendMathObject(allocator, context, page, object, content_frame),
        .vector_asset => try appendAssetObject(allocator, context, page, object, content_frame, .vector_image),
        .raster_asset => try appendAssetObject(allocator, context, page, object, content_frame, .raster_image),
        .chrome_only => {},
    }
}

fn appendTextObject(
    allocator: std.mem.Allocator,
    context: *SceneBuildContext,
    page: *scene.Page,
    object: input.ObjectInput,
    frame: scene.Frame,
    text: core.render_policy.TextPaint,
) !void {
    const resolver = text_layout.ResourceResolver{
        .context = context,
        .appendMath = appendInlineMathAtom,
        .appendIcon = appendInlineIconAtom,
        .appendDisplayMathBlock = appendDisplayMathBlock,
    };
    switch (object.parse_mode) {
        .none => return,
        .block => try markdown_layout.appendMarkdownText(allocator, page, object.node_id, frame, object.content, text, object.tex_preamble, resolver, context.highlighting),
        .inline_text => {
            var layout = try core.markdown.parseTextLayoutContent(allocator, object.content);
            defer layout.deinit(allocator);
            var item = try text_layout.textItemFromLines(allocator, object.node_id, frame, layout.lines.items, text, text.wrap, object.tex_preamble, resolver);
            errdefer item.deinit(allocator);
            try page.items.append(allocator, .{ .text = item });
        },
    }
}

fn appendMathObject(
    allocator: std.mem.Allocator,
    context: *SceneBuildContext,
    page: *scene.Page,
    object: input.ObjectInput,
    frame: scene.Frame,
) !void {
    const paint = object.render.math orelse defaultMathPaint();
    var generated = try artifacts.generate(context.artifacts, .{ .math_svg = .{
        .source = object.content,
        .preamble = object.tex_preamble,
        .mode = object.math_kind,
        .color_sensitive = false,
    } });
    defer generated.deinit(allocator);
    const resource_id = try artifacts.addResource(allocator, &context.document.resources, generated);
    const fitted = fitMathBlockSize(generated.intrinsic_width, generated.intrinsic_height, frame.width, frame.height, object.content, paint);
    try page.items.append(allocator, .{ .resource = .{
        .node_id = object.node_id,
        .resource_id = resource_id,
        .frame = .{
            .x = alignedX(frame.x, frame.width, fitted.width, paint.horizontal_align),
            .y = frame.y + @max((frame.height - fitted.height) / 2.0, 0),
            .width = fitted.width,
            .height = fitted.height,
        },
        .tint = paint.color,
        .clip = true,
        .link_id = object.link_id,
    } });
}

fn appendAssetObject(
    allocator: std.mem.Allocator,
    context: *SceneBuildContext,
    page: *scene.Page,
    object: input.ObjectInput,
    frame: scene.Frame,
    comptime tag: std.meta.Tag(artifacts.Request),
) !void {
    var generated = switch (tag) {
        .vector_image => try artifacts.generate(context.artifacts, .{ .vector_image = .{
            .source = object.content,
            .target_width = frame.width,
            .target_height = frame.height,
        } }),
        .raster_image => try artifacts.generate(context.artifacts, .{ .raster_image = .{
            .source = object.content,
            .target_width = frame.width,
            .target_height = frame.height,
        } }),
        else => unreachable,
    };
    defer generated.deinit(allocator);
    const resource_id = try artifacts.addResource(allocator, &context.document.resources, generated);
    const fitted = fitSize(generated.intrinsic_width, generated.intrinsic_height, frame.width, frame.height);
    try page.items.append(allocator, .{ .resource = .{
        .node_id = object.node_id,
        .resource_id = resource_id,
        .frame = .{
            .x = frame.x,
            .y = frame.y + @max((frame.height - fitted.height) / 2.0, 0),
            .width = fitted.width,
            .height = fitted.height,
        },
        .clip = true,
        .link_id = object.link_id,
    } });
}

fn appendInlineMathAtom(
    raw_context: *anyopaque,
    allocator: std.mem.Allocator,
    out_atoms: *std.ArrayList(atoms.Atom),
    source: []const u8,
    preamble: []const core.render_env.TexPreambleEntry,
    mode: input.MathMode,
    text: core.render_policy.TextPaint,
) !void {
    const context: *SceneBuildContext = @ptrCast(@alignCast(raw_context));
    var generated = try artifacts.generate(context.artifacts, .{ .math_svg = .{
        .source = source,
        .preamble = preamble,
        .mode = mode,
        .color_sensitive = false,
    } });
    defer generated.deinit(allocator);
    const resource_id = try artifacts.addResource(allocator, &context.document.resources, generated);
    const target_height = switch (mode) {
        .display => @max(text.font_size * text.display_math_height_factor, 1),
        else => @max(text.font_size * text.inline_math_height_factor, 1),
    };
    const scale = if (generated.intrinsic_height > 0) target_height / generated.intrinsic_height else 1;
    try atoms.appendResourceAtom(
        allocator,
        out_atoms,
        resource_id,
        @max(generated.intrinsic_width * scale, 1),
        target_height,
        text.font,
        text.font_size,
        text.color,
    );
}

fn appendInlineIconAtom(
    raw_context: *anyopaque,
    allocator: std.mem.Allocator,
    out_atoms: *std.ArrayList(atoms.Atom),
    source: []const u8,
    text: core.render_policy.TextPaint,
) !void {
    const context: *SceneBuildContext = @ptrCast(@alignCast(raw_context));
    var generated = try artifacts.generate(context.artifacts, .{ .icon_svg = .{ .source = source } });
    defer generated.deinit(allocator);
    const resource_id = try artifacts.addResource(allocator, &context.document.resources, generated);
    const target_height = @max(text.font_size, 1);
    const scale = if (generated.intrinsic_height > 0) target_height / generated.intrinsic_height else 1;
    try atoms.appendResourceAtom(
        allocator,
        out_atoms,
        resource_id,
        @max(generated.intrinsic_width * scale, 1),
        target_height,
        text.font,
        text.font_size,
        text.link_color,
    );
}

fn appendDisplayMathBlock(
    raw_context: *anyopaque,
    allocator: std.mem.Allocator,
    page: *scene.Page,
    node_id: scene.NodeId,
    frame: scene.Frame,
    source: []const u8,
    preamble: []const core.render_env.TexPreambleEntry,
    text: core.render_policy.TextPaint,
) !void {
    const context: *SceneBuildContext = @ptrCast(@alignCast(raw_context));
    var generated = try artifacts.generate(context.artifacts, .{ .math_svg = .{
        .source = source,
        .preamble = preamble,
        .mode = .display,
        .color_sensitive = false,
    } });
    defer generated.deinit(allocator);
    const resource_id = try artifacts.addResource(allocator, &context.document.resources, generated);
    const target_height = displayMathTargetHeight(source, text);
    const scale = if (generated.intrinsic_width > 0 and generated.intrinsic_height > 0)
        @min(frame.width / generated.intrinsic_width, target_height / generated.intrinsic_height)
    else
        1;
    const fitted = Size{
        .width = @max(generated.intrinsic_width * scale, 1),
        .height = @max(generated.intrinsic_height * scale, 1),
    };
    try page.items.append(allocator, .{ .resource = .{
        .node_id = node_id,
        .resource_id = resource_id,
        .frame = .{
            .x = alignedX(frame.x, frame.width, fitted.width, text.math_align),
            .y = frame.y + @max((frame.height - fitted.height) / 2.0, 0),
            .width = fitted.width,
            .height = fitted.height,
        },
        .tint = text.color,
        .clip = true,
    } });
}

fn toTopLeftPageFrame(frame: core.Frame) scene.Frame {
    return .{
        .x = 0,
        .y = 0,
        .width = frame.width,
        .height = frame.height,
    };
}

fn toTopLeftFrame(page_frame: core.Frame, frame: core.Frame) scene.Frame {
    return .{
        .x = frame.x,
        .y = page_frame.height - frame.y - frame.height,
        .width = frame.width,
        .height = frame.height,
        .x_set = frame.x_set,
        .y_set = frame.y_set,
    };
}

fn contentFrameForRender(frame: scene.Frame, render: core.render_policy.ResolvedRender) scene.Frame {
    return .{
        .x = frame.x + render.chrome.pad_x,
        .y = frame.y + render.chrome.pad_y,
        .width = @max(@as(f32, 1.0), frame.width - 2.0 * render.chrome.pad_x),
        .height = @max(@as(f32, 1.0), frame.height - 2.0 * render.chrome.pad_y),
    };
}

fn defaultTextPaint(color: scene.Color) core.render_policy.TextPaint {
    const font: scene.FontFace = .{
        .family = "Helvetica",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
    };
    return .{
        .font = font,
        .bold_font = font,
        .italic_font = font,
        .code_font = font,
        .font_size = 18,
        .line_height = 22,
        .color = color,
        .link_color = color,
        .markdown_bold_color = null,
        .link_underline_width = 0,
        .link_underline_offset = 0,
        .inline_math_height_factor = 1,
        .inline_math_spacing = 0,
        .display_math_height_factor = 2,
        .math_align = .center,
        .emoji_spacing = 0,
        .markdown_block_gap = 0,
        .markdown_list_inset = 0,
        .markdown_list_indent = 0,
        .markdown_code_font_size = 18,
        .markdown_code_line_height = 22,
        .markdown_code_pad_x = 0,
        .markdown_code_pad_y = 0,
        .markdown_code_fill = null,
        .markdown_code_stroke = null,
        .markdown_code_line_width = 0,
        .markdown_code_radius = 0,
        .markdown_code_plain_color = null,
        .markdown_code_keyword_color = null,
        .markdown_code_function_color = null,
        .markdown_code_type_color = null,
        .markdown_code_constant_color = null,
        .markdown_code_number_color = null,
        .markdown_code_variable_color = null,
        .markdown_code_operator_color = null,
        .markdown_code_comment_color = null,
        .markdown_code_string_color = null,
        .markdown_table_cell_pad_x = 0,
        .markdown_table_cell_pad_y = 0,
        .markdown_table_border = null,
        .markdown_table_line_width = 0,
        .markdown_table_header_fill = null,
        .markdown_table_alt_row_fill = null,
        .cjk_bold_passes = 1,
        .cjk_bold_dx = 0,
        .wrap = false,
    };
}

fn defaultCodePaint(color: scene.Color) core.render_policy.CodePaint {
    return .{
        .language = null,
        .plain = color,
        .keyword = color,
        .function = color,
        .type = color,
        .constant = color,
        .number = color,
        .variable = color,
        .operator = color,
        .comment = color,
        .string = color,
    };
}

fn defaultMathPaint() core.render_policy.MathPaint {
    return .{
        .block_line_height = 22,
        .block_min_height = 30,
        .block_vertical_padding = 2,
        .scale = 1,
        .horizontal_align = .center,
        .color = .{ .r = 0, .g = 0, .b = 0 },
    };
}

const Size = struct { width: f32, height: f32 };

fn fitSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    const scale = @min(max_width / source_width, max_height / source_height);
    return .{ .width = source_width * scale, .height = source_height * scale };
}

fn fitMathBlockSize(source_width: f32, source_height: f32, max_width: f32, max_height: f32, source_text: []const u8, math: core.render_policy.MathPaint) Size {
    if (source_width <= 0 or source_height <= 0) return .{ .width = max_width, .height = max_height };
    const target_height = @max(
        math.block_min_height,
        @as(f32, @floatFromInt(mathVisualLineCount(source_text))) * math.block_line_height + math.block_vertical_padding,
    ) * math.scale;
    const scale = @min(@min(max_width / source_width, max_height / source_height), target_height / source_height);
    return .{ .width = source_width * scale, .height = source_height * scale };
}

fn displayMathTargetHeight(source_text: []const u8, text: core.render_policy.TextPaint) f32 {
    const visual_lines = @as(f32, @floatFromInt(@max(mathVisualLineCount(source_text), 1)));
    const line_height = @max(text.line_height, text.font_size * text.display_math_height_factor);
    return visual_lines * line_height;
}

fn alignedX(x: f32, width: f32, content_width: f32, horizontal_align: core.render_policy.HorizontalAlign) f32 {
    const slack = @max(width - content_width, 0);
    return switch (horizontal_align) {
        .left => x,
        .center => x + slack / 2.0,
        .right => x + slack,
    };
}

fn mathVisualLineCount(source_text: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r\n").len == 0) continue;
        count += 1;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, line, cursor, "\\\\")) |break_index| {
            count += 1;
            cursor = break_index + 2;
        }
    }
    return @max(count, 1);
}
