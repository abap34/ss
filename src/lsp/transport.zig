const std = @import("std");

const protocol = @import("protocol.zig");
const utils = @import("utils");

const queue_capacity = 256;

pub const RequestState = struct {
    canceled: std.atomic.Value(bool) = .init(false),
};

pub const Request = struct {
    key: []u8,
    state: *RequestState,
};

pub const Payload = union(enum) {
    message: utils.json.ParsedValue,
    parse_error,
};

pub const Envelope = struct {
    payload: Payload,
    revision: u64,
    request: ?Request,

    pub fn deinit(self: *Envelope, ingress: *Ingress) void {
        if (self.request) |request| {
            ingress.requests.unregister(request.key, request.state);
            ingress.allocator.free(request.key);
            ingress.allocator.destroy(request.state);
        }
        switch (self.payload) {
            .message => |*message| message.deinit(),
            .parse_error => {},
        }
        self.* = undefined;
    }
};

const RequestRegistry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    states: std.StringHashMap(*RequestState),

    fn init(allocator: std.mem.Allocator, io: std.Io) RequestRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .states = std.StringHashMap(*RequestState).init(allocator),
        };
    }

    fn deinit(self: *RequestRegistry) void {
        var iterator = self.states.iterator();
        while (iterator.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.states.deinit();
    }

    fn register(self: *RequestRegistry, key: []const u8, state: *RequestState) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.states.fetchRemove(key)) |previous| self.allocator.free(previous.key);
        try self.states.put(owned_key, state);
    }

    fn cancel(self: *RequestRegistry, key: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const state = self.states.get(key) orelse return;
        state.canceled.store(true, .release);
    }

    fn unregister(self: *RequestRegistry, key: []const u8, state: *RequestState) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const registered = self.states.get(key) orelse return;
        if (registered != state) return;
        const removed = self.states.fetchRemove(key) orelse return;
        self.allocator.free(removed.key);
    }
};

pub const Ingress = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    queue_buffer: [queue_capacity]Envelope = undefined,
    queue: std.Io.Queue(Envelope),
    requests: RequestRegistry,
    revision: std.atomic.Value(u64) = .init(0),
    wake_epoch: std.atomic.Value(u32) = .init(0),
    read_failed: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    pub fn init(self: *Ingress, allocator: std.mem.Allocator, io: std.Io) void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .queue = undefined,
            .requests = RequestRegistry.init(allocator, io),
        };
        self.queue = std.Io.Queue(Envelope).init(&self.queue_buffer);
    }

    pub fn deinit(self: *Ingress) void {
        while (true) {
            var messages: [1]Envelope = undefined;
            const count = self.queue.getUncancelable(self.io, &messages, 0) catch break;
            if (count == 0) break;
            messages[0].deinit(self);
        }
        self.requests.deinit();
    }

    pub fn read(self: *Ingress) void {
        self.readMessages() catch self.read_failed.store(true, .release);
        self.finished.store(true, .release);
        self.queue.close(self.io);
        self.wake();
    }

    pub fn next(self: *Ingress, timeout_ms: ?u64) !?Envelope {
        while (true) {
            const observed_epoch = self.wake_epoch.load(.acquire);
            var messages: [1]Envelope = undefined;
            const count = self.queue.getUncancelable(self.io, &messages, 0) catch |err| switch (err) {
                error.Closed => return null,
            };
            if (count == 1) return messages[0];

            const timeout: std.Io.Timeout = if (timeout_ms) |milliseconds|
                .{ .duration = .{
                    .clock = .boot,
                    .raw = .fromMilliseconds(@intCast(@min(milliseconds, @as(u64, std.math.maxInt(i64))))),
                } }
            else
                .none;
            self.io.futexWaitTimeout(u32, &self.wake_epoch.raw, observed_epoch, timeout) catch |err| switch (err) {
                error.Canceled => unreachable,
            };
            if (timeout_ms != null and self.wake_epoch.load(.acquire) == observed_epoch) return null;
        }
    }

    pub fn isFinished(self: *const Ingress) bool {
        return self.finished.load(.acquire);
    }

    pub fn readFailed(self: *const Ingress) bool {
        return self.read_failed.load(.acquire);
    }

    fn readMessages(self: *Ingress) !void {
        while (try protocol.readMessage(self.allocator)) |body| {
            defer self.allocator.free(body);
            var parsed = utils.json.parseValue(self.allocator, body, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                try self.enqueue(.{
                    .payload = .parse_error,
                    .revision = self.revision.load(.acquire),
                    .request = null,
                });
                continue;
            };
            var parsed_owned = true;
            defer if (parsed_owned) parsed.deinit();

            const method = if (parsed.value == .object) protocol.stringField(&parsed.value.object, "method") else null;
            if (parsed.value == .object) {
                const root = &parsed.value.object;
                if (method) |name| {
                    if (std.mem.eql(u8, name, "$/cancelRequest")) {
                        if (protocol.objectFieldObject(root, "params")) |params| {
                            if (utils.json.fieldValue(params, "id")) |id| {
                                const key = try requestKey(self.allocator, id.*);
                                defer self.allocator.free(key);
                                self.requests.cancel(key);
                            }
                        }
                        continue;
                    }
                }
            }

            const revision = if (method) |name|
                if (invalidatesAnalysis(name)) self.revision.fetchAdd(1, .acq_rel) + 1 else self.revision.load(.acquire)
            else
                self.revision.load(.acquire);
            const request = if (parsed.value == .object) if (utils.json.fieldValue(&parsed.value.object, "id")) |id| blk: {
                const key = try requestKey(self.allocator, id.*);
                errdefer self.allocator.free(key);
                const state = try self.allocator.create(RequestState);
                errdefer self.allocator.destroy(state);
                state.* = .{};
                try self.requests.register(key, state);
                break :blk Request{ .key = key, .state = state };
            } else null else null;
            errdefer if (request) |value| {
                self.requests.unregister(value.key, value.state);
                self.allocator.free(value.key);
                self.allocator.destroy(value.state);
            };

            try self.enqueue(.{
                .payload = .{ .message = parsed },
                .revision = revision,
                .request = request,
            });
            parsed_owned = false;
            if (method) |name| if (std.mem.eql(u8, name, "exit")) return;
        }
    }

    fn enqueue(self: *Ingress, envelope: Envelope) !void {
        try self.queue.putOneUncancelable(self.io, envelope);
        self.wake();
    }

    fn wake(self: *Ingress) void {
        _ = self.wake_epoch.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.wake_epoch.raw, 1);
    }
};

fn invalidatesAnalysis(method: []const u8) bool {
    return std.mem.eql(u8, method, "textDocument/didOpen") or
        std.mem.eql(u8, method, "textDocument/didChange") or
        std.mem.eql(u8, method, "textDocument/didSave") or
        std.mem.eql(u8, method, "textDocument/didClose") or
        std.mem.eql(u8, method, "workspace/didChangeWatchedFiles");
}

fn requestKey(allocator: std.mem.Allocator, id: protocol.JsonValue) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try protocol.appendJsonValue(allocator, &out, id);
    return out.toOwnedSlice(allocator);
}
