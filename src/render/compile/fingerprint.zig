const std = @import("std");
const core = @import("core");
const pdf_ffi = @import("pdf_ffi");
const render_resources = @import("render_resources");

const c = pdf_ffi.c;
const Color = core.render_policy.Color;
const FontFace = core.font.Face;
const HorizontalAlign = core.render_policy.HorizontalAlign;
const LatexPreambleEntry = core.render_env.LatexPreambleEntry;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    resource_cache: ?*render_resources.SourceCache = null,
    font_environment: [c.SS_FONT_ENVIRONMENT_ID_SIZE]u8 = @splat(0),
};

pub const Command = struct {
    frame: core.Frame,
    content: []const u8,
    link_id: ?[]const u8,
    parse_mode: []const u8,
    render: core.render_policy.ResolvedRender,
    latex_preamble: []const LatexPreambleEntry,
    latex_engine: core.render_env.LatexEngine,
    latex_kind: []const u8,
    document_body: bool,
};

const File = struct {
    present: bool,
    digest: u64,
};

pub fn layoutMeasurementKey(
    ctx: Context,
    cache_version: []const u8,
    native_cache_version: []const u8,
    page_width: f32,
    page_height: f32,
    mode: core.LayoutMeasurementMode,
    width: f32,
    command: Command,
) !u64 {
    var files = std.StringHashMap(File).init(ctx.allocator);
    defer {
        var keys = files.keyIterator();
        while (keys.next()) |key| ctx.allocator.free(key.*);
        files.deinit();
    }

    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, cache_version);
    hashString(&hasher, native_cache_version);
    hashNativeRuntime(&hasher);
    hasher.update(&ctx.font_environment);
    hashF32(&hasher, page_width);
    hashF32(&hasher, page_height);
    hashString(&hasher, @tagName(mode));
    hashF32(&hasher, width);
    try hashCommand(ctx, &files, &hasher, command);
    return hasher.final();
}

pub fn renderPageKey(
    ctx: Context,
    cache_version: []const u8,
    page_id: core.NodeId,
    page_index: usize,
    background: ?Color,
    highlight_languages: anytype,
    commands: anytype,
) !u64 {
    var files = std.StringHashMap(File).init(ctx.allocator);
    defer {
        var keys = files.keyIterator();
        while (keys.next()) |key| ctx.allocator.free(key.*);
        files.deinit();
    }

    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, cache_version);
    hashNativeRuntime(&hasher);
    hasher.update(&ctx.font_environment);
    hashU64(&hasher, page_id);
    hashUsize(&hasher, page_index);
    hashOptionalColor(&hasher, background);
    hashUsize(&hasher, highlight_languages.len);
    for (highlight_languages) |language| {
        hashString(&hasher, language.name);
        hashString(&hasher, language.parser);
        hashString(&hasher, language.query);
        if (!std.mem.startsWith(u8, language.query, "builtin:")) {
            const fingerprint = try fileFingerprint(ctx, &files, language.query);
            hashBool(&hasher, fingerprint.present);
            hashU64(&hasher, fingerprint.digest);
        }
    }
    hashUsize(&hasher, commands.len);
    for (commands) |command| {
        hashU64(&hasher, command.page_id);
        hashU64(&hasher, command.node_id);
        try hashCommand(ctx, &files, &hasher, .{
            .frame = command.frame,
            .content = command.content,
            .link_id = command.link_id,
            .parse_mode = @tagName(command.parse_mode),
            .render = command.render,
            .latex_preamble = command.latex_preamble,
            .latex_engine = command.latex_engine,
            .latex_kind = @tagName(command.latex_kind),
            .document_body = command.latex_kind == .body,
        });
    }
    return hasher.final();
}

pub fn latexArtifactKey(
    ctx: Context,
    cache_version: []const u8,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: core.render_env.LatexEngine,
    kind: []const u8,
) !u64 {
    var files = std.StringHashMap(File).init(ctx.allocator);
    defer {
        var keys = files.keyIterator();
        while (keys.next()) |key| ctx.allocator.free(key.*);
        files.deinit();
    }

    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, cache_version);
    hashString(&hasher, "latex");
    hashString(&hasher, @tagName(engine));
    hashString(&hasher, kind);
    hashString(&hasher, source);
    try hashLatexPreamble(ctx, &files, &hasher, preamble);
    return hasher.final();
}

fn hashCommand(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, command: Command) !void {
    hashFrame(hasher, command.frame);
    hashString(hasher, command.content);
    hashOptionalString(hasher, command.link_id);
    hashString(hasher, command.parse_mode);
    if ((command.render.kind == .latex and command.document_body) or
        (command.render.kind == .text and command.latex_preamble.len != 0))
    {
        hashString(hasher, @tagName(command.latex_engine));
        try hashLatexPreamble(ctx, files, hasher, command.latex_preamble);
    }
    hashResolvedRender(hasher, command.render);
    switch (command.render.kind) {
        .latex => hashString(hasher, command.latex_kind),
        .vector_asset, .raster_asset => {
            if (core.fontawesome.parseSource(command.content) != null) {
                hashString(hasher, core.fontawesome.cache_namespace);
            } else {
                const source = try resolveAssetPath(ctx, command.content);
                defer ctx.allocator.free(source);
                try hashAssetFile(ctx, files, hasher, source);
            }
        },
        else => {},
    }
}

fn hashLatexPreamble(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, preamble: []const LatexPreambleEntry) !void {
    hashUsize(hasher, preamble.len);
    for (preamble) |entry| {
        hashString(hasher, @tagName(entry.source));
        hashString(hasher, entry.value);
        if (entry.source != .file) continue;
        const source = try resolveAssetPath(ctx, entry.value);
        defer ctx.allocator.free(source);
        hashLogicalAssetPath(ctx, hasher, source);
        const fingerprint = try fileFingerprint(ctx, files, source);
        hashBool(hasher, fingerprint.present);
        hashU64(hasher, fingerprint.digest);
    }
}

fn hashAssetFile(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, source: []const u8) !void {
    hashLogicalAssetPath(ctx, hasher, source);
    const fingerprint = try fileFingerprint(ctx, files, source);
    hashBool(hasher, fingerprint.present);
    hashU64(hasher, fingerprint.digest);
}

fn fileFingerprint(ctx: Context, files: *std.StringHashMap(File), source: []const u8) !File {
    if (files.get(source)) |fingerprint| return fingerprint;
    const fingerprint = try readFileFingerprint(ctx, source);
    const owned_source = try ctx.allocator.dupe(u8, source);
    errdefer ctx.allocator.free(owned_source);
    try files.put(owned_source, fingerprint);
    return fingerprint;
}

fn readFileFingerprint(ctx: Context, source: []const u8) !File {
    if (ctx.resource_cache) |cache| {
        const fingerprint = try cache.fileFingerprint(source);
        return .{ .present = fingerprint.present, .digest = fingerprint.digest };
    }
    var file = std.Io.Dir.cwd().openFile(ctx.io, source, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .present = false, .digest = 0 },
        else => return err,
    };
    defer file.close(ctx.io);
    var file_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, ctx.io, file_buffer[0..]);
    var chunk: [16 * 1024]u8 = undefined;
    var hasher = std.hash.Wyhash.init(0);
    while (true) {
        const read_len = reader.interface.readSliceShort(chunk[0..]) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
        };
        if (read_len == 0) break;
        hasher.update(chunk[0..read_len]);
    }
    return .{ .present = true, .digest = hasher.final() };
}

fn hashResolvedRender(hasher: *std.hash.Wyhash, render: core.render_policy.ResolvedRender) void {
    hashString(hasher, @tagName(render.kind));
    hashOptionalTextPaint(hasher, render.text);
    hashOptionalLatexPaint(hasher, render.latex);
    hashOptionalAssetPaint(hasher, render.asset);
    hashOptionalCodePaint(hasher, render.code);
    hashOptionalVectorPathPaint(hasher, render.vector_path);
    hashOptionalConnectorPaint(hasher, render.connector);
    hashChromePaint(hasher, render.chrome);
    hashUnderlinePaint(hasher, render.underline);
    hashRulePaint(hasher, render.rule);
}

fn hashOptionalTextPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.TextPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |text| {
        hashFontFace(hasher, text.font);
        hashFontFace(hasher, text.bold_font);
        hashFontFace(hasher, text.italic_font);
        hashFontFace(hasher, text.code_font);
        hashF32(hasher, text.font_size);
        hashF32(hasher, text.line_height);
        hashColor(hasher, text.color);
        hashColor(hasher, text.link_color);
        hashOptionalColor(hasher, text.markdown_bold_color);
        hashMarkdownUnderlinePaint(hasher, text.markdown_underline);
        hashMarkdownQuotePaint(hasher, text.markdown_quote);
        for (text.markdown_headings) |heading| hashOptionalHeadingPaint(hasher, heading);
        hashF32(hasher, text.inline_math_height_factor);
        hashF32(hasher, text.inline_math_spacing);
        hashF32(hasher, text.display_math_height_factor);
        hashHorizontalAlign(hasher, text.math_align);
        hashF32(hasher, text.emoji_spacing);
        hashF32(hasher, text.markdown_block_gap);
        hashF32(hasher, text.markdown_list_inset);
        hashF32(hasher, text.markdown_list_indent);
        hashF32(hasher, text.markdown_code_font_size);
        hashF32(hasher, text.markdown_code_line_height);
        hashF32(hasher, text.markdown_code_pad_x);
        hashF32(hasher, text.markdown_code_pad_y);
        hashOptionalColor(hasher, text.markdown_code_fill);
        hashOptionalColor(hasher, text.markdown_code_stroke);
        hashF32(hasher, text.markdown_code_line_width);
        hashF32(hasher, text.markdown_code_radius);
        hashOptionalColor(hasher, text.markdown_code_plain_color);
        hashOptionalColor(hasher, text.markdown_code_keyword_color);
        hashOptionalColor(hasher, text.markdown_code_function_color);
        hashOptionalColor(hasher, text.markdown_code_type_color);
        hashOptionalColor(hasher, text.markdown_code_constant_color);
        hashOptionalColor(hasher, text.markdown_code_number_color);
        hashOptionalColor(hasher, text.markdown_code_variable_color);
        hashOptionalColor(hasher, text.markdown_code_operator_color);
        hashOptionalColor(hasher, text.markdown_code_comment_color);
        hashOptionalColor(hasher, text.markdown_code_string_color);
        hashF32(hasher, text.markdown_table_cell_pad_x);
        hashF32(hasher, text.markdown_table_cell_pad_y);
        hashOptionalColor(hasher, text.markdown_table_border);
        hashF32(hasher, text.markdown_table_line_width);
        hashOptionalColor(hasher, text.markdown_table_header_fill);
        hashOptionalColor(hasher, text.markdown_table_alt_row_fill);
        hashBool(hasher, text.wrap);
    }
}

fn hashOptionalHeadingPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.MarkdownHeadingPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |heading| {
        hashFontFace(hasher, heading.font);
        hashFontFace(hasher, heading.bold_font);
        hashFontFace(hasher, heading.italic_font);
        hashFontFace(hasher, heading.code_font);
        hashF32(hasher, heading.font_size);
        hashF32(hasher, heading.line_height);
        hashColor(hasher, heading.color);
        hashColor(hasher, heading.link_color);
        hashOptionalColor(hasher, heading.markdown_bold_color);
        hashMarkdownUnderlinePaint(hasher, heading.markdown_underline);
        hashF32(hasher, heading.inline_math_height_factor);
        hashF32(hasher, heading.inline_math_spacing);
        hashF32(hasher, heading.display_math_height_factor);
        std.hash.autoHash(hasher, @intFromEnum(heading.math_align));
        hashF32(hasher, heading.emoji_spacing);
    }
}

fn hashMarkdownUnderlinePaint(hasher: *std.hash.Wyhash, underline: core.render_policy.MarkdownUnderlinePaint) void {
    hashOptionalColor(hasher, underline.color);
    hashF32(hasher, underline.opacity);
    hashBool(hasher, underline.width != null);
    if (underline.width) |width| hashF32(hasher, width);
    hashF32(hasher, underline.offset);
    hashBool(hasher, underline.dash != null);
    if (underline.dash) |dash| {
        hashF32(hasher, dash.on);
        hashF32(hasher, dash.off);
    }
}

fn hashMarkdownQuotePaint(hasher: *std.hash.Wyhash, quote: core.render_policy.MarkdownQuotePaint) void {
    hashOptionalColor(hasher, quote.color);
    hashF32(hasher, quote.inset);
    hashF32(hasher, quote.pad_x);
    hashF32(hasher, quote.pad_y);
    hashOptionalColor(hasher, quote.fill);
    hashF32(hasher, quote.radius);
    hashOptionalColor(hasher, quote.bar_color);
    hashF32(hasher, quote.bar_width);
    hashBool(hasher, quote.bar_dash != null);
    if (quote.bar_dash) |dash| {
        hashF32(hasher, dash.on);
        hashF32(hasher, dash.off);
    }
}

fn hashOptionalLatexPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.LatexPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |latex| {
        hashF32(hasher, latex.min_height);
        hashF32(hasher, latex.scale);
        hashHorizontalAlign(hasher, latex.horizontal_align);
    }
}

fn hashOptionalAssetPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.AssetPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |asset| {
        hashF32(hasher, asset.scale);
        hashOptionalColor(hasher, asset.tint);
        hashU64(hasher, asset.pdf_page);
        hashString(hasher, @tagName(asset.pdf_box));
    }
}

fn hashOptionalCodePaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.CodePaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |code| {
        hashOptionalString(hasher, code.language);
        hashColor(hasher, code.plain);
        hashColor(hasher, code.keyword);
        hashColor(hasher, code.function);
        hashColor(hasher, code.type);
        hashColor(hasher, code.constant);
        hashColor(hasher, code.number);
        hashColor(hasher, code.variable);
        hashColor(hasher, code.operator);
        hashColor(hasher, code.comment);
        hashColor(hasher, code.string);
    }
}

fn hashOptionalVectorPathPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.VectorPathPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |path| {
        hashCorePath(hasher, path.path);
        hashVectorFill(hasher, path.fill);
        hashOptionalVectorStroke(hasher, path.stroke);
        hashOptionalMarker(hasher, path.marker_start);
        hashOptionalMarker(hasher, path.marker_end);
    }
}

fn hashVectorFill(hasher: *std.hash.Wyhash, fill: core.render_policy.VectorFillPaint) void {
    hashString(hasher, @tagName(fill.kind));
    hashOptionalColor(hasher, fill.color);
    hashOptionalColor(hasher, fill.color2);
    hashF32(hasher, fill.start_x);
    hashF32(hasher, fill.start_y);
    hashF32(hasher, fill.start_radius);
    hashF32(hasher, fill.end_x);
    hashF32(hasher, fill.end_y);
    hashF32(hasher, fill.end_radius);
    hashString(hasher, @tagName(fill.spread));
    hashString(hasher, @tagName(fill.space));
    hashString(hasher, @tagName(fill.rule));
    hashF32(hasher, fill.opacity);
    hashBool(hasher, fill.pattern != null);
    if (fill.pattern) |pattern| {
        hashCorePath(hasher, pattern.path);
        hashF32(hasher, pattern.cell_width);
        hashF32(hasher, pattern.cell_height);
        hashF32(hasher, pattern.xx);
        hashF32(hasher, pattern.yx);
        hashF32(hasher, pattern.xy);
        hashF32(hasher, pattern.yy);
        hashF32(hasher, pattern.x0);
        hashF32(hasher, pattern.y0);
        hashString(hasher, @tagName(pattern.space));
        hashOptionalColor(hasher, pattern.fill);
        hashOptionalVectorStroke(hasher, pattern.stroke);
    }
}

fn hashCorePath(hasher: *std.hash.Wyhash, path: core.Path) void {
    hashU64(hasher, path.commands.len);
    for (path.commands) |command| {
        hashString(hasher, @tagName(command));
        switch (command) {
            .move_to, .line_to => |point| {
                hashF32(hasher, point.x);
                hashF32(hasher, point.y);
            },
            .cubic_to => |cubic| {
                hashF32(hasher, cubic.control1.x);
                hashF32(hasher, cubic.control1.y);
                hashF32(hasher, cubic.control2.x);
                hashF32(hasher, cubic.control2.y);
                hashF32(hasher, cubic.end.x);
                hashF32(hasher, cubic.end.y);
            },
            .close => {},
        }
    }
}

fn hashOptionalVectorStroke(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.VectorStrokePaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |stroke| {
        hashColor(hasher, stroke.color);
        hashF32(hasher, stroke.width);
        hashString(hasher, @tagName(stroke.cap));
        hashString(hasher, @tagName(stroke.join));
        hashF32(hasher, stroke.miter_limit);
        hashU64(hasher, stroke.dash.count);
        for (stroke.dash.slice()) |entry| hashF32(hasher, entry);
        hashF32(hasher, stroke.dash.offset);
    }
}

fn hashOptionalConnectorPaint(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.ConnectorPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |connector| {
        hashU64(hasher, connector.source);
        hashU64(hasher, connector.target);
        hashString(hasher, @tagName(connector.source_anchor));
        hashString(hasher, @tagName(connector.target_anchor));
        hashString(hasher, @tagName(connector.route));
        hashF32(hasher, connector.curve);
        hashOptionalVectorStroke(hasher, connector.stroke);
        hashOptionalMarker(hasher, connector.marker_start);
        hashOptionalMarker(hasher, connector.marker_end);
    }
}

fn hashOptionalMarker(hasher: *std.hash.Wyhash, maybe: ?core.render_policy.MarkerPaint) void {
    hashBool(hasher, maybe != null);
    if (maybe) |marker| {
        hashCorePath(hasher, marker.path);
        hashF32(hasher, marker.width);
        hashF32(hasher, marker.height);
        hashVectorFill(hasher, marker.fill);
        hashOptionalVectorStroke(hasher, marker.stroke);
    }
}

fn hashChromePaint(hasher: *std.hash.Wyhash, chrome: core.render_policy.ChromePaint) void {
    hashOptionalColor(hasher, chrome.fill);
    hashOptionalColor(hasher, chrome.stroke);
    hashF32(hasher, chrome.line_width);
    hashF32(hasher, chrome.radius);
    hashF32(hasher, chrome.pad_x);
    hashF32(hasher, chrome.pad_y);
}

fn hashUnderlinePaint(hasher: *std.hash.Wyhash, underline: core.render_policy.UnderlinePaint) void {
    hashOptionalColor(hasher, underline.color);
    hashF32(hasher, underline.width);
    hashF32(hasher, underline.offset);
}

fn hashRulePaint(hasher: *std.hash.Wyhash, rule: core.render_policy.RulePaint) void {
    hashOptionalColor(hasher, rule.stroke);
    hashF32(hasher, rule.line_width);
    hashBool(hasher, rule.dash != null);
    if (rule.dash) |dash| {
        hashF32(hasher, dash.on);
        hashF32(hasher, dash.off);
    }
}

fn resolveAssetPath(ctx: Context, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return ctx.allocator.dupe(u8, path);
    return std.fs.path.join(ctx.allocator, &.{ ctx.asset_base_dir, path });
}

fn hashLogicalAssetPath(ctx: Context, hasher: *std.hash.Wyhash, source: []const u8) void {
    const base = ctx.asset_base_dir;
    if (base.len > 0 and !std.mem.eql(u8, base, ".")) {
        if (std.mem.eql(u8, source, base)) return hashString(hasher, ".");
        if (source.len > base.len and source[base.len] == std.fs.path.sep and std.mem.eql(u8, source[0..base.len], base)) {
            return hashString(hasher, source[base.len + 1 ..]);
        }
    }
    if (std.mem.startsWith(u8, source, "./")) return hashString(hasher, source[2..]);
    hashString(hasher, source);
}

fn hashFrame(hasher: *std.hash.Wyhash, frame: core.Frame) void {
    hashF32(hasher, frame.x);
    hashF32(hasher, frame.y);
    hashF32(hasher, frame.width);
    hashF32(hasher, frame.height);
}

fn hashOptionalColor(hasher: *std.hash.Wyhash, value: ?Color) void {
    hashBool(hasher, value != null);
    if (value) |color| hashColor(hasher, color);
}

fn hashColor(hasher: *std.hash.Wyhash, color: Color) void {
    hashF32(hasher, color.r);
    hashF32(hasher, color.g);
    hashF32(hasher, color.b);
}

fn hashFontFace(hasher: *std.hash.Wyhash, face: FontFace) void {
    hashString(hasher, face.family);
    hashU32(hasher, @intCast(face.weight));
    hashU32(hasher, @intFromEnum(face.style));
    hashU32(hasher, @intFromEnum(face.stretch));
}

fn hashHorizontalAlign(hasher: *std.hash.Wyhash, value: HorizontalAlign) void {
    hashU32(hasher, @intFromEnum(value));
}

fn hashNativeRuntime(hasher: *std.hash.Wyhash) void {
    hashCString(hasher, c.ss_pdf_cairo_version_string());
    hashCString(hasher, c.ss_pdf_pango_version_string());
    hashCString(hasher, c.ss_pdf_librsvg_version_string());
    hashU32(hasher, @intCast(c.ss_pdf_fontconfig_version()));
    hashCString(hasher, c.ss_pdf_harfbuzz_version_string());
}

fn hashCString(hasher: *std.hash.Wyhash, pointer: [*c]const u8) void {
    hashBool(hasher, pointer != null);
    if (pointer == null) return;
    const sentinel: [*:0]const u8 = @ptrCast(pointer);
    hashString(hasher, std.mem.span(sentinel));
}

fn hashOptionalString(hasher: *std.hash.Wyhash, value: ?[]const u8) void {
    hashBool(hasher, value != null);
    if (value) |text| hashString(hasher, text);
}

fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(&.{byte});
}

fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
    hashU64(hasher, @intCast(value));
}

fn hashU64(hasher: *std.hash.Wyhash, value: u64) void {
    hasher.update(std.mem.asBytes(&value));
}

fn hashU32(hasher: *std.hash.Wyhash, value: u32) void {
    hasher.update(std.mem.asBytes(&value));
}

fn hashF32(hasher: *std.hash.Wyhash, value: f32) void {
    hasher.update(std.mem.asBytes(&value));
}
