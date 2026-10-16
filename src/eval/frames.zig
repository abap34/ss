const std = @import("std");
const core = @import("core");
const Environment = @import("environment.zig").Environment;

// An implementation resource limit, independent of the static termination proof.
pub const default_max_frames: u32 = 128;

pub const Frame = struct {
    environment: Environment,
    module_id: core.SourceModuleId,
    caller_module_id: core.SourceModuleId,
    origin: core.SourceOrigin,
    parent: ?*Frame,
};

pub const Stack = struct {
    allocator: std.mem.Allocator,
    storage: std.heap.MemoryPool(Frame),
    maximum: u32 = default_max_frames,
    depth: u32 = 0,
    current: ?*Frame = null,

    pub fn init(allocator: std.mem.Allocator, maximum: u32) Stack {
        return .{ .allocator = allocator, .storage = .empty, .maximum = maximum };
    }

    pub fn push(
        self: *Stack,
        module_id: core.SourceModuleId,
        caller_module_id: core.SourceModuleId,
        origin: core.SourceOrigin,
        captured: ?*const Environment,
    ) !*Frame {
        if (self.depth >= self.maximum) return error.EvaluationResourceLimit;
        const frame = try self.storage.create(self.allocator);
        frame.* = .{
            .environment = if (captured) |env| Environment.child(self.allocator, env) else Environment.init(self.allocator),
            .module_id = module_id,
            .caller_module_id = caller_module_id,
            .origin = origin,
            .parent = self.current,
        };
        self.current = frame;
        self.depth += 1;
        return frame;
    }

    pub fn pop(self: *Stack, frame: *Frame) void {
        std.debug.assert(self.current == frame);
        self.current = frame.parent;
        self.depth -= 1;
        frame.environment.deinit();
        self.storage.destroy(frame);
    }

    pub fn deinit(self: *Stack) void {
        while (self.current) |frame| self.pop(frame);
        self.storage.deinit(self.allocator);
    }
};
