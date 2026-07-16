const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");
const render_compile = @import("render_compile");
const render_resources = @import("render_resources");

const testing = std.testing;

const FakeCompiler = struct {
    prepare_count: usize = 0,
    page_count: usize = 0,
    fail_at_index: ?usize = null,

    pub fn prepare(
        self: *FakeCompiler,
        _: std.mem.Allocator,
        _: *core.DocumentState,
        _: *const core.prepared.PreparedPages,
    ) !void {
        self.prepare_count += 1;
    }

    pub fn compilePage(
        self: *FakeCompiler,
        allocator: std.mem.Allocator,
        _: *core.DocumentState,
        prepared_page: *const core.prepared.PreparedPage,
        _: *render_resources.Builder,
        _: *render.FontBuilder,
        _: *render.MathBuilder,
    ) !render.Page {
        if (self.fail_at_index == prepared_page.index) return error.IntentionalCompileFailure;
        self.page_count += 1;
        var page = render.Page{
            .page_id = prepared_page.page_id,
            .index = prepared_page.index,
            .width = 1280,
            .height = 720,
        };
        errdefer page.deinit(allocator);
        try page.appendFillRect(
            allocator,
            prepared_page.page_id,
            .{ .x = 20, .y = 20, .width = 200, .height = 40 },
            .{ .r = 0, .g = 0, .b = 0 },
        );
        return page;
    }
};

fn initEmptyDocumentState() !core.DocumentState {
    const allocator = testing.allocator;
    const asset_base_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(asset_base_dir);
    const project_path = try allocator.dupe(u8, "render-compile-test.ss");
    errdefer allocator.free(project_path);
    const project_source = try allocator.dupe(u8, "");
    errdefer allocator.free(project_source);
    return try core.DocumentState.init(allocator, asset_base_dir, project_path, project_source, ast.Module.init());
}

fn preparedPage(page_id: core.NodeId, index: usize) core.prepared.PreparedPage {
    return .{
        .page_id = page_id,
        .index = index,
        .background = null,
        .object_ids = &.{},
        .constraints = &.{},
        .objects = &.{},
    };
}

test "render compiler prepares once and preserves page order" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{};

    var result = try render_compile.document(testing.allocator, &state, &prepared_pages, &compiler);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), compiler.prepare_count);
    try testing.expectEqual(@as(usize, 2), compiler.page_count);
    try testing.expectEqual(@as(usize, 2), result.pages.len);
    try testing.expectEqual(@as(core.NodeId, 10), result.pages[0].page_id);
    try testing.expectEqual(@as(core.NodeId, 20), result.pages[1].page_id);
}

test "render compiler releases completed pages after a later failure" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var compiler = FakeCompiler{ .fail_at_index = 1 };

    try testing.expectError(
        error.IntentionalCompileFailure,
        render_compile.document(testing.allocator, &state, &prepared_pages, &compiler),
    );
    try testing.expectEqual(@as(usize, 1), compiler.page_count);
}

test "resource compiler records deterministic raster SVG and PDF metadata" {
    const root = ".ss-cache/test-render-resources";
    const png_path = root ++ "/pixel.png";
    const svg_path = root ++ "/shape.svg";
    const pdf_path = root ++ "/page.pdf";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const encoded_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    const png_size = try std.base64.standard.Decoder.calcSizeForSlice(encoded_png);
    const png = try testing.allocator.alloc(u8, png_size);
    defer testing.allocator.free(png);
    try std.base64.standard.Decoder.decode(png, encoded_png);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = png_path, .data = png, .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = svg_path,
        .data = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\" viewBox=\"1 2 80 40\" preserveAspectRatio=\"xMaxYMin slice\"><rect width=\"80\" height=\"40\"/></svg>",
        .flags = .{ .truncate = true },
    });
    const pdf_path_z = try testing.allocator.dupeZ(u8, pdf_path);
    defer testing.allocator.free(pdf_path_z);
    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 120, 60) orelse return error.CairoCreateFailed;
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
    c.ss_pdf_destroy(pdf);

    var builder = render_resources.Builder{};
    defer builder.deinit(testing.allocator);
    const raster_id = try builder.addPath(testing.allocator, testing.io, .raster, png_path);
    const svg_id = try builder.addPath(testing.allocator, testing.io, .svg, svg_path);
    const pdf_id = try builder.addPath(testing.allocator, testing.io, .pdf, pdf_path);
    try testing.expectEqual(raster_id, try builder.addPath(testing.allocator, testing.io, .raster, png_path));
    try std.Io.Dir.cwd().deleteFile(testing.io, png_path);
    try testing.expectEqual(raster_id, try builder.addPath(testing.allocator, testing.io, .raster, png_path));
    try testing.expectEqual(@as(usize, 3), builder.entries.items.len);

    const raster = builder.find(raster_id) orelse return error.MissingRenderResource;
    const raster_metadata = raster.metadata.raster;
    try testing.expectEqual(@as(usize, 1), raster_metadata.pixel_width);
    try testing.expectEqual(@as(usize, 1), raster_metadata.pixel_height);
    try testing.expectEqual(render.RasterOrientation.normal, raster_metadata.orientation);
    try testing.expect(raster_metadata.has_alpha);

    const svg = builder.find(svg_id) orelse return error.MissingRenderResource;
    const svg_metadata = svg.metadata.svg;
    try testing.expectEqual(@as(f64, 80), svg_metadata.width);
    try testing.expectEqual(@as(f64, 40), svg_metadata.height);
    try testing.expectEqual(render.SvgAlign.x_max_y_min, svg_metadata.alignment);
    try testing.expectEqual(render.SvgScale.slice, svg_metadata.scale);
    try testing.expectEqual(@as(f64, 1), svg_metadata.view_box.?.x);
    try testing.expectEqual(@as(f64, 2), svg_metadata.view_box.?.y);

    const pdf_resource = builder.find(pdf_id) orelse return error.MissingRenderResource;
    const pdf_metadata = pdf_resource.metadata.pdf;
    try testing.expectEqual(@as(usize, 1), pdf_metadata.pages.len);
    try testing.expectApproxEqAbs(@as(f64, 120), pdf_metadata.pages[0].crop.width(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 60), pdf_metadata.pages[0].crop.height(), 0.001);
    try testing.expectEqual(@as(f64, 1), pdf_metadata.pages[0].user_unit);
    try testing.expect(!pdf_metadata.encrypted);
    try testing.expect(!pdf_metadata.has_javascript);
}
