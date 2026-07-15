const module_loader = @import("../modules/loader.zig");
const pdf = @import("../render/pdf.zig");

pub const RenderOptions = pdf.Options;

pub const PdfWriteOptions = struct {
    render: RenderOptions = .{},
    diagnostics_json_path: ?[]const u8 = null,
};

pub const SourceRequest = struct {
    input_path: []const u8,
    asset_base_dir: []const u8,
    layout_jobs: ?usize = null,
    overlay: ?*const module_loader.SourceOverlay = null,
};

pub const PdfWriteRequest = struct {
    source: SourceRequest,
    output_path: []const u8,
    options: PdfWriteOptions = .{},
};
