const std = @import("std");

pub const Severity = enum {
    note,
    warning,
    @"error",
};

pub const ByteSpan = struct {
    start: usize,
    end: usize,
};

pub const Location = struct {
    line: usize,
    column: usize,
};

const Line = struct {
    number: usize,
    start: usize,
    end: usize,
};

pub const SourceReport = struct {
    path: []const u8 = "",
    source: []const u8,
    severity: Severity,
    message: []const u8,
    span: ?ByteSpan = null,
    context_lines: usize = 2,
};

pub fn parseByteOrigin(origin: []const u8) ?ByteSpan {
    if (!std.mem.startsWith(u8, origin, "bytes:")) return null;
    const payload = origin["bytes:".len..];
    const dash = std.mem.indexOfScalar(u8, payload, '-') orelse return null;
    const start = std.fmt.parseInt(usize, payload[0..dash], 10) catch return null;
    const end = std.fmt.parseInt(usize, payload[dash + 1 ..], 10) catch return null;
    return .{ .start = start, .end = end };
}

pub fn computeLineColumn(source: []const u8, byte_index: usize) Location {
    var line: usize = 1;
    var line_start: usize = 0;
    const limit = @min(byte_index, source.len);
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        if (source[index] == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    const prefix = source[line_start..limit];
    const column = (std.unicode.utf8CountCodepoints(prefix) catch prefix.len) + 1;
    return .{ .line = line, .column = column };
}

pub fn spanFromOrigin(origin: ?[]const u8) ?ByteSpan {
    const text = origin orelse return null;
    return parseByteOrigin(text);
}

pub fn print(report: SourceReport) void {
    printSeverityPrefix(report.severity);
    const span = report.span;
    if (span) |s| {
        const loc = computeLineColumn(report.source, s.start);
        printColor(report.severity);
        if (report.path.len != 0) {
            std.debug.print("{s}:{d}:{d}: {s}", .{ report.path, loc.line, loc.column, report.message });
        } else {
            std.debug.print("{s} at {d}:{d}", .{ report.message, loc.line, loc.column });
        }
        printReset();
        std.debug.print("\n", .{});
        printExcerpt(report.source, s, report.severity, report.message, report.context_lines);
    } else if (report.path.len != 0) {
        printColor(report.severity);
        std.debug.print("{s}: {s}", .{ report.path, report.message });
        printReset();
        std.debug.print("\n", .{});
    } else {
        printColor(report.severity);
        std.debug.print("{s}", .{report.message});
        printReset();
        std.debug.print("\n", .{});
    }
}

pub fn printNote(message: []const u8) void {
    std.debug.print("  note: {s}\n", .{message});
}

pub fn printLabeledOrigin(source: []const u8, label: []const u8, origin: ?[]const u8) void {
    const span = spanFromOrigin(origin) orelse return;
    const loc = computeLineColumn(source, span.start);
    printDim();
    std.debug.print("  {s} from {d}:{d}", .{ label, loc.line, loc.column });
    printReset();
    std.debug.print("\n", .{});
    printExcerpt(source, span, .note, label, 0);
}

pub fn printParseError(path: []const u8, source: []const u8, err: anyerror, diagnostic: anytype) void {
    const parsed_diagnostic = diagnostic orelse {
        var message_buf: [128]u8 = undefined;
        print(.{
            .path = path,
            .source = source,
            .severity = .@"error",
            .message = std.fmt.bufPrint(&message_buf, "{s}: {s}", .{ @errorName(err), @errorName(err) }) catch @errorName(err),
            .span = null,
        });
        return;
    };
    var message_buf: [256]u8 = undefined;
    const message = formatParseDiagnostic(&message_buf, parsed_diagnostic);
    print(.{
        .path = path,
        .source = source,
        .severity = .@"error",
        .message = message,
        .span = .{ .start = parsed_diagnostic.span.start, .end = parsed_diagnostic.span.end },
    });
}

pub fn printIrDiagnostics(path: []const u8, source: []const u8, ir: anytype) void {
    for (ir.diagnostics.items) |diagnostic| {
        const message = formatIrDiagnostic(ir.allocator, diagnostic) catch @tagName(diagnostic.phase);
        defer if (!std.mem.eql(u8, message, @tagName(diagnostic.phase))) ir.allocator.free(message);
        const span = if (spanFromOrigin(diagnostic.origin)) |origin_span|
            origin_span
        else if (diagnostic.node_id) |node_id| blk: {
            const node = ir.getNode(node_id) orelse break :blk null;
            break :blk spanFromOrigin(node.origin);
        } else null;
        print(.{
            .path = path,
            .source = source,
            .severity = switch (diagnostic.severity) {
                .warning => .warning,
                .@"error" => .@"error",
            },
            .message = message,
            .span = span,
        });
    }
}

pub fn hasIrErrors(ir: anytype) bool {
    for (ir.diagnostics.items) |diagnostic| {
        if (diagnostic.severity == .@"error") return true;
    }
    return false;
}

pub fn printConstraintFailure(
    path: []const u8,
    source: []const u8,
    ir: anytype,
    err: anyerror,
    formatConstraint: anytype,
) void {
    const failure = ir.last_constraint_failure orelse {
        std.debug.print("constraint error: {s}\n", .{@errorName(err)});
        return;
    };
    const kind_text = switch (failure.kind) {
        .conflict => "ConstraintConflict: constraint conflict",
        .negative_size => "NegativeConstraintSize: negative size from constraints",
    };
    const constraint_text = formatConstraint(ir.allocator, failure.constraint) catch "";
    defer if (constraint_text.len > 0) ir.allocator.free(constraint_text);
    const existing_text = if (failure.existing_constraint) |constraint|
        formatConstraint(ir.allocator, constraint) catch ""
    else
        "";
    defer if (existing_text.len > 0) ir.allocator.free(existing_text);

    if (failure.constraint.origin) |origin| {
        if (parseByteOrigin(origin)) |span| {
            print(.{
                .path = path,
                .source = source,
                .severity = .@"error",
                .message = kind_text,
                .span = span,
            });
            if (failure.existing_constraint != null) {
                printLabeledOrigin(source, "other constraint", failure.existing_constraint.?.origin);
            }
            if (constraint_text.len > 0 and existing_text.len == 0) {
                std.debug.print("  constraint: {s}\n", .{constraint_text});
            }
            return;
        }
    }

    if (path.len != 0) {
        std.debug.print("{s}: error: {s}\n", .{ path, kind_text });
    } else {
        std.debug.print("{s}\n", .{kind_text});
    }
    if (failure.existing_constraint != null) {
        printLabeledOrigin(source, "other constraint", failure.existing_constraint.?.origin);
    }
    if (constraint_text.len > 0 and existing_text.len == 0) {
        std.debug.print("  constraint: {s}\n", .{constraint_text});
        printLabeledOrigin(source, "constraint", failure.constraint.origin);
    }
}

pub fn isExpectedCliError(err: anyerror) bool {
    return switch (err) {
        error.UnknownFunction,
        error.UnknownQuery,
        error.UnknownTransform,
        error.UnknownIdentifier,
        error.ExpectedString,
        error.ExpectedIdentifier,
        error.ExpectedKeyword,
        error.ExpectedChar,
        error.ExpectedLineBreak,
        error.ExpectedEnd,
        error.ExpectedNumber,
        error.ExpectedTypeAnnotation,
        error.AssignmentRequiresLet,
        error.ZeroArgCallRequiresParens,
        error.ExpectedReturn,
        error.UnterminatedString,
        error.UnterminatedEscape,
        error.InvalidEscape,
        error.UnknownAnchor,
        error.ReturnOutsideFunction,
        error.InvalidLibraryModule,
        error.UnknownProperty,
        error.FunctionDoesNotReturnValue,
        error.InvalidArity,
        error.InvalidSemanticSort,
        error.UnknownImport,
        error.RecursiveFunction,
        error.ExpectedSelection,
        error.ExpectedConstraintSet,
        error.ExpectedStringArgument,
        error.ExpectedNumberArgument,
        error.ExpectedStyleArgument,
        error.ExpectedAnchor,
        error.ExpectedObject,
        error.UnknownRole,
        error.UnknownPayloadKind,
        error.PageCannotBeConstraintTarget,
        error.MissingHighlightTarget,
        error.UnsupportedFragmentRoot,
        error.FunctionDidNotReturnValue,
        error.ConstraintConflict,
        error.NegativeConstraintSize,
        error.DiagnosticsFailed,
        => true,
        else => false,
    };
}

fn formatParseDiagnostic(buf: []u8, diagnostic: anytype) []const u8 {
    return switch (diagnostic.err) {
        error.UnterminatedString => "UnterminatedString: unterminated string",
        error.UnterminatedEscape => "UnterminatedEscape: unterminated escape sequence",
        error.InvalidEscape => "InvalidEscape: invalid escape sequence",
        error.UnknownAnchor => "UnknownAnchor: unknown anchor name",
        error.AssignmentRequiresLet => "AssignmentRequiresLet: plain assignment statements are not supported; use 'let name = expr'",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens: zero-argument calls require parentheses; use 'name()'",
        else => blk: {
            const expected = diagnostic.expected orelse @errorName(diagnostic.err);
            const found = diagnostic.found orelse "unknown token";
            break :blk std.fmt.bufPrint(buf, "{s}: expected {s}, found {s}", .{ parseDiagnosticCode(diagnostic.err), expected, found }) catch @errorName(diagnostic.err);
        },
    };
}

fn parseDiagnosticCode(err: anyerror) []const u8 {
    return switch (err) {
        error.ExpectedString => "ExpectedString",
        error.ExpectedIdentifier => "ExpectedIdentifier",
        error.ExpectedKeyword => "ExpectedKeyword",
        error.ExpectedChar => "ExpectedPunctuation",
        error.ExpectedLineBreak => "ExpectedLineBreak",
        error.ExpectedEnd => "ExpectedEnd",
        error.ExpectedNumber => "ExpectedNumber",
        error.ExpectedTypeAnnotation => "ExpectedTypeAnnotation",
        error.AssignmentRequiresLet => "AssignmentRequiresLet",
        error.ZeroArgCallRequiresParens => "ZeroArgCallRequiresParens",
        error.ExpectedReturn => "ExpectedReturn",
        error.InvalidSemanticSort => "InvalidSemanticSort",
        else => @errorName(err),
    };
}

fn formatIrDiagnostic(allocator: std.mem.Allocator, diagnostic: anytype) ![]const u8 {
    return switch (diagnostic.data) {
        .user_report => |data| allocator.dupe(u8, data.message),
        .asset_not_found => |data| std.fmt.allocPrint(
            allocator,
            "AssetNotFound: {s} (resolved to {s})",
            .{ data.requested_path, data.resolved_path },
        ),
        .asset_invalid => |data| std.fmt.allocPrint(allocator, "InvalidAsset: {s}", .{data.reason}),
        .type_mismatch => |data| std.fmt.allocPrint(
            allocator,
            "{s}: expected {s}, got {s}",
            .{ @tagName(data.code), @tagName(data.expected), @tagName(data.actual) },
        ),
        .recursive_function => |data| std.fmt.allocPrint(
            allocator,
            "RecursiveFunction: recursive function cycle involving {s}",
            .{data.function_name},
        ),
        .unresolved_frame => |data| std.fmt.allocPrint(
            allocator,
            "UnresolvedFrame: missing_horizontal={s} missing_vertical={s}",
            .{
                if (data.missing_horizontal) "true" else "false",
                if (data.missing_vertical) "true" else "false",
            },
        ),
        .page_overflow => |data| std.fmt.allocPrint(
            allocator,
            "PageOverflow: left={d:.1} right={d:.1} top={d:.1} bottom={d:.1}",
            .{ data.overflow_left, data.overflow_right, data.overflow_top, data.overflow_bottom },
        ),
    };
}

fn printExcerpt(source: []const u8, span: ByteSpan, severity: Severity, label: []const u8, context: usize) void {
    const target = lineAt(source, span.start);
    const first_line = if (target.number > context) target.number - context else 1;
    const last_line = @min(lineCount(source), target.number + context);
    const width = decimalWidth(last_line);

    var line = first_line;
    while (line <= last_line) : (line += 1) {
        const current = lineByNumber(source, line) orelse break;
        printDim();
        std.debug.print(" ", .{});
        printSpaces(width - decimalWidth(line));
        std.debug.print("{d} | ", .{line});
        printReset();
        printHighlightedSlice(source[current.start..current.end]);
        std.debug.print("\n", .{});
        if (line == target.number) {
            printDim();
            std.debug.print(" ", .{});
            printSpaces(width);
            std.debug.print(" | ", .{});
            printReset();
            printSpaces(displayWidthBetween(source, current.start, span.start));
            printColor(severity);
            printRule(caretWidthOnLine(source, span, current));
            if (label.len != 0) {
                std.debug.print(" {s}", .{label});
            }
            printReset();
            std.debug.print("\n", .{});
        }
    }
}

fn lineAt(source: []const u8, byte_index: usize) Line {
    const limit = @min(byte_index, source.len);
    var start: usize = limit;
    while (start > 0 and source[start - 1] != '\n') : (start -= 1) {}
    var end: usize = limit;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    return .{ .number = computeLineColumn(source, limit).line, .start = start, .end = end };
}

fn lineByNumber(source: []const u8, number: usize) ?Line {
    var current: usize = 1;
    var start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index == source.len or source[index] == '\n') {
            if (current == number) return .{ .number = current, .start = start, .end = index };
            current += 1;
            start = index + 1;
        }
    }
    return null;
}

fn lineCount(source: []const u8) usize {
    if (source.len == 0) return 1;
    var count: usize = 1;
    for (source) |ch| {
        if (ch == '\n') count += 1;
    }
    return count;
}

fn caretWidthOnLine(source: []const u8, span: ByteSpan, line: Line) usize {
    const start = @max(span.start, line.start);
    const end = @min(@max(span.end, span.start + 1), line.end);
    if (end <= start) return 1;
    return @max(1, displayWidthSlice(source[start..end]));
}

fn decimalWidth(value: usize) usize {
    var width: usize = 1;
    var n = value;
    while (n >= 10) : (n /= 10) width += 1;
    return width;
}

fn printSpaces(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print(" ", .{});
}

fn printRule(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) std.debug.print("▔", .{});
}

fn printHighlightedSlice(slice: []const u8) void {
    var index: usize = 0;
    while (index < slice.len) {
        if (slice[index] == '\t') {
            printSpaces(4);
            index += 1;
            continue;
        }

        if (commentStart(slice, index) != null) {
            printAnsi("90");
            printDisplayRaw(slice[index..]);
            printReset();
            return;
        }

        if (slice[index] == '"') {
            const end = stringEnd(slice, index);
            printAnsi("32");
            printDisplayRaw(slice[index..end]);
            printReset();
            index = end;
            continue;
        }

        if (std.ascii.isDigit(slice[index]) or (slice[index] == '-' and index + 1 < slice.len and std.ascii.isDigit(slice[index + 1]))) {
            const end = numberEnd(slice, index);
            printAnsi("35");
            std.debug.print("{s}", .{slice[index..end]});
            printReset();
            index = end;
            continue;
        }

        if (isAsciiIdentifierStart(slice[index])) {
            const end = asciiIdentifierEnd(slice, index);
            const token = slice[index..end];
            if (isKeyword(token)) {
                printAnsi("34;1");
                std.debug.print("{s}", .{token});
                printReset();
            } else {
                printAnsi("36");
                std.debug.print("{s}", .{token});
                printReset();
            }
            index = end;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(slice[index]) catch 1;
        printDisplayRaw(slice[index..@min(index + len, slice.len)]);
        index += len;
    }
}

fn printDisplayRaw(slice: []const u8) void {
    var view = std.unicode.Utf8View.init(slice) catch {
        std.debug.print("{s}", .{slice});
        return;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_slice| {
        if (cp_slice.len == 1 and cp_slice[0] == '\t') {
            printSpaces(4);
        } else {
            std.debug.print("{s}", .{cp_slice});
        }
    }
}

fn commentStart(slice: []const u8, index: usize) ?usize {
    if (slice[index] == '#') return 1;
    if (index + 1 >= slice.len) return null;
    if (slice[index] == ';' and slice[index + 1] == ';') return 2;
    if (slice[index] == '/' and slice[index + 1] == '/') return 2;
    return null;
}

fn stringEnd(slice: []const u8, start: usize) usize {
    var index = start + 1;
    var escaped = false;
    while (index < slice.len) : (index += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (slice[index] == '\\') {
            escaped = true;
            continue;
        }
        if (slice[index] == '"') return index + 1;
    }
    return slice.len;
}

fn numberEnd(slice: []const u8, start: usize) usize {
    var index = start;
    if (slice[index] == '-') index += 1;
    var saw_dot = false;
    while (index < slice.len) : (index += 1) {
        if (std.ascii.isDigit(slice[index])) continue;
        if (slice[index] == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        break;
    }
    return index;
}

fn isAsciiIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn asciiIdentifierEnd(slice: []const u8, start: usize) usize {
    var index = start + 1;
    while (index < slice.len and (std.ascii.isAlphanumeric(slice[index]) or slice[index] == '_')) : (index += 1) {}
    return index;
}

fn isKeyword(token: []const u8) bool {
    const keywords = [_][]const u8{ "import", "const", "page", "fn", "let", "bind", "return", "end", "constrain" };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, token, keyword)) return true;
    }
    return false;
}

fn printAnsi(code: []const u8) void {
    std.debug.print("\x1b[{s}m", .{code});
}

fn printDim() void {
    printAnsi("2;37");
}

fn printSeverityPrefix(severity: Severity) void {
    switch (severity) {
        .@"error" => std.debug.print("\x1b[1;31mERROR:\x1b[0m ", .{}),
        .warning => std.debug.print("\x1b[1;38;5;208mWARNING:\x1b[0m ", .{}),
        .note => {},
    }
}

fn displayWidthBetween(source: []const u8, start: usize, end: usize) usize {
    return displayWidthSlice(source[@min(start, source.len)..@min(end, source.len)]);
}

fn displayWidthSlice(slice: []const u8) usize {
    var view = std.unicode.Utf8View.init(slice) catch return slice.len;
    var it = view.iterator();
    var width: usize = 0;
    var after_zwj = false;
    var regional_indicator_count: usize = 0;

    while (it.nextCodepoint()) |cp| {
        if (cp == '\t') {
            width += 4;
            after_zwj = false;
            regional_indicator_count = 0;
            continue;
        }

        if (cp == 0x200D) {
            after_zwj = true;
            continue;
        }

        const cp_width = codepointDisplayWidth(cp, after_zwj, regional_indicator_count);
        width += cp_width;
        after_zwj = false;
        if (isRegionalIndicator(cp)) {
            regional_indicator_count += 1;
        } else {
            regional_indicator_count = 0;
        }
    }
    return width;
}

fn codepointDisplayWidth(cp: u21, after_zwj: bool, regional_indicator_count: usize) usize {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7F and cp < 0xA0)) return 0;
    if (isCombiningMark(cp) or isVariationSelector(cp) or isEmojiModifier(cp)) return 0;
    if (after_zwj and isEmojiWide(cp)) return 0;
    if (isRegionalIndicator(cp)) return if (regional_indicator_count % 2 == 0) 2 else 0;
    return if (isWideCodepoint(cp)) 2 else 1;
}

fn isCombiningMark(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F);
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xE0100 and cp <= 0xE01EF);
}

fn isEmojiModifier(cp: u21) bool {
    return cp >= 0x1F3FB and cp <= 0x1F3FF;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

fn isEmojiWide(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or
        (cp >= 0x2600 and cp <= 0x27BF);
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        cp == 0x2329 or cp == 0x232A or
        (cp >= 0x2E80 and cp <= 0xA4CF and cp != 0x303F) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        isEmojiWide(cp);
}

fn printColor(severity: Severity) void {
    switch (severity) {
        .@"error" => std.debug.print("\x1b[31m", .{}),
        .warning => std.debug.print("\x1b[33m", .{}),
        .note => std.debug.print("\x1b[36m", .{}),
    }
}

fn printReset() void {
    std.debug.print("\x1b[0m", .{});
}
