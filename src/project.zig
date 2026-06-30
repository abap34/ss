const std = @import("std");
const utils = @import("utils");
const highlight = utils.highlight;

pub const Config = struct {
    path: []u8,
    dir: []u8,
    entry: []u8,
    asset_base_dir: []u8,
    lsp: LspConfig = .{},
    preview: PreviewConfig = .{},
    page_guide: PageGuideConfig = .{},
    highlight: highlight.Config = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.dir);
        allocator.free(self.entry);
        allocator.free(self.asset_base_dir);
        self.highlight.deinit(allocator);
    }
};

pub const LspConfig = struct {
    enabled: bool = true,
    debounce_ms: u64 = 120,
    diagnostics: bool = true,
    completion: bool = true,
    hover: bool = true,
    definition: bool = true,
    inlay_hints: bool = true,
    inlay_hint_arguments: bool = true,
    inlay_hint_positions: bool = true,
    document_symbols: bool = true,
    folding_ranges: bool = true,
    semantic_tokens: bool = true,
    colors: bool = true,
};

pub const PreviewOpenMode = enum {
    vscode,
    external,
};

pub const PreviewConfig = struct {
    enabled: bool = true,
    debounce_ms: u64 = 350,
    refresh_on_save: bool = true,
    refresh_on_dependency_change: bool = true,
    open_mode: PreviewOpenMode = .vscode,
    reveal_after_render: bool = true,
    render_timeout_ms: u64 = 30000,
};

pub const PageGuideConfig = struct {
    enabled: bool = true,
    body_background: bool = true,
    boundary: bool = true,
    boundary_background: bool = true,
    gutter_icon: bool = true,
    overview_ruler: bool = true,
};

pub const Resolved = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    project_file: ?[]u8 = null,
    project_dir: ?[]u8 = null,
    highlight: highlight.Config = .{},

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.entry_path);
        allocator.free(self.asset_base_dir);
        if (self.project_file) |path| allocator.free(path);
        if (self.project_dir) |dir| allocator.free(dir);
        self.highlight.deinit(allocator);
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: ?[]const u8,
    project_arg: ?[]const u8,
    asset_base_arg: ?[]const u8,
) !Resolved {
    var config: ?Config = if (project_arg) |arg|
        try loadProjectArgument(allocator, io, arg)
    else if (input_path == null)
        try discover(allocator, io, ".")
    else if (input_path) |input|
        try discoverForInput(allocator, io, input)
    else
        null;
    defer if (config) |*cfg| cfg.deinit(allocator);

    const entry_path = if (input_path) |input|
        try absolutePath(allocator, input)
    else if (config) |cfg|
        try allocator.dupe(u8, cfg.entry)
    else
        return error.MissingInputPath;
    errdefer allocator.free(entry_path);

    const asset_base_dir = if (asset_base_arg) |asset_base|
        try absolutePath(allocator, asset_base)
    else if (input_path != null) blk: {
        if (config) |cfg| break :blk try allocator.dupe(u8, cfg.asset_base_dir);
        break :blk try dirnameAlloc(allocator, entry_path);
    } else if (config) |cfg|
        try allocator.dupe(u8, cfg.asset_base_dir)
    else
        try dirnameAlloc(allocator, entry_path);
    errdefer allocator.free(asset_base_dir);

    return .{
        .entry_path = entry_path,
        .asset_base_dir = asset_base_dir,
        .project_file = if (config) |cfg| try allocator.dupe(u8, cfg.path) else null,
        .project_dir = if (config) |cfg| try allocator.dupe(u8, cfg.dir) else null,
        .highlight = if (config) |cfg| try cfg.highlight.clone(allocator) else try highlight.defaultConfig(allocator),
    };
}

fn discoverForInput(allocator: std.mem.Allocator, io: std.Io, input_path: []const u8) !?Config {
    const absolute = try absolutePath(allocator, input_path);
    defer allocator.free(absolute);
    const dir = std.fs.path.dirname(absolute) orelse ".";
    return try discover(allocator, io, dir);
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io, start_dir: []const u8) !?Config {
    const path = try discoverPath(allocator, start_dir);
    defer if (path) |found| allocator.free(found);
    return if (path) |found| try loadFile(allocator, io, found) else null;
}

pub fn discoverPath(allocator: std.mem.Allocator, start_dir: []const u8) !?[]u8 {
    var current = try absolutePath(allocator, start_dir);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "ss.toml" });
        if (utils.fs.fileExists(allocator, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    return null;
}

pub fn isConfigError(err: anyerror) bool {
    return switch (err) {
        error.MissingProjectEntry,
        error.UnknownHighlightLanguageField,
        error.BuiltinHighlightLanguageReserved,
        error.MissingHighlightParser,
        error.MissingHighlightQuery,
        error.UnknownHighlightParser,
        error.DuplicateHighlightLanguage,
        => true,
        else => false,
    };
}

pub fn loadProjectArgument(allocator: std.mem.Allocator, io: std.Io, arg: []const u8) !Config {
    const absolute = try absolutePath(allocator, arg);
    defer allocator.free(absolute);
    const path = if (std.mem.endsWith(u8, absolute, ".toml"))
        try allocator.dupe(u8, absolute)
    else
        try std.fs.path.join(allocator, &.{ absolute, "ss.toml" });
    defer allocator.free(path);
    return try loadFile(allocator, io, path);
}

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const source = try utils.fs.readFileAlloc(io, allocator, path);
    defer allocator.free(source);
    return parseSource(allocator, path, source);
}

pub fn parseSource(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !Config {
    const dir = try dirnameAlloc(allocator, path);
    errdefer allocator.free(dir);

    const raw_entry = parseString(source, "project", "entry") orelse return error.MissingProjectEntry;
    const raw_asset_base = parseString(source, "project", "asset_base_dir");
    const entry = try resolveAgainst(allocator, dir, raw_entry);
    errdefer allocator.free(entry);
    const asset_base_dir = if (raw_asset_base) |value|
        try resolveAgainst(allocator, dir, value)
    else
        try dirnameAlloc(allocator, entry);
    errdefer allocator.free(asset_base_dir);

    var parsed_highlight = try parseHighlightConfig(allocator, dir, source);
    defer parsed_highlight.deinit(allocator);
    var highlight_config = try highlight.configWithDefaults(allocator, parsed_highlight.languages);
    errdefer highlight_config.deinit(allocator);

    return .{
        .path = try allocator.dupe(u8, path),
        .dir = dir,
        .entry = entry,
        .asset_base_dir = asset_base_dir,
        .lsp = parseLspConfig(source),
        .preview = parsePreviewConfig(source),
        .page_guide = parsePageGuideConfig(source),
        .highlight = highlight_config,
    };
}

pub fn configErrorSpan(source: []const u8, err: anyerror) ?utils.err.ByteSpan {
    return switch (err) {
        error.MissingProjectEntry => tomlKeySpan(source, "project", "entry") orelse tomlSectionSpan(source, "project"),
        error.UnknownHighlightLanguageField,
        error.BuiltinHighlightLanguageReserved,
        error.MissingHighlightParser,
        error.MissingHighlightQuery,
        error.UnknownHighlightParser,
        error.DuplicateHighlightLanguage,
        => highlightConfigErrorSpan(source, err),
        else => null,
    };
}

pub fn tomlSectionSpan(source: []const u8, section_name: []const u8) ?utils.err.ByteSpan {
    return tomlSpan(source, .{ .section = section_name });
}

pub fn tomlKeySpan(source: []const u8, section_name: []const u8, key: []const u8) ?utils.err.ByteSpan {
    return tomlSpan(source, .{ .section = section_name, .key = key });
}

fn parseLspConfig(source: []const u8) LspConfig {
    const inlay_hints = parseBool(source, "editor.lsp.inlay_hints", "enabled", true);
    return .{
        .enabled = parseBool(source, "editor.lsp", "enabled", true),
        .debounce_ms = parseU64(source, "editor.lsp", "debounce", 120),
        .diagnostics = parseBool(source, "editor.lsp", "diagnostics", true),
        .completion = parseBool(source, "editor.lsp", "completion", true),
        .hover = parseBool(source, "editor.lsp", "hover", true),
        .definition = parseBool(source, "editor.lsp", "definition", true),
        .inlay_hints = inlay_hints,
        .inlay_hint_arguments = parseBool(source, "editor.lsp.inlay_hints", "arguments", inlay_hints),
        .inlay_hint_positions = parseBool(source, "editor.lsp.inlay_hints", "positions", inlay_hints),
        .document_symbols = parseBool(source, "editor.lsp", "document_symbols", true),
        .folding_ranges = parseBool(source, "editor.lsp", "folding_ranges", true),
        .semantic_tokens = parseBool(source, "editor.lsp", "semantic_tokens", true),
        .colors = parseBool(source, "editor.lsp", "colors", true),
    };
}

fn parsePreviewConfig(source: []const u8) PreviewConfig {
    return .{
        .enabled = parseBool(source, "editor.preview", "enabled", true),
        .debounce_ms = parseU64(source, "editor.preview", "debounce", 350),
        .refresh_on_save = parseBool(source, "editor.preview.refresh", "save", true),
        .refresh_on_dependency_change = parseBool(source, "editor.preview.refresh", "dependency", true),
        .open_mode = parsePreviewOpenMode(source, "editor.preview", "open", .vscode),
        .reveal_after_render = parseBool(source, "editor.preview", "reveal", true),
        .render_timeout_ms = parseU64(source, "editor.preview.render", "timeout", 30000),
    };
}

fn parsePageGuideConfig(source: []const u8) PageGuideConfig {
    return .{
        .enabled = parseBool(source, "editor.page_guide", "enabled", true),
        .body_background = parseBool(source, "editor.page_guide", "body_background", true),
        .boundary = parseBool(source, "editor.page_guide", "boundary", true),
        .boundary_background = parseBool(source, "editor.page_guide", "boundary_background", true),
        .gutter_icon = parseBool(source, "editor.page_guide", "gutter_icon", true),
        .overview_ruler = parseBool(source, "editor.page_guide", "overview_ruler", true),
    };
}

fn parsePreviewOpenMode(source: []const u8, section: []const u8, key: []const u8, default: PreviewOpenMode) PreviewOpenMode {
    const value = parseString(source, section, key) orelse return default;
    return std.meta.stringToEnum(PreviewOpenMode, value) orelse default;
}

fn parseHighlightConfig(allocator: std.mem.Allocator, project_dir: []const u8, source: []const u8) !highlight.Config {
    var languages = std.ArrayList(highlight.Language).empty;
    errdefer {
        for (languages.items) |*language| language.deinit(allocator);
        languages.deinit(allocator);
    }

    var current: ?HighlightLanguageBuilder = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const comment_start = tomlCommentStart(line_raw);
        const line = std.mem.trim(u8, line_raw[0..comment_start], " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try finishHighlightLanguage(allocator, project_dir, &languages, &current);
            current = null;
            if (highlightLanguageSectionName(line)) |name| {
                current = .{ .name = name };
            }
            continue;
        }

        if (current) |*builder| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const value = parseTomlStringValue(std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse continue;
            if (std.mem.eql(u8, key, "parser")) {
                builder.parser = value;
            } else if (std.mem.eql(u8, key, "query")) {
                builder.query = value;
            } else {
                return error.UnknownHighlightLanguageField;
            }
        }
    }
    try finishHighlightLanguage(allocator, project_dir, &languages, &current);

    return .{ .languages = try languages.toOwnedSlice(allocator) };
}

const HighlightLanguageBuilder = struct {
    name: []const u8,
    parser: ?[]const u8 = null,
    query: ?[]const u8 = null,
};

const HighlightSpanBuilder = struct {
    name: []const u8,
    section_span: utils.err.ByteSpan,
    parser: ?[]const u8 = null,
    parser_span: ?utils.err.ByteSpan = null,
    query: ?[]const u8 = null,
};

fn highlightConfigErrorSpan(source: []const u8, err: anyerror) ?utils.err.ByteSpan {
    var current: ?HighlightSpanBuilder = null;
    var line_start: usize = 0;
    while (line_start <= source.len) {
        const raw_line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line_end = if (raw_line_end > line_start and source[raw_line_end - 1] == '\r') raw_line_end - 1 else raw_line_end;
        const comment_start = line_start + tomlCommentStart(source[line_start..line_end]);
        const bounds = trimmedBounds(source, line_start, comment_start);
        const line = source[bounds.start..bounds.end];

        if (line.len != 0 and line[0] == '[') {
            if (finishHighlightSpan(source, current, err)) |span| return span;
            current = null;
            if (highlightLanguageSectionName(line)) |name| {
                current = .{
                    .name = name,
                    .section_span = .{ .start = bounds.start, .end = bounds.end },
                };
            }
        } else if (current) |*builder| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                if (raw_line_end == source.len) break;
                line_start = raw_line_end + 1;
                continue;
            };
            const key_bounds = trimmedBounds(source, bounds.start, bounds.start + eq);
            const key = source[key_bounds.start..key_bounds.end];
            const value = parseTomlStringValue(std.mem.trim(u8, line[eq + 1 ..], " \t")) orelse {
                if (raw_line_end == source.len) break;
                line_start = raw_line_end + 1;
                continue;
            };
            if (std.mem.eql(u8, key, "parser")) {
                builder.parser = value;
                builder.parser_span = .{ .start = bounds.start, .end = bounds.end };
            } else if (std.mem.eql(u8, key, "query")) {
                builder.query = value;
            } else if (err == error.UnknownHighlightLanguageField) {
                return .{ .start = bounds.start, .end = bounds.end };
            }
        }

        if (raw_line_end == source.len) break;
        line_start = raw_line_end + 1;
    }
    return finishHighlightSpan(source, current, err);
}

fn finishHighlightSpan(
    source: []const u8,
    current: ?HighlightSpanBuilder,
    err: anyerror,
) ?utils.err.ByteSpan {
    const builder = current orelse return null;
    if (highlight.isBuiltinLanguageName(builder.name)) {
        return if (err == error.BuiltinHighlightLanguageReserved) builder.section_span else null;
    }
    if (builder.parser == null) {
        return if (err == error.MissingHighlightParser) builder.section_span else null;
    }
    if (!highlight.isBuiltinParserName(builder.parser.?)) {
        return if (err == error.UnknownHighlightParser) builder.parser_span orelse builder.section_span else null;
    }
    if (builder.query == null) {
        return if (err == error.MissingHighlightQuery) builder.section_span else null;
    }
    if (hasPreviousHighlightLanguage(source, builder.name, builder.section_span.start)) {
        return if (err == error.DuplicateHighlightLanguage) builder.section_span else null;
    }
    return null;
}

fn hasPreviousHighlightLanguage(source: []const u8, name: []const u8, before: usize) bool {
    var line_start: usize = 0;
    while (line_start < before and line_start < source.len) {
        const raw_line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line_end = if (raw_line_end > line_start and source[raw_line_end - 1] == '\r') raw_line_end - 1 else raw_line_end;
        const comment_start = line_start + tomlCommentStart(source[line_start..line_end]);
        const bounds = trimmedBounds(source, line_start, comment_start);
        const line = source[bounds.start..bounds.end];
        if (line.len != 0 and line[0] == '[') {
            if (highlightLanguageSectionName(line)) |found| {
                if (std.ascii.eqlIgnoreCase(found, name)) return true;
            }
        }
        if (raw_line_end == source.len) break;
        line_start = raw_line_end + 1;
    }
    return false;
}

fn finishHighlightLanguage(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    languages: *std.ArrayList(highlight.Language),
    current: *?HighlightLanguageBuilder,
) !void {
    const builder = current.* orelse return;
    current.* = null;
    if (highlight.isBuiltinLanguageName(builder.name)) return error.BuiltinHighlightLanguageReserved;
    const parser = builder.parser orelse return error.MissingHighlightParser;
    if (!highlight.isBuiltinParserName(parser)) return error.UnknownHighlightParser;
    const query = builder.query orelse return error.MissingHighlightQuery;
    for (languages.items) |language| {
        if (std.ascii.eqlIgnoreCase(language.name, builder.name)) return error.DuplicateHighlightLanguage;
    }

    var language = highlight.Language{
        .name = try allocator.dupe(u8, builder.name),
        .parser = try allocator.dupe(u8, parser),
        .query = try resolveHighlightValue(allocator, project_dir, query),
    };
    errdefer language.deinit(allocator);
    try languages.append(allocator, language);
}

fn resolveHighlightValue(allocator: std.mem.Allocator, project_dir: []const u8, value: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, value, "builtin:")) return allocator.dupe(u8, value);
    return resolveAgainst(allocator, project_dir, value);
}

fn highlightLanguageSectionName(line: []const u8) ?[]const u8 {
    if (line.len < 2 or line[0] != '[' or line[line.len - 1] != ']') return null;
    const section = line[1 .. line.len - 1];
    const prefix = "highlight.languages.";
    if (!std.mem.startsWith(u8, section, prefix)) return null;
    const name = section[prefix.len..];
    if (name.len == 0) return null;
    return name;
}

fn parseTomlStringValue(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn parseBool(source: []const u8, section: []const u8, key: []const u8, default: bool) bool {
    const value = parseValue(source, section, key) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return default;
}

fn parseU64(source: []const u8, section: []const u8, key: []const u8, default: u64) u64 {
    const value = parseValue(source, section, key) orelse return default;
    return std.fmt.parseUnsigned(u64, value, 10) catch default;
}

fn parseString(source: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    const value = parseValue(source, section, key) orelse return null;
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return null;
    return value[1 .. value.len - 1];
}

fn parseValue(source: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var in_target_section = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line_raw| {
        const comment_start = tomlCommentStart(line_raw);
        const line = std.mem.trim(u8, line_raw[0..comment_start], " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_target_section = sectionHeaderMatches(line, section);
            continue;
        }
        if (!in_target_section) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        if (!std.mem.eql(u8, name, key)) continue;
        return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

const TomlSpanQuery = struct {
    section: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

fn tomlSpan(source: []const u8, query: TomlSpanQuery) ?utils.err.ByteSpan {
    var in_target_section = false;
    var line_start: usize = 0;
    while (line_start <= source.len) {
        const raw_line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line_end = if (raw_line_end > line_start and source[raw_line_end - 1] == '\r') raw_line_end - 1 else raw_line_end;
        const comment_start = line_start + tomlCommentStart(source[line_start..line_end]);
        const bounds = trimmedBounds(source, line_start, comment_start);
        const line = source[bounds.start..bounds.end];

        if (line.len != 0 and line[0] == '[') {
            in_target_section = if (query.section) |section| sectionHeaderMatches(line, section) else false;
            if (in_target_section and query.key == null) return .{ .start = bounds.start, .end = bounds.end };
        } else if (in_target_section) {
            if (query.key) |wanted_key| {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
                    if (raw_line_end == source.len) break;
                    line_start = raw_line_end + 1;
                    continue;
                };
                const key_bounds = trimmedBounds(source, bounds.start, bounds.start + eq);
                const key_text = source[key_bounds.start..key_bounds.end];
                if (std.mem.eql(u8, key_text, wanted_key)) return .{ .start = bounds.start, .end = bounds.end };
            }
        }

        if (raw_line_end == source.len) break;
        line_start = raw_line_end + 1;
    }
    return null;
}

fn trimmedBounds(source: []const u8, start: usize, end: usize) utils.err.ByteSpan {
    var first = start;
    while (first < end and (source[first] == ' ' or source[first] == '\t' or source[first] == '\r')) first += 1;
    var last = end;
    while (last > first and (source[last - 1] == ' ' or source[last - 1] == '\t' or source[last - 1] == '\r')) last -= 1;
    return .{ .start = first, .end = last };
}

fn sectionHeaderMatches(line: []const u8, section: []const u8) bool {
    if (line.len != section.len + 2) return false;
    if (line[0] != '[' or line[line.len - 1] != ']') return false;
    return std.mem.eql(u8, line[1 .. line.len - 1], section);
}

fn tomlCommentStart(line: []const u8) usize {
    var in_string = false;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        if (byte == '"') {
            in_string = true;
        } else if (byte == '#') {
            return index;
        }
    }
    return line.len;
}

fn resolveAgainst(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.resolve(allocator, &.{ base, path });
}

pub fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd = try cwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

fn cwdAlloc(allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&buffer, buffer.len) == null) return error.CurrentWorkingDirectoryUnavailable;
    const len = std.mem.indexOfScalar(u8, &buffer, 0) orelse return error.NameTooLong;
    return allocator.dupe(u8, buffer[0..len]);
}

fn dirnameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return absolutePath(allocator, dir);
}
