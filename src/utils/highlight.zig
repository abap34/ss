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
