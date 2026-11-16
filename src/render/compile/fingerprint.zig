const std = @import("std");
const core = @import("core");
const pdf_ffi = @import("pdf_ffi");
const render_resources = @import("render_resources");
const syntax_highlight = @import("syntax_highlight.zig");
const latex_inputs = @import("latex_inputs.zig");
const latex_references = @import("latex_references.zig");
const utils = @import("utils");
const cache_versions = @import("cache_versions.zig");

const c = pdf_ffi.c;
const Color = core.render_paint.Color;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8 = utils.render_cache.native_path,
    resource_cache: ?*render_resources.SourceCache = null,
    latex_references: ?*latex_references.Cache = null,
    font_environment: [c.SS_FONT_ENVIRONMENT_ID_SIZE]u8 = @splat(0),
};

pub const Command = struct {
    frame: core.Frame,
    content: []const u8,
    link_id: ?[]const u8,
    parse_mode: []const u8,
    render: core.render_paint.ResolvedRender,
    latex_preamble: []const u8,
    latex_engine: core.latex_config.LatexEngine,
    latex_kind: []const u8,
    asset_deps: []const core.prepared.AssetDependency = &.{},
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
    highlight_languages: anytype,
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
    try hashHighlightLanguages(ctx, &files, &hasher, highlight_languages);
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
    hashPaint(&hasher, background);
    try hashHighlightLanguages(ctx, &files, &hasher, highlight_languages);
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
            .asset_deps = command.asset_deps,
        });
    }
    return hasher.final();
}

pub fn latexArtifactKey(
    ctx: Context,
    cache_version: []const u8,
    source: []const u8,
    preamble: []const u8,
    engine: core.latex_config.LatexEngine,
    kind: []const u8,
) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, cache_version);
    hashString(&hasher, "latex");
    const base = try utils.fs.absolutePath(ctx.io, ctx.allocator, ctx.asset_base_dir);
    defer ctx.allocator.free(base);
    hashString(&hasher, base);
    hashString(&hasher, @tagName(engine));
    hashString(&hasher, kind);
    hashString(&hasher, source);
    hashString(&hasher, preamble);
    return hasher.final();
}

fn hashCommand(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, command: Command) !void {
    hashFrame(hasher, command.frame);
    hashString(hasher, command.content);
    hashOptionalString(hasher, command.link_id);
    hashString(hasher, command.parse_mode);
    if (command.render.kind() == .latex or command.render.kind() == .text) {
        hashString(hasher, @tagName(command.latex_engine));
        hashString(hasher, command.latex_preamble);
    }
    for (command.asset_deps) |dependency| {
        switch (dependency.kind) {
            .inline_math, .display_math, .latex_body => try hashLatexInputs(ctx, files, hasher, dependency.source, command.latex_preamble, command.latex_engine, switch (dependency.kind) {
                .inline_math => "inline_math",
                .display_math => "display_math",
                .latex_body => "body",
                else => unreachable,
            }),
            .vector_pdf, .raster_asset => {
                const path = try resolveAssetPath(ctx, dependency.source);
                defer ctx.allocator.free(path);
                try hashAssetFile(ctx, files, hasher, path);
            },
            .icon => hashString(hasher, core.fontawesome.cache_namespace),
        }
    }
    if (command.render.kind() == .latex and command.asset_deps.len == 0) {
        try hashLatexInputs(ctx, files, hasher, command.content, command.latex_preamble, command.latex_engine, command.latex_kind);
    }
    hashPaint(hasher, command.render);
    switch (command.render.kind()) {
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

pub fn latexReferencePath(ctx: Context, source: []const u8, preamble: []const u8, engine: core.latex_config.LatexEngine, kind: []const u8) ![]u8 {
    const key = try latexArtifactKey(ctx, cache_versions.native_artifacts, source, preamble, engine, kind);
    return std.fmt.allocPrint(ctx.allocator, "{s}/latex-{x}.ref", .{ ctx.cache_dir, key });
}

fn hashLatexInputs(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, source: []const u8, preamble: []const u8, engine: core.latex_config.LatexEngine, kind: []const u8) !void {
    const path = try latexReferencePath(ctx, source, preamble, engine, kind);
    defer ctx.allocator.free(path);
    var reference = latex_references.read(ctx.allocator, ctx.io, path, ctx.latex_references) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => return err,
        else => return hashBool(hasher, false),
    };
    defer reference.deinit();
    hashBool(hasher, true);
    for (reference.inputs) |input| {
        const current = try fileFingerprint(ctx, files, input.path);
        latex_inputs.hashInput(hasher, input.path, .{ .present = current.present, .digest = current.digest });
    }
}

fn hashHighlightLanguages(ctx: Context, files: *std.StringHashMap(File), hasher: *std.hash.Wyhash, languages: anytype) !void {
    hashUsize(hasher, languages.len);
    for (languages) |language| {
        hashString(hasher, language.name);
        hashString(hasher, language.parser);
        hashString(hasher, language.query);
        if (syntax_highlight.builtinHighlightQueryDigest(language.query)) |digest| {
            hashBool(hasher, true);
            hashU64(hasher, digest);
        } else {
            const fingerprint = try fileFingerprint(ctx, files, language.query);
            hashBool(hasher, fingerprint.present);
            hashU64(hasher, fingerprint.digest);
        }
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

/// Hash paint by value, including the active tag, optional presence, and slice
/// contents. New style fields automatically participate in cache invalidation.
fn hashPaint(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => hashBool(hasher, value),
        .float => hashF32(hasher, value),
        .int => std.hash.autoHash(hasher, value),
        .@"enum" => hashPaint(hasher, @backingInt(value)),
        .optional => {
            hashBool(hasher, value != null);
            if (value) |item| hashPaint(hasher, item);
        },
        .array => for (value) |item| hashPaint(hasher, item),
        .@"struct" => inline for (comptime std.meta.fieldNames(T)) |name| hashPaint(hasher, @field(value, name)),
        .@"union" => switch (value) {
            inline else => |payload, tag| {
                hashPaint(hasher, tag);
                hashPaint(hasher, payload);
            },
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("only slice pointers may occur in paint values: " ++ @typeName(T));
            hashUsize(hasher, value.len);
            if (ptr.child == u8) hasher.update(value) else for (value) |item| hashPaint(hasher, item);
        },
        else => @compileError("unsupported paint field: " ++ @typeName(T)),
    }
}

fn resolveAssetPath(ctx: Context, path: []const u8) ![]u8 {
    return utils.fs.resolveAssetPath(ctx.allocator, ctx.asset_base_dir, path);
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

pub fn hashString(hasher: *std.hash.Wyhash, value: []const u8) void {
    hashUsize(hasher, value.len);
    hasher.update(value);
}

fn hashBool(hasher: *std.hash.Wyhash, value: bool) void {
    const byte: u8 = if (value) 1 else 0;
    hasher.update(&.{byte});
}

pub fn hashUsize(hasher: *std.hash.Wyhash, value: usize) void {
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
