const std = @import("std");
const core = @import("core");
const utils = @import("utils");

const commands = @import("app/commands.zig");
const types = @import("app/types.zig");

pub const RenderOptions = types.RenderOptions;
pub const RenderFormat = types.RenderFormat;
pub const WriteOptions = types.WriteOptions;
pub const SourceRequest = types.SourceRequest;
pub const PdfWriteRequest = types.PdfWriteRequest;
pub const HtmlWriteRequest = types.HtmlWriteRequest;
pub const PdfAndHtmlWriteRequest = types.PdfAndHtmlWriteRequest;
pub const render_progress_steps = commands.render_progress_steps;
pub const pdf_and_html_progress_steps = commands.pdf_and_html_progress_steps;

const Progress = utils.progress.Progress;

pub fn buildFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: ?*Progress) !core.DocumentState {
    return try commands.buildFile(io, allocator, request, progress);
}

pub fn buildTypedFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: ?*Progress) !core.DocumentState {
    return try commands.buildTypedFile(io, allocator, request, progress);
}

pub fn checkFile(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: ?*Progress) !void {
    try commands.checkFile(io, allocator, request, progress);
}

pub fn printContextJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, progress: *Progress) !void {
    try commands.printContextJson(io, allocator, request, progress);
}

pub fn writeContextJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    try commands.writeContextJson(io, allocator, request, output_path, progress);
}

pub fn writeScheduleTraceJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    try commands.writeScheduleTraceJson(io, allocator, request, output_path, progress);
}

pub fn writeLayoutTraceJson(io: std.Io, allocator: std.mem.Allocator, request: SourceRequest, output_path: []const u8, progress: *Progress) !void {
    try commands.writeLayoutTraceJson(io, allocator, request, output_path, progress);
}

pub fn layoutConflictReportJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: SourceRequest,
    progress: ?*Progress,
) ![]u8 {
    return try commands.layoutConflictReportJson(io, allocator, request, progress);
}

pub fn writeLayoutConflictReportFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    request: SourceRequest,
    output_path: []const u8,
    progress: *Progress,
) !void {
    try commands.writeLayoutConflictReportFile(io, allocator, request, output_path, progress);
}

pub fn writePdf(io: std.Io, allocator: std.mem.Allocator, request: PdfWriteRequest, progress: *Progress) !void {
    try commands.writePdf(io, allocator, request, progress);
}

pub fn writeHtml(io: std.Io, allocator: std.mem.Allocator, request: HtmlWriteRequest, progress: *Progress) !void {
    try commands.writeHtml(io, allocator, request, progress);
}

pub fn writePdfAndHtml(io: std.Io, allocator: std.mem.Allocator, request: PdfAndHtmlWriteRequest, progress: *Progress) !void {
    try commands.writePdfAndHtml(io, allocator, request, progress);
}
