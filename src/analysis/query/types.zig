const std = @import("std");

pub const SourceRequest = struct {
    path: []const u8,
    source_version: u64 = 0,
    offset: usize,
    source: []const u8,
};

pub const QueryOptions = struct {
    budget_ms: u32,
    allow_stale: bool = true,
    require_layout: bool = false,
};

pub const QueryBudget = struct {
    start_ns: i128,
    budget_ns: i128,

    pub fn start(opts: QueryOptions) QueryBudget {
        return .{
            .start_ns = monotonicNowNs(),
            .budget_ns = @as(i128, opts.budget_ms) * std.time.ns_per_ms,
        };
    }

    pub fn expired(self: QueryBudget) bool {
        if (self.budget_ns <= 0) return true;
        return monotonicNowNs() - self.start_ns >= self.budget_ns;
    }
};

pub const CompletionKind = enum {
    keyword,
    function,
    variable,
    property,
    enum_case,
    type_decl,
    class,
    role,
};

pub const CompletionCandidate = struct {
    label: []const u8,
    kind: CompletionKind,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
};

pub const CompletionResult = struct {
    items: []CompletionCandidate,

    pub fn deinit(self: *CompletionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

fn monotonicNowNs() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub const HoverInfo = struct {
    markdown: []u8,

    pub fn deinit(self: *HoverInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
    }
};

pub const DefinitionTarget = struct {
    path: ?[]const u8 = null,
    module_spec: ?[]const u8 = null,
    line: usize,
    character: usize,
    end_line: usize,
    end_character: usize,
};
