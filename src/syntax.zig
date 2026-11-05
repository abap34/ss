const ast = @import("ast");

pub const Module = ast.Module;
const std = @import("std");
const parser = @import("syntax/parse.zig");
const expansion = @import("syntax/desugar.zig");
const utils = @import("utils");
const hole = @import("syntax/hole.zig");
pub const Surface = ast.Surface;
pub const ParseDiagnostic = parser.ParseDiagnostic;
pub const ParseFailure = parser.ParseFailure;
pub const HoleKind = hole.HoleKind;
pub const HoleTable = hole.Result;
pub const ExpectedSyntax = hole.ExpectedSyntax;
pub const desugar = expansion.desugar;
pub const DesugarOptions = expansion.Options;
pub const DesugarFailure = expansion.Failure;
pub const IncludeResolver = expansion.IncludeResolver;
pub const parseSurface = parser.parse;
pub const printExpandedAlloc = @import("syntax/print.zig").moduleAlloc;

pub const ParseOptions = struct {
    expansion: struct { expand_stages: bool = true, expand_includes: bool = true } = .{},
    include_resolver: ?IncludeResolver = null,
    failure: ?*ParseFailure = null,
    cancellation: ?utils.Cancellation = null,
};

pub const ParseResult = struct {
    module: ast.Module,
    holes: hole.Result,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        self.module.deinit(allocator);
        self.holes.deinit(allocator);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !ast.Module {
    return parseWithSourceName(allocator, text, "");
}

pub fn parseWithSourceName(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8) !ast.Module {
    return parseWithSourceNameInner(allocator, text, source_name, null);
}

pub fn parseWithSourceNameAndFailure(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8, failure: *ParseFailure) !ast.Module {
    return parseWithSourceNameInner(allocator, text, source_name, failure);
}

pub fn parseWithOptions(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8, options: ParseOptions) !ast.Module {
    var surface = if (options.failure) |failure|
        try parser.parseWithSourceNameAndFailure(allocator, text, source_name, failure)
    else
        try parser.parseWithSourceName(allocator, text, source_name);
    defer surface.deinit(allocator);
    return expand(allocator, &surface, text, source_name, options);
}

fn parseWithSourceNameInner(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8, failure: ?*ParseFailure) !ast.Module {
    var surface = if (failure) |output|
        try parser.parseWithSourceNameAndFailure(allocator, text, source_name, output)
    else
        try parser.parseWithSourceName(allocator, text, source_name);
    defer surface.deinit(allocator);
    return expand(allocator, &surface, text, source_name, .{ .failure = failure });
}

pub fn parseRecovering(allocator: std.mem.Allocator, text: []const u8) !ParseResult {
    return parseRecoveringWithSourceName(allocator, text, "");
}

pub fn parseRecoveringWithSourceName(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8) !ParseResult {
    return parseRecoveringWithOptions(allocator, text, source_name, .{});
}

pub fn parseRecoveringWithSourceNameAndFailure(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8, failure: *ParseFailure) !ParseResult {
    return parseRecoveringWithOptions(allocator, text, source_name, .{ .failure = failure });
}

pub fn parseRecoveringWithOptions(allocator: std.mem.Allocator, text: []const u8, source_name: []const u8, options: ParseOptions) !ParseResult {
    var surface = try parser.parseRecoveringWithOptions(allocator, text, source_name, .{
        .failure = options.failure,
        .cancellation = options.cancellation,
    });
    defer surface.deinit(allocator);
    var module = try expand(allocator, &surface.module, text, source_name, options);
    errdefer module.deinit(allocator);
    const holes = surface.holes;
    surface.holes = .{ .holes = &.{}, .diagnostics = &.{} };
    return .{ .module = module, .holes = holes };
}

fn expand(allocator: std.mem.Allocator, surface: *const Surface.Module, text: []const u8, path: []const u8, options: ParseOptions) !ast.Module {
    var failure: DesugarFailure = .{};
    const config = DesugarOptions{ .expand_stages = options.expansion.expand_stages, .expand_includes = options.expansion.expand_includes, .include_resolver = options.include_resolver, .source_name = path, .source_length = text.len, .failure = &failure, .cancellation = options.cancellation };
    return desugar(allocator, surface, config) catch |err| {
        if (options.failure) |output| {
            const span = failure.span orelse ast.Span{ .start = text.len, .end = text.len };
            output.diagnostic = .{
                .err = err,
                .span = span,
                .expected = @import("syntax/diagnostics.zig").expected(err),
                .found = @import("syntax/diagnostics.zig").foundToken(text, @min(span.start, text.len)),
                .detail = failure.detail,
            };
        }
        return err;
    };
}
