const std = @import("std");
const app = @import("app");
const utils = @import("utils");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 4) return error.InvalidArguments;
    const input = args[1];
    const pdf_output = args[2];
    const html_output = args[3];
    const asset_base_dir = std.fs.path.dirname(input) orelse ".";
    var progress = utils.progress.Progress.disabled(app.pdf_and_html_progress_steps);
    try app.writePdfAndHtml(init.io, allocator, .{
        .source = .{
            .input_path = input,
            .asset_base_dir = asset_base_dir,
        },
        .pdf_output_path = pdf_output,
        .html_output_path = html_output,
        .options = .{ .render = .{ .cache_dir = ".ss-cache/render-parity/cache" } },
    }, &progress);
}
