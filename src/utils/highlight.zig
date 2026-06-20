const std = @import("std");

pub const Language = struct {
    name: []u8,
    parser: []u8,
    query: []u8,
    library: ?[]u8 = null,
    symbol: ?[]u8 = null,

    pub fn deinit(self: *Language, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parser);
        allocator.free(self.query);
        if (self.library) |value| allocator.free(value);
        if (self.symbol) |value| allocator.free(value);
    }

    pub fn clone(self: Language, allocator: std.mem.Allocator) !Language {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .parser = try allocator.dupe(u8, self.parser),
            .query = try allocator.dupe(u8, self.query),
            .library = if (self.library) |value| try allocator.dupe(u8, value) else null,
            .symbol = if (self.symbol) |value| try allocator.dupe(u8, value) else null,
        };
    }
};

pub const Config = struct {
    languages: []Language = &.{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.languages) |*language| language.deinit(allocator);
        allocator.free(self.languages);
    }

    pub fn clone(self: Config, allocator: std.mem.Allocator) !Config {
        var languages = std.ArrayList(Language).empty;
        errdefer {
            for (languages.items) |*language| language.deinit(allocator);
            languages.deinit(allocator);
        }
        for (self.languages) |language| {
            try languages.append(allocator, try language.clone(allocator));
        }
        return .{ .languages = try languages.toOwnedSlice(allocator) };
    }
};

pub const BuiltinLanguage = struct {
    name: []const u8,
    parser: []const u8,
    query: []const u8,
};

pub const CaptureRole = enum {
    plain,
    keyword,
    function,
    type,
    constant,
    number,
    variable,
    operator,
    comment,
    string,
};

pub const builtin_languages = [_]BuiltinLanguage{
    .{ .name = "ss", .parser = "ss", .query = "builtin:ss" },
    .{ .name = "bash", .parser = "bash", .query = "builtin:bash" },
    .{ .name = "sh", .parser = "bash", .query = "builtin:bash" },
    .{ .name = "shell", .parser = "bash", .query = "builtin:bash" },
    .{ .name = "c", .parser = "c", .query = "builtin:c" },
    .{ .name = "cpp", .parser = "cpp", .query = "builtin:cpp" },
    .{ .name = "c++", .parser = "cpp", .query = "builtin:cpp" },
    .{ .name = "cc", .parser = "cpp", .query = "builtin:cpp" },
    .{ .name = "css", .parser = "css", .query = "builtin:css" },
    .{ .name = "go", .parser = "go", .query = "builtin:go" },
    .{ .name = "golang", .parser = "go", .query = "builtin:go" },
    .{ .name = "html", .parser = "html", .query = "builtin:html" },
    .{ .name = "java", .parser = "java", .query = "builtin:java" },
    .{ .name = "javascript", .parser = "javascript", .query = "builtin:javascript" },
    .{ .name = "js", .parser = "javascript", .query = "builtin:javascript" },
    .{ .name = "json", .parser = "json", .query = "builtin:json" },
    .{ .name = "julia", .parser = "julia", .query = "builtin:julia" },
    .{ .name = "jl", .parser = "julia", .query = "builtin:julia" },
    .{ .name = "python", .parser = "python", .query = "builtin:python" },
    .{ .name = "py", .parser = "python", .query = "builtin:python" },
    .{ .name = "rust", .parser = "rust", .query = "builtin:rust" },
    .{ .name = "rs", .parser = "rust", .query = "builtin:rust" },
    .{ .name = "toml", .parser = "toml", .query = "builtin:toml" },
    .{ .name = "typescript", .parser = "typescript", .query = "builtin:typescript" },
    .{ .name = "ts", .parser = "typescript", .query = "builtin:typescript" },
    .{ .name = "tsx", .parser = "tsx", .query = "builtin:typescript" },
    .{ .name = "yaml", .parser = "yaml", .query = "builtin:yaml" },
    .{ .name = "yml", .parser = "yaml", .query = "builtin:yaml" },
    .{ .name = "zig", .parser = "zig", .query = "builtin:zig" },
};

pub fn defaultConfig(allocator: std.mem.Allocator) !Config {
    return configWithDefaults(allocator, &.{});
}

pub fn configWithDefaults(allocator: std.mem.Allocator, overrides: []const Language) !Config {
    var languages = std.ArrayList(Language).empty;
    errdefer {
        for (languages.items) |*language| language.deinit(allocator);
        languages.deinit(allocator);
    }

    for (builtin_languages) |language| {
        try languages.append(allocator, try cloneBuiltinLanguage(allocator, language));
    }
    for (overrides) |language| {
        if (languageIndex(languages.items, language.name)) |index| {
            const replacement = try language.clone(allocator);
            languages.items[index].deinit(allocator);
            languages.items[index] = replacement;
        } else {
            try languages.append(allocator, try language.clone(allocator));
        }
    }

    return .{ .languages = try languages.toOwnedSlice(allocator) };
}

fn cloneBuiltinLanguage(allocator: std.mem.Allocator, language: BuiltinLanguage) !Language {
    const name = try allocator.dupe(u8, language.name);
    errdefer allocator.free(name);
    const parser = try allocator.dupe(u8, language.parser);
    errdefer allocator.free(parser);
    const query = try allocator.dupe(u8, language.query);
    return .{
        .name = name,
        .parser = parser,
        .query = query,
    };
}

fn languageIndex(languages: []const Language, name: []const u8) ?usize {
    for (languages, 0..) |language, index| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return index;
    }
    return null;
}

pub fn roleForCapture(capture_name: []const u8) ?CaptureRole {
    if (capture_name.len == 0) return null;
    if (captureHasSegment(capture_name, "comment")) return .comment;
    if (captureHasSegment(capture_name, "escape")) return .string;
    if (captureHasSegment(capture_name, "string")) return .string;
    if (captureHasSegment(capture_name, "character")) return .string;
    if (captureHasSegment(capture_name, "operator")) return .operator;
    if (captureHasSegment(capture_name, "punctuation")) return .operator;
    if (captureHasSegment(capture_name, "delimiter")) return .operator;
    if (captureHasSegment(capture_name, "keyword")) return .keyword;
    if (captureHasSegment(capture_name, "import")) return .keyword;
    if (captureHasSegment(capture_name, "media")) return .keyword;
    if (captureHasSegment(capture_name, "supports")) return .keyword;
    if (captureHasSegment(capture_name, "charset")) return .keyword;
    if (captureHasSegment(capture_name, "keyframes")) return .keyword;
    if (std.mem.eql(u8, capture_name, "cImport")) return .function;
    if (captureHasSegment(capture_name, "function")) return .function;
    if (captureHasSegment(capture_name, "method")) return .function;
    if (captureHasSegment(capture_name, "macro")) return .function;
    if (captureHasSegment(capture_name, "constructor")) return .type;
    if (captureHasSegment(capture_name, "type")) return .type;
    if (captureHasSegment(capture_name, "namespace")) return .type;
    if (captureHasSegment(capture_name, "module")) return .type;
    if (captureHasSegment(capture_name, "tag")) return .type;
    if (captureHasSegment(capture_name, "number")) return .number;
    if (captureHasSegment(capture_name, "float")) return .number;
    if (captureHasSegment(capture_name, "constant")) return .constant;
    if (captureHasSegment(capture_name, "boolean")) return .constant;
    if (captureHasSegment(capture_name, "attribute")) return .constant;
    if (captureHasSegment(capture_name, "label")) return .constant;
    if (captureHasSegment(capture_name, "property")) return .variable;
    if (captureHasSegment(capture_name, "field")) return .variable;
    if (captureHasSegment(capture_name, "parameter")) return .variable;
    if (captureHasSegment(capture_name, "member")) return .variable;
    if (captureHasSegment(capture_name, "variable")) return .variable;
    if (std.mem.startsWith(u8, capture_name, "_")) return .operator;
    return null;
}

fn captureHasSegment(capture_name: []const u8, segment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, capture_name, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, segment)) return true;
    }
    return false;
}
