const std = @import("std");
const utils = @import("utils");
const engine = @import("../syntax_highlight.zig");
const spans = @import("../highlight_spans.zig");
const Allocator = std.mem.Allocator;

const QueryKey = struct {
    language: *const anyopaque,
    source: []const u8,
    digest: u64,
};

const QueryKeyContext = struct {
    pub fn hash(_: QueryKeyContext, key: QueryKey) u64 {
        return key.digest ^ @as(u64, @intCast(@intFromPtr(key.language)));
    }

    pub fn eql(_: QueryKeyContext, left: QueryKey, right: QueryKey) bool {
        return left.language == right.language and std.mem.eql(u8, left.source, right.source);
    }
};

const SharedQuery = struct {
    allocator: Allocator,
    references: std.atomic.Value(usize) = .init(1),
    key: QueryKey,
    query: engine.Query,
    byte_size: usize,

    fn retain(self: *SharedQuery) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedQuery) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.query.deinit();
        self.allocator.free(self.key.source);
        self.allocator.destroy(self);
    }
};

const ContentKey = struct {
    query: ?*SharedQuery,
    content: []const u8,
    digest: u64,
};

const ContentKeyContext = struct {
    pub fn hash(_: ContentKeyContext, key: ContentKey) u64 {
        const identity: u64 = if (key.query) |query| @intCast(@intFromPtr(query)) else 0;
        return key.digest ^ identity;
    }

    pub fn eql(_: ContentKeyContext, left: ContentKey, right: ContentKey) bool {
        return left.query == right.query and std.mem.eql(u8, left.content, right.content);
    }
};

const SharedContent = struct {
    allocator: Allocator,
    references: std.atomic.Value(usize) = .init(1),
    key: ContentKey,
    segments: []spans.Segment,
    byte_size: usize,

    fn retain(self: *SharedContent) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *SharedContent) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        if (self.key.query) |query| query.release();
        self.allocator.free(self.key.content);
        self.allocator.free(self.segments);
        self.allocator.destroy(self);
    }
};

pub const Result = struct {
    owner: *SharedContent,

    pub fn segments(self: Result) []const spans.Segment {
        return self.owner.segments;
    }

    pub fn deinit(self: *Result) void {
        self.owner.release();
        self.* = undefined;
    }
};

fn Entry(comptime T: type) type {
    return struct { value: *T, last_used: u64 };
}

pub const Limits = struct {
    queries: usize = 32,
    query_bytes: usize = 2 * 1024 * 1024,
    contents: usize = 256,
    content_bytes: usize = 32 * 1024 * 1024,
};

pub const Stats = struct {
    query_compilations: usize = 0,
    content_analyses: usize = 0,
    query_entries: usize = 0,
    content_entries: usize = 0,
    query_bytes: usize = 0,
    content_bytes: usize = 0,
};

// Concurrent callers require a thread-safe allocator. I/O, query compilation,
// parsing, and segment construction occur outside the index mutex. Results keep
// their own references when entries are evicted or the cache is cleared.
pub const Cache = struct {
    allocator: Allocator,
    io: std.Io,
    limits: Limits = .{},
    mutex: std.Io.Mutex = .init,
    queries: std.HashMap(QueryKey, Entry(SharedQuery), QueryKeyContext, std.hash_map.default_max_load_percentage),
    contents: std.HashMap(ContentKey, Entry(SharedContent), ContentKeyContext, std.hash_map.default_max_load_percentage),
    clock: u64 = 0,
    counters: Stats = .{},

    pub fn init(allocator: Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io, .queries = .init(allocator), .contents = .init(allocator) };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.queries.deinit();
        self.contents.deinit();
    }

    pub fn clear(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.contents.count() != 0) self.evict(&self.contents, &self.counters.content_bytes);
        while (self.queries.count() != 0) self.evict(&self.queries, &self.counters.query_bytes);
    }

    pub fn stats(self: *Cache) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var result = self.counters;
        result.query_entries = self.queries.count();
        result.content_entries = self.contents.count();
        return result;
    }

    pub fn highlight(
        self: *Cache,
        languages: []const utils.highlight.Language,
        language_name: []const u8,
        content: []const u8,
        failure: *engine.Failure,
    ) !Result {
        failure.* = .none;
        try std.Io.checkCancel(self.io);
        const query = if (utils.highlight.findLanguage(languages, language_name)) |configured|
            try self.acquireQuery(configured, failure)
        else
            null;
        defer if (query) |value| value.release();
        const key = ContentKey{ .query = query, .content = content, .digest = std.hash.Wyhash.hash(0, content) };
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.contents.getPtr(key)) |entry| {
                entry.last_used = self.tick();
                entry.value.retain();
                return .{ .owner = entry.value };
            }
        }

        var captures = if (query) |value| try value.query.collect(self.allocator, self.io, content) else std.ArrayList(engine.Span).empty;
        defer captures.deinit(self.allocator);
        const created = blk: {
            const segments = try spans.compile(self.allocator, captures.items, content.len);
            errdefer self.allocator.free(segments);
            const owned_content = try self.allocator.dupe(u8, content);
            errdefer self.allocator.free(owned_content);
            const shared = try self.allocator.create(SharedContent);
            shared.* = .{
                .allocator = self.allocator,
                .key = .{ .query = query, .content = owned_content, .digest = key.digest },
                .segments = segments,
                .byte_size = @sizeOf(SharedContent) + content.len + segments.len * @sizeOf(spans.Segment) +
                    (if (query) |value| value.byte_size else @as(usize, 0)),
            };
            if (query) |value| value.retain();
            break :blk shared;
        };
        return self.publishContent(created);
    }

    fn publishContent(self: *Cache, created: *SharedContent) !Result {
        errdefer created.release();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.counters.content_analyses += 1;
        if (self.contents.getPtr(created.key)) |entry| {
            entry.last_used = self.tick();
            entry.value.retain();
            created.release();
            return .{ .owner = entry.value };
        }
        if (self.limits.contents != 0 and created.byte_size <= self.limits.content_bytes) {
            while (self.contents.count() >= self.limits.contents or self.counters.content_bytes > self.limits.content_bytes - created.byte_size) {
                self.evict(&self.contents, &self.counters.content_bytes);
            }
            try self.contents.put(created.key, .{ .value = created, .last_used = self.tick() });
            created.retain();
            self.counters.content_bytes += created.byte_size;
        }
        return .{ .owner = created };
    }

    fn acquireQuery(self: *Cache, configured: *const utils.highlight.Language, failure: *engine.Failure) !*SharedQuery {
        const language = try engine.languageForConfiguration(configured);
        var source = engine.loadHighlightQuerySource(self.allocator, self.io, configured) catch |err| {
            failure.* = .{ .query_read = .{ .path = configured.query, .cause = err } };
            return err;
        };
        defer source.deinit(self.allocator);
        const key = QueryKey{ .language = language, .source = source.text, .digest = std.hash.Wyhash.hash(0, source.text) };
        {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.queries.getPtr(key)) |entry| {
                entry.last_used = self.tick();
                entry.value.retain();
                return entry.value;
            }
        }
        const created = blk: {
            var compiled = try engine.Query.init(language, source.text, configured.query, failure);
            errdefer compiled.deinit();
            const owned_source = try self.allocator.dupe(u8, source.text);
            errdefer self.allocator.free(owned_source);
            const shared = try self.allocator.create(SharedQuery);
            shared.* = .{
                .allocator = self.allocator,
                .key = .{ .language = language, .source = owned_source, .digest = key.digest },
                .query = compiled,
                .byte_size = @sizeOf(SharedQuery) + owned_source.len,
            };
            break :blk shared;
        };
        return self.publishQuery(created);
    }

    fn publishQuery(self: *Cache, created: *SharedQuery) !*SharedQuery {
        errdefer created.release();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.counters.query_compilations += 1;
        if (self.queries.getPtr(created.key)) |entry| {
            entry.last_used = self.tick();
            entry.value.retain();
            created.release();
            return entry.value;
        }
        if (self.limits.queries != 0 and created.byte_size <= self.limits.query_bytes) {
            while (self.queries.count() >= self.limits.queries or self.counters.query_bytes > self.limits.query_bytes - created.byte_size) {
                self.evict(&self.queries, &self.counters.query_bytes);
            }
            try self.queries.put(created.key, .{ .value = created, .last_used = self.tick() });
            created.retain();
            self.counters.query_bytes += created.byte_size;
        }
        return created;
    }

    fn tick(self: *Cache) u64 {
        self.clock +%= 1;
        return self.clock;
    }

    fn evict(_: *Cache, entries: anytype, bytes: *usize) void {
        var iterator = entries.iterator();
        var oldest = iterator.next().?;
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_used < oldest.value_ptr.last_used) oldest = entry;
        }
        const key = oldest.key_ptr.*;
        const value = oldest.value_ptr.value;
        _ = entries.remove(key);
        bytes.* -= value.byte_size;
        value.release();
    }
};
