const pdfjs_assets = @import("pdfjs_assets");

const document = @import("../document.zig");
const embedded_runtime = @import("../embedded_runtime.zig");

pub fn documentRuntime() document.PdfRuntime {
    return .{
        .import_map = embedded_runtime.pdf_import_map,
        .renderer_module = embedded_runtime.pdf_renderer_module,
        .pdfjs_module = embedded_runtime.pdfjs_module,
        .worker_module = embedded_runtime.pdf_worker_module,
        .license = pdfjs_assets.license,
    };
}
