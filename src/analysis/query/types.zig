const std = @import("std");
const utils = @import("utils");

pub const SourceRequest = struct {
    path: []const u8,
    source_version: u64 = 0,
    offset: usize,
    source: []const u8,
    line_index: ?utils.source.LineIndex = null,
};

pub const QueryOptions = struct {
    budget_ms: u32,
    allow_stale: bool = true,
    require_layout: bool = false,
    cancellation: ?utils.Cancellation = null,
    clock: ?Clock = null,
};

pub const Clock = struct {
    context: *const anyopaque,
    now_ns: *const fn (*const anyopaque) i128,

    fn now(self: Clock) i128 {
        return self.now_ns(self.context);
    }
};

pub const QueryBudget = struct {
    start_ns: i128,
    budget_ns: i128,
    cancellation: ?utils.Cancellation = null,
    clock: ?Clock = null,

    pub fn start(opts: QueryOptions) QueryBudget {
        return .{
            .start_ns = if (opts.clock) |clock| clock.now() else monotonicNowNs(),
            .budget_ns = @as(i128, opts.budget_ms) * std.time.ns_per_ms,
            .cancellation = opts.cancellation,
            .clock = opts.clock,
        };
    }

    pub fn expired(self: QueryBudget) bool {
        if (self.canceled()) return true;
        if (self.budget_ns <= 0) return true;
        const now = if (self.clock) |clock| clock.now() else monotonicNowNs();
        return now - self.start_ns >= self.budget_ns;
    }

    pub fn canceled(self: QueryBudget) bool {
        return if (self.cancellation) |token| token.canceled() else false;
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
    is_incomplete: bool = false,

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
