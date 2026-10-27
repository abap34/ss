const std = @import("std");
const utils = @import("utils");
const inputs = @import("latex_inputs.zig");

const Allocator = std.mem.Allocator;
const Header = utils.render_cache.LatexReference;

/// Borrowed results remain valid until the operation's cache is destroyed.
/// Uncached results instead own their buffer and parsed dependency manifest.
pub const Reference = struct {
    value: Header,
    inputs: []const inputs.Input,
    owned: ?struct { allocator: Allocator, contents: []u8, parsed: inputs.Parsed } = null,

    pub fn deinit(self: *Reference) void {
        if (self.owned) |*owned| {
            owned.parsed.deinit();
            owned.allocator.free(owned.contents);
        }
        self.* = undefined;
    }
};

const Identity = struct {
    inode: std.Io.File.INode,
    size: u64,
    mtime: i96,
    ctime: i96,

    fn fromStat(stat: std.Io.File.Stat) Identity {
        return .{ .inode = stat.inode, .size = stat.size, .mtime = stat.mtime.nanoseconds, .ctime = stat.ctime.nanoseconds };
    }

    fn matches(self: Identity, stat: std.Io.File.Stat) bool {
        return std.meta.eql(self, fromStat(stat));
    }
};

const Entry = struct {
    path: []u8,
    identity: Identity,
    value: Header,
    inputs: []const inputs.Input,

    fn reference(self: *const Entry) Reference {
        return .{ .value = self.value, .inputs = self.inputs };
    }
};

const Interned = struct { text: []const u8, inputs: []const inputs.Input };

/// Scoped to one preload, measurement, or IR compilation operation. Every
/// lookup checks the reference's file generation; dependency validation remains
/// the caller's responsibility. Retired generations stay alive for borrowers.
pub const Cache = struct {
    allocator: Allocator,
    mutex: std.Io.Mutex = .init,
    current: std.StringHashMapUnmanaged(*Entry) = .{},
    entries: std.ArrayList(*Entry) = .empty,
    manifests: std.StringHashMapUnmanaged(inputs.Parsed) = .{},
    retained_bytes: usize = 0,
    limits: Limits = .{},

    pub const Limits = struct {
        entries: usize = 2048,
        bytes: usize = 16 * 1024 * 1024,
    };

    pub fn init(allocator: Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.current.deinit(self.allocator);
        for (self.entries.items) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.value.pdf_name);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        var manifests = self.manifests.iterator();
        while (manifests.next()) |manifest| {
            manifest.value_ptr.deinit();
            self.allocator.free(manifest.key_ptr.*);
        }
        self.manifests.deinit(self.allocator);
        self.* = undefined;
    }

    fn load(self: *Cache, allocator: Allocator, io: std.Io, path: []const u8) !Reference {
        try std.Io.checkCancel(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (self.current.get(path)) |entry| {
            if (entry.identity.matches(stat)) return entry.reference();
        }
        var identity: Identity = undefined;
        const contents = try readStable(allocator, io, path, &identity);
        var contents_owned = true;
        defer if (contents_owned) allocator.free(contents);
        const header = try Header.parse(contents);
        const entry_bytes = @sizeOf(Entry) +| path.len +| header.pdf_name.len;
        if (self.entries.items.len < self.limits.entries and entry_bytes <= self.limits.bytes -| self.retained_bytes) {
            if (try self.intern(header.dependencies, entry_bytes)) |manifest| {
                const entry = try self.allocator.create(Entry);
                errdefer self.allocator.destroy(entry);
                const owned_path = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(owned_path);
                const pdf_name = try self.allocator.dupe(u8, header.pdf_name);
                errdefer self.allocator.free(pdf_name);
                try self.current.ensureUnusedCapacity(self.allocator, 1);
                try self.entries.ensureUnusedCapacity(self.allocator, 1);
                entry.* = .{ .path = owned_path, .identity = identity, .value = header, .inputs = manifest.inputs };
                entry.value.pdf_name = pdf_name;
                entry.value.dependencies = manifest.text;
                self.entries.appendAssumeCapacity(entry);
                self.current.putAssumeCapacity(owned_path, entry);
                self.retained_bytes += entry_bytes;
                return entry.reference();
            }
        }
        const result = try ownedReference(allocator, contents, header);
        contents_owned = false;
        return result;
    }

    fn intern(self: *Cache, text: []const u8, reserved_bytes: usize) !?Interned {
        if (self.manifests.getEntry(text)) |entry| return .{ .text = entry.key_ptr.*, .inputs = entry.value_ptr.value.inputs };
        var parsed = try inputs.parse(self.allocator, text);
        var parsed_owned = true;
        defer if (parsed_owned) parsed.deinit();
        const byte_size = text.len +| parsed.arena.queryCapacity();
        if (byte_size +| reserved_bytes > self.limits.bytes -| self.retained_bytes) return null;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        try self.manifests.put(self.allocator, owned_text, parsed);
        parsed_owned = false;
        self.retained_bytes += byte_size;
        return .{ .text = owned_text, .inputs = parsed.value.inputs };
    }
};

pub fn read(allocator: Allocator, io: std.Io, path: []const u8, cache: ?*Cache) !Reference {
    if (cache) |value| return value.load(allocator, io, path);
    var identity: Identity = undefined;
    const contents = try readStable(allocator, io, path, &identity);
    errdefer allocator.free(contents);
    return ownedReference(allocator, contents, try Header.parse(contents));
}

fn ownedReference(allocator: Allocator, contents: []u8, header: Header) !Reference {
    const parsed = try inputs.parse(allocator, header.dependencies);
    return .{ .value = header, .inputs = parsed.value.inputs, .owned = .{ .allocator = allocator, .contents = contents, .parsed = parsed } };
}

fn readStable(allocator: Allocator, io: std.Io, path: []const u8, identity: *Identity) ![]u8 {
    for (0..4) |_| {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const before = try file.stat(io);
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(file, io, &buffer);
        const contents = reader.interface.allocRemaining(allocator, .limited(Header.read_limit)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => return err,
        };
        var contents_owned = true;
        defer if (contents_owned) allocator.free(contents);
        const after = try file.stat(io);
        const current = try std.Io.Dir.cwd().statFile(io, path, .{});
        const candidate = Identity.fromStat(before);
        if (!candidate.matches(after) or !candidate.matches(current) or after.size != contents.len) continue;
        identity.* = candidate;
        contents_owned = false;
        return contents;
    }
    return error.ResourceChangedDuringRead;
}
