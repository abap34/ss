const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const c = @import("pdf_ffi").c;
const render_ir = @import("render");
const render_resources = @import("render_resources");
const fingerprint = @import("fingerprint.zig");
const latex_document = @import("latex.zig");
const latex_inputs = @import("latex_inputs.zig");
const external_process = @import("external_process.zig");
const native_artifact_cache_version = @import("cache_versions.zig").native_artifacts;
const hashString = fingerprint.hashString;
const Allocator = std.mem.Allocator;
const LatexPreambleEntry = core.render_env.LatexPreambleEntry;
const LatexEngine = core.render_env.LatexEngine;
const LatexFragmentKind = latex_document.FragmentKind;
const NativePdfError = error{ ImageDecodeFailed, AssetConversionFailed, InvalidPdfCache, InvalidFontAwesomeIcon };
const command_failure_output_limit: usize = 1600;
var temp_cache_counter: usize = 0;

pub const FailureSink = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!void,

    fn record(self: FailureSink, message: []const u8) !void {
        try self.write(self.context, message);
    }
};

pub const Context = struct {
    allocator: Allocator,
    io: std.Io,
    asset_base_dir: []const u8,
    cache_dir: []const u8,
    resource_cache: ?*render_resources.SourceCache = null,
    file_inputs: ?*utils.FileInputs = null,
    failure: ?FailureSink = null,
};

pub const Size = struct { width: f32, height: f32 };

// Production results own their paths; geometry queries return only dimensions.
pub const SvgAsset = struct {
    path: []const u8,
    width: f32,
    height: f32,
};

pub const LatexAsset = struct {
    path: []const u8,
    page_index: usize,
    width: f32,
    height: f32,
    baseline_from_bottom: f32,
    reference_height: f32,
};

const LatexAssetGeometry = struct { baseline_from_bottom: f32, reference_height: f32 };

pub const BatchEntry = struct {
    source: []const u8,
    kind: LatexFragmentKind,
    out: []const u8,
};

pub fn renderLatexBatch(ctx: Context, entries: []const BatchEntry, preamble: []const LatexPreambleEntry, engine: LatexEngine) !void {
    if (entries.len == 0) return;
    const document_entries = try latexDocumentEntries(ctx.allocator, entries);
    defer ctx.allocator.free(document_entries);
    const tex = try latexDocumentSource(ctx, preamble, document_entries);
    defer ctx.allocator.free(tex);
    var generated = try compileLatexDocument(ctx, entries[0].out, engine, tex);
    defer generated.deinit();
    try publishLatexBatch(ctx, entries, generated.pdf_path, generated.metrics_path, generated.inputs);
}

fn latexDocumentEntries(allocator: Allocator, entries: []const BatchEntry) ![]latex_document.Entry {
    const document_entries = try allocator.alloc(latex_document.Entry, entries.len);
    for (entries, document_entries) |entry, *document_entry| document_entry.* = .{ .source = entry.source, .kind = entry.kind };
    return document_entries;
}

pub fn rasterAssetSize(ctx: Context, source: []const u8) !Size {
    var resource = render_resources.readResource(ctx.allocator, ctx.io, .raster, source, ctx.resource_cache) catch |err| switch (err) {
        error.InvalidRasterResource => return error.ImageDecodeFailed,
        else => return err,
    };
    defer resource.deinit(ctx.allocator);
    const metadata = resource.metadata.raster;
    return .{ .width = @floatFromInt(metadata.oriented_width), .height = @floatFromInt(metadata.oriented_height) };
}

pub fn pdfAssetSize(ctx: Context, source: []const u8, asset: ?core.render_policy.AssetPaint, kind: render_ir.ResourceKind) !Size {
    var resource = render_resources.readResource(ctx.allocator, ctx.io, kind, source, ctx.resource_cache) catch |err| {
        if (err == error.InvalidPdfResource) {
            try recordQpdfFailure(ctx, "read PDF page geometry");
            return error.ImageDecodeFailed;
        }
        return err;
    };
    defer resource.deinit(ctx.allocator);
    const metadata = switch (resource.metadata) {
        .pdf => |value| value,
        .latex_pdf => |value| value,
        else => return error.RenderResourceKindConflict,
    };
    const page_number = if (asset) |paint| paint.pdf_page else 1;
    if (page_number == 0 or page_number > metadata.pages.len) return error.InvalidPdfResource;
    const page = &metadata.pages[page_number - 1];
    const page_box = if (asset) |paint| paint.pdf_box else .crop;
    const box = page.box(page_box);
    var width = box.width() * page.user_unit;
    var height = box.height() * page.user_unit;
    if (page.rotation == 90 or page.rotation == 270) std.mem.swap(f64, &width, &height);
    return .{ .width = @floatCast(width), .height = @floatCast(height) };
}

pub fn svgAsset(ctx: Context, path: []const u8) !Size {
    var resource = render_resources.readResource(ctx.allocator, ctx.io, .svg, path, ctx.resource_cache) catch |err| switch (err) {
        error.InvalidSvgResource => return error.ImageDecodeFailed,
        else => return err,
    };
    defer resource.deinit(ctx.allocator);
    const metadata = resource.metadata.svg;
    return .{ .width = @floatCast(metadata.width), .height = @floatCast(metadata.height) };
}

const GeneratedLatexDocument = struct {
    allocator: Allocator,
    io: std.Io,
    dir: []u8,
    pdf_path: []u8,
    metrics_path: []u8,
    inputs: []latex_inputs.Input,

    fn deinit(self: *GeneratedLatexDocument) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.dir) catch {};
        latex_inputs.free(self.allocator, self.inputs);
        self.allocator.free(self.metrics_path);
        self.allocator.free(self.pdf_path);
        self.allocator.free(self.dir);
        self.* = undefined;
    }
};

fn publishLatexBatch(
    ctx: Context,
    entries: []const BatchEntry,
    generated_pdf_path: []const u8,
    metrics_path: []const u8,
    inputs: []const latex_inputs.Input,
) !void {
    if (entries.len == 0) return;
    const batch_path = try latexBatchPdfPath(ctx, entries, inputs);
    defer ctx.allocator.free(batch_path);
    try publishGeneratedPdf(ctx, generated_pdf_path, batch_path);

    const batch_path_z = try ctx.allocator.dupeZ(u8, batch_path);
    defer ctx.allocator.free(batch_path_z);
    const widths = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(widths);
    const heights = try ctx.allocator.alloc(f64, entries.len);
    defer ctx.allocator.free(heights);
    const document_entries = try latexDocumentEntries(ctx.allocator, entries);
    defer ctx.allocator.free(document_entries);
    const metrics = try readLatexMetrics(ctx, metrics_path, document_entries);
    defer ctx.allocator.free(metrics);
    if (c.ss_qpdf_page_sizes(batch_path_z.ptr, @intFromEnum(core.render_policy.PdfPageBox.crop), widths.ptr, heights.ptr, entries.len) != 0) {
        try recordQpdfFailure(ctx, "read LaTeX PDF page geometry");
        return NativePdfError.AssetConversionFailed;
    }

    for (entries, 0..) |entry, index| {
        const baseline_from_bottom = if (metrics[index]) |metric| heights[index] * metric.baseline_ratio else 0;
        const reference_height = if (metrics[index]) |metric| heights[index] * metric.reference_height_ratio else heights[index];
        try writeLatexReference(
            ctx,
            entry.out,
            batch_path,
            index,
            widths[index],
            heights[index],
            baseline_from_bottom,
            reference_height,
            inputs,
        );
    }
}

fn latexBatchPdfPath(ctx: Context, entries: []const BatchEntry, inputs: []const latex_inputs.Input) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, "latex-batch-pdf");
    for (entries) |entry| hashString(&hasher, entry.out);
    const dependencies = latex_inputs.digest(inputs);
    hasher.update(std.mem.asBytes(&dependencies));
    return std.fmt.allocPrint(ctx.allocator, "{s}/latex-batch-{x}.pdf", .{ ctx.cache_dir, hasher.final() });
}

fn publishGeneratedPdf(ctx: Context, generated_path: []const u8, output: []const u8) !void {
    if (try cachedPdfAvailable(ctx, output)) return;
    const tmp = try tempCachePath(ctx, output, "pdf");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(generated_path, cwd, tmp, ctx.io);
    try validatePdfFile(ctx, tmp);
    try publishCacheFile(ctx, tmp, output);
}

fn writeLatexReference(
    ctx: Context,
    output: []const u8,
    pdf_path: []const u8,
    page_index: usize,
    width: f64,
    height: f64,
    baseline_from_bottom: f64,
    reference_height: f64,
    inputs: []const latex_inputs.Input,
) !void {
    const dependencies = try std.json.Stringify.valueAlloc(ctx.allocator, latex_inputs.Manifest{ .inputs = inputs }, .{});
    defer ctx.allocator.free(dependencies);
    const contents = try std.fmt.allocPrint(ctx.allocator, "{d}\t{d}\t{d}\t{d}\t{d}\t{s}\n{s}\n", .{
        page_index,
        width,
        height,
        baseline_from_bottom,
        reference_height,
        std.fs.path.basename(pdf_path),
        dependencies,
    });
    defer ctx.allocator.free(contents);
    try utils.fs.writeFile(ctx.io, output, contents);
}

fn compileLatexDocument(
    ctx: Context,
    output_anchor: []const u8,
    engine: LatexEngine,
    source: []const u8,
) !GeneratedLatexDocument {
    const temporary = try tempCachePath(ctx, output_anchor, "latex-dir");
    defer ctx.allocator.free(temporary);
    const dir = try utils.fs.absolutePath(ctx.io, ctx.allocator, temporary);
    errdefer ctx.allocator.free(dir);
    errdefer std.Io.Dir.cwd().deleteTree(ctx.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(ctx.io, dir);

    const tex_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.tex" });
    defer ctx.allocator.free(tex_path);
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.pdf" });
    errdefer ctx.allocator.free(pdf_path);
    const metrics_path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.ssm" });
    errdefer ctx.allocator.free(metrics_path);

    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tex_path, .data = source, .flags = .{ .truncate = true } });
    const working_directory = try utils.fs.absolutePath(ctx.io, ctx.allocator, ctx.asset_base_dir);
    defer ctx.allocator.free(working_directory);
    const output_option = try std.fmt.allocPrint(ctx.allocator, "-output-directory={s}", .{dir});
    defer ctx.allocator.free(output_option);
    const started = std.Io.Timestamp.now(ctx.io, .real).nanoseconds;
    runChecked(ctx, &.{ engine.executable(), "-interaction=nonstopmode", "-halt-on-error", "-recorder", output_option, tex_path }, .{ .path = working_directory }) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        // A failed run may not have opened the missing input yet. Retain the
        // partial recorder and a recovery observation until compilation succeeds.
        if (ctx.file_inputs) |observed| {
            const partial = readRecordedLatexInputs(ctx, dir, working_directory) catch |record_err| switch (record_err) {
                error.Canceled, error.OutOfMemory => return record_err,
                else => null,
            };
            if (partial) |inputs| latex_inputs.free(ctx.allocator, inputs);
            try recordPreviousLatexInputs(ctx, output_anchor);
            try recordMissingLatexInputs(ctx, dir, working_directory);
            try observed.record(".", ctx.asset_base_dir, .directory);
        }
        return err;
    };
    const inputs = try readRecordedLatexInputs(ctx, dir, working_directory);
    errdefer latex_inputs.free(ctx.allocator, inputs);
    for (inputs) |input| {
        const stat = try utils.fs.statFile(ctx.io, input.path);
        if (stat.mtime.nanoseconds >= started or stat.ctime.nanoseconds >= started) {
            if (ctx.file_inputs) |observed| observed.observations_complete = false;
            return error.ResourceChangedDuringRead;
        }
    }
    return .{ .allocator = ctx.allocator, .io = ctx.io, .dir = dir, .pdf_path = pdf_path, .metrics_path = metrics_path, .inputs = inputs };
}

fn recordMissingLatexInputs(ctx: Context, directory: []const u8, working_directory: []const u8) !void {
    const observed = ctx.file_inputs orelse return;
    const path = try std.fs.path.join(ctx.allocator, &.{ directory, "main.log" });
    defer ctx.allocator.free(path);
    const contents = utils.fs.readFileAllocLimited(ctx.io, ctx.allocator, path, .limited(latex_inputs.read_limit)) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return,
    };
    defer ctx.allocator.free(contents);
    try latex_inputs.recordMissingInputs(observed, contents, working_directory);
}

fn recordPreviousLatexInputs(ctx: Context, reference_path: []const u8) !void {
    const observed = ctx.file_inputs orelse return;
    const contents = utils.fs.readFileAllocLimited(ctx.io, ctx.allocator, reference_path, .limited(utils.render_cache.LatexReference.read_limit)) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return,
    };
    defer ctx.allocator.free(contents);
    const reference = utils.render_cache.LatexReference.parse(contents) catch return;
    var manifest = latex_inputs.parse(ctx.allocator, reference.dependencies) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer manifest.deinit();
    for (manifest.value.inputs) |input| try observed.record(".", input.path, .file);
}

fn latexInputContext(ctx: Context) latex_inputs.Context {
    return .{ .allocator = ctx.allocator, .io = ctx.io, .cache = ctx.resource_cache, .observed = ctx.file_inputs };
}

fn readRecordedLatexInputs(ctx: Context, dir: []const u8, working_directory: []const u8) ![]latex_inputs.Input {
    const path = try std.fs.path.join(ctx.allocator, &.{ dir, "main.fls" });
    defer ctx.allocator.free(path);
    const contents = try utils.fs.readFileAllocLimited(ctx.io, ctx.allocator, path, .limited(latex_inputs.read_limit));
    defer ctx.allocator.free(contents);
    const paths = try latex_inputs.recorderPaths(ctx.allocator, contents, working_directory, dir);
    defer {
        for (paths) |input| ctx.allocator.free(input);
        ctx.allocator.free(paths);
    }
    if (paths.len == 0) return error.InvalidLatexRecorder;
    return latex_inputs.capture(latexInputContext(ctx), paths);
}

fn recordQpdfFailure(ctx: Context, operation: []const u8) !void {
    const detail_pointer = c.ss_qpdf_last_error();
    const detail = if (detail_pointer == null) "unknown libqpdf error" else std.mem.span(detail_pointer);
    if (ctx.failure) |target| {
        const message = try std.fmt.allocPrint(ctx.allocator, "failed to {s}: {s}", .{ operation, detail });
        defer ctx.allocator.free(message);
        try target.record(message);
    }
}

pub fn cachedLatexReference(ctx: Context, reference_path: []const u8) !?LatexAsset {
    if (!fileExists(reference_path)) return null;
    return readLatexReference(ctx, reference_path) catch |err| switch (err) {
        // Retain a stale manifest until replacement so failed TeX runs can
        // continue watching previously resolved inputs, including missing files.
        error.InvalidPdfCache => return null,
        else => return err,
    };
}

fn readLatexReference(ctx: Context, reference_path: []const u8) !LatexAsset {
    const contents = utils.fs.readFileAllocLimited(ctx.io, ctx.allocator, reference_path, .limited(utils.render_cache.LatexReference.read_limit)) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return NativePdfError.InvalidPdfCache,
    };
    defer ctx.allocator.free(contents);
    const reference = try utils.render_cache.LatexReference.parse(contents);
    var manifest = try latex_inputs.parse(ctx.allocator, reference.dependencies);
    defer manifest.deinit();
    var inputs_ctx = latexInputContext(ctx);
    inputs_ctx.observed = null;
    if (!try latex_inputs.matches(inputs_ctx, manifest.value.inputs)) return NativePdfError.InvalidPdfCache;
    if (ctx.file_inputs) |observed| {
        for (manifest.value.inputs) |input| try observed.record(".", input.path, .file);
        if (!try latex_inputs.matches(inputs_ctx, manifest.value.inputs)) return NativePdfError.InvalidPdfCache;
    }
    const directory = std.fs.path.dirname(reference_path) orelse ".";
    const pdf_path = try std.fs.path.join(ctx.allocator, &.{ directory, reference.pdf_name });
    errdefer ctx.allocator.free(pdf_path);
    if (!try cachedPdfAvailable(ctx, pdf_path)) return NativePdfError.InvalidPdfCache;
    return .{
        .path = pdf_path,
        .page_index = reference.page_index,
        .width = reference.width,
        .height = reference.height,
        .baseline_from_bottom = reference.baseline_from_bottom,
        .reference_height = reference.reference_height,
    };
}

pub fn resolveAssetPath(ctx: Context, rel_path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(rel_path)) return ctx.allocator.dupe(u8, rel_path);
    return std.fs.path.join(ctx.allocator, &.{ ctx.asset_base_dir, rel_path });
}

pub fn renderLatexToPdf(
    ctx: Context,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
) !LatexAsset {
    const reference_path = try cachedLatexPath(ctx, source, preamble, engine, kind, "ref");
    defer ctx.allocator.free(reference_path);
    if (try cachedLatexReference(ctx, reference_path)) |asset| return asset;
    const document_entries = [_]latex_document.Entry{.{ .source = source, .kind = kind }};
    const tex = try latexDocumentSource(ctx, preamble, &document_entries);
    defer ctx.allocator.free(tex);
    var generated = try compileLatexDocument(ctx, reference_path, engine, tex);
    defer generated.deinit();
    const output_pdf_path = try std.fmt.allocPrint(ctx.allocator, "{s}-{x}.pdf", .{ reference_path[0 .. reference_path.len - 4], latex_inputs.digest(generated.inputs) });
    defer ctx.allocator.free(output_pdf_path);
    try publishGeneratedPdf(ctx, generated.pdf_path, output_pdf_path);
    const size = try pdfAssetSize(ctx, output_pdf_path, null, .latex_pdf);
    const geometry: LatexAssetGeometry = if (kind == .body)
        .{ .baseline_from_bottom = @as(f32, 0), .reference_height = size.height }
    else blk: {
        const metrics = try readLatexMetrics(ctx, generated.metrics_path, &document_entries);
        defer ctx.allocator.free(metrics);
        const metric = metrics[0] orelse return NativePdfError.AssetConversionFailed;
        break :blk .{
            .baseline_from_bottom = size.height * @as(f32, @floatCast(metric.baseline_ratio)),
            .reference_height = size.height * @as(f32, @floatCast(metric.reference_height_ratio)),
        };
    };
    try writeLatexReference(
        ctx,
        reference_path,
        output_pdf_path,
        0,
        size.width,
        size.height,
        geometry.baseline_from_bottom,
        geometry.reference_height,
        generated.inputs,
    );
    return (try cachedLatexReference(ctx, reference_path)) orelse NativePdfError.InvalidPdfCache;
}

pub fn renderIconToSvg(ctx: Context, source: []const u8) !SvgAsset {
    const out = try cachedIconPath(ctx, source, "svg");
    errdefer ctx.allocator.free(out);
    if (try cachedSvgAsset(ctx, out)) |size| return .{ .path = out, .width = size.width, .height = size.height };
    const spec = core.fontawesome.parseSource(source) orelse return NativePdfError.InvalidFontAwesomeIcon;
    const icon_svg = core.fontawesome.extractSvg(ctx.allocator, spec) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return NativePdfError.InvalidFontAwesomeIcon,
    };
    defer ctx.allocator.free(icon_svg);
    const tmp = try tempCachePath(ctx, out, "svg");
    defer ctx.allocator.free(tmp);
    errdefer deleteFileIfExists(ctx, tmp);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = icon_svg, .flags = .{ .truncate = true } });
    _ = try svgAsset(ctx, tmp);
    try publishCacheFile(ctx, tmp, out);
    const size = try svgAsset(ctx, out);
    return .{ .path = out, .width = size.width, .height = size.height };
}

fn readLatexMetrics(
    ctx: Context,
    path: []const u8,
    entries: []const latex_document.Entry,
) ![]?latex_document.Metrics {
    const contents = utils.fs.readFileAllocLimited(
        ctx.io,
        ctx.allocator,
        path,
        .limited(latex_document.metrics_read_limit),
    ) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        else => return NativePdfError.AssetConversionFailed,
    };
    defer ctx.allocator.free(contents);
    return latex_document.parseMetrics(ctx.allocator, contents, entries) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return NativePdfError.AssetConversionFailed,
    };
}

fn latexDocumentSource(
    ctx: Context,
    preamble: []const LatexPreambleEntry,
    entries: []const latex_document.Entry,
) ![]u8 {
    const preamble_lines = try latexPreambleLines(ctx, preamble);
    defer ctx.allocator.free(preamble_lines);
    return latex_document.documentSource(ctx.allocator, preamble_lines, entries);
}

fn latexPreambleLines(ctx: Context, preamble: []const LatexPreambleEntry) ![]const u8 {
    const allocator = ctx.allocator;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (preamble) |entry| {
        const text = switch (entry.source) {
            .text => entry.value,
            .file => try readLatexPreambleFile(ctx, entry.value),
        };
        defer if (entry.source == .file) allocator.free(text);
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
        if (text[text.len - 1] != '\n') try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn readLatexPreambleFile(ctx: Context, path: []const u8) ![]const u8 {
    const resolved = try resolveAssetPath(ctx, path);
    defer ctx.allocator.free(resolved);
    return utils.fs.readFileAllocLimited(
        ctx.io,
        ctx.allocator,
        resolved,
        .limited(latex_document.preamble_read_limit),
    ) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        if (ctx.failure) |target| {
            var reason_buf: [256]u8 = undefined;
            const message = try std.fmt.allocPrint(
                ctx.allocator,
                "LaTeX preamble '{s}' could not be read (resolved to '{s}'): {s}",
                .{ path, resolved, utils.err.formatErrorReason(&reason_buf, err) },
            );
            defer ctx.allocator.free(message);
            try target.record(message);
        }
        return err;
    };
}

pub fn cachedLatexPath(
    ctx: Context,
    source: []const u8,
    preamble: []const LatexPreambleEntry,
    engine: LatexEngine,
    kind: LatexFragmentKind,
    extension: []const u8,
) ![]u8 {
    std.debug.assert(std.mem.eql(u8, extension, "ref"));
    return fingerprint.latexReferencePath(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .asset_base_dir = ctx.asset_base_dir,
        .cache_dir = ctx.cache_dir,
        .resource_cache = ctx.resource_cache,
    }, source, preamble, engine, @tagName(kind)) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        recordLatexPreambleFingerprintFailure(ctx, preamble);
        return err;
    };
}

pub fn recordLatexPreambleFingerprintFailure(ctx: Context, preamble: []const LatexPreambleEntry) void {
    if (ctx.failure == null) return;
    for (preamble) |entry| {
        if (entry.source != .file) continue;
        const text = readLatexPreambleFile(ctx, entry.value) catch return;
        ctx.allocator.free(text);
    }
}

pub fn cachedIconPath(ctx: Context, source: []const u8, extension: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    hashString(&hasher, native_artifact_cache_version);
    hashString(&hasher, core.fontawesome.cache_namespace);
    hashString(&hasher, source);
    return std.fmt.allocPrint(ctx.allocator, "{s}/fontawesome-{x}.{s}", .{ ctx.cache_dir, hasher.final(), extension });
}

fn tempCachePath(ctx: Context, final_path: []const u8, extension: []const u8) ![]u8 {
    const serial = @atomicRmw(usize, &temp_cache_counter, .Add, 1, .monotonic);
    return std.fmt.allocPrint(
        ctx.allocator,
        "{s}.tmp-{d}-{d}.{s}",
        .{ final_path, std.c.getpid(), serial, extension },
    );
}

fn publishCacheFile(ctx: Context, tmp_path: []const u8, final_path: []const u8) !void {
    if (fileExists(final_path)) {
        deleteFileIfExists(ctx, tmp_path);
        return;
    }
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, final_path, ctx.io) catch |err| {
        if (fileExists(final_path)) {
            deleteFileIfExists(ctx, tmp_path);
            return;
        }
        return err;
    };
}

fn deleteFileIfExists(ctx: Context, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
}

pub fn cachedPdfAvailable(ctx: Context, path: []const u8) !bool {
    if (!fileExists(path)) return false;
    validatePdfFile(ctx, path) catch |err| switch (err) {
        error.InvalidPdfCache => {
            deleteFileIfExists(ctx, path);
            return false;
        },
        else => return err,
    };
    return true;
}

fn validatePdfFile(ctx: Context, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| switch (err) {
        error.Canceled => return err,
        else => return NativePdfError.InvalidPdfCache,
    };
    defer file.close(ctx.io);

    const stat = file.stat(ctx.io) catch |err| switch (err) {
        error.Canceled => return err,
        else => return NativePdfError.InvalidPdfCache,
    };
    if (stat.kind != .file or stat.size < 8) return NativePdfError.InvalidPdfCache;

    var header: [5]u8 = undefined;
    var header_vec = [_][]u8{header[0..]};
    const header_len = file.readPositional(ctx.io, header_vec[0..], 0) catch |err| switch (err) {
        error.Canceled => return err,
        else => return NativePdfError.InvalidPdfCache,
    };
    if (header_len != header.len or !std.mem.eql(u8, header[0..], "%PDF-")) return NativePdfError.InvalidPdfCache;

    const tail_len_u64 = @min(stat.size, 4096);
    const tail_len: usize = @intCast(tail_len_u64);
    const tail = try ctx.allocator.alloc(u8, tail_len);
    defer ctx.allocator.free(tail);
    var tail_vec = [_][]u8{tail};
    const tail_offset = stat.size - tail_len_u64;
    const read_len = file.readPositional(ctx.io, tail_vec[0..], tail_offset) catch |err| switch (err) {
        error.Canceled => return err,
        else => return NativePdfError.InvalidPdfCache,
    };
    if (read_len == 0) return NativePdfError.InvalidPdfCache;
    if (std.mem.indexOf(u8, tail[0..read_len], "%%EOF") == null) return NativePdfError.InvalidPdfCache;
}

pub fn cachedSvgAsset(ctx: Context, path: []const u8) !?Size {
    if (!fileExists(path)) return null;
    return svgAsset(ctx, path) catch |err| switch (err) {
        error.ImageDecodeFailed => {
            deleteFileIfExists(ctx, path);
            return null;
        },
        else => return err,
    };
}

fn runChecked(ctx: Context, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const profile_command = utils.measure_profile.start();
    const result = external_process.run(ctx.allocator, ctx.io, argv, cwd) catch |err| {
        if (err == error.Canceled or err == error.OutOfMemory) return err;
        if (argv.len > 0) utils.measure_profile.recordCommand(argv[0], true, profile_command);
        const message = try commandSpawnFailureMessage(ctx.allocator, argv, err);
        defer ctx.allocator.free(message);
        if (ctx.failure) |target| try target.record(message);
        return NativePdfError.AssetConversionFailed;
    };
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (argv.len > 0) utils.measure_profile.recordCommand(argv[0], failed, profile_command);
    if (!failed) return;
    const message = try commandTermFailureMessage(ctx.allocator, argv, result.term, result.stdout, result.stderr);
    defer ctx.allocator.free(message);
    if (ctx.failure) |target| try target.record(message);
    return NativePdfError.AssetConversionFailed;
}

fn commandSpawnFailureMessage(allocator: Allocator, argv: []const []const u8, err: anyerror) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (err == error.FileNotFound and argv.len != 0) {
        try out.appendSlice(allocator, "executable '");
        try out.appendSlice(allocator, argv[0]);
        try out.appendSlice(allocator, "' was not found in PATH; install it or select an available latex_engine; command:");
    } else if (err == error.InvalidExe and argv.len != 0) {
        try out.appendSlice(allocator, "executable '");
        try out.appendSlice(allocator, argv[0]);
        try out.appendSlice(allocator, "' is not runnable on this platform; install a compatible executable or select another latex_engine; command:");
    } else if (err == error.Timeout) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command exceeded the {d}-second limit; fix LaTeX source or configured preamble content that stalls the engine; command:",
            .{external_process.timeout_seconds},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else if (err == error.CommandStdoutTooLong) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command wrote more than {d} KiB to stdout; fix repeated diagnostics in the LaTeX source or configured preamble; command:",
            .{external_process.stdout_limit / 1024},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else if (err == error.CommandStderrTooLong) {
        const prefix = try std.fmt.allocPrint(
            allocator,
            "command wrote more than {d} KiB to stderr; fix repeated diagnostics in the LaTeX source or configured preamble; command:",
            .{external_process.stderr_limit / 1024},
        );
        defer allocator.free(prefix);
        try out.appendSlice(allocator, prefix);
    } else {
        var reason_buf: [256]u8 = undefined;
        try out.appendSlice(allocator, "failed to run command: ");
        try out.appendSlice(allocator, utils.err.formatErrorReason(&reason_buf, err));
        try out.appendSlice(allocator, "; command:");
    }
    try appendCommandLine(allocator, &out, argv);
    return try out.toOwnedSlice(allocator);
}

fn commandTermFailureMessage(
    allocator: Allocator,
    argv: []const []const u8,
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "command failed (");
    try appendCommandTerm(allocator, &out, term);
    try out.appendSlice(allocator, "):");
    try appendCommandLine(allocator, &out, argv);
    try appendCommandOutput(allocator, &out, "stdout", stdout);
    try appendCommandOutput(allocator, &out, "stderr", stderr);
    return try out.toOwnedSlice(allocator);
}

fn appendCommandLine(allocator: Allocator, out: *std.ArrayList(u8), argv: []const []const u8) !void {
    for (argv) |arg| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
}

fn appendCommandTerm(allocator: Allocator, out: *std.ArrayList(u8), term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| {
            const text = try std.fmt.allocPrint(allocator, "exit {d}", .{code});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .signal => |signal| {
            const text = try std.fmt.allocPrint(allocator, "signal {d}", .{@intFromEnum(signal)});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .stopped => |signal| {
            const text = try std.fmt.allocPrint(allocator, "stopped {d}", .{@intFromEnum(signal)});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .unknown => |code| {
            const text = try std.fmt.allocPrint(allocator, "unknown {d}", .{code});
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
    }
}

fn appendCommandOutput(allocator: Allocator, out: *std.ArrayList(u8), label: []const u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return;
    const summary = try commandOutputSummary(allocator, trimmed);
    defer allocator.free(summary);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\n");
    try out.appendSlice(allocator, summary);
}

fn commandOutputSummary(allocator: Allocator, output: []const u8) ![]u8 {
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(allocator);

    var include_following: usize = 0;
    var lines = utils.source.lineIterator(output);
    while (lines.next()) |line_view| {
        const line = line_view.text(output);
        const trimmed_line = std.mem.trim(u8, line, " \t\r\n");
        const interesting = commandOutputLineLooksRelevant(trimmed_line);
        if (interesting) include_following = 2;
        if (interesting or include_following > 0) {
            try appendLimitedOutputLine(allocator, &summary, line);
            if (!interesting and include_following > 0) include_following -= 1;
            if (summary.items.len >= command_failure_output_limit) break;
        }
    }

    if (summary.items.len > 0) return try summary.toOwnedSlice(allocator);
    return try commandOutputTail(allocator, output);
}

fn commandOutputLineLooksRelevant(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '!') return true;
    return containsAsciiIgnoreCase(line, "error") or
        containsAsciiIgnoreCase(line, "failed") or
        containsAsciiIgnoreCase(line, "fatal");
}

fn appendLimitedOutputLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    if (out.items.len != 0) try out.append(allocator, '\n');
    const remaining = command_failure_output_limit - @min(out.items.len, command_failure_output_limit);
    if (remaining == 0) return;
    const end = @min(line.len, remaining);
    try out.appendSlice(allocator, line[0..end]);
}

fn commandOutputTail(allocator: Allocator, output: []const u8) ![]u8 {
    if (output.len <= command_failure_output_limit) return allocator.dupe(u8, output);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "... output truncated ...\n");
    const start = output.len - command_failure_output_limit;
    try out.appendSlice(allocator, output[start..]);
    return try out.toOwnedSlice(allocator);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

pub fn fileExists(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(@ptrCast(&buf), 0) == 0;
}
