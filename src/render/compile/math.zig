const std = @import("std");
const core = @import("core");
const c = @import("pdf_ffi").c;
const math_assets = @import("math_assets");
const render = @import("render");
const resources_compile = @import("render_resources");
const text_compile = @import("render_text");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    font_size: f64,
    display: bool,
    text_cache: ?*text_compile.Cache = null,
};

pub const Compiled = struct {
    tree: render.MathTreeId,
    layout: render.MathLayout,
    reference_height: f64,
};

const LayoutResult = struct {
    layout: render.MathLayout,
    reference_height: f64,
};

pub fn compile(
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    math: *render.MathBuilder,
    source: []const u8,
    input_kind: render.MathInputKind,
    options: Options,
) !Compiled {
    const tree_id = try math.add(allocator, source, input_kind);
    const tree = math.find(tree_id) orelse return error.InvalidMathTree;
    const result = try layout(allocator, io, resources, fonts, tree, options);
    return .{
        .tree = tree_id,
        .layout = result.layout,
        .reference_height = result.reference_height,
    };
}

fn layout(
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    tree: *const render.MathTree,
    options: Options,
) !LayoutResult {
    if (options.font_size <= 0 or !std.math.isFinite(options.font_size)) return error.InvalidMathSize;
    try prepareFont(allocator, io);
    const math_font = core.font.Face{
        .family = "STIX Two Math",
        .weight = 400,
        .style = .normal,
        .stretch = .normal,
    };
    var probe = try text_compile.shape(
        allocator,
        io,
        resources,
        fonts,
        "x",
        math_font,
        options.font_size,
        std.math.floatMax(f64),
        false,
        options.text_cache,
    );
    defer probe.deinit(allocator);
    if (probe.runs.len == 0) return error.MissingMathFont;
    const font = fonts.get(io, probe.runs[0].font_instance) orelse return error.MissingMathFont;
    const constants = font.math orelse return error.MissingMathTable;
    const reference_height = shapedHeight(probe);
    if (!(reference_height > 0) or !std.math.isFinite(reference_height)) return error.InvalidMathSize;

    var builder = Builder{
        .allocator = allocator,
        .io = io,
        .resources = resources,
        .fonts = fonts,
        .tree = tree,
        .font = math_font,
        .constants = constants,
        .display = options.display,
        .text_cache = options.text_cache,
    };
    var root = try builder.node(tree.root, options.font_size, 0);
    errdefer root.deinit(allocator);
    const elements = try root.elements.toOwnedSlice(allocator);
    root.elements = .empty;
    return .{
        .layout = .{
            .width = @max(root.width, 0),
            .height = @max(root.ascent + root.descent, 0),
            .baseline = @max(root.ascent, 0),
            .elements = elements,
        },
        .reference_height = reference_height,
    };
}

const bundled_font_directory = ".ss-cache/render/fonts";
const bundled_font_path = bundled_font_directory ++ "/3a5f3f26f40d5698b3c62dd085d48d6663696a3f80825aab8b553d5097518e8c.otf";

pub fn prepareFont(allocator: Allocator, io: std.Io) !void {
    bundled_math_font_mutex.lockUncancelable(io);
    defer bundled_math_font_mutex.unlock(io);
    if (bundled_math_font_ready) return;
    try std.Io.Dir.cwd().createDirPath(io, bundled_font_directory);
    const current = std.Io.Dir.cwd().readFileAlloc(io, bundled_font_path, allocator, .unlimited) catch null;
    defer if (current) |bytes| allocator.free(bytes);
    if (current == null or !std.mem.eql(u8, current.?, math_assets.font)) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = bundled_font_path,
            .data = math_assets.font,
            .flags = .{ .truncate = true },
        });
    }
    const path_z = try allocator.dupeZ(u8, bundled_font_path);
    defer allocator.free(path_z);
    if (c.ss_font_register(path_z.ptr) != 0) return error.MathFontRegistrationFailed;
    bundled_math_font_ready = true;
}

var bundled_math_font_mutex: std.Io.Mutex = .init;
var bundled_math_font_ready = false;

pub fn scale(value: *render.MathLayout, factor: f64) !void {
    if (!std.math.isFinite(factor) or factor <= 0) return error.InvalidMathScale;
    value.width *= factor;
    value.height *= factor;
    value.baseline *= factor;
    for (value.elements) |*element| switch (element.*) {
        .text => |*text| {
            text.x *= factor;
            text.y *= factor;
            text.font_size *= factor;
            scaleTextLayout(&text.layout, factor);
        },
        .rule => |*rule| {
            rule.rect.x *= factor;
            rule.rect.y *= factor;
            rule.rect.width *= factor;
            rule.rect.height *= factor;
        },
    };
}

const Builder = struct {
    allocator: Allocator,
    io: std.Io,
    resources: *resources_compile.Builder,
    fonts: *render.FontBuilder,
    tree: *const render.MathTree,
    font: core.font.Face,
    constants: render.MathConstants,
    display: bool,
    text_cache: ?*text_compile.Cache,

    fn node(self: *Builder, id: render.MathNodeId, font_size: f64, script_level: u8) anyerror!Box {
        const value = self.tree.find(id) orelse return error.InvalidMathTree;
        return switch (value.kind) {
            .row => self.row(value, font_size, script_level),
            .identifier, .number, .operator, .text, .space => self.leaf(value, font_size),
            .fraction => self.fraction(value, font_size, script_level),
            .square_root => self.squareRoot(value, font_size, script_level),
            .superscript => self.scripts(value, font_size, script_level, false, true),
            .subscript => self.scripts(value, font_size, script_level, true, false),
            .subscript_superscript => self.scripts(value, font_size, script_level, true, true),
            .raw_tex => error.UnsupportedMathSyntax,
        };
    }

    fn leaf(self: *Builder, node_value: *const render.MathNode, font_size: f64) !Box {
        const source = node_value.text orelse "";
        const visual = if (node_value.kind == .identifier)
            try mathIdentifier(self.allocator, source)
        else
            try self.allocator.dupe(u8, source);
        defer self.allocator.free(visual);
        var shaped = try text_compile.shape(
            self.allocator,
            self.io,
            self.resources,
            self.fonts,
            visual,
            self.font,
            font_size,
            std.math.floatMax(f64),
            false,
            self.text_cache,
        );
        errdefer shaped.deinit(self.allocator);
        const baseline = shaped.firstBaseline();
        const height = shapedHeight(shaped);
        var width = shaped.logical_bounds.width;
        for (shaped.runs) |run| width = @max(width, run.x + run.advance);
        var elements = std.ArrayList(render.MathElement).empty;
        errdefer elements.deinit(self.allocator);
        try elements.append(self.allocator, .{ .text = .{
            .node = node_value.id,
            .x = 0,
            .y = 0,
            .font_size = font_size,
            .layout = shaped,
        } });
        return .{
            .width = @max(width, 0),
            .ascent = @max(baseline, 0),
            .descent = @max(height - baseline, 0),
            .elements = elements,
        };
    }

    fn row(self: *Builder, node_value: *const render.MathNode, font_size: f64, script_level: u8) !Box {
        var children = std.ArrayList(Box).empty;
        defer {
            for (children.items) |*child| child.deinit(self.allocator);
            children.deinit(self.allocator);
        }
        var ascent: f64 = 0;
        var descent: f64 = 0;
        var width: f64 = 0;
        for (node_value.children) |child_id| {
            const child = try self.node(child_id, font_size, script_level);
            ascent = @max(ascent, child.ascent);
            descent = @max(descent, child.descent);
            width += child.width;
            try children.append(self.allocator, child);
        }
        var result = Box{ .width = width, .ascent = ascent, .descent = descent };
        errdefer result.deinit(self.allocator);
        var x: f64 = 0;
        for (children.items) |*child| {
            try result.absorb(self.allocator, child, x, ascent - child.ascent);
            x += child.width;
        }
        return result;
    }

    fn fraction(self: *Builder, node_value: *const render.MathNode, font_size: f64, script_level: u8) !Box {
        if (node_value.children.len != 2) return error.InvalidMathTree;
        const child_size = font_size * self.scriptScale(script_level + 1);
        var numerator = try self.node(node_value.children[0], child_size, script_level + 1);
        defer numerator.deinit(self.allocator);
        var denominator = try self.node(node_value.children[1], child_size, script_level + 1);
        defer denominator.deinit(self.allocator);

        const axis = self.constants.axis_height * font_size;
        const thickness = self.constants.fraction_rule_thickness * font_size;
        if (!(thickness > 0) or !std.math.isFinite(thickness)) return error.InvalidMathTable;
        const numerator_gap = (if (self.display and script_level == 0)
            self.constants.fraction_numerator_display_gap_min
        else
            self.constants.fraction_numerator_gap_min) * font_size;
        const denominator_gap = (if (self.display and script_level == 0)
            self.constants.fraction_denominator_display_gap_min
        else
            self.constants.fraction_denominator_gap_min) * font_size;
        var numerator_shift = (if (self.display and script_level == 0)
            self.constants.fraction_numerator_display_shift_up
        else
            self.constants.fraction_numerator_shift_up) * font_size;
        var denominator_shift = (if (self.display and script_level == 0)
            self.constants.fraction_denominator_display_shift_down
        else
            self.constants.fraction_denominator_shift_down) * font_size;
        numerator_shift = @max(numerator_shift, numerator.descent + axis + thickness / 2 + numerator_gap);
        denominator_shift = @max(denominator_shift, denominator.ascent - axis + thickness / 2 + denominator_gap);

        const width = @max(numerator.width, denominator.width);
        const rule_top = -axis - thickness / 2;
        const top = @min(-numerator_shift - numerator.ascent, rule_top);
        const bottom = @max(denominator_shift + denominator.descent, rule_top + thickness);
        var result = Box{ .width = width, .ascent = -top, .descent = bottom };
        errdefer result.deinit(self.allocator);
        try result.absorb(self.allocator, &numerator, (width - numerator.width) / 2, -numerator_shift - numerator.ascent - top);
        try result.absorb(self.allocator, &denominator, (width - denominator.width) / 2, denominator_shift - denominator.ascent - top);
        try result.elements.append(self.allocator, .{ .rule = .{
            .node = node_value.id,
            .rect = .{ .x = 0, .y = rule_top - top, .width = width, .height = thickness },
        } });
        return result;
    }

    fn scripts(
        self: *Builder,
        node_value: *const render.MathNode,
        font_size: f64,
        script_level: u8,
        has_subscript: bool,
        has_superscript: bool,
    ) !Box {
        const expected: usize = 1 + @as(usize, @intFromBool(has_subscript)) + @as(usize, @intFromBool(has_superscript));
        if (node_value.children.len != expected) return error.InvalidMathTree;
        var base = try self.node(node_value.children[0], font_size, script_level);
        defer base.deinit(self.allocator);
        const child_size = font_size * self.scriptScale(script_level + 1);
        var next_child: usize = 1;
        var subscript: ?Box = if (has_subscript) blk: {
            const value = try self.node(node_value.children[next_child], child_size, script_level + 1);
            next_child += 1;
            break :blk value;
        } else null;
        defer if (subscript) |*value| value.deinit(self.allocator);
        var superscript: ?Box = if (has_superscript)
            try self.node(node_value.children[next_child], child_size, script_level + 1)
        else
            null;
        defer if (superscript) |*value| value.deinit(self.allocator);

        var sub_baseline: f64 = 0;
        if (subscript) |value| {
            sub_baseline = @max(self.constants.subscript_shift_down * font_size, value.ascent - self.constants.subscript_top_max * font_size);
            sub_baseline = @max(sub_baseline, base.descent + self.constants.subscript_baseline_drop_min * font_size);
        }
        var sup_baseline: f64 = 0;
        if (superscript) |value| {
            const shift = @max(self.constants.superscript_shift_up * font_size, value.descent + self.constants.superscript_bottom_min * font_size);
            sup_baseline = -@max(shift, base.ascent - self.constants.superscript_baseline_drop_max * font_size);
        }
        if (subscript != null and superscript != null) {
            const sup = superscript.?;
            const sub = subscript.?;
            const actual_gap = (sub_baseline - sub.ascent) - (sup_baseline + sup.descent);
            const required_gap = self.constants.sub_superscript_gap_min * font_size;
            if (actual_gap < required_gap) {
                const adjustment = (required_gap - actual_gap) / 2;
                sup_baseline -= adjustment;
                sub_baseline += adjustment;
            }
        }

        const top = @min(-base.ascent, if (superscript) |value| sup_baseline - value.ascent else 0);
        const bottom = @max(base.descent, if (subscript) |value| sub_baseline + value.descent else 0);
        const script_width = @max(if (subscript) |value| value.width else 0, if (superscript) |value| value.width else 0);
        const after = if (subscript != null or superscript != null) self.constants.space_after_script * font_size else 0;
        var result = Box{ .width = base.width + script_width + after, .ascent = -top, .descent = bottom };
        errdefer result.deinit(self.allocator);
        const base_width = base.width;
        try result.absorb(self.allocator, &base, 0, -base.ascent - top);
        if (superscript) |*value| try result.absorb(self.allocator, value, base_width, sup_baseline - value.ascent - top);
        if (subscript) |*value| try result.absorb(self.allocator, value, base_width, sub_baseline - value.ascent - top);
        return result;
    }

    fn squareRoot(self: *Builder, node_value: *const render.MathNode, font_size: f64, script_level: u8) !Box {
        if (node_value.children.len != 1) return error.InvalidMathTree;
        var radicand = try self.node(node_value.children[0], font_size, script_level);
        defer radicand.deinit(self.allocator);
        const thickness = self.constants.radical_rule_thickness * font_size;
        if (!(thickness > 0) or !std.math.isFinite(thickness)) return error.InvalidMathTable;
        const gap = (if (self.display and script_level == 0)
            self.constants.radical_display_vertical_gap
        else
            self.constants.radical_vertical_gap) * font_size;
        const extra = self.constants.radical_extra_ascender * font_size;
        const target_height = radicand.ascent + radicand.descent + gap + thickness + extra;
        var radical = try self.leaf(&.{ .id = node_value.id, .kind = .operator, .text = @constCast("√") }, @max(font_size, target_height));
        defer radical.deinit(self.allocator);

        const rule_top: f64 = 0;
        const radicand_top = extra + thickness + gap;
        const baseline = radicand_top + radicand.ascent;
        const radical_y = @max(target_height - (radical.ascent + radical.descent), 0);
        const width = radical.width + radicand.width;
        const height = @max(target_height, radical_y + radical.ascent + radical.descent);
        var result = Box{ .width = width, .ascent = baseline, .descent = @max(height - baseline, 0) };
        errdefer result.deinit(self.allocator);
        const radical_width = radical.width;
        const rule_start = std.math.clamp(radical.inkRight() - thickness, 0, radical_width);
        try result.absorb(self.allocator, &radical, 0, radical_y);
        try result.absorb(self.allocator, &radicand, radical_width, radicand_top);
        try result.elements.append(self.allocator, .{ .rule = .{
            .node = node_value.id,
            .rect = .{ .x = rule_start, .y = rule_top + extra, .width = width - rule_start, .height = thickness },
        } });
        return result;
    }

    fn scriptScale(self: *const Builder, level: u8) f64 {
        return if (level <= 1) self.constants.script_scale else self.constants.script_script_scale;
    }
};

const Box = struct {
    width: f64,
    ascent: f64,
    descent: f64,
    elements: std.ArrayList(render.MathElement) = .empty,

    fn deinit(self: *Box, allocator: Allocator) void {
        for (self.elements.items) |*element| switch (element.*) {
            .text => |*value| value.layout.deinit(allocator),
            .rule => {},
        };
        self.elements.deinit(allocator);
        self.* = .{ .width = 0, .ascent = 0, .descent = 0 };
    }

    fn absorb(self: *Box, allocator: Allocator, child: *Box, x: f64, y: f64) !void {
        for (child.elements.items) |*element| {
            translate(element, x, y);
            try self.elements.append(allocator, element.*);
        }
        child.elements.clearRetainingCapacity();
    }

    fn inkRight(self: *const Box) f64 {
        var right: f64 = 0;
        for (self.elements.items) |element| switch (element) {
            .text => |text| right = @max(right, text.x + text.layout.ink_bounds.x + text.layout.ink_bounds.width),
            .rule => |rule| right = @max(right, rule.rect.x + rule.rect.width),
        };
        return right;
    }
};

fn translate(element: *render.MathElement, x: f64, y: f64) void {
    switch (element.*) {
        .text => |*value| {
            value.x += x;
            value.y += y;
        },
        .rule => |*value| {
            value.rect.x += x;
            value.rect.y += y;
        },
    }
}

fn scaleTextLayout(value: *render.TextLayout, factor: f64) void {
    scaleRect(&value.logical_bounds, factor);
    scaleRect(&value.ink_bounds, factor);
    for (value.lines) |*line| {
        line.baseline_y *= factor;
        scaleRect(&line.logical_bounds, factor);
        scaleRect(&line.ink_bounds, factor);
    }
    for (value.runs) |*run| {
        run.x *= factor;
        run.baseline_y *= factor;
        run.advance *= factor;
    }
    for (value.clusters) |*cluster| {
        cluster.x *= factor;
        cluster.baseline_y *= factor;
        cluster.advance_x *= factor;
        cluster.advance_y *= factor;
        scaleRect(&cluster.logical_bounds, factor);
        scaleRect(&cluster.ink_bounds, factor);
    }
    for (value.glyphs) |*glyph| {
        glyph.offset_x *= factor;
        glyph.offset_y *= factor;
        glyph.advance_x *= factor;
        glyph.advance_y *= factor;
    }
}

fn scaleRect(value: *render.Rect, factor: f64) void {
    value.x *= factor;
    value.y *= factor;
    value.width *= factor;
    value.height *= factor;
}

fn shapedHeight(value: render.TextLayout) f64 {
    return @max(value.logical_bounds.y + value.logical_bounds.height, value.logical_bounds.height);
}

fn mathIdentifier(allocator: Allocator, source: []const u8) ![]u8 {
    const count = std.unicode.utf8CountCodepoints(source) catch return allocator.dupe(u8, source);
    if (count != 1) return allocator.dupe(u8, source);
    var view = std.unicode.Utf8View.init(source) catch return allocator.dupe(u8, source);
    var iterator = view.iterator();
    const codepoint = iterator.nextCodepoint() orelse return allocator.dupe(u8, source);
    const mapped = mathItalic(codepoint) orelse return allocator.dupe(u8, source);
    var buffer: [4]u8 = undefined;
    const length = try std.unicode.utf8Encode(mapped, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn mathItalic(codepoint: u21) ?u21 {
    if (codepoint >= 'A' and codepoint <= 'Z') return @intCast(0x1d434 + codepoint - 'A');
    if (codepoint >= 'a' and codepoint <= 'g') return @intCast(0x1d44e + codepoint - 'a');
    if (codepoint == 'h') return 0x210e;
    if (codepoint >= 'i' and codepoint <= 'z') return @intCast(0x1d456 + codepoint - 'i');
    return switch (codepoint) {
        'α' => 0x1d6fc,
        'β' => 0x1d6fd,
        'γ' => 0x1d6fe,
        'δ' => 0x1d6ff,
        'ε' => 0x1d700,
        'θ' => 0x1d703,
        'λ' => 0x1d706,
        'μ' => 0x1d707,
        'π' => 0x1d70b,
        'ρ' => 0x1d70c,
        'σ' => 0x1d70e,
        'φ' => 0x1d711,
        'ω' => 0x1d714,
        'Γ' => 0x1d6e4,
        else => null,
    };
}
