const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const timeout_seconds: u64 = 120;
pub const stdout_limit: usize = 64 * 1024;
pub const stderr_limit: usize = 128 * 1024;

const timeout = std.Io.Clock.Duration{
    .raw = std.Io.Duration.fromSeconds(timeout_seconds),
    .clock = .awake,
};

const TaskResult = union(enum) {
    stdout: anyerror![]u8,
    stderr: anyerror![]u8,
    timeout: void,
};

const OutputStream = enum {
    stdout,
    stderr,
};

const WindowsJobBasicLimitInformation = extern struct {
    per_process_user_time_limit: i64,
    per_job_user_time_limit: i64,
    limit_flags: u32,
    minimum_working_set_size: usize,
    maximum_working_set_size: usize,
    active_process_limit: u32,
    affinity: usize,
    priority_class: u32,
    scheduling_class: u32,
};

const WindowsJobIoCounters = extern struct {
    read_operation_count: u64,
    write_operation_count: u64,
    other_operation_count: u64,
    read_transfer_count: u64,
    write_transfer_count: u64,
    other_transfer_count: u64,
};

const WindowsJobExtendedLimitInformation = extern struct {
    basic_limit_information: WindowsJobBasicLimitInformation,
    io_info: WindowsJobIoCounters,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
};

const windows_job_object_extended_limit_information: c_int = 9;
const windows_job_object_limit_kill_on_job_close: u32 = 0x0000_2000;

extern "kernel32" fn CreateJobObjectW(
    job_attributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
    name: ?[*:0]const u16,
) callconv(.winapi) ?std.os.windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    job: std.os.windows.HANDLE,
    information_class: c_int,
    information: *anyopaque,
    information_size: u32,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(
    job: std.os.windows.HANDLE,
    process: std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn TerminateJobObject(
    job: std.os.windows.HANDLE,
    exit_code: u32,
) callconv(.winapi) std.os.windows.BOOL;

pub fn run(
    allocator: Allocator,
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
) !std.process.RunResult {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, timeout);
    var windows_job: ?std.os.windows.HANDLE = null;
    defer if (builtin.os.tag == .windows) {
        if (windows_job) |job| std.os.windows.CloseHandle(job);
    };
    if (builtin.os.tag == .windows) {
        const job = CreateJobObjectW(null, null) orelse
            return std.os.windows.unexpectedError(std.os.windows.GetLastError());
        windows_job = job;
        var limits = std.mem.zeroes(WindowsJobExtendedLimitInformation);
        limits.basic_limit_information.limit_flags = windows_job_object_limit_kill_on_job_close;
        if (!SetInformationJobObject(
            job,
            windows_job_object_extended_limit_information,
            &limits,
            @sizeOf(WindowsJobExtendedLimitInformation),
        ).toBool()) return std.os.windows.unexpectedError(std.os.windows.GetLastError());
    }

    var spawn_options = std.process.SpawnOptions{
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    };
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) spawn_options.pgid = 0;
    if (builtin.os.tag == .windows) spawn_options.start_suspended = true;
    var child = try std.process.spawn(io, spawn_options);

    var result_buffer: [3]TaskResult = undefined;
    var tasks = std.Io.Select(TaskResult).init(io, &result_buffer);
    var stdout: ?[]u8 = null;
    errdefer if (stdout) |bytes| allocator.free(bytes);
    var stderr: ?[]u8 = null;
    errdefer if (stderr) |bytes| allocator.free(bytes);
    defer {
        if (child.id != null) terminateChild(&child, io, windows_job);
        cancelTasks(&tasks, allocator);
    }

    if (builtin.os.tag == .windows) {
        if (!AssignProcessToJobObject(windows_job.?, child.id.?).toBool()) {
            return std.os.windows.unexpectedError(std.os.windows.GetLastError());
        }
        switch (std.os.windows.ntdll.NtResumeThread(child.thread_handle, null)) {
            .SUCCESS => {},
            else => |status| return std.os.windows.unexpectedStatus(status),
        }
    }

    try tasks.concurrent(.stdout, readOutput, .{ allocator, io, child.stdout.?, @as(std.Io.Limit, .limited(stdout_limit)), OutputStream.stdout });
    try tasks.concurrent(.stderr, readOutput, .{ allocator, io, child.stderr.?, @as(std.Io.Limit, .limited(stderr_limit)), OutputStream.stderr });
    try tasks.concurrent(.timeout, waitForTimeout, .{io});

    while (stdout == null or stderr == null) switch (try tasks.await()) {
        .stdout => |result| stdout = try result,
        .stderr => |result| stderr = try result,
        .timeout => return error.Timeout,
    };

    return .{
        .term = try waitForChild(&child, io, deadline),
        .stdout = stdout.?,
        .stderr = stderr.?,
    };
}

fn waitForChild(
    child: *std.process.Child,
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    return switch (builtin.os.tag) {
        .windows => try waitForChildWindows(child, io, deadline),
        .wasi => try child.wait(io),
        else => try waitForChildPosix(child, io, deadline),
    };
}

fn waitForChildWindows(
    child: *std.process.Child,
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    const windows = std.os.windows;
    const immediate_timeout: windows.LARGE_INTEGER = 0;
    while (true) {
        switch (windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &immediate_timeout)) {
            windows.NTSTATUS.WAIT_0 => return try child.wait(io),
            .TIMEOUT, .ALERTED, .USER_APC => {},
            else => return error.Unexpected,
        }
        if (std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, deadline.clock), .gte, deadline)) {
            return error.Timeout;
        }
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
}

fn waitForChildPosix(
    child: *std.process.Child,
    io: std.Io,
    deadline: std.Io.Clock.Timestamp,
) !std.process.Child.Term {
    const pid = child.id.?;
    while (true) {
        var status: if (builtin.link_libc) c_int else u32 = undefined;
        const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result != 0) {
                    cleanupChildPosix(child, io);
                    return termFromPosixStatus(@bitCast(status));
                }
            },
            .INTR => continue,
            .CHILD => return error.Unexpected,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        if (std.Io.Clock.Timestamp.compare(std.Io.Clock.Timestamp.now(io, deadline.clock), .gte, deadline)) {
            return error.Timeout;
        }
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
}

fn termFromPosixStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn cleanupChildPosix(child: *std.process.Child, io: std.Io) void {
    if (child.stdin) |file| file.close(io);
    if (child.stdout) |file| file.close(io);
    if (child.stderr) |file| file.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    child.id = null;
}

fn terminateChild(child: *std.process.Child, io: std.Io, windows_job: ?std.os.windows.HANDLE) void {
    switch (builtin.os.tag) {
        .windows => {
            if (windows_job) |job| _ = TerminateJobObject(job, 1);
        },
        .wasi => {},
        else => {
            const pid = child.id.?;
            std.posix.kill(-pid, .KILL) catch {};
        },
    }
    child.kill(io);
}

fn readOutput(
    allocator: Allocator,
    io: std.Io,
    file: std.Io.File,
    limit: std.Io.Limit,
    stream: OutputStream,
) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.StreamTooLong => switch (stream) {
            .stdout => error.CommandStdoutTooLong,
            .stderr => error.CommandStderrTooLong,
        },
        else => err,
    };
}

fn waitForTimeout(io: std.Io) void {
    (std.Io.Timeout{ .duration = timeout }).sleep(io) catch {};
}

fn cancelTasks(tasks: *std.Io.Select(TaskResult), allocator: Allocator) void {
    while (tasks.cancel()) |result| switch (result) {
        .stdout, .stderr => |output| if (output) |bytes| allocator.free(bytes) else |_| {},
        .timeout => {},
    };
}
