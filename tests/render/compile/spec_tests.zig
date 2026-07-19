const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");
const render_compile = @import("render_compile");
const render_emitter = @import("render_emitter");
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

const ConcurrentResourceAdd = struct {
    builder: *render_resources.Builder,
    io: std.Io,
    path: []const u8,
    ready: std.atomic.Value(usize) = .init(0),
    results: [4]?render.ResourceId = .{null} ** 4,
    errors: [4]?anyerror = .{null} ** 4,

    fn run(self: *ConcurrentResourceAdd, index: usize) void {
        _ = self.ready.fetchAdd(1, .seq_cst);
        while (self.ready.load(.seq_cst) != self.results.len) std.atomic.spinLoopHint();
        self.results[index] = self.builder.addPath(std.heap.c_allocator, self.io, .svg, self.path) catch |err| {
            self.errors[index] = err;
            return;
        };
    }
};

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

test "render compiler produces deterministic document fingerprints" {
    var first_state = try initEmptyDocumentState();
    defer first_state.deinit();
    var second_state = try initEmptyDocumentState();
    defer second_state.deinit();
    var source_pages = [_]core.prepared.PreparedPage{
        preparedPage(10, 0),
        preparedPage(20, 1),
    };
    const prepared_pages = core.prepared.PreparedPages{ .pages = &source_pages };
    var first_compiler = FakeCompiler{};
    var second_compiler = FakeCompiler{};

    var first = try render_compile.document(testing.allocator, &first_state, &prepared_pages, &first_compiler);
    defer first.deinit(testing.allocator);
    var second = try render_compile.document(testing.allocator, &second_state, &prepared_pages, &second_compiler);
    defer second.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &first.fingerprint(), &second.fingerprint());
    for (first.pages, second.pages) |*first_page, *second_page| {
        try testing.expectEqualSlices(u8, &render.pageFingerprint(first_page), &render.pageFingerprint(second_page));
    }
}

test "text decorations and measurements use resolved font run metrics" {
    var page = render.Page{
        .page_id = 1,
        .index = 0,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var emitter = render_emitter.Emitter{
        .page = &page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
    };

    const baseline_y: f64 = 180;
    const font_size: f64 = 48;
    try emitter.textBaseline(
        testing.allocator,
        40,
        baseline_y,
        800,
        "[metrics]: MWgjpqy",
        .{ .family = "sans-serif", .weight = 700, .style = .normal, .stretch = .normal },
        font_size,
        .{ .r = 0, .g = 0, .b = 0 },
        false,
        .{ .strikethrough = true, .underline = true },
    );

    try testing.expectEqual(@as(usize, 3), page.items.items.len);
    const underline = switch (page.items.items[0]) {
        .stroke_line => |value| value,
        else => return error.ExpectedUnderlineItem,
    };
    const text_item = switch (page.items.items[1]) {
        .text => |value| value,
        else => return error.ExpectedTextItem,
    };
    try testing.expectEqual(@as(usize, 1), text_item.layout.runs.len);
    const run = text_item.layout.runs[0];
    const instance = fonts.get(testing.io, run.font_instance) orelse return error.MissingRenderFont;
    const strike = switch (page.items.items[2]) {
        .stroke_line => |value| value,
        else => return error.ExpectedStrikeItem,
    };
    const run_baseline = text_item.y + run.baseline_y;
    try testing.expectApproxEqAbs(
        run_baseline - font_size * instance.strikethrough_position_ratio + strike.line_width / 2,
        strike.start.y,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        font_size * instance.strikethrough_thickness_ratio,
        strike.line_width,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        run_baseline - font_size * instance.underline_position_ratio + underline.line_width / 2,
        underline.start.y,
        0.0001,
    );
    try testing.expectApproxEqAbs(
        font_size * instance.underline_thickness_ratio,
        underline.line_width,
        0.0001,
    );

    const measured = try core.render_text_measure.layout(
        testing.allocator,
        "[metrics]: MWgjpqy",
        .{ .family = "sans-serif", .weight = 700, .style = .normal, .stretch = .normal },
        font_size,
        800,
        false,
        .{ .strikethrough = true, .underline = true },
    );
    const decorated = measured.decoration_bounds orelse return error.MissingDecorationMeasurement;
    const measured_layout_y = baseline_y - measured.first_baseline;
    const drawn_top = @min(
        strike.start.y - strike.line_width / 2,
        underline.start.y - underline.line_width / 2,
    );
    const drawn_bottom = @max(
        strike.start.y + strike.line_width / 2,
        underline.start.y + underline.line_width / 2,
    );
    try testing.expectApproxEqAbs(@as(f64, 40 + decorated.x), @min(strike.start.x, underline.start.x), 0.0001);
    try testing.expectApproxEqAbs(measured_layout_y + decorated.y, drawn_top, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, decorated.width), @max(strike.end.x, underline.end.x) - 40, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, decorated.height), drawn_bottom - drawn_top, 0.0001);
}

test "generic monospace text keeps narrow and wide glyph advances equal" {
    var page = render.Page{
        .page_id = 1,
        .index = 0,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var emitter = render_emitter.Emitter{
        .page = &page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
    };

    const face = core.font.Face{ .family = "monospace", .weight = 400, .style = .normal, .stretch = .normal };
    try emitter.textBaseline(testing.allocator, 40, 100, 800, "iiiiiiii", face, 24, .{ .r = 0, .g = 0, .b = 0 }, false, .{});
    try emitter.textBaseline(testing.allocator, 40, 140, 800, "WWWWWWWW", face, 24, .{ .r = 0, .g = 0, .b = 0 }, false, .{});

    const narrow = page.items.items[0].text.layout.runs[0].advance;
    const wide = page.items.items[1].text.layout.runs[0].advance;
    try testing.expectApproxEqAbs(narrow, wide, 0.0001);
}

test "markdown underline paint controls color opacity width offset and dash" {
    var page = render.Page{
        .page_id = 1,
        .index = 0,
        .width = 1280,
        .height = 720,
    };
    defer page.deinit(testing.allocator);
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var emitter = render_emitter.Emitter{
        .page = &page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
    };

    const baseline_y: f64 = 180;
    const font_size: f64 = 48;
    const underline_color = core.render_policy.Color{ .r = 0.8, .g = 0.2, .b = 0.4 };
    try emitter.textBaseline(
        testing.allocator,
        40,
        baseline_y,
        800,
        "custom underline",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        font_size,
        .{ .r = 0, .g = 0, .b = 0 },
        false,
        .{
            .underline = true,
            .underline_color = underline_color,
            .underline_opacity = 0.35,
            .underline_width = 5,
            .underline_offset = 3,
            .underline_dash_on = 8,
            .underline_dash_off = 4,
        },
    );

    try testing.expectEqual(@as(usize, 2), page.items.items.len);
    const underline = switch (page.items.items[0]) {
        .stroke_line => |value| value,
        else => return error.ExpectedUnderlineItem,
    };
    const text_item = switch (page.items.items[1]) {
        .text => |value| value,
        else => return error.ExpectedTextItem,
    };
    const run = text_item.layout.runs[0];
    const instance = fonts.get(testing.io, run.font_instance) orelse return error.MissingRenderFont;
    const run_baseline = text_item.y + run.baseline_y;
    const native_thickness = font_size * instance.underline_thickness_ratio;
    try testing.expectApproxEqAbs(
        run_baseline - font_size * instance.underline_position_ratio + native_thickness / 2 + 3,
        underline.start.y,
        0.0001,
    );
    try testing.expectApproxEqAbs(@as(f64, 5), underline.line_width, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 0.35), underline.header.opacity, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), underline.color.r, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.2), underline.color.g, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), underline.color.b, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 8), underline.dash_on, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 4), underline.dash_off, 0.0001);
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

    const raster = builder.get(testing.io, raster_id) orelse return error.MissingRenderResource;
    const raster_metadata = raster.metadata.raster;
    try testing.expectEqual(@as(usize, 1), raster_metadata.pixel_width);
    try testing.expectEqual(@as(usize, 1), raster_metadata.pixel_height);
    try testing.expectEqual(render.RasterOrientation.normal, raster_metadata.orientation);
    try testing.expect(raster_metadata.has_alpha);

    const svg = builder.get(testing.io, svg_id) orelse return error.MissingRenderResource;
    const svg_metadata = svg.metadata.svg;
    try testing.expectEqual(@as(f64, 80), svg_metadata.width);
    try testing.expectEqual(@as(f64, 40), svg_metadata.height);
    try testing.expectEqual(render.SvgAlign.x_max_y_min, svg_metadata.alignment);
    try testing.expectEqual(render.SvgScale.slice, svg_metadata.scale);
    try testing.expectEqual(@as(f64, 1), svg_metadata.view_box.?.x);
    try testing.expectEqual(@as(f64, 2), svg_metadata.view_box.?.y);

    const pdf_resource = builder.get(testing.io, pdf_id) orelse return error.MissingRenderResource;
    const pdf_metadata = pdf_resource.metadata.pdf;
    try testing.expectEqual(@as(usize, 1), pdf_metadata.pages.len);
    try testing.expectApproxEqAbs(@as(f64, 120), pdf_metadata.pages[0].crop.width(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 60), pdf_metadata.pages[0].crop.height(), 0.001);
    try testing.expectEqual(@as(f64, 1), pdf_metadata.pages[0].user_unit);
    try testing.expect(!pdf_metadata.encrypted);
    try testing.expect(!pdf_metadata.has_javascript);

    var catalog = try builder.take(testing.allocator);
    defer catalog.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), catalog.entries.len);
    for (catalog.entries[1..], catalog.entries[0 .. catalog.entries.len - 1]) |current, previous| {
        try testing.expect(std.mem.order(u8, &previous.id, &current.id) == .lt);
    }
}

test "resource compiler shares one in-flight load across workers" {
    const root = ".ss-cache/test-render-resources-concurrent";
    const svg_path = root ++ "/shape.svg";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = svg_path,
        .data = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\"/></svg>",
        .flags = .{ .truncate = true },
    });

    var builder = render_resources.Builder{};
    defer builder.deinit(std.heap.c_allocator);
    var work = ConcurrentResourceAdd{ .builder = &builder, .io = testing.io, .path = svg_path };
    var threads: [work.results.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    while (started < threads.len) : (started += 1) {
        threads[started] = try std.Thread.spawn(.{}, ConcurrentResourceAdd.run, .{ &work, started });
    }
    for (threads) |thread| thread.join();

    for (work.errors) |err| try testing.expect(err == null);
    const expected = work.results[0] orelse return error.MissingRenderResource;
    for (work.results[1..]) |result| try testing.expectEqual(expected, result orelse return error.MissingRenderResource);
    try testing.expectEqual(@as(usize, 1), builder.entries.items.len);
    try testing.expectEqual(@as(usize, 1), builder.sources.items.len);
}
