const std = @import("std");
const ast = @import("ast");
const core = @import("core");
const c = @import("pdf_ffi").c;
const render = @import("render");
const render_compile = @import("render_compile");
const render_emitter = @import("render_emitter");
const render_resources = @import("render_resources");
const render_text = @import("render_text");

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

test "captured measurement items keep page order and annotations" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page_id = try state.addPage("capture");
    const object_id = try state.makeObject(
        page_id,
        "linked text",
        null,
        .text,
        .text,
        "[linked text](https://example.com)",
    );
    const object = state.getNode(object_id) orelse return error.MissingTestObject;
    object.frame = .{ .x = 80, .y = 500, .width = 420, .height = 80 };

    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    prepared.pages[0].objects[0].render.chrome.fill = .{ .r = 0.9, .g = 0.9, .b = 0.9 };

    var result = try render_compile.compile(
        testing.allocator,
        testing.io,
        &state,
        &prepared,
        .{ .jobs = 1 },
    );
    defer result.deinit(testing.allocator);

    const page = &result.pages[0];
    try testing.expect(page.items.items.len >= 3);
    for (page.items.items, 0..) |item, index| {
        const header = item.header();
        try testing.expectEqual(@as(u32, @intCast(index)), header.paint_index);
        try testing.expectEqual((@as(u64, 1) << 32) | @as(u64, @intCast(index)), header.item_id);
    }
    try testing.expectEqual(@as(usize, 3), page.links.items.len);
    for (page.links.items) |link| {
        try testing.expectEqualStrings("https://example.com", link.target);
    }
}

test "render compiler rejects unavailable PDF pages" {
    const root = ".ss-cache/test-render-invalid-pdf-page";
    const pdf_path = root ++ "/page.pdf";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    const pdf_path_z = try testing.allocator.dupeZ(u8, pdf_path);
    defer testing.allocator.free(pdf_path_z);
    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 120, 60) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));

    var state = try initEmptyDocumentState();
    defer state.deinit();
    const page_id = try state.addPage("pdf-page");
    const object_id = try state.makeObject(page_id, "pdf", null, .asset, .pdf_ref, pdf_path);
    try state.setNodeFieldValue(object_id, "render_kind", .{ .string = "vector_asset" });
    const object = state.getNode(object_id) orelse return error.MissingTestObject;
    object.frame = .{ .x = 40, .y = 60, .width = 240, .height = 120, .x_set = true, .y_set = true };

    var prepared = try core.prepared.prepare(testing.allocator, &state);
    defer prepared.deinit(testing.allocator);
    prepared.pages[0].objects[0].render.asset.?.pdf_page = 2;

    if (render_compile.compile(
        testing.allocator,
        testing.io,
        &state,
        &prepared,
        .{ .jobs = 1, .cache_dir = root ++ "/cache" },
    )) |result| {
        var ir = result;
        defer ir.deinit(testing.allocator);
        return error.ExpectedInvalidPdfResource;
    } else |err| {
        try testing.expectEqual(error.InvalidPdfResource, err);
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

test "unwrapped text shapes ignore the available width in cache keys" {
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
    var cache = render_text.Cache.init(testing.allocator, testing.io);
    defer cache.deinit();
    var emitter = render_emitter.Emitter{
        .page = &page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
        .text_cache = &cache,
    };

    const face = core.font.Face{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal };
    try emitter.textBaseline(testing.allocator, 40, 100, 120, "same shape", face, 24, .{ .r = 0, .g = 0, .b = 0 }, false, .{});
    try emitter.textBaseline(testing.allocator, 40, 140, 800, "same shape", face, 24, .{ .r = 0, .g = 0, .b = 0 }, false, .{});

    try testing.expectEqual(@as(usize, 1), cache.entryCount());
    try testing.expectEqualSlices(
        render.Glyph,
        page.items.items[0].text.layout.glyphs,
        page.items.items[1].text.layout.glyphs,
    );
}

test "text layout append failure consumes one shared reference" {
    var source_page = render.Page{
        .page_id = 1,
        .index = 0,
        .width = 320,
        .height = 180,
    };
    defer source_page.deinit(testing.allocator);
    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var source_emitter = render_emitter.Emitter{
        .page = &source_page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
    };
    const face = core.font.Face{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal };
    try source_emitter.textBaseline(
        testing.allocator,
        10,
        40,
        200,
        "retained",
        face,
        20,
        .{ .r = 0, .g = 0, .b = 0 },
        false,
        .{},
    );
    var canonical = try source_page.items.items[0].text.layout.clone(testing.allocator);
    defer canonical.deinit(testing.allocator);
    const handed_off = try canonical.clone(testing.allocator);

    var target_page = render.Page{
        .page_id = 2,
        .index = 1,
        .width = 320,
        .height = 180,
    };
    defer target_page.deinit(testing.allocator);
    var target_emitter = render_emitter.Emitter{
        .page = &target_page,
        .resources = &resources,
        .fonts = &fonts,
        .math = &math,
        .io = testing.io,
    };
    var failing_state = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, target_emitter.textLayoutBaseline(
        failing_state.allocator(),
        10,
        40,
        200,
        handed_off,
        20,
        .{ .r = 0, .g = 0, .b = 0 },
        .{},
    ));
    try testing.expectEqualStrings("retained", canonical.source_text);
    try testing.expect(canonical.glyphs.len != 0);
}

test "text shape cache persists across compiler processes and rejects corrupt data" {
    const root = ".ss-cache/test-render-persistent-text-shapes";
    const cache_path = root ++ "/text-shapes-v2/shapes.bin";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};

    const face = core.font.Face{
        .family = "sans-serif",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
    };
    var first_resources = render_resources.Builder{};
    defer first_resources.deinit(testing.allocator);
    var first_fonts = render.FontBuilder{};
    defer first_fonts.deinit(testing.allocator);
    var first_cache = render_text.Cache.init(testing.allocator, testing.io);
    defer first_cache.deinit();
    var first_layout = try render_text.shape(
        testing.allocator,
        testing.io,
        &first_resources,
        &first_fonts,
        "persistent shape",
        face,
        24,
        420,
        true,
        &first_cache,
    );
    defer first_layout.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), first_cache.entryCount());
    first_cache.persist(root);

    var second_cache = render_text.Cache.init(testing.allocator, testing.io);
    defer second_cache.deinit();
    second_cache.restore(root);
    try testing.expectEqual(@as(usize, 1), second_cache.entryCount());
    var second_resources = render_resources.Builder{};
    defer second_resources.deinit(testing.allocator);
    var second_fonts = render.FontBuilder{};
    defer second_fonts.deinit(testing.allocator);
    var second_layout = try render_text.shape(
        testing.allocator,
        testing.io,
        &second_resources,
        &second_fonts,
        "persistent shape",
        face,
        24,
        420,
        true,
        &second_cache,
    );
    defer second_layout.deinit(testing.allocator);
    try testing.expectEqualSlices(render.Glyph, first_layout.glyphs, second_layout.glyphs);
    try testing.expectEqualSlices(render.TextCluster, first_layout.clusters, second_layout.clusters);

    const persisted = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        cache_path,
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(persisted);
    persisted[persisted.len / 2] ^= 0x01;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = cache_path, .data = persisted, .flags = .{ .truncate = true } });
    var corrupt_cache = render_text.Cache.init(testing.allocator, testing.io);
    defer corrupt_cache.deinit();
    corrupt_cache.restore(root);
    try testing.expectEqual(@as(usize, 0), corrupt_cache.entryCount());
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
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));

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

test "font source cache reloads changed files across builders" {
    const root = ".ss-cache/test-render-font-source-cache";
    const font_path = root ++ "/font.otf";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    const source = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "third_party/stix-two-math/STIXTwoMath.otf",
        testing.allocator,
        .unlimited,
    );
    defer testing.allocator.free(source);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = font_path, .data = source, .flags = .{ .truncate = true } });

    var cache = render_resources.SourceCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const first = blk: {
        var builder = render_resources.Builder{ .cache = &cache };
        defer builder.deinit(testing.allocator);
        break :blk try builder.addPath(testing.allocator, testing.io, .font, font_path);
    };
    const second = blk: {
        var builder = render_resources.Builder{ .cache = &cache };
        defer builder.deinit(testing.allocator);
        break :blk try builder.addPath(testing.allocator, testing.io, .font, font_path);
    };
    try testing.expectEqual(first, second);

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = font_path, .data = source[0 .. source.len - 1], .flags = .{ .truncate = true } });
    const changed = blk: {
        var builder = render_resources.Builder{ .cache = &cache };
        defer builder.deinit(testing.allocator);
        break :blk try builder.addPath(testing.allocator, testing.io, .font, font_path);
    };
    try testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "source cache teardown keeps builder resources alive" {
    const root = ".ss-cache/test-render-source-cache-lifetime";
    const svg_path = root ++ "/shape.svg";
    const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"80\" height=\"40\"><rect width=\"80\" height=\"40\"/></svg>";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = svg_path, .data = svg, .flags = .{ .truncate = true } });

    var cache = render_resources.SourceCache.init(testing.allocator, testing.io);
    var cache_live = true;
    defer if (cache_live) cache.deinit();
    var builder = render_resources.Builder{ .cache = &cache };
    defer builder.deinit(testing.allocator);
    const resource_id = try builder.addPath(testing.allocator, testing.io, .svg, svg_path);
    cache.deinit();
    cache_live = false;

    const resource = builder.get(testing.io, resource_id) orelse return error.MissingRenderResource;
    try testing.expectEqualStrings(svg, resource.bytes);
    try testing.expectEqualStrings("shape.svg", resource.name);
}

test "source cache invalidates an atomic replacement with preserved size and mtime" {
    const root = ".ss-cache/test-render-source-cache-atomic-replacement";
    const font_path = root ++ "/font.ttf";
    const replacement_path = root ++ "/replacement.ttf";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = font_path, .data = "font-a", .flags = .{ .truncate = true } });

    var original_file = try std.Io.Dir.cwd().openFile(testing.io, font_path, .{});
    const original_stat = try original_file.stat(testing.io);
    original_file.close(testing.io);
    var cache = render_resources.SourceCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const first_fingerprint = try cache.fileFingerprint(font_path);
    const first_id = blk: {
        var builder = render_resources.Builder{ .cache = &cache };
        defer builder.deinit(testing.allocator);
        break :blk try builder.addPath(testing.allocator, testing.io, .font, font_path);
    };

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = replacement_path, .data = "font-b", .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().setTimestamps(testing.io, replacement_path, .{
        .modify_timestamp = .{ .new = original_stat.mtime },
    });
    try std.Io.Dir.cwd().rename(replacement_path, std.Io.Dir.cwd(), font_path, testing.io);
    var replaced_file = try std.Io.Dir.cwd().openFile(testing.io, font_path, .{});
    const replaced_stat = try replaced_file.stat(testing.io);
    replaced_file.close(testing.io);
    try testing.expectEqual(original_stat.size, replaced_stat.size);
    try testing.expectEqual(original_stat.mtime.nanoseconds, replaced_stat.mtime.nanoseconds);
    try testing.expect(original_stat.inode != replaced_stat.inode);

    const changed_fingerprint = try cache.fileFingerprint(font_path);
    try testing.expect(first_fingerprint.digest != changed_fingerprint.digest);
    const changed_id = blk: {
        var builder = render_resources.Builder{ .cache = &cache };
        defer builder.deinit(testing.allocator);
        break :blk try builder.addPath(testing.allocator, testing.io, .font, font_path);
    };
    try testing.expect(!std.mem.eql(u8, &first_id, &changed_id));
}

test "page cache misses when a dependent resource changes under the same page key" {
    const root = ".ss-cache/test-render-page-cache-resource-change";
    const svg_path = root ++ "/shape.svg";
    const replacement_path = root ++ "/replacement.svg";
    const first_svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"4\"><rect fill=\"red\"/></svg>";
    const second_svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"4\"><rect fill=\"tan\"/></svg>";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = svg_path, .data = first_svg, .flags = .{ .truncate = true } });
    var original_file = try std.Io.Dir.cwd().openFile(testing.io, svg_path, .{});
    const original_stat = try original_file.stat(testing.io);
    original_file.close(testing.io);

    var source_cache = render_resources.SourceCache.init(testing.allocator, testing.io);
    defer source_cache.deinit();
    var source_builder = render_resources.Builder{ .cache = &source_cache };
    defer source_builder.deinit(testing.allocator);
    const resource_id = try source_builder.addPath(testing.allocator, testing.io, .svg, svg_path);
    const source_dependencies = try source_builder.sourceDependencies(testing.allocator, testing.io);
    defer render_resources.deinitSourceDependencies(testing.allocator, source_dependencies);
    var source_graph = try source_builder.take(testing.allocator);
    defer source_graph.deinit(testing.allocator);
    const font_catalog = render.FontCatalog{};
    const math_catalog = render.MathCatalog{};
    var page = render.Page{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    defer page.deinit(testing.allocator);
    try page.appendSvg(
        testing.allocator,
        7,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        resource_id,
        null,
    );
    var page_cache = render_compile.PageCache.init(testing.allocator, testing.io);
    defer page_cache.deinit();
    try testing.expect(try page_cache.put(42, testing.allocator, &page, &source_graph, source_dependencies, &font_catalog, &math_catalog));

    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = replacement_path, .data = second_svg, .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().setTimestamps(testing.io, replacement_path, .{
        .modify_timestamp = .{ .new = original_stat.mtime },
    });
    try std.Io.Dir.cwd().rename(replacement_path, std.Io.Dir.cwd(), svg_path, testing.io);

    var resources = render_resources.Builder{ .cache = &source_cache };
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    try testing.expect((try page_cache.materialize(42, testing.allocator, testing.io, &resources, &fonts, &math)) == null);
    try testing.expect((try page_cache.materialize(42, testing.allocator, testing.io, &resources, &fonts, &math)) == null);
}

test "source cache bounds paths without invalidating builder resources" {
    const root = ".ss-cache/test-render-source-cache-bound";
    const font = "synthetic font bytes";
    std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, root);

    var cache = render_resources.SourceCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    var builder = render_resources.Builder{ .cache = &cache };
    defer builder.deinit(testing.allocator);
    var first_id: ?render.ResourceId = null;
    for (0..257) |index| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/font-{d}.ttf", .{ root, index });
        defer testing.allocator.free(path);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = font, .flags = .{ .truncate = true } });
        const resource_id = try builder.addPath(testing.allocator, testing.io, .font, path);
        if (first_id == null) first_id = resource_id;
    }

    try testing.expect(cache.sources.items.len < 257);
    const resource = builder.get(testing.io, first_id orelse return error.MissingRenderResource) orelse
        return error.MissingRenderResource;
    try testing.expectEqualStrings(font, resource.bytes);
}

test "page cache keeps materialized content alive across eviction" {
    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    var cache_live = true;
    defer if (cache_live) cache.deinit();
    const resource_graph = render.ResourceGraph{};
    const font_catalog = render.FontCatalog{};
    const math_catalog = render.MathCatalog{};

    var source = render.Page{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    defer source.deinit(testing.allocator);
    try source.appendFillRect(
        testing.allocator,
        7,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        .{ .r = 1, .g = 0, .b = 0 },
    );
    try source.appendLink(testing.allocator, .destination, "target", .{ .x = 10, .y = 20, .width = 30, .height = 40 });
    try source.appendDestination(testing.allocator, "target", .{ .x = 10, .y = 20 });
    try testing.expect(try cache.put(1, testing.allocator, &source, &resource_graph, &.{}, &font_catalog, &math_catalog));

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var first = (try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer first.deinit(testing.allocator);
    var second = (try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer second.deinit(testing.allocator);
    first.items.items[0].fill_rect.header.opacity = 0.25;
    try testing.expectEqual(@as(f64, 1), second.items.items[0].fill_rect.header.opacity);

    for (2..258) |key| {
        var page = render.Page{ .page_id = @intCast(key), .index = key - 1, .width = 320, .height = 180 };
        defer page.deinit(testing.allocator);
        try page.appendFillRect(
            testing.allocator,
            @intCast(key),
            .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .{ .r = 0, .g = 0, .b = 0 },
        );
        try testing.expect(try cache.put(@intCast(key), testing.allocator, &page, &resource_graph, &.{}, &font_catalog, &math_catalog));
    }
    cache.deinit();
    cache_live = false;

    try testing.expectEqualStrings("target", first.links.items[0].target);
    try testing.expectEqualStrings("target", second.destinations.items[0].name);
    try testing.expectEqual(@as(f64, 0.25), first.items.items[0].fill_rect.header.opacity);
    try testing.expectEqual(@as(f64, 1), second.items.items[0].fill_rect.header.opacity);
}

test "page cache evicts the least recently used page" {
    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    const resource_graph = render.ResourceGraph{};
    const font_catalog = render.FontCatalog{};
    const math_catalog = render.MathCatalog{};

    for (1..257) |key| {
        var page = render.Page{ .page_id = @intCast(key), .index = key - 1, .width = 320, .height = 180 };
        defer page.deinit(testing.allocator);
        try testing.expect(try cache.put(@intCast(key), testing.allocator, &page, &resource_graph, &.{}, &font_catalog, &math_catalog));
    }

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var refreshed = (try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer refreshed.deinit(testing.allocator);

    var newest = render.Page{ .page_id = 257, .index = 256, .width = 320, .height = 180 };
    defer newest.deinit(testing.allocator);
    try testing.expect(try cache.put(257, testing.allocator, &newest, &resource_graph, &.{}, &font_catalog, &math_catalog));

    try testing.expect((try cache.materialize(2, testing.allocator, testing.io, &resources, &fonts, &math)) == null);
    var retained = (try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer retained.deinit(testing.allocator);
}

test "page cache retains a complete document beyond its baseline entry count" {
    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    defer cache.deinit();
    cache.beginDocument(257);
    const resource_graph = render.ResourceGraph{};
    const font_catalog = render.FontCatalog{};
    const math_catalog = render.MathCatalog{};

    for (1..258) |key| {
        var page = render.Page{ .page_id = @intCast(key), .index = key - 1, .width = 320, .height = 180 };
        defer page.deinit(testing.allocator);
        try testing.expect(try cache.put(@intCast(key), testing.allocator, &page, &resource_graph, &.{}, &font_catalog, &math_catalog));
    }

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    var first = (try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer first.deinit(testing.allocator);
    var last = (try cache.materialize(257, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer last.deinit(testing.allocator);
}

test "page cache resource survives source graph and cache teardown" {
    var source_graph = blk: {
        const bytes = try testing.allocator.dupe(u8, "cached raster bytes");
        errdefer testing.allocator.free(bytes);
        const entries = try testing.allocator.alloc(render.Resource, 1);
        errdefer testing.allocator.free(entries);
        const name = try testing.allocator.dupe(u8, "cached.bin");
        errdefer testing.allocator.free(name);
        entries[0] = .{
            .id = render.identifyResource(.raster, bytes),
            .kind = .raster,
            .name = name,
            .bytes = bytes,
            .metadata = .{ .raster = .{
                .pixel_width = 1,
                .pixel_height = 1,
                .oriented_width = 1,
                .oriented_height = 1,
                .orientation = .normal,
                .color_space = .unknown,
                .has_alpha = false,
            } },
            .identity_verified = true,
        };
        try entries[0].share(testing.allocator);
        break :blk render.ResourceGraph{ .entries = entries };
    };
    const resource_id = source_graph.entries[0].id;
    var source_graph_live = true;
    defer if (source_graph_live) source_graph.deinit(testing.allocator);

    var cache = render_compile.PageCache.init(testing.allocator, testing.io);
    var cache_live = true;
    defer if (cache_live) cache.deinit();
    var input_fonts = render.FontBuilder{};
    defer input_fonts.deinit(testing.allocator);
    _ = try input_fonts.add(testing.allocator, testing.io, .{
        .resource = resource_id,
        .face_index = 0,
        .family = "Cached font",
        .postscript_name = "CachedFont",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
        .ascent_ratio = 0.8,
        .descent_ratio = 0.2,
        .line_gap_ratio = 0,
        .underline_position_ratio = -0.1,
        .underline_thickness_ratio = 0.05,
        .strikethrough_position_ratio = 0.3,
        .strikethrough_thickness_ratio = 0.05,
    });
    var font_catalog = try input_fonts.take(testing.allocator);
    defer font_catalog.deinit(testing.allocator);
    const math_catalog = render.MathCatalog{};
    var first_source_page = render.Page{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    defer first_source_page.deinit(testing.allocator);
    try first_source_page.appendRaster(
        testing.allocator,
        7,
        .{ .x = 10, .y = 20, .width = 30, .height = 40 },
        resource_id,
    );
    try testing.expect(try cache.put(1, testing.allocator, &first_source_page, &source_graph, &.{}, &font_catalog, &math_catalog));
    var second_source_page = render.Page{ .page_id = 2, .index = 1, .width = 320, .height = 180 };
    defer second_source_page.deinit(testing.allocator);
    try second_source_page.appendRaster(
        testing.allocator,
        8,
        .{ .x = 50, .y = 60, .width = 70, .height = 80 },
        resource_id,
    );
    try testing.expect(try cache.put(2, testing.allocator, &second_source_page, &source_graph, &.{}, &font_catalog, &math_catalog));
    const empty_graph = render.ResourceGraph{};
    const empty_fonts = render.FontCatalog{};
    for (3..258) |key| {
        var page = render.Page{ .page_id = @intCast(key), .index = key - 1, .width = 320, .height = 180 };
        defer page.deinit(testing.allocator);
        try testing.expect(try cache.put(@intCast(key), testing.allocator, &page, &empty_graph, &.{}, &empty_fonts, &math_catalog));
    }
    source_graph.deinit(testing.allocator);
    source_graph_live = false;

    var resources = render_resources.Builder{};
    defer resources.deinit(testing.allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(testing.allocator);
    var math = render.MathBuilder{};
    defer math.deinit(testing.allocator);
    try testing.expect((try cache.materialize(1, testing.allocator, testing.io, &resources, &fonts, &math)) == null);
    var materialized = (try cache.materialize(2, testing.allocator, testing.io, &resources, &fonts, &math)) orelse
        return error.MissingCachedPage;
    defer materialized.deinit(testing.allocator);
    cache.deinit();
    cache_live = false;

    var retained_graph = try resources.take(testing.allocator);
    defer retained_graph.deinit(testing.allocator);
    const retained_resource = retained_graph.find(resource_id) orelse return error.MissingRenderResource;
    try testing.expectEqualStrings("cached raster bytes", retained_resource.bytes);
    try testing.expectEqual(resource_id, materialized.items.items[0].raster.resource);
    var retained_fonts = try fonts.take(testing.allocator);
    defer retained_fonts.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), retained_fonts.instances.len);
    try testing.expectEqualStrings("Cached font", retained_fonts.instances[0].family);
}

test "document font environment rejects changes between layout and compilation" {
    var state = try initEmptyDocumentState();
    defer state.deinit();
    const prepared_pages = core.prepared.PreparedPages{ .pages = &.{} };

    const font_environment = try render_compile.acquireFontEnvironment(
        testing.allocator,
        testing.io,
        &state,
        &prepared_pages,
    );
    try render_compile.validateFontEnvironment(font_environment);
    try render_compile.refreshAndValidateFontEnvironment(font_environment);

    var seed_shape = std.mem.zeroes(c.SsTextShape);
    try testing.expectEqual(@as(c_int, 0), c.ss_text_shape(
        "font environment seed",
        "sans-serif",
        400,
        0,
        4,
        16,
        320,
        0,
        &seed_shape,
    ));
    defer c.ss_text_shape_free(&seed_shape);
    try testing.expect(seed_shape.run_count != 0);
    try testing.expect(seed_shape.runs[0].font_path != null);
    const font_path_ptr: [*:0]const u8 = @ptrCast(seed_shape.runs[0].font_path);
    const font_path = try testing.allocator.dupeZ(u8, std.mem.span(font_path_ptr));
    defer testing.allocator.free(font_path);

    const generation_before_registration = c.ss_font_generation();
    try testing.expectEqual(@as(c_int, 0), c.ss_font_register(font_path.ptr));
    try testing.expect(c.ss_font_generation() > generation_before_registration);

    try testing.expectError(
        error.FontEnvironmentChanged,
        render_compile.validateFontEnvironment(font_environment),
    );
    try testing.expectError(
        error.FontEnvironmentChanged,
        render_compile.refreshAndValidateFontEnvironment(font_environment),
    );
    try testing.expectError(
        error.FontEnvironmentChanged,
        render_compile.LayoutMeasurementScope.init(
            testing.allocator,
            testing.io,
            &state,
            &prepared_pages,
            null,
            &.{},
            font_environment,
        ),
    );
    try testing.expectError(
        error.FontEnvironmentChanged,
        render_compile.compilePrepared(
            testing.allocator,
            testing.io,
            &state,
            &prepared_pages,
            .{ .font_environment = font_environment },
        ),
    );
    try testing.expectError(
        error.FontEnvironmentChanged,
        render_compile.compile(
            testing.allocator,
            testing.io,
            &state,
            &prepared_pages,
            .{ .font_environment = font_environment },
        ),
    );
    try testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    for (state.diagnostics.items) |diagnostic| {
        const message = switch (diagnostic.data) {
            .user_report => |data| data.message,
            else => return error.ExpectedFontEnvironmentDiagnostic,
        };
        try testing.expect(std.mem.startsWith(u8, message, "FontEnvironmentChanged:"));
        try testing.expect(std.mem.indexOf(u8, message, "retry after font installation or font-cache updates finish") != null);
    }
}

test "font environment refresh failures produce actionable diagnostics" {
    var state = try initEmptyDocumentState();
    defer state.deinit();

    try testing.expect(try render_compile.addFontEnvironmentDiagnostic(&state, error.FontEnvironmentRefreshFailed));
    try testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    const message = switch (state.diagnostics.items[0].data) {
        .user_report => |data| data.message,
        else => return error.ExpectedFontEnvironmentDiagnostic,
    };
    try testing.expect(std.mem.startsWith(u8, message, "FontSetupFailed:"));
    try testing.expect(std.mem.indexOf(u8, message, "fc-list") != null);
    try testing.expect(std.mem.indexOf(u8, message, "FONTCONFIG_FILE") != null);
    try testing.expect(std.mem.indexOf(u8, message, "FontEnvironmentRefreshFailed") == null);

    try testing.expect(try render_compile.addFontEnvironmentDiagnostic(&state, error.FontEnvironmentRefreshFailed));
    try testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);

    try testing.expect(try render_compile.addFontEnvironmentDiagnostic(&state, error.PangoCreateFailed));
    try testing.expectEqual(@as(usize, 2), state.diagnostics.items.len);
    const pango_message = switch (state.diagnostics.items[1].data) {
        .user_report => |data| data.message,
        else => return error.ExpectedFontEnvironmentDiagnostic,
    };
    try testing.expect(std.mem.startsWith(u8, pango_message, "TextLayoutUnavailable:"));
    try testing.expect(std.mem.indexOf(u8, pango_message, "text layout data") != null);
    try testing.expect(std.mem.indexOf(u8, pango_message, "PangoCreateFailed") == null);

    try testing.expect(!(try render_compile.addFontEnvironmentDiagnostic(&state, error.IntentionalCompileFailure)));
    try testing.expectEqual(@as(usize, 2), state.diagnostics.items.len);
}

test "preload cache scan reports the TeX preamble path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer testing.allocator.free(root);
    const preamble_path = try std.fs.path.join(testing.allocator, &.{ root, "preamble.tex" });
    defer testing.allocator.free(preamble_path);
    const cache_dir = try std.fs.path.join(testing.allocator, &.{ root, "render-cache" });
    defer testing.allocator.free(cache_dir);
    try std.Io.Dir.cwd().createDirPath(testing.io, preamble_path);

    var state = try initEmptyDocumentState();
    defer state.deinit();
    const preamble = [_]core.render_env.TexPreambleEntry{
        .{ .source = .file, .value = preamble_path },
    };
    var dependencies = [_]core.prepared.AssetDependency{
        .{ .kind = .block_math, .source = "x", .content_start = 0, .content_end = 1 },
    };
    var objects = [_]core.prepared.PreparedObject{
        .{
            .node_id = 2,
            .content = "x",
            .content_provenance = &.{},
            .link_id = null,
            .render = undefined,
            .parse_mode = .none,
            .asset_deps = &dependencies,
            .tex_preamble = &preamble,
            .tex_engine = .pdflatex,
            .origin = null,
            .payload_kind = .math_tex,
            .attached = true,
        },
    };
    var page_storage = [_]core.prepared.PreparedPage{
        .{
            .page_id = 1,
            .index = 0,
            .background = null,
            .object_ids = &.{},
            .constraints = &.{},
            .objects = &objects,
        },
    };
    const pages = core.prepared.PreparedPages{ .pages = &page_storage };

    var failed = false;
    render_compile.preload(testing.allocator, testing.io, &state, &pages, .{ .cache_dir = cache_dir }, null) catch {
        failed = true;
    };
    try testing.expect(failed);
    try testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    const message = switch (state.diagnostics.items[0].data) {
        .render_failed => |data| data.reason,
        else => return error.ExpectedRenderFailureDiagnostic,
    };
    try testing.expect(std.mem.indexOf(u8, message, "TeX preamble") != null);
    try testing.expect(std.mem.indexOf(u8, message, preamble_path) != null);
    try testing.expect(std.mem.indexOf(u8, message, "could not be read") != null);
}
