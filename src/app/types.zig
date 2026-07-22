const module_loader = @import("../modules/loader.zig");
const utils = @import("utils");

pub const RenderFormat = enum {
    pdf,
    html,
};

pub const RenderOptions = struct {
    jobs: ?usize = null,
    cache_dir: []const u8 = ".ss-cache/render",
    highlight_languages: []const utils.highlight.Language = &.{},
};

pub const WriteOptions = struct {
    render: RenderOptions = .{},
    diagnostics_json_path: ?[]const u8 = null,
};

pub const SourceRequest = struct {
    input_path: []const u8,
    asset_base_dir: []const u8,
    layout_jobs: ?usize = null,
    highlight_languages: []const utils.highlight.Language = &.{},
    overlay: ?*const module_loader.SourceOverlay = null,
    embedded_cache: ?*module_loader.EmbeddedSyntaxCache = null,
};

pub const PdfWriteRequest = struct {
    source: SourceRequest,
    output_path: []const u8,
    options: WriteOptions = .{},
};

pub const HtmlWriteRequest = struct {
    source: SourceRequest,
    output_path: []const u8,
    options: WriteOptions = .{},
};

pub const PdfAndHtmlWriteRequest = struct {
    source: SourceRequest,
    pdf_output_path: []const u8,
    html_output_path: []const u8,
    options: WriteOptions = .{},
};
