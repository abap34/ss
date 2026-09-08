const std = @import("std");

pub const LatexReference = struct {
    page_index: usize,
    width: f32,
    height: f32,
    baseline_from_bottom: f32,
    reference_height: f32,
    pdf_name: []const u8,
    dependencies: []const u8 = "",

    pub const read_limit = 8 * 1024 * 1024;

    pub fn parse(contents: []const u8) error{InvalidPdfCache}!LatexReference {
        const end = std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len;
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, contents[0..end], " \t\r"), '\t');
        const page_text = fields.next() orelse return error.InvalidPdfCache;
        const width_text = fields.next() orelse return error.InvalidPdfCache;
        const height_text = fields.next() orelse return error.InvalidPdfCache;
        const baseline_text = fields.next() orelse return error.InvalidPdfCache;
        const reference_height_text = fields.next() orelse return error.InvalidPdfCache;
        const pdf_name = fields.next() orelse return error.InvalidPdfCache;
        if (fields.next() != null or !std.mem.endsWith(u8, pdf_name, ".pdf") or
            !std.mem.eql(u8, std.fs.path.basename(pdf_name), pdf_name))
        {
            return error.InvalidPdfCache;
        }
        const result = LatexReference{
            .page_index = std.fmt.parseInt(usize, page_text, 10) catch return error.InvalidPdfCache,
            .width = std.fmt.parseFloat(f32, width_text) catch return error.InvalidPdfCache,
            .height = std.fmt.parseFloat(f32, height_text) catch return error.InvalidPdfCache,
            .baseline_from_bottom = std.fmt.parseFloat(f32, baseline_text) catch return error.InvalidPdfCache,
            .reference_height = std.fmt.parseFloat(f32, reference_height_text) catch return error.InvalidPdfCache,
            .pdf_name = pdf_name,
            .dependencies = if (end < contents.len) std.mem.trim(u8, contents[end + 1 ..], " \t\r\n") else "",
        };
        if (!std.math.isFinite(result.width) or !std.math.isFinite(result.height) or
            !std.math.isFinite(result.baseline_from_bottom) or !std.math.isFinite(result.reference_height) or
            result.width <= 0 or result.height <= 0 or result.reference_height <= 0)
        {
            return error.InvalidPdfCache;
        }
        return result;
    }
};
