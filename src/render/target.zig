const utils = @import("utils");

pub const Target = enum {
    pdf,
    html,
};

pub const CoordinateSpace = struct {
    unit: []const u8 = "pt",
    origin: []const u8 = "page-top-left",
    x_axis: []const u8 = "right",
    y_axis: []const u8 = "down",
};

pub const HtmlOptions = struct {};

pub const PdfOptions = struct {
    keep_temps: bool = false,
    cache_dir: []const u8 = ".ss-cache/render",
    cache_id: ?[]const u8 = null,
    highlight_languages: []const utils.highlight.Language = &.{},
};
