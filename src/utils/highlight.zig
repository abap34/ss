const std = @import("std");

pub const Language = struct {
    name: []u8,
    parser: []u8,
    query: []u8,

    pub fn deinit(self: *Language, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.parser);
        allocator.free(self.query);
    }

    pub fn clone(self: Language, allocator: std.mem.Allocator) !Language {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .parser = try allocator.dupe(u8, self.parser),
            .query = try allocator.dupe(u8, self.query),
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

const CaptureRuleKind = enum {
    segment,
    exact,
    prefix,
};

const CaptureRule = struct {
    kind: CaptureRuleKind = .segment,
    name: []const u8,
    role: CaptureRole,
};

const capture_rules = [_]CaptureRule{
    .{ .name = "comment", .role = .comment },
    .{ .name = "escape", .role = .string },
    .{ .name = "string", .role = .string },
    .{ .name = "character", .role = .string },
    .{ .name = "operator", .role = .operator },
    .{ .name = "punctuation", .role = .operator },
    .{ .name = "delimiter", .role = .operator },
    .{ .name = "keyword", .role = .keyword },
    .{ .name = "import", .role = .keyword },
    .{ .name = "media", .role = .keyword },
    .{ .name = "supports", .role = .keyword },
    .{ .name = "charset", .role = .keyword },
    .{ .name = "keyframes", .role = .keyword },
    .{ .kind = .exact, .name = "cImport", .role = .function },
    .{ .name = "function", .role = .function },
    .{ .name = "method", .role = .function },
    .{ .name = "macro", .role = .function },
    .{ .name = "constructor", .role = .type },
    .{ .name = "type", .role = .type },
    .{ .name = "namespace", .role = .type },
    .{ .name = "module", .role = .type },
    .{ .name = "tag", .role = .type },
    .{ .name = "number", .role = .number },
    .{ .name = "float", .role = .number },
    .{ .name = "constant", .role = .constant },
    .{ .name = "boolean", .role = .constant },
    .{ .name = "attribute", .role = .constant },
    .{ .name = "label", .role = .constant },
    .{ .name = "property", .role = .variable },
    .{ .name = "field", .role = .variable },
    .{ .name = "parameter", .role = .variable },
    .{ .name = "member", .role = .variable },
    .{ .name = "variable", .role = .variable },
    .{ .kind = .prefix, .name = "_", .role = .operator },
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

pub fn configWithDefaults(allocator: std.mem.Allocator, additions: []const Language) !Config {
    var languages = std.ArrayList(Language).empty;
    errdefer {
        for (languages.items) |*language| language.deinit(allocator);
        languages.deinit(allocator);
    }

    for (builtin_languages) |language| {
        try languages.append(allocator, try cloneBuiltinLanguage(allocator, language));
    }
    for (additions) |language| {
        if (isBuiltinLanguageName(language.name)) return error.BuiltinHighlightLanguageReserved;
        if (languageIndex(languages.items, language.name) != null) return error.DuplicateHighlightLanguage;
        if (!isBuiltinParserName(language.parser)) return error.UnknownHighlightParser;
        try languages.append(allocator, try language.clone(allocator));
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

pub fn isBuiltinLanguageName(name: []const u8) bool {
    for (builtin_languages) |language| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return true;
    }
    return false;
}

pub fn isBuiltinParserName(name: []const u8) bool {
    return canonicalParserName(name) != null;
}

pub fn canonicalParserName(name: []const u8) ?[]const u8 {
    for (builtin_languages) |language| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return language.parser;
        if (std.ascii.eqlIgnoreCase(language.parser, name)) return language.parser;
    }
    return null;
}

pub fn findLanguage(languages: []const Language, name: []const u8) ?*const Language {
    for (languages) |*language| {
        if (std.ascii.eqlIgnoreCase(language.name, name)) return language;
    }
    return null;
}

pub fn roleForCapture(capture_name: []const u8) ?CaptureRole {
    if (capture_name.len == 0) return null;
    for (capture_rules) |rule| {
        const matches = switch (rule.kind) {
            .segment => captureHasSegment(capture_name, rule.name),
            .exact => std.mem.eql(u8, capture_name, rule.name),
            .prefix => std.mem.startsWith(u8, capture_name, rule.name),
        };
        if (matches) return rule.role;
    }
    return null;
}

fn captureHasSegment(capture_name: []const u8, segment: []const u8) bool {
    var parts = std.mem.splitScalar(u8, capture_name, '.');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, segment)) return true;
    }
    return false;
}
