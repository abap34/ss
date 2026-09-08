const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils");
const highlight = utils.highlight;
const source = utils.source;
const error_report = utils.err;
pub const toml = @import("project/toml.zig");
pub const ConfigDiagnostic = toml.Diagnostic;
pub const max_editor_delay_ms = std.math.maxInt(i32);

pub const Config = struct {
    path: []u8,
    dir: []u8,
    entry: []u8,
    asset_base_dir: []u8,
    lsp: LspConfig = .{},
    wysiwyg: WysiwygConfig = .{},
    page_guide: PageGuideConfig = .{},
    highlight: highlight.Config = .{},
    cli: CliConfig = .{},
    cache: utils.render_cache.Config = .{},

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
    document_symbols: bool = true,
    folding_ranges: bool = true,
    semantic_tokens: bool = true,
    colors: bool = true,
};

pub const WysiwygConfig = struct {
    enabled: bool = true,
    debounce_ms: u64 = 140,
    max_wait_ms: u64 = 700,
    refresh_automatically: bool = true,
    refresh_on_dependency_change: bool = true,
};

pub const PageGuideConfig = struct {
    enabled: bool = true,
    body_background: bool = true,
    boundary: bool = true,
    boundary_background: bool = true,
    gutter_icon: bool = true,
    overview_ruler: bool = true,
};

pub const CliConfig = struct {
    diagnostic_level: ?error_report.DiagnosticLevel = null,
    jobs: ?usize = null,
};

pub const Resolved = struct {
    entry_path: []u8,
    asset_base_dir: []u8,
    project_file: ?[]u8 = null,
    project_dir: ?[]u8 = null,
    highlight: highlight.Config = .{},
    cli: CliConfig = .{},
    cache: utils.render_cache.Config = .{},

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
        .cli = if (config) |cfg| cfg.cli else .{},
        .cache = if (config) |cfg| cfg.cache else .{},
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
    var paths = try ConfigurationSearch.init(allocator, start_dir);
    defer paths.deinit(allocator);
    while (try paths.next(allocator)) |candidate| {
        errdefer allocator.free(candidate);
        if (try utils.fs.fileExists(allocator, candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

const ConfigurationSearch = struct {
    start: []u8,
    current: ?[]const u8,

    fn init(allocator: std.mem.Allocator, start_dir: []const u8) !ConfigurationSearch {
        const start = try absolutePath(allocator, start_dir);
        return .{ .start = start, .current = start };
    }

    fn deinit(self: *ConfigurationSearch, allocator: std.mem.Allocator) void {
        allocator.free(self.start);
    }

    fn next(self: *ConfigurationSearch, allocator: std.mem.Allocator) !?[]u8 {
        const current = self.current orelse return null;
        const candidate = try std.fs.path.join(allocator, &.{ current, "ss.toml" });
        const parent = std.fs.path.dirname(current);
        self.current = if (parent != null and !std.mem.eql(u8, parent.?, current)) parent else null;
        return candidate;
    }
};

// Include missing candidates so creating a nearer configuration changes discovery.
pub fn configurationPaths(allocator: std.mem.Allocator, input_path: ?[]const u8, project_arg: ?[]const u8) ![][]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    if (project_arg) |arg| {
        const path = try projectArgumentPath(allocator, arg);
        errdefer allocator.free(path);
        try paths.append(allocator, path);
    } else {
        const input = if (input_path) |path| try absolutePath(allocator, path) else null;
        defer if (input) |path| allocator.free(path);
        var search = try ConfigurationSearch.init(allocator, if (input) |path| std.fs.path.dirname(path) orelse "." else ".");
        defer search.deinit(allocator);
        while (try search.next(allocator)) |path| {
            errdefer allocator.free(path);
            try paths.append(allocator, path);
        }
    }
    return try paths.toOwnedSlice(allocator);
}

pub fn isConfigError(err: anyerror) bool {
    return switch (err) {
        error.InvalidToml,
        error.UnknownConfigKey,
        error.InvalidConfigTable,
        error.InvalidProjectPath,
        error.InvalidEditorSetting,
        error.MissingProjectEntry,
        error.UnknownHighlightLanguageField,
        error.BuiltinHighlightLanguageReserved,
        error.MissingHighlightParser,
        error.MissingHighlightQuery,
        error.UnknownHighlightParser,
        error.DuplicateHighlightLanguage,
        error.InvalidDiagnosticLevel,
        error.InvalidCliJobs,
        error.InvalidCacheAutomaticPruning,
        error.InvalidCacheMaxSize,
        error.InvalidCachePruneInterval,
        => true,
        else => false,
    };
}

pub fn configErrorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.InvalidToml => "InvalidToml: use valid TOML 1.1, including quoted strings and unique keys and tables",
        error.UnknownConfigKey => "UnknownConfigKey: remove or correct the unsupported configuration key",
        error.InvalidConfigTable => "InvalidConfigTable: this configuration section must be a TOML table",
        error.InvalidProjectPath => "InvalidProjectPath: use a string path without NUL characters and a non-empty project entry",
        error.InvalidEditorSetting => "InvalidEditorSetting: use booleans for switches and integers from 0 to 2147483647 for millisecond delays",
        error.MissingProjectEntry => "MissingProjectEntry: add or set 'entry = \"path/to/slides.ss\"' under [project] using a quoted path",
        error.UnknownHighlightLanguageField => "UnknownHighlightLanguageField: remove the unsupported key from the highlight language section",
        error.BuiltinHighlightLanguageReserved => "BuiltinHighlightLanguageReserved: rename the custom language because its name is reserved by a built-in language",
        error.MissingHighlightParser => "MissingHighlightParser: add or set the parser key in the highlight language section using a quoted built-in parser name",
        error.MissingHighlightQuery => "MissingHighlightQuery: add or set the query key in the highlight language section using a quoted path or builtin:name value",
        error.UnknownHighlightParser => "UnknownHighlightParser: use a supported built-in tree-sitter parser name",
        error.DuplicateHighlightLanguage => "DuplicateHighlightLanguage: each highlight language name may be declared only once",
        error.InvalidDiagnosticLevel => "InvalidDiagnosticLevel: use note, warning, error, or off for cli.diagnostic_level",
        error.InvalidCliJobs => "InvalidCliJobs: cli.jobs must be a positive integer",
        error.InvalidCacheAutomaticPruning => "InvalidCacheAutomaticPruning: cache.automatic_pruning must be true or false",
        error.InvalidCacheMaxSize => "InvalidCacheMaxSize: cache.max_size_mib must be a positive integer whose byte value fits in 64 bits",
        error.InvalidCachePruneInterval => "InvalidCachePruneInterval: cache.prune_interval_seconds must be a non-negative integer",
        else => null,
    };
}

pub fn loadProjectArgument(allocator: std.mem.Allocator, io: std.Io, arg: []const u8) !Config {
    const path = try projectArgumentPath(allocator, arg);
    defer allocator.free(path);
    return try loadFile(allocator, io, path);
}

pub fn projectArgumentPath(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    const absolute = try absolutePath(allocator, arg);
    defer allocator.free(absolute);
    return if (std.mem.endsWith(u8, absolute, ".toml"))
        try allocator.dupe(u8, absolute)
    else
        try std.fs.path.join(allocator, &.{ absolute, "ss.toml" });
}

pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
    const text = try utils.fs.readFileAlloc(io, allocator, path);
    defer allocator.free(text);
    return parseSource(allocator, path, text);
}

pub fn parseSource(allocator: std.mem.Allocator, path: []const u8, text: []const u8) !Config {
    return parseSourceWithDiagnostic(allocator, path, text, null);
}

pub fn parseSourceWithDiagnostic(allocator: std.mem.Allocator, path: []const u8, text: []const u8, diagnostic: ?*ConfigDiagnostic) !Config {
    var document = try toml.Document.parse(text, diagnostic);
    defer document.deinit();
    const root = document.root();
    try document.keys(root, &.{ "project", "cli", "cache", "editor", "highlight" }, error.UnknownConfigKey);
    const project_table = try document.table(root, "project");
    try document.keys(project_table, &.{ "entry", "asset_base_dir" }, error.UnknownConfigKey);
    const raw_entry = try document.string(project_table, "entry", error.InvalidProjectPath) orelse
        return document.fail(project_table, error.MissingProjectEntry);
    const raw_asset_base = try document.string(project_table, "asset_base_dir", error.InvalidProjectPath);
    if (raw_entry.len == 0 or std.mem.indexOfScalar(u8, raw_entry, 0) != null)
        return document.fail(toml.get(project_table, "entry"), error.InvalidProjectPath);
    if (raw_asset_base) |value| {
        if (std.mem.indexOfScalar(u8, value, 0) != null)
            return document.fail(toml.get(project_table, "asset_base_dir"), error.InvalidProjectPath);
    }
    const dir = try dirnameAlloc(allocator, path);
    errdefer allocator.free(dir);
    const entry = try resolveAgainst(allocator, dir, raw_entry);
    errdefer allocator.free(entry);
    const asset_base_dir = if (raw_asset_base) |value|
        try resolveAgainst(allocator, dir, value)
    else
        try dirnameAlloc(allocator, entry);
    errdefer allocator.free(asset_base_dir);

    const editor = try document.table(root, "editor");
    try document.keys(editor, &.{ "lsp", "wysiwyg", "page_guide" }, error.UnknownConfigKey);
    const lsp_config = try parseFlatSettings(LspConfig, &document, try document.table(editor, "lsp"));
    const wysiwyg_config = try parseWysiwygConfig(&document, try document.table(editor, "wysiwyg"));
    const page_guide_config = try parseFlatSettings(PageGuideConfig, &document, try document.table(editor, "page_guide"));
    const cli_config = try parseCliConfig(&document, try document.table(root, "cli"));
    const cache_config = try parseCacheConfig(&document, try document.table(root, "cache"));
    var parsed_highlight = try parseHighlightConfig(allocator, dir, &document);
    defer parsed_highlight.deinit(allocator);
    var highlight_config = try highlight.configWithDefaults(allocator, parsed_highlight.languages);
    errdefer highlight_config.deinit(allocator);

    return .{
        .path = try allocator.dupe(u8, path),
        .dir = dir,
        .entry = entry,
        .asset_base_dir = asset_base_dir,
        .lsp = lsp_config,
        .wysiwyg = wysiwyg_config,
        .page_guide = page_guide_config,
        .highlight = highlight_config,
        .cli = cli_config,
        .cache = cache_config,
    };
}

pub fn configErrorSpan(text: []const u8, err: anyerror) ?source.ByteSpan {
    return configErrorDiagnostic(text, err).span;
}

pub fn configErrorDiagnostic(text: []const u8, err: anyerror) ConfigDiagnostic {
    var diagnostic = ConfigDiagnostic{};
    var config = parseSourceWithDiagnostic(std.heap.page_allocator, "/ss.toml", text, &diagnostic) catch |actual| return if (actual == err) diagnostic else .{};
    config.deinit(std.heap.page_allocator);
    return .{};
}

pub fn tomlKeySpan(text: []const u8, section_name: []const u8, key: []const u8) ?source.ByteSpan {
    var document = toml.Document.parse(text, null) catch return null;
    defer document.deinit();
    var table = document.root();
    var names = std.mem.splitScalar(u8, section_name, '.');
    while (names.next()) |name| table = toml.get(table, name);
    return document.span(toml.get(table, key));
}

fn settingKey(comptime field: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, field, "_ms")) field[0 .. field.len - 3] else field;
}

fn parseFlatSettings(comptime T: type, document: *const toml.Document, table: toml.Value) !T {
    const fields = std.meta.fields(T);
    const keys = comptime blk: {
        var names: [fields.len][]const u8 = undefined;
        for (fields, 0..) |field, i| names[i] = settingKey(field.name);
        break :blk names;
    };
    try document.keys(table, &keys, error.UnknownConfigKey);
    var result = T{};
    inline for (fields) |field| {
        const key = comptime settingKey(field.name);
        @field(result, field.name) = switch (field.type) {
            bool => try document.boolean(table, key, @field(result, field.name), error.InvalidEditorSetting),
            u64 => (try document.integer(table, key, @field(result, field.name), 0, max_editor_delay_ms, error.InvalidEditorSetting)).?,
            else => @compileError("Unsupported project setting type"),
        };
    }
    return result;
}

fn parseWysiwygConfig(document: *const toml.Document, table: toml.Value) !WysiwygConfig {
    try document.keys(table, &.{ "enabled", "debounce", "max_wait", "refresh" }, error.UnknownConfigKey);
    const refresh = try document.table(table, "refresh");
    try document.keys(refresh, &.{ "automatic", "dependency" }, error.UnknownConfigKey);
    var config = WysiwygConfig{};
    config.enabled = try document.boolean(table, "enabled", config.enabled, error.InvalidEditorSetting);
    config.debounce_ms = (try document.integer(table, "debounce", config.debounce_ms, 0, max_editor_delay_ms, error.InvalidEditorSetting)).?;
    config.max_wait_ms = (try document.integer(table, "max_wait", config.max_wait_ms, 0, max_editor_delay_ms, error.InvalidEditorSetting)).?;
    config.refresh_automatically = try document.boolean(refresh, "automatic", config.refresh_automatically, error.InvalidEditorSetting);
    config.refresh_on_dependency_change = try document.boolean(refresh, "dependency", config.refresh_on_dependency_change, error.InvalidEditorSetting);
    return config;
}

fn parseCliConfig(document: *const toml.Document, table: toml.Value) !CliConfig {
    try document.keys(table, &.{ "diagnostic_level", "jobs" }, error.UnknownConfigKey);
    var config = CliConfig{};
    if (try document.string(table, "diagnostic_level", error.InvalidDiagnosticLevel)) |value| {
        config.diagnostic_level = error_report.parseDiagnosticLevel(value) orelse
            return document.fail(toml.get(table, "diagnostic_level"), error.InvalidDiagnosticLevel);
    }
    if (try document.integer(table, "jobs", null, 1, std.math.maxInt(usize), error.InvalidCliJobs)) |value| config.jobs = @intCast(value);
    return config;
}

fn parseCacheConfig(document: *const toml.Document, table: toml.Value) !utils.render_cache.Config {
    try document.keys(table, &.{ "automatic_pruning", "max_size_mib", "prune_interval_seconds" }, error.UnknownConfigKey);
    var config = utils.render_cache.Config{};
    config.automatic_pruning = try document.boolean(table, "automatic_pruning", config.automatic_pruning, error.InvalidCacheAutomaticPruning);
    config.max_size_mib = (try document.integer(table, "max_size_mib", config.max_size_mib, 1, std.math.maxInt(u64) / (1024 * 1024), error.InvalidCacheMaxSize)).?;
    config.prune_interval_seconds = (try document.integer(table, "prune_interval_seconds", config.prune_interval_seconds, 0, std.math.maxInt(u64), error.InvalidCachePruneInterval)).?;
    return config;
}

fn parseHighlightConfig(allocator: std.mem.Allocator, project_dir: []const u8, document: *const toml.Document) !highlight.Config {
    const table = try document.table(document.root(), "highlight");
    try document.keys(table, &.{"languages"}, error.UnknownConfigKey);
    const languages_table = try document.table(table, "languages");
    var languages = std.ArrayList(highlight.Language).empty;
    errdefer {
        for (languages.items) |*language| language.deinit(allocator);
        languages.deinit(allocator);
    }
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (0..toml.tableSize(languages_table)) |i| {
        const name = toml.keyAt(languages_table, i);
        const language_table = try document.table(languages_table, name);
        try document.keys(language_table, &.{ "parser", "query" }, error.UnknownHighlightLanguageField);
        if (highlight.isBuiltinLanguageName(name)) return document.fail(language_table, error.BuiltinHighlightLanguageReserved);
        const parser = try document.string(language_table, "parser", error.MissingHighlightParser) orelse
            return document.fail(language_table, error.MissingHighlightParser);
        if (!highlight.isBuiltinParserName(parser)) return document.fail(toml.get(language_table, "parser"), error.UnknownHighlightParser);
        const query = try document.string(language_table, "query", error.MissingHighlightQuery) orelse
            return document.fail(language_table, error.MissingHighlightQuery);
        if (std.mem.indexOfScalar(u8, query, 0) != null) return document.fail(toml.get(language_table, "query"), error.MissingHighlightQuery);
        const owned_name = try std.ascii.allocLowerString(allocator, name);
        errdefer allocator.free(owned_name);
        const found = try names.getOrPut(owned_name);
        if (found.found_existing) return document.fail(language_table, error.DuplicateHighlightLanguage);
        const owned_parser = try allocator.dupe(u8, parser);
        errdefer allocator.free(owned_parser);
        const owned_query = if (std.mem.startsWith(u8, query, "builtin:"))
            try allocator.dupe(u8, query)
        else
            try resolveAgainst(allocator, project_dir, query);
        errdefer allocator.free(owned_query);
        try languages.append(allocator, .{ .name = owned_name, .parser = owned_parser, .query = owned_query });
    }
    return .{ .languages = try languages.toOwnedSlice(allocator) };
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

pub fn pathsReferToSameFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    left_path: []const u8,
    right_path: []const u8,
) !bool {
    const left_absolute = try absolutePath(allocator, left_path);
    defer allocator.free(left_absolute);
    const right_absolute = try absolutePath(allocator, right_path);
    defer allocator.free(right_absolute);
    if (std.mem.eql(u8, left_absolute, right_absolute)) return true;

    const cwd = std.Io.Dir.cwd();
    var left_file = cwd.openFile(io, left_absolute, .{}) catch return false;
    defer left_file.close(io);
    var right_file = cwd.openFile(io, right_absolute, .{}) catch return false;
    defer right_file.close(io);

    const left_identity = fileIdentity(left_file) orelse return false;
    const right_identity = fileIdentity(right_file) orelse return false;
    return left_identity.device_major == right_identity.device_major and
        left_identity.device_minor == right_identity.device_minor and
        left_identity.inode == right_identity.inode;
}

const FileIdentity = struct {
    device_major: u64,
    device_minor: u64,
    inode: u64,
};

fn fileIdentity(file: std.Io.File) ?FileIdentity {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var statx = std.mem.zeroes(linux.Statx);
        const request: linux.STATX = .{ .INO = true };
        if (linux.errno(linux.statx(file.handle, "", linux.AT.EMPTY_PATH, request, &statx)) != .SUCCESS) return null;
        if (!statx.mask.INO) return null;
        return .{
            .device_major = statx.dev_major,
            .device_minor = statx.dev_minor,
            .inode = statx.ino,
        };
    }
    if (comptime std.c.Stat == void or !@hasDecl(std.c, "fstat")) return null;
    var stat = std.mem.zeroes(std.c.Stat);
    if (std.c.errno(std.c.fstat(file.handle, &stat)) != .SUCCESS) return null;
    return .{
        .device_major = @intCast(stat.dev),
        .device_minor = 0,
        .inode = @intCast(stat.ino),
    };
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
