const std = @import("std");
const pdf_backend = @import("pdf_backend");
const pdf_document = @import("pdf_document");
const render = @import("render");
const render_support = @import("render_test_support");
const render_resources = @import("render_resources");

const c = @cImport({
    @cInclude("backend.h");
});

const testing = std.testing;

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing expected PDF JSON text: {s}\n", .{needle});
        return error.ExpectedPdfJsonTextMissing;
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

const LayerDrawStats = struct {
    invocations: usize,
    distinct_resources: usize,
};

fn layerDrawStats(allocator: std.mem.Allocator, qdf: []const u8) !LayerDrawStats {
    var resources = std.StringHashMap(void).init(allocator);
    defer resources.deinit();
    var invocations: usize = 0;
    var previous: ?[]const u8 = null;
    var tokens = std.mem.tokenizeAny(u8, qdf, " \t\r\n");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "Do")) {
            if (previous) |name| {
                if (std.mem.startsWith(u8, name, "/SsLayer")) {
                    invocations += 1;
                    try resources.put(name, {});
                }
            }
        }
        previous = token;
    }
    return .{ .invocations = invocations, .distinct_resources = resources.count() };
}

fn expectInternalDestination(json: []const u8) !void {
    const direct_dest = contains(json, "\"/Dest\": \"u:target\"") or
        contains(json, "\"/Dest\": \"target\"") or
        contains(json, "\"/Dest\": [");
    const goto_action = contains(json, "\"/S\": \"/GoTo\"") and
        (contains(json, "\"/D\": \"u:target\"") or contains(json, "\"/D\": \"target\"") or contains(json, "\"/D\": ["));
    if (direct_dest or goto_action) return;

    std.debug.print("missing expected internal destination annotation in PDF JSON\n", .{});
    return error.ExpectedPdfJsonTextMissing;
}

fn expectCString(ptr: [*c]const u8) !void {
    try testing.expect(ptr != null);
    const sentinel: [*:0]const u8 = @ptrCast(ptr);
    try testing.expect(std.mem.span(sentinel).len > 0);
}

fn cStringSlice(ptr: [*c]const u8) []const u8 {
    if (ptr == null) return "";
    const sentinel: [*:0]const u8 = @ptrCast(ptr);
    return std.mem.span(sentinel);
}

const FontMapWorker = struct {
    phase: *std.atomic.Value(usize),
    completed: *std.atomic.Value(usize),
    failed: *std.atomic.Value(bool),
    generations: [2]u64 = .{ 0, 0 },

    fn run(self: *FontMapWorker) void {
        for (0..2) |round| {
            while (self.phase.load(.seq_cst) < round + 1) std.atomic.spinLoopHint();
            var shape = std.mem.zeroes(c.SsTextShape);
            if (c.ss_text_shape(
                "persistent worker",
                "sans-serif",
                400,
                0,
                4,
                16,
                320,
                0,
                &shape,
            ) != 0) {
                self.failed.store(true, .seq_cst);
            } else {
                self.generations[round] = shape.environment.generation;
                c.ss_text_shape_free(&shape);
            }
            _ = self.completed.fetchAdd(1, .seq_cst);
        }
    }
};

fn expectDeterministicDocumentId(io: std.Io, pdf_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, pdf_path, testing.allocator, .limited(2 * 1024 * 1024));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "31415926535897932384626433832795") == null);
}

fn firstPdfPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pdf")) {
            return try std.fs.path.join(allocator, &.{ directory, entry.name });
        }
    }
    return error.ExpectedCachedPdfMissing;
}

fn corruptFileWithoutChangingSize(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    if (bytes.len < 16) return error.ExpectedCachedPdfMissing;
    bytes[bytes.len / 2] ^= 0xff;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn expectUriLinkRect(json: []const u8, uri: []const u8, expected: [4]f64) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const qpdf_entries = parsed.value.object.get("qpdf") orelse return error.ExpectedPdfJsonTextMissing;
    for (qpdf_entries.array.items) |entry_group| {
        var entries = entry_group.object.iterator();
        while (entries.next()) |entry| {
            const wrapper = switch (entry.value_ptr.*) {
                .object => |value| value,
                else => continue,
            };
            const value = wrapper.get("value") orelse continue;
            const dictionary = switch (value) {
                .object => |object| object,
                else => continue,
            };
            const action_value = dictionary.get("/A") orelse continue;
            const action = switch (action_value) {
                .object => |object| object,
                else => continue,
            };
            const uri_value = action.get("/URI") orelse continue;
            const actual_uri = switch (uri_value) {
                .string => |string| if (std.mem.startsWith(u8, string, "u:")) string[2..] else string,
                else => continue,
            };
            if (!std.mem.eql(u8, actual_uri, uri)) continue;
            const rect_value = dictionary.get("/Rect") orelse return error.ExpectedPdfJsonTextMissing;
            const rect = switch (rect_value) {
                .array => |array| array,
                else => return error.ExpectedPdfJsonTextMissing,
            };
            if (rect.items.len != expected.len) return error.ExpectedPdfJsonTextMissing;
            for (rect.items, expected) |component, expected_component| {
                const actual = switch (component) {
                    .integer => |integer| @as(f64, @floatFromInt(integer)),
                    .float => |float| float,
                    else => return error.ExpectedPdfJsonTextMissing,
                };
                try testing.expectApproxEqAbs(expected_component, actual, 0.001);
            }
            return;
        }
    }
    return error.ExpectedPdfJsonTextMissing;
}

fn qpdfJson(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "qpdf", "--json", pdf_path },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    reportQpdfFailure("inspect", pdf_path, result.term, result.stderr);
    allocator.free(result.stdout);
    return error.QpdfJsonFailed;
}

fn qpdfQdf(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8, qdf_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "qpdf", "--qdf", "--object-streams=disable", "--stream-data=uncompress", pdf_path, qdf_path },
        .stdout_limit = .limited(128 * 1024),
        .stderr_limit = .limited(128 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return std.Io.Dir.cwd().readFileAlloc(io, qdf_path, allocator, .limited(2 * 1024 * 1024)),
        else => {},
    }
    reportQpdfFailure("convert", pdf_path, result.term, result.stderr);
    return error.QpdfQdfFailed;
}

fn reportQpdfFailure(action: []const u8, pdf_path: []const u8, term: std.process.Child.Term, stderr: []const u8) void {
    std.debug.print("qpdf could not {s} generated PDF '{s}' (termination: {}).\n", .{ action, pdf_path, term });
    const detail = std.mem.trim(u8, stderr, " \t\r\n");
    if (detail.len != 0) std.debug.print("qpdf reported:\n{s}\n", .{detail});
}

fn pdfTextIfAvailable(allocator: std.mem.Allocator, io: std.Io, pdf_path: []const u8) !?[]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "pdftotext", pdf_path, "-" },
        .stdout_limit = .limited(512 * 1024),
        .stderr_limit = .limited(128 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.PdfTextExtractionFailed;
}

fn expectFileMissing(io: std.Io, file_path: []const u8) !void {
    std.Io.Dir.cwd().access(io, file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ExpectedTemporaryFileCleanup;
}

fn documentSemantics(allocator: std.mem.Allocator, page_count: usize) !render.SemanticTree {
    const nodes = try allocator.alloc(render.SemanticNode, page_count + 1);
    errdefer allocator.free(nodes);
    const page_ids = try allocator.alloc(render.SemanticId, page_count);
    for (0..page_count) |index| {
        const id: render.SemanticId = @intCast(index + 2);
        page_ids[index] = id;
        nodes[index + 1] = .{ .id = id, .role = .page };
    }
    nodes[0] = .{ .id = 1, .role = .document, .children = page_ids };
    return .{ .root = 1, .nodes = nodes };
}

fn renderPage(ir: *const render.Ir, page_index: usize, output: []const u8) !void {
    var resources = try pdf_backend.ResourceFiles.init(testing.allocator, testing.io, &ir.resources, output);
    defer resources.deinit();
    try pdf_backend.render(testing.allocator, testing.io, ir, page_index, output, &resources);
}

fn renderDocument(ir: *const render.Ir, output: []const u8) !void {
    const cache_dir = try std.fmt.allocPrint(testing.allocator, "{s}.cache", .{output});
    defer testing.allocator.free(cache_dir);
    try pdf_document.write(testing.allocator, testing.io, ir, output, .{ .cache_dir = cache_dir }, null);
}

fn writeCairoPage(path: [*c]const u8, width: f64, height: f64) !void {
    const pdf = c.ss_pdf_create(path, width, height) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, width, height);
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}

test "render PDF spec: Cairo shim exposes rendering dependency versions" {
    try expectCString(c.ss_pdf_cairo_version_string());
    try expectCString(c.ss_pdf_pango_version_string());
    try expectCString(c.ss_pdf_librsvg_version_string());
    try expectCString(c.ss_pdf_gdk_pixbuf_version_string());
    try testing.expect(c.ss_pdf_fontconfig_version() > 0);
    try expectCString(c.ss_pdf_harfbuzz_version_string());
    try expectCString(c.ss_qpdf_version_string());
}

test "render PDF spec: Cairo output failures preserve their detail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const output_directory = try std.fs.path.join(allocator, &.{ root, "output-directory" });
    defer allocator.free(output_directory);
    try std.Io.Dir.cwd().createDirPath(testing.io, output_directory);
    const resource_root = try std.fs.path.join(allocator, &.{ root, "resource-root" });
    defer allocator.free(resource_root);

    var pages = [_]render.Page{.{ .page_id = 1, .index = 0, .width = 32, .height = 18 }};
    defer pages[0].deinit(allocator);
    var semantics = try documentSemantics(allocator, pages.len);
    defer semantics.deinit(allocator);
    const ir = render.Ir{ .semantics = semantics, .pages = &pages };
    var resources = try pdf_backend.ResourceFiles.init(allocator, testing.io, &ir.resources, resource_root);
    defer resources.deinit();

    try testing.expectError(
        error.CairoWriteFailed,
        pdf_backend.render(allocator, testing.io, &ir, 0, output_directory, &resources),
    );
    const detail = pdf_backend.lastFailureDetail() orelse return error.ExpectedCairoFailureDetail;
    try testing.expect(std.mem.indexOf(u8, detail, "writ") != null or std.mem.indexOf(u8, detail, "file") != null);
}

test "render PDF spec: writer classifies invalid input as preparation failure" {
    const allocator = testing.allocator;
    const output = ".ss-cache/test-render-pdf/invalid-input.pdf";
    var pages = [_]render.Page{.{ .page_id = 1, .index = 1, .width = 32, .height = 18 }};
    defer pages[0].deinit(allocator);
    var semantics = try documentSemantics(allocator, pages.len);
    defer semantics.deinit(allocator);
    const ir = render.Ir{ .semantics = semantics, .pages = &pages };

    var failure = pdf_document.WriteFailure{};
    defer failure.deinit(allocator);
    try testing.expectError(
        error.InvalidPageIndex,
        pdf_document.write(allocator, testing.io, &ir, output, .{ .failure = &failure }, null),
    );
    try testing.expectEqual(pdf_document.WriteFailureKind.preparation, failure.kind);
    try testing.expectEqualStrings("validate PDF render input", failure.operation);
    try testing.expectEqual(error.InvalidPageIndex, failure.cause.?);
    try testing.expectEqualStrings(output, failure.path.?);
}

test "render PDF spec: font environment selects a usable Fontconfig map" {
    var first_environment = std.mem.zeroes(c.SsFontEnvironment);
    var second_environment = std.mem.zeroes(c.SsFontEnvironment);
    try testing.expectEqual(@as(c_int, 0), c.ss_font_environment_snapshot(&first_environment));
    try testing.expectEqual(@as(c_int, 0), c.ss_font_environment_snapshot(&second_environment));
    try testing.expectEqual(first_environment.generation, second_environment.generation);
    try testing.expectEqualSlices(u8, &first_environment.id, &second_environment.id);
    var refreshed_environment = std.mem.zeroes(c.SsFontEnvironment);
    try testing.expectEqual(@as(c_int, 0), c.ss_font_environment_refresh(&refreshed_environment));
    try testing.expectEqual(first_environment.generation, refreshed_environment.generation);
    try testing.expectEqualSlices(u8, &first_environment.id, &refreshed_environment.id);
    const zero_environment = std.mem.zeroes(@TypeOf(first_environment.id));
    try testing.expect(!std.mem.eql(u8, &first_environment.id, &zero_environment));
}

test "render PDF spec: persistent worker font maps follow registered font generations" {
    var seed_shape = std.mem.zeroes(c.SsTextShape);
    try testing.expectEqual(@as(c_int, 0), c.ss_text_shape(
        "font registration seed",
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
    const font_path = try testing.allocator.dupeZ(u8, cStringSlice(seed_shape.runs[0].font_path));
    defer testing.allocator.free(font_path);

    var phase = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);
    var workers: [4]FontMapWorker = undefined;
    var threads: [workers.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        phase.store(2, .seq_cst);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&workers, 0..) |*worker, index| {
        worker.* = .{ .phase = &phase, .completed = &completed, .failed = &failed };
        threads[index] = try std.Thread.spawn(.{}, FontMapWorker.run, .{worker});
        started += 1;
    }

    phase.store(1, .seq_cst);
    while (completed.load(.seq_cst) != workers.len) std.atomic.spinLoopHint();
    try testing.expect(!failed.load(.seq_cst));
    const initial_generation = workers[0].generations[0];
    for (workers) |worker| try testing.expectEqual(initial_generation, worker.generations[0]);

    const generation_before_registration = c.ss_font_generation();
    try testing.expectEqual(@as(c_int, 0), c.ss_font_register(font_path.ptr));
    const registered_generation = c.ss_font_generation();
    try testing.expect(registered_generation > generation_before_registration);
    try testing.expectEqual(@as(c_int, 0), c.ss_font_register(font_path.ptr));
    try testing.expectEqual(registered_generation, c.ss_font_generation());

    phase.store(2, .seq_cst);
    while (completed.load(.seq_cst) != workers.len * 2) std.atomic.spinLoopHint();
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    try testing.expect(!failed.load(.seq_cst));
    for (workers) |worker| {
        try testing.expectEqual(registered_generation, worker.generations[1]);
        try testing.expect(worker.generations[1] > worker.generations[0]);
    }
}

test "render PDF spec: cached resources replace equal-sized corrupt files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/resource-cache", .{tmp.sub_path[0..]});
    defer allocator.free(root);

    const source = "<svg>ok</svg>";
    const id = render.identifyResource(.svg, source);
    var entries = [_]render.Resource{.{
        .id = id,
        .kind = .svg,
        .name = @constCast("asset.svg"),
        .bytes = @constCast(source),
        .metadata = .{ .svg = .{ .width = 1, .height = 1, .view_box = null } },
    }};
    const graph = render.ResourceGraph{ .entries = &entries };

    var first = try pdf_backend.ResourceFiles.initCached(allocator, testing.io, &graph, root);
    first.deinit();

    const hex = std.fmt.bytesToHex(id, .lower);
    const path = try std.fmt.allocPrint(allocator, "{s}/resources/{s}.svg", .{ root, &hex });
    defer allocator.free(path);
    const corrupt = try allocator.alloc(u8, source.len);
    defer allocator.free(corrupt);
    @memset(corrupt, 'x');
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = corrupt, .flags = .{ .truncate = true } });

    var second = try pdf_backend.ResourceFiles.initCached(allocator, testing.io, &graph, root);
    second.deinit();
    const restored = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, allocator, .unlimited);
    defer allocator.free(restored);
    try testing.expectEqualStrings(source, restored);
}

test "render PDF spec: qpdf replaces selected pages in an immutable base document" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const first_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replace-first.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(first_path);
    const old_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replace-old.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(old_path);
    const last_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replace-last.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(last_path);
    const replacement_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replacement.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(replacement_path);
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replace-base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/replace-output.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);

    try writeQpdfTestLayer(allocator, first_path, "first", "https://example.com/first");
    try writeQpdfTestLayer(allocator, old_path, "old", "https://example.com/old");
    try writeQpdfTestLayer(allocator, last_path, "last", "https://example.com/last");
    try writeQpdfTestLayerSized(allocator, replacement_path, "replacement", "https://example.com/replacement", 400, 240);

    const first_z = try allocator.dupeZ(u8, first_path);
    defer allocator.free(first_z);
    const old_z = try allocator.dupeZ(u8, old_path);
    defer allocator.free(old_z);
    const last_z = try allocator.dupeZ(u8, last_path);
    defer allocator.free(last_z);
    const replacement_z = try allocator.dupeZ(u8, replacement_path);
    defer allocator.free(replacement_z);
    const base_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_z);
    const output_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_z);
    const inputs = [_][*c]const u8{ first_z.ptr, old_z.ptr, last_z.ptr };
    try testing.expectEqual(
        @as(c_int, 0),
        c.ss_qpdf_merge(base_z.ptr, inputs[0..].ptr, inputs.len, 1, null, 0, null, 0),
    );
    const replacements = [_][*c]const u8{replacement_z.ptr};
    const page_indices = [_]usize{1};
    try testing.expectEqual(
        @as(c_int, 0),
        c.ss_qpdf_replace_pages(
            output_z.ptr,
            base_z.ptr,
            replacements[0..].ptr,
            page_indices[0..].ptr,
            replacements.len,
        ),
    );

    var widths: [3]f64 = undefined;
    var heights: [3]f64 = undefined;
    try testing.expectEqual(
        @as(c_int, 0),
        c.ss_qpdf_page_sizes(output_z.ptr, 1, widths[0..].ptr, heights[0..].ptr, widths.len),
    );
    try testing.expectApproxEqAbs(@as(f64, 320), widths[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 400), widths[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 320), widths[2], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), heights[0], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 240), heights[1], 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), heights[2], 0.001);

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "https://example.com/first");
    try expectContains(json, "https://example.com/replacement");
    try expectContains(json, "https://example.com/last");
    try testing.expect(!contains(json, "https://example.com/old"));
}

test "render PDF spec: qpdf merge creates link annotations and destinations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/links.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);
    const merged_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/merged-links.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(merged_path);
    const merged_path_z = try allocator.dupeZ(u8, merged_path);
    defer allocator.free(merged_path_z);

    {
        const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
        defer c.ss_pdf_destroy(pdf);
        try expectCString(c.ss_pdf_status_string(pdf));
        c.ss_pdf_begin_page(pdf, 320, 180);
        c.ss_pdf_fill_rect(pdf, 20, 20, 120, 24, 0, 0, 0);
        c.ss_pdf_fill_rect(pdf, 20, 60, 120, 24, 0, 0, 0);
        c.ss_pdf_end_page(pdf);
        try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
    }

    const inputs = [_][*c]const u8{pdf_path_z.ptr};
    const links = [_]c.SsQpdfLink{
        .{
            .page_index = 0,
            .kind = c.SS_QPDF_LINK_URI,
            .target = "https://example.com",
            .x = 20,
            .y = 20,
            .width = 120,
            .height = 24,
        },
        .{
            .page_index = 0,
            .kind = c.SS_QPDF_LINK_DESTINATION,
            .target = "target",
            .x = 20,
            .y = 60,
            .width = 120,
            .height = 24,
        },
    };
    const destinations = [_]c.SsQpdfDestination{
        .{
            .page_index = 0,
            .name = "target",
            .x = 20,
            .y = 20,
        },
        .{
            .page_index = 0,
            .name = "section 'one' \\ café λ",
            .x = 40,
            .y = 40,
        },
    };
    try testing.expectEqual(
        @as(c_int, 0),
        c.ss_qpdf_merge(
            merged_path_z.ptr,
            inputs[0..].ptr,
            inputs.len,
            1,
            &links,
            links.len,
            &destinations,
            destinations.len,
        ),
    );
    const json = try qpdfJson(allocator, testing.io, merged_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Names\"");
    try expectContains(json, "\"/Annots\"");
    try expectContains(json, "\"/Subtype\": \"/Link\"");
    try expectContains(json, "\"/P\"");
    try expectContains(json, "\"/S\": \"/URI\"");
    try expectContains(json, "https://example.com");
    try expectContains(json, "café λ");
    try expectUriLinkRect(json, "https://example.com", .{ 20, 136, 140, 160 });
    try expectInternalDestination(json);
}

test "render PDF spec: qpdf merge rejects unsafe link annotations" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/unsafe-link.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);
    const merged_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/unsafe-link-merged.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(merged_path);
    const merged_path_z = try allocator.dupeZ(u8, merged_path);
    defer allocator.free(merged_path_z);

    try writeCairoPage(pdf_path_z.ptr, 320, 180);
    const inputs = [_][*c]const u8{pdf_path_z.ptr};
    const links = [_]c.SsQpdfLink{.{
        .page_index = 0,
        .kind = c.SS_QPDF_LINK_URI,
        .target = "javascript:alert(1)",
        .x = 20,
        .y = 20,
        .width = 120,
        .height = 24,
    }};
    try testing.expectEqual(
        @as(c_int, 1),
        c.ss_qpdf_merge(merged_path_z.ptr, inputs[0..].ptr, inputs.len, 1, &links, links.len, null, 0),
    );
    try expectContains(cStringSlice(c.ss_qpdf_last_error()), "unsafe PDF link URI");
}

test "render PDF spec: Cairo item effects preserve drawing state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/item-effects.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    var effects = std.mem.zeroes(c.SsLayerEffects);
    effects.xx = 1;
    effects.yy = 1;
    effects.opacity = 1;
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_begin_item(pdf, &effects));
    c.ss_pdf_fill_rect(pdf, 20, 20, 120, 24, 0, 0, 0);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_end_item(pdf));
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}

test "render PDF spec: native primitive parameters cross the C boundary intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/native-primitives.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const qdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/native-primitives.qdf.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(qdf_path);

    var pages = [_]render.Page{.{
        .page_id = 1,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer pages[0].deinit(allocator);
    try pages[0].appendFillRect(
        allocator,
        null,
        .{ .x = 0, .y = 0, .width = 320, .height = 180 },
        .{ .r = 1, .g = 1, .b = 1 },
    );
    try pages[0].appendStrokeLine(
        allocator,
        10,
        .{ .x = 20, .y = 30 },
        .{ .x = 300, .y = 150 },
        7,
        .{ .r = 0.1, .g = 0.2, .b = 0.3 },
        11,
        13,
    );
    try pages[0].appendRoundedRect(
        allocator,
        11,
        .{ .x = 40, .y = 50, .width = 120, .height = 70 },
        9,
        .{ .r = 0.2, .g = 0.4, .b = 0.6 },
        .{ .r = 0.7, .g = 0.8, .b = 0.9 },
        5,
    );
    var semantics = try documentSemantics(allocator, pages.len);
    defer semantics.deinit(allocator);
    const ir = render.Ir{ .semantics = semantics, .pages = &pages };
    try renderPage(&ir, 0, output_path);

    const qdf = try qpdfQdf(allocator, testing.io, output_path, qdf_path);
    defer allocator.free(qdf);
    try expectContains(qdf, "0.1 0.2 0.3 RG 7 w");
    try expectContains(qdf, "[ 11 13] 0 d");
    try expectContains(qdf, "20 30 m 300 150 l S");
    try expectContains(qdf, "0.2 0.4 0.6 rg");
    try expectContains(qdf, "0.7 0.8 0.9 RG 5 w");
}

test "render PDF spec: page renderer replays and composes ordered resources" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/page-source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/page-composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);

    var source_pages = [_]render.Page{.{
        .page_id = 1,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer source_pages[0].deinit(allocator);
    try source_pages[0].appendFillRect(allocator, null, .{ .x = 0, .y = 0, .width = 320, .height = 180 }, .{ .r = 1, .g = 1, .b = 1 });
    var source_resource_builder = render_resources.Builder{};
    defer source_resource_builder.deinit(allocator);
    var source_font_builder = render.FontBuilder{};
    defer source_font_builder.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &source_pages[0],
        &source_resource_builder,
        &source_font_builder,
        10,
        20,
        60,
        260,
        "selectable page text",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try source_pages[0].appendLink(allocator, .uri, "https://example.com/page", .{ .x = 20, .y = 36, .width = 240, .height = 32 });
    var source_semantics = try documentSemantics(allocator, source_pages.len);
    defer source_semantics.deinit(allocator);
    const source_catalogs = try render_support.takeCatalogs(allocator, &source_resource_builder, &source_font_builder);
    defer {
        var owned_resources = source_catalogs.resources;
        owned_resources.deinit(allocator);
        var owned_fonts = source_catalogs.fonts;
        owned_fonts.deinit(allocator);
    }
    const source_ir = render.Ir{
        .resources = source_catalogs.resources,
        .fonts = source_catalogs.fonts,
        .semantics = source_semantics,
        .pages = &source_pages,
    };
    try renderDocument(&source_ir, source_path);

    var composed_pages = [_]render.Page{.{
        .page_id = 2,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer composed_pages[0].deinit(allocator);
    try composed_pages[0].appendFillRect(allocator, null, .{ .x = 0, .y = 0, .width = 320, .height = 180 }, .{ .r = 1, .g = 1, .b = 1 });
    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(allocator);
    var composed_font_builder = render.FontBuilder{};
    defer composed_font_builder.deinit(allocator);
    const source_resource = try resource_builder.addPath(allocator, testing.io, .pdf, source_path);
    try render_support.appendText(
        allocator,
        testing.io,
        &composed_pages[0],
        &resource_builder,
        &composed_font_builder,
        10,
        10,
        16,
        300,
        "native text before PDF",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        10,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try composed_pages[0].appendPdfPage(
        allocator,
        11,
        .{ .x = 20, .y = 20, .width = 280, .height = 140 },
        source_resource,
        0,
        .crop,
        true,
    );
    composed_pages[0].items.items[2].pdf_page.header.transform.x0 = 6;
    composed_pages[0].items.items[2].pdf_page.header.clip = .{ .rect = .{ .x = 20, .y = 20, .width = 260, .height = 120 } };
    composed_pages[0].items.items[2].pdf_page.header.opacity = 0.75;
    composed_pages[0].items.items[2].pdf_page.header.blend_mode = .multiply;
    try render_support.appendText(
        allocator,
        testing.io,
        &composed_pages[0],
        &resource_builder,
        &composed_font_builder,
        12,
        10,
        176,
        300,
        "native text after PDF",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        10,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try composed_pages[0].appendStrokeLine(
        allocator,
        13,
        .{ .x = 20, .y = 20 },
        .{ .x = 300, .y = 160 },
        2,
        .{ .r = 1, .g = 0, .b = 0 },
        0,
        0,
    );
    const composed_catalogs = try render_support.takeCatalogs(allocator, &resource_builder, &composed_font_builder);
    defer {
        var owned_resources = composed_catalogs.resources;
        owned_resources.deinit(allocator);
        var owned_fonts = composed_catalogs.fonts;
        owned_fonts.deinit(allocator);
    }
    var composed_semantics = try documentSemantics(allocator, composed_pages.len);
    defer composed_semantics.deinit(allocator);
    const composed_ir = render.Ir{
        .resources = composed_catalogs.resources,
        .fonts = composed_catalogs.fonts,
        .semantics = composed_semantics,
        .pages = &composed_pages,
    };
    try renderPage(&composed_ir, 0, output_path);

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Subtype\": \"/Form\"");
    try expectContains(json, "\"/BM\": \"/Multiply\"");
    try expectContains(json, "\"/ca\": 0.75");
    try expectContains(json, "https://example.com/page");
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "native text before PDF");
        try expectContains(text, "selectable page text");
        try expectContains(text, "native text after PDF");
    }
    const first_layer_path = try std.fmt.allocPrint(allocator, "{s}.layer-0.pdf", .{output_path});
    defer allocator.free(first_layer_path);
    const second_layer_path = try std.fmt.allocPrint(allocator, "{s}.layer-1.pdf", .{output_path});
    defer allocator.free(second_layer_path);
    try expectFileMissing(testing.io, first_layer_path);
    try expectFileMissing(testing.io, second_layer_path);
}

test "render PDF spec: document renderer publishes, verifies, and reuses content-addressed output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const cache = try std.fs.path.join(allocator, &.{ root, "render-cache" });
    defer allocator.free(cache);
    const first_path = try std.fs.path.join(allocator, &.{ root, "first.pdf" });
    defer allocator.free(first_path);
    const second_path = try std.fs.path.join(allocator, &.{ root, "second.pdf" });
    defer allocator.free(second_path);

    var pages = try allocator.alloc(render.Page, 2);
    pages[0] = .{ .page_id = 1, .index = 0, .width = 320, .height = 180 };
    pages[1] = .{ .page_id = 2, .index = 1, .width = 320, .height = 180 };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(allocator);
    ir.semantics = try documentSemantics(allocator, pages.len);
    var text_resources = render_resources.Builder{};
    defer text_resources.deinit(allocator);
    var text_fonts = render.FontBuilder{};
    defer text_fonts.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[0],
        &text_resources,
        &text_fonts,
        10,
        20,
        60,
        260,
        "first cached page",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[1],
        &text_resources,
        &text_fonts,
        11,
        20,
        60,
        260,
        "second cached page",
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        24,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    const text_catalogs = try render_support.takeCatalogs(allocator, &text_resources, &text_fonts);
    ir.resources = text_catalogs.resources;
    ir.fonts = text_catalogs.fonts;

    try pdf_document.write(allocator, testing.io, &ir, first_path, .{ .jobs = 1, .cache_dir = cache }, null);
    const first = try std.Io.Dir.cwd().readFileAlloc(testing.io, first_path, allocator, .unlimited);
    defer allocator.free(first);
    const first_path_z = try allocator.dupeZ(u8, first_path);
    defer allocator.free(first_path_z);
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_validate(first_path_z.ptr, 2, 1));
    try testing.expect(c.ss_qpdf_validate(first_path_z.ptr, 1, 1) != 0);

    const cache_root = try std.fs.path.join(allocator, &.{ cache, pdf_document.cache_version });
    defer allocator.free(cache_root);
    const document_directory = try std.fs.path.join(allocator, &.{ cache_root, "documents" });
    defer allocator.free(document_directory);
    const page_directory = try std.fs.path.join(allocator, &.{ cache_root, "pages" });
    defer allocator.free(page_directory);
    const cached_document = try firstPdfPath(allocator, testing.io, document_directory);
    defer allocator.free(cached_document);
    const cached_page = try firstPdfPath(allocator, testing.io, page_directory);
    defer allocator.free(cached_page);
    try corruptFileWithoutChangingSize(allocator, testing.io, cached_document);
    try corruptFileWithoutChangingSize(allocator, testing.io, cached_page);

    try pdf_document.write(allocator, testing.io, &ir, second_path, .{ .jobs = 8, .cache_dir = cache }, null);
    const second = try std.Io.Dir.cwd().readFileAlloc(testing.io, second_path, allocator, .unlimited);
    defer allocator.free(second);
    try testing.expectEqualSlices(u8, first, second);
    if (try pdfTextIfAvailable(allocator, testing.io, second_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "first cached page");
        try expectContains(text, "second cached page");
    }
}

test "render PDF spec: parallel page failures preserve qpdf detail and cache path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const cache = try std.fs.path.join(allocator, &.{ root, "render-cache" });
    defer allocator.free(cache);
    const output = try std.fs.path.join(allocator, &.{ root, "output.pdf" });
    defer allocator.free(output);
    const source_pdf = try std.fs.path.join(allocator, &.{ root, "source.pdf" });
    defer allocator.free(source_pdf);

    var source_pages = [_]render.Page{.{ .page_id = 1, .index = 0, .width = 32, .height = 18 }};
    defer source_pages[0].deinit(allocator);
    var source_semantics = try documentSemantics(allocator, source_pages.len);
    defer source_semantics.deinit(allocator);
    const source_ir = render.Ir{ .semantics = source_semantics, .pages = &source_pages };
    try renderPage(&source_ir, 0, source_pdf);

    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(allocator);
    const resource_id = try resource_builder.addPath(allocator, testing.io, .pdf, source_pdf);
    var resources = try resource_builder.take(allocator);
    defer resources.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), resources.entries.len);
    @memset(resources.entries[0].bytes, 0);

    var pages = [_]render.Page{
        .{ .page_id = 1, .index = 0, .width = 320, .height = 180 },
        .{ .page_id = 2, .index = 1, .width = 320, .height = 180 },
    };
    defer for (&pages) |*page| page.deinit(allocator);
    for (&pages) |*page| {
        try page.appendPdfPage(
            allocator,
            page.page_id + 10,
            .{ .x = 20, .y = 20, .width = 280, .height = 140 },
            resource_id,
            0,
            .crop,
            true,
        );
    }
    var semantics = try documentSemantics(allocator, pages.len);
    defer semantics.deinit(allocator);
    const ir = render.Ir{ .resources = resources, .semantics = semantics, .pages = &pages };

    var failure = pdf_document.WriteFailure{};
    defer failure.deinit(allocator);
    try testing.expectError(
        error.AssetConversionFailed,
        pdf_document.write(allocator, testing.io, &ir, output, .{
            .jobs = 2,
            .cache_dir = cache,
            .failure = &failure,
        }, null),
    );
    try testing.expectEqual(pdf_document.WriteFailureKind.page_render, failure.kind);
    try testing.expectEqual(error.AssetConversionFailed, failure.cause.?);
    try testing.expect(std.mem.indexOf(u8, failure.path.?, "/pages/") != null);
    try testing.expect(std.mem.indexOf(u8, failure.detail.?, "PDF") != null);
}

test "render PDF spec: manifest fingerprint workers handle empty and single-page documents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    defer allocator.free(root);
    const cache = try std.fs.path.join(allocator, &.{ root, "render-cache" });
    defer allocator.free(cache);
    const empty_path = try std.fs.path.join(allocator, &.{ root, "empty.pdf" });
    defer allocator.free(empty_path);
    const single_path = try std.fs.path.join(allocator, &.{ root, "single.pdf" });
    defer allocator.free(single_path);

    var empty_semantics = try documentSemantics(allocator, 0);
    defer empty_semantics.deinit(allocator);
    const empty_ir = render.Ir{ .semantics = empty_semantics, .pages = &.{} };
    try pdf_document.write(allocator, testing.io, &empty_ir, empty_path, .{ .jobs = 32, .cache_dir = cache }, null);

    var pages = [_]render.Page{.{
        .page_id = 1,
        .index = 0,
        .width = 320,
        .height = 180,
    }};
    defer pages[0].deinit(allocator);
    var single_semantics = try documentSemantics(allocator, pages.len);
    defer single_semantics.deinit(allocator);
    const single_ir = render.Ir{ .semantics = single_semantics, .pages = &pages };
    try pdf_document.write(allocator, testing.io, &single_ir, single_path, .{ .jobs = 32, .cache_dir = cache }, null);

    const single_path_z = try allocator.dupeZ(u8, single_path);
    defer allocator.free(single_path_z);
    var width: f64 = 0;
    var height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_page_size(single_path_z.ptr, 0, 1, &width, &height));
    try testing.expectApproxEqAbs(@as(f64, 320), width, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), height, 0.001);
}

test "render PDF spec: raster shim decodes and draws without a converted PNG" {
    var width: f64 = 0;
    var height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_raster_size("assets/logo.png", &width, &height));
    try testing.expect(width > 0);
    try testing.expect(height > 0);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/raster.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_draw_raster(pdf, "assets/logo.png", 20, 20, 120, 120));
    c.ss_pdf_end_page(pdf);
    try testing.expectEqual(@as(c_int, 0), c.ss_pdf_finish(pdf));
}

test "render PDF spec: image loaders preserve native error details" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const raster_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/missing-raster.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(raster_path);
    const raster_path_z = try allocator.dupeZ(u8, raster_path);
    defer allocator.free(raster_path_z);

    const raster_pdf = c.ss_pdf_create(raster_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(raster_pdf);
    c.ss_pdf_begin_page(raster_pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 1), c.ss_pdf_draw_raster(raster_pdf, "missing-raster.png", 20, 20, 120, 120));
    const raster_error = cStringSlice(c.ss_pdf_status_string(raster_pdf));
    try testing.expect(contains(raster_error, "could not load raster image"));
    try testing.expect(contains(raster_error, "missing-raster.png"));

    const svg_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/missing-svg.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(svg_path);
    const svg_path_z = try allocator.dupeZ(u8, svg_path);
    defer allocator.free(svg_path_z);

    const svg_pdf = c.ss_pdf_create(svg_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(svg_pdf);
    c.ss_pdf_begin_page(svg_pdf, 320, 180);
    try testing.expectEqual(@as(c_int, 1), c.ss_pdf_draw_svg(svg_pdf, "missing-vector.svg", 20, 20, 120, 120));
    const svg_error = cStringSlice(c.ss_pdf_status_string(svg_pdf));
    try testing.expect(contains(svg_error, "could not load SVG image"));
    try testing.expect(contains(svg_error, "missing-vector.svg"));
}

test "render PDF spec: raster replay preserves image failure detail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const output = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/invalid-raster.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output);

    var resource_builder = render_resources.Builder{};
    defer resource_builder.deinit(allocator);
    const resource_id = try resource_builder.addPath(allocator, testing.io, .raster, "assets/logo.png");
    var resource_graph = try resource_builder.take(allocator);
    defer resource_graph.deinit(allocator);
    @memset(resource_graph.entries[0].bytes, 0);

    var pages = [_]render.Page{.{ .page_id = 1, .index = 0, .width = 320, .height = 180 }};
    defer pages[0].deinit(allocator);
    try pages[0].appendRaster(
        allocator,
        1,
        .{ .x = 20, .y = 20, .width = 120, .height = 120 },
        resource_id,
    );
    var semantics = try documentSemantics(allocator, pages.len);
    defer semantics.deinit(allocator);
    const ir = render.Ir{ .resources = resource_graph, .semantics = semantics, .pages = &pages };
    var resources = try pdf_backend.ResourceFiles.init(allocator, testing.io, &ir.resources, output);
    defer resources.deinit();

    try testing.expectError(
        error.ImageDecodeFailed,
        pdf_backend.render(allocator, testing.io, &ir, 0, output, &resources),
    );
    const detail = pdf_backend.lastFailureDetail() orelse return error.ExpectedCairoFailureDetail;
    try testing.expect(contains(detail, "could not load raster image"));
}

test "render PDF spec: glyph failures preserve native error details" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const pdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/operation-errors.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(pdf_path);
    const pdf_path_z = try allocator.dupeZ(u8, pdf_path);
    defer allocator.free(pdf_path_z);

    const pdf = c.ss_pdf_create(pdf_path_z.ptr, 320, 180) orelse return error.CairoCreateFailed;
    defer c.ss_pdf_destroy(pdf);
    c.ss_pdf_begin_page(pdf, 320, 180);

    try testing.expectEqual(@as(c_int, 1), c.ss_pdf_draw_glyph_run(
        pdf,
        "missing-font-face.ttf",
        0,
        16,
        0,
        0,
        0,
        "",
        0,
        null,
        0,
        null,
        0,
        0,
    ));
    const glyph_error = cStringSlice(c.ss_pdf_status_string(pdf));
    try testing.expect(contains(glyph_error, "could not load PDF font face"));
    try testing.expect(contains(glyph_error, "missing-font-face.ttf"));
}

test "render PDF spec: libqpdf composes a selectable page form and copies links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "selectable form text", "https://example.com/form");

    var source_width: f64 = 0;
    var source_height: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_page_size(source_path_z.ptr, 0, 1, &source_width, &source_height));
    try testing.expectApproxEqAbs(@as(f64, 320), source_width, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 180), source_height, 0.001);

    const layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, true),
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));
    try expectDeterministicDocumentId(testing.io, output_path);

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/Subtype\": \"/Form\"");
    try expectContains(json, "https://example.com/form");
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "selectable form text");
    }
}

test "render PDF spec: libqpdf reuses one imported form for repeated placements" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const qdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.qdf.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(qdf_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "repeated form text", "https://example.com/repeated");
    const layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 20, 30, 120, 68, true),
        qpdfLayer(source_path_z.ptr, 170, 80, 120, 68, true),
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, json, "https://example.com/repeated"));

    const qdf = try qpdfQdf(allocator, testing.io, output_path, qdf_path);
    defer allocator.free(qdf);
    const draw_stats = try layerDrawStats(allocator, qdf);
    try testing.expectEqual(@as(usize, 2), draw_stats.invocations);
    try testing.expectEqual(@as(usize, 1), draw_stats.distinct_resources);
}

test "render PDF spec: libqpdf omits source links when annotation copying is disabled" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "text without copied link", "https://example.com/omitted");
    const layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, false),
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try testing.expect(!contains(json, "https://example.com/omitted"));
    if (try pdfTextIfAvailable(allocator, testing.io, output_path)) |text| {
        defer allocator.free(text);
        try expectContains(text, "text without copied link");
    }
}

test "render PDF spec: libqpdf applies layer effects to content and copied links" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = testing.allocator;
    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/base.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(base_path);
    const source_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/source.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(source_path);
    const output_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(output_path);
    const qdf_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/composed.qdf.pdf", .{tmp.sub_path[0..]});
    defer allocator.free(qdf_path);
    const base_path_z = try allocator.dupeZ(u8, base_path);
    defer allocator.free(base_path_z);
    const source_path_z = try allocator.dupeZ(u8, source_path);
    defer allocator.free(source_path_z);
    const output_path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(output_path_z);

    try writeQpdfTestLayer(allocator, base_path, "base", null);
    try writeQpdfTestLayer(allocator, source_path, "effected selectable text", "https://example.com/effected");
    var layers = [_]c.SsQpdfLayer{
        qpdfLayer(base_path_z.ptr, 0, 0, 320, 180, false),
        qpdfLayer(source_path_z.ptr, 40, 30, 160, 90, true),
    };
    layers[1].effects = .{
        .xx = 1,
        .yx = 0,
        .xy = 0,
        .yy = 1,
        .x0 = 12,
        .y0 = -8,
        .has_clip = 1,
        .clip_x = 40,
        .clip_y = 30,
        .clip_width = 120,
        .clip_height = 80,
        .opacity = 0.5,
        .blend_mode = 1,
    };
    try testing.expectEqual(@as(c_int, 0), c.ss_qpdf_compose(output_path_z.ptr, &layers, layers.len));

    const json = try qpdfJson(allocator, testing.io, output_path);
    defer allocator.free(json);
    try expectContains(json, "\"/BM\": \"/Multiply\"");
    try expectContains(json, "\"/ca\": 0.5");
    try expectContains(json, "https://example.com/effected");
    try expectUriLinkRect(json, "https://example.com/effected", .{ 62, 87, 172, 102 });

    const qdf = try qpdfQdf(allocator, testing.io, output_path, qdf_path);
    defer allocator.free(qdf);
    try expectContains(qdf, "1 0 0 1 12 -8 cm");
    try expectContains(qdf, "40 30 120 80 re W n");
    try expectContains(qdf, "/SsState1 gs");
}

fn qpdfLayer(
    path: [*c]const u8,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    copy_annotations: bool,
) c.SsQpdfLayer {
    return .{
        .path = path,
        .page_index = 0,
        .box = 1,
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .copy_annotations = @intFromBool(copy_annotations),
        .effects = .{
            .xx = 1,
            .yx = 0,
            .xy = 0,
            .yy = 1,
            .x0 = 0,
            .y0 = 0,
            .has_clip = 0,
            .clip_x = 0,
            .clip_y = 0,
            .clip_width = 0,
            .clip_height = 0,
            .opacity = 1,
            .blend_mode = 0,
        },
    };
}

fn writeQpdfTestLayer(allocator: std.mem.Allocator, path: []const u8, text: []const u8, uri: ?[]const u8) !void {
    return writeQpdfTestLayerSized(allocator, path, text, uri, 320, 180);
}

fn writeQpdfTestLayerSized(
    allocator: std.mem.Allocator,
    path: []const u8,
    text: []const u8,
    uri: ?[]const u8,
    width: f64,
    height: f64,
) !void {
    var pages = try allocator.alloc(render.Page, 1);
    pages[0] = .{ .page_id = 1, .index = 0, .width = width, .height = height };
    var ir = render.Ir{ .pages = pages };
    defer ir.deinit(allocator);
    ir.semantics = try documentSemantics(allocator, pages.len);
    var resources = render_resources.Builder{};
    defer resources.deinit(allocator);
    var fonts = render.FontBuilder{};
    defer fonts.deinit(allocator);
    try render_support.appendText(
        allocator,
        testing.io,
        &pages[0],
        &resources,
        &fonts,
        1,
        20,
        38,
        260,
        text,
        .{ .family = "sans-serif", .weight = 400, .style = .normal, .stretch = .normal },
        18,
        .{ .r = 0, .g = 0, .b = 0 },
    );
    if (uri) |target| try pages[0].appendLink(allocator, .uri, target, .{ .x = 20, .y = 20, .width = 220, .height = 30 });
    const catalogs = try render_support.takeCatalogs(allocator, &resources, &fonts);
    ir.resources = catalogs.resources;
    ir.fonts = catalogs.fonts;
    try renderDocument(&ir, path);
}
