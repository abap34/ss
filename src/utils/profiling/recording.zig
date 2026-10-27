const std = @import("std");
const builtin = @import("builtin");
const fs = @import("../fs.zig");

pub const available = @import("profiling_options").enabled;
pub const default_buffer_kb = 32 * 1024;
pub const Outcome = enum { success, failed, canceled, superseded };
pub const Metadata = struct {
    version: []const u8 = "unknown",
    commit: []const u8 = "unknown",
    dirty: []const u8 = "unknown",
    command: []const u8 = "unknown",
};
pub const TaskMetadata = struct {
    parent: ?u64 = null,
    revision: u64 = 0,
    version: ?i64 = null,
    request: u64 = 0,
};

extern fn ss_profile_start([*:0]const u8, u32) ?*anyopaque;
extern fn ss_profile_checkpoint(*anyopaque, bool) c_int;
extern fn ss_profile_destroy(*anyopaque) void;
extern fn ss_profile_now_ns() u64;
extern fn ss_profile_span([*]const u8, usize, [*]const u8, usize, u64, u64, u64) void;
extern fn ss_profile_counter([*]const u8, usize, u64) void;
extern fn ss_profile_task(u64, u64, [*]const u8, usize, u64, i64, u64, bool) void;
extern fn ss_profile_enter(u64, bool) void;
extern fn ss_profile_finish(u64, [*:0]const u8) void;
extern fn ss_profile_cancel(u64) void;
extern fn ss_profile_flush_thread() void;

var active: ?*Session = null;
threadlocal var current_operation: u64 = 0;

pub fn isEnabled() bool {
    return available and active != null;
}

pub fn timestamp() i128 {
    if (!available) return 0;
    return if (isEnabled()) ss_profile_now_ns() else 0;
}

pub fn activate(session: *Session) void {
    std.debug.assert(active == null);
    active = session;
    current_operation = 0;
}

pub fn deactivate() void {
    active = null;
    current_operation = 0;
}

pub fn span(category: []const u8, name: []const u8, started: i128) void {
    if (!available or !isEnabled() or started == 0) return;
    ss_profile_span(category.ptr, category.len, name.ptr, name.len, @intCast(started), ss_profile_now_ns(), current_operation);
}

pub fn counter(name: []const u8, value: u64) void {
    if (available and isEnabled()) ss_profile_counter(name.ptr, name.len, value);
}

/// The transport carries only this token; metadata lives in the trace.
pub const Task = struct {
    id: u64 = 0,
    queued: bool = true,

    pub fn enqueue(name: []const u8, metadata: TaskMetadata) Task {
        return create(name, metadata, true);
    }

    fn create(name: []const u8, metadata: TaskMetadata, queued: bool) Task {
        const session = active orelse return .{};
        if (!available) return .{};
        const id = session.next_id.fetchAdd(1, .monotonic);
        ss_profile_task(id, metadata.parent orelse current_operation, name.ptr, name.len, metadata.revision, metadata.version orelse -1, metadata.request, queued);
        return .{ .id = id, .queued = queued };
    }

    pub fn run(self: Task) Operation {
        const previous = current_operation;
        if (available and self.id != 0) {
            ss_profile_enter(self.id, self.queued);
            current_operation = self.id;
            sampleMemory();
        }
        return .{ .task = self, .previous = previous };
    }

    pub fn cancel(self: Task) void {
        if (available and self.id != 0) ss_profile_cancel(self.id);
    }

    pub fn discard(self: Task) void {
        if (available and self.id != 0) ss_profile_finish(self.id, "superseded");
    }
};

pub const Operation = struct {
    task: Task,
    previous: u64,
    outcome: Outcome = .success,

    pub fn begin(name: []const u8, metadata: TaskMetadata) Operation {
        return Task.create(name, metadata, false).run();
    }

    pub fn finish(self: *Operation) void {
        if (available and self.task.id != 0) {
            ss_profile_finish(self.task.id, @tagName(self.outcome));
            sampleMemory();
        }
        current_operation = self.previous;
    }
};

pub const Zone = struct {
    name: []const u8,
    started: i128,

    pub fn end(self: Zone) void {
        span("function", self.name, self.started);
    }
};

pub fn zone(comptime source: std.builtin.SourceLocation) Zone {
    return .{ .name = source.fn_name, .started = timestamp() };
}

/// Context propagation belongs to thread dispatch, not worker input structs.
pub fn spawn(config: std.Thread.SpawnConfig, comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
    if (!isEnabled()) return std.Thread.spawn(config, function, args);
    const Runner = struct {
        fn run(operation: u64, parameters: @TypeOf(args)) void {
            const previous = current_operation;
            current_operation = operation;
            defer current_operation = previous;
            defer if (available) ss_profile_flush_thread();
            @call(.auto, function, parameters);
        }
    };
    return std.Thread.spawn(config, Runner.run, .{ current_operation, args });
}

/// Preserve attribution when structured I/O dispatches onto another thread.
pub fn concurrent(select: anytype, comptime field: anytype, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.ConcurrentError!void {
    if (!isEnabled()) return select.concurrent(field, function, args);
    const Runner = struct {
        fn run(operation: u64, parameters: @TypeOf(args)) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
            const previous = current_operation;
            current_operation = operation;
            defer current_operation = previous;
            defer if (available) ss_profile_flush_thread();
            return @call(.auto, function, parameters);
        }
    };
    return select.concurrent(field, Runner.run, .{ current_operation, args });
}

pub fn call(comptime name: []const u8, comptime function: anytype, args: anytype) @TypeOf(@call(.auto, function, args)) {
    var operation = Operation.begin(name, .{});
    defer operation.finish();
    const Result = @TypeOf(@call(.auto, function, args));
    if (@typeInfo(Result) == .error_union) {
        return @call(.auto, function, args) catch |err| {
            operation.outcome = .failed;
            return err;
        };
    }
    return @call(.auto, function, args);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    metadata: Metadata,
    buffer_kb: u32,
    native: *anyopaque,
    next_id: std.atomic.Value(u64) = .init(1),
    input_sha256: ?[64]u8 = null,
    checkpoint_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, buffer_kb: usize, metadata: Metadata) !Session {
        if (!available) return error.ProfilingNotBuilt;
        if (buffer_kb < 64 or buffer_kb > 1024 * 1024) return error.InvalidProfileLimit;
        if (std.fs.path.dirname(directory)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
        try std.Io.Dir.cwd().createDir(io, directory, .default_dir);
        const path = try std.fs.path.join(allocator, &.{ directory, "trace.pftrace" });
        defer allocator.free(path);
        const terminated = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(terminated);
        const native = ss_profile_start(terminated, @intCast(buffer_kb)) orelse return error.ProfileStartFailed;
        return .{ .allocator = allocator, .io = io, .directory = directory, .metadata = metadata, .buffer_kb = @intCast(buffer_kb), .native = native };
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(active != self);
        if (available) ss_profile_destroy(self.native);
    }

    pub fn identifyInput(self: *Session, bytes: []const u8) void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        self.input_sha256 = std.fmt.bytesToHex(digest, .lower);
    }

    pub fn write(self: *Session, stop: bool) !void {
        if (!available) return;
        if (ss_profile_checkpoint(self.native, stop) == 0) return error.ProfileCheckpointFailed;
        self.checkpoint_count += 1;
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = 2,
            .ss = self.metadata,
            .sdk = @import("profiling_options").sdk,
            .zig = builtin.zig_version_string,
            .optimize = @tagName(builtin.mode),
            .os = @tagName(builtin.os.tag),
            .architecture = @tagName(builtin.cpu.arch),
            .cpu_target = builtin.cpu.model.name,
            .buffer_kb = self.buffer_kb,
            .checkpoints = self.checkpoint_count,
            .completed = stop,
            .input_sha256 = if (self.input_sha256) |*digest| @as(?[]const u8, digest) else null,
            .source_content_recorded = false,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        const path = try std.fs.path.join(self.allocator, &.{ self.directory, "manifest.json" });
        defer self.allocator.free(path);
        try fs.writeFile(self.io, path, bytes);
    }
};

pub fn checkpoint() !bool {
    const session = active orelse return false;
    try session.write(false);
    return true;
}

pub fn identifyInput(io: std.Io, allocator: std.mem.Allocator, path: []const u8) void {
    const session = active orelse return;
    const bytes = fs.readFileAlloc(io, allocator, path) catch return;
    defer allocator.free(bytes);
    session.identifyInput(bytes);
}

pub fn identifySource(bytes: []const u8) void {
    const session = active orelse return;
    if (session.input_sha256 == null) session.identifyInput(bytes);
}

fn sampleMemory() void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(std.c.rusage.SELF, &usage) != 0 or usage.maxrss < 0) return;
    const scale: u64 = if (builtin.os.tag == .macos) 1 else 1024;
    counter("process.peak_rss_bytes", @as(u64, @intCast(usage.maxrss)) *| scale);
    counter("process.user_cpu_ns", @as(u64, @intCast(@max(0, usage.utime.sec))) *| std.time.ns_per_s +| @as(u64, @intCast(@max(0, usage.utime.usec))) *| std.time.ns_per_us);
    counter("process.system_cpu_ns", @as(u64, @intCast(@max(0, usage.stime.sec))) *| std.time.ns_per_s +| @as(u64, @intCast(@max(0, usage.stime.usec))) *| std.time.ns_per_us);
}
