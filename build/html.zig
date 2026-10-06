const std = @import("std");
const compat = @import("compat.zig");

const ImportGroup = enum { shared, pdf };
const Source = struct {
    name: []const u8,
    path: []const u8,
    limit: usize = 256 * 1024,
    exported: bool = true,
    specifier: ?[]const u8 = null,
    group: ImportGroup = .shared,
};

// Each runtime source declares its generated export and import-map membership here.
const sources = [_]Source{
    .{ .name = "resource_module", .path = "src/render/html/resources.js" },
    .{ .name = "dom_module", .path = "src/render/html/dom.js", .exported = false, .specifier = "@ss/dom" },
    .{ .name = "presentation_module", .path = "src/render/html/presentation.js" },
    .{ .name = "navigation_module", .path = "src/render/html/navigation.js" },
    .{ .name = "text_module", .path = "src/render/html/text.js" },
    .{ .name = "pdf_controller_module", .path = "src/render/html/pdf/controller.js", .exported = false, .specifier = "@ss/pdf/controller", .group = .pdf },
    .{ .name = "pdf_geometry_module", .path = "src/render/html/pdf/geometry.js", .exported = false, .specifier = "@ss/pdf/geometry", .group = .pdf },
    .{ .name = "pdf_placement_module", .path = "src/render/html/pdf/placement.js", .exported = false, .specifier = "@ss/pdf/placement", .group = .pdf },
    .{ .name = "pdf_queue_module", .path = "src/render/html/pdf/queue.js", .exported = false, .specifier = "@ss/pdf/queue", .group = .pdf },
    .{ .name = "pdf_renderer_module", .path = "src/render/html/pdf/index.js" },
    .{ .name = "pdf_service_module", .path = "src/render/html/pdf/service.js", .exported = false, .specifier = "@ss/pdf/service", .group = .pdf },
    .{ .name = "pdfjs_module", .path = "third_party/pdfjs/pdf.mjs", .limit = 2 * 1024 * 1024 },
    .{ .name = "pdf_worker_module", .path = "third_party/pdfjs/pdf.worker.mjs", .limit = 4 * 1024 * 1024 },
};

pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: compat.Optimize) *std.Build.Module {
    const files = b.addWriteFiles();
    var root: std.ArrayList(u8) = .empty;
    var urls: [sources.len][]const u8 = undefined;
    for (sources, &urls) |source, *url| {
        url.* = javascriptDataUrl(b, source.path, source.limit);
        if (source.exported) addExport(b, files, &root, source.name, url.*);
    }
    addExport(b, files, &root, "presentation_import_map", importMap(b, &urls, false));
    addExport(b, files, &root, "pdf_import_map", importMap(b, &urls, true));
    return b.createModule(.{
        .root_source_file = files.add("root.zig", root.items),
        .target = target,
        .optimize = optimize,
    });
}

fn addExport(b: *std.Build, files: *std.Build.Step.WriteFile, root: *std.ArrayList(u8), name: []const u8, content: []const u8) void {
    const filename = b.fmt("{s}.txt", .{name});
    _ = files.add(filename, content);
    root.appendSlice(b.allocator, b.fmt("pub const {s} = @embedFile(\"{s}\");\n", .{ name, filename })) catch @panic("OOM");
}

fn importMap(b: *std.Build, urls: []const []const u8, include_pdf: bool) []const u8 {
    var json: std.ArrayList(u8) = .empty;
    json.appendSlice(b.allocator, "{\"imports\":{") catch @panic("OOM");
    var separator: []const u8 = "";
    for (sources, urls) |source, url| {
        const specifier = source.specifier orelse continue;
        if (source.group == .pdf and !include_pdf) continue;
        json.appendSlice(b.allocator, b.fmt("{s}\"{s}\":\"{s}\"", .{ separator, specifier, url })) catch @panic("OOM");
        separator = ",";
    }
    json.appendSlice(b.allocator, "}}") catch @panic("OOM");
    return json.items;
}

fn javascriptDataUrl(b: *std.Build, path: []const u8, max_bytes: usize) []const u8 {
    const source = compat.readFile(b, path, .limited(max_bytes)) catch
        std.debug.panic("HTML runtime source is missing: {s}", .{path});
    const prefix = "data:text/javascript;charset=utf-8;base64,";
    const result = b.allocator.alloc(u8, prefix.len + std.base64.standard.Encoder.calcSize(source.len)) catch @panic("OOM");
    @memcpy(result[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(result[prefix.len..], source);
    return result;
}
