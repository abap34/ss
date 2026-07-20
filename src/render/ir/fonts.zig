const std = @import("std");
const core = @import("core");
const resources = @import("resources.zig");

pub const Id = [32]u8;

pub const Variation = struct {
    tag: [4]u8,
    value: f64,
};

pub const Feature = struct {
    tag: [4]u8,
    value: u32,
};

pub const MathConstants = struct {
    script_scale: f64,
    script_script_scale: f64,
    axis_height: f64,
    subscript_shift_down: f64,
    subscript_top_max: f64,
    subscript_baseline_drop_min: f64,
    superscript_shift_up: f64,
    superscript_bottom_min: f64,
    superscript_baseline_drop_max: f64,
    sub_superscript_gap_min: f64,
    superscript_bottom_max_with_subscript: f64,
    space_after_script: f64,
    fraction_numerator_shift_up: f64,
    fraction_numerator_display_shift_up: f64,
    fraction_denominator_shift_down: f64,
    fraction_denominator_display_shift_down: f64,
    fraction_numerator_gap_min: f64,
    fraction_numerator_display_gap_min: f64,
    fraction_rule_thickness: f64,
    fraction_denominator_gap_min: f64,
    fraction_denominator_display_gap_min: f64,
    radical_vertical_gap: f64,
    radical_display_vertical_gap: f64,
    radical_rule_thickness: f64,
    radical_extra_ascender: f64,
};

pub const Instance = struct {
    id: Id,
    resource: resources.Id,
    face_index: u32,
    family: [:0]u8,
    postscript_name: [:0]u8,
    weight: u16,
    style: core.font.Style,
    stretch: core.font.Stretch,
    ascent_ratio: f64,
    descent_ratio: f64,
    line_gap_ratio: f64,
    underline_position_ratio: f64,
    underline_thickness_ratio: f64,
    strikethrough_position_ratio: f64,
    strikethrough_thickness_ratio: f64,
    math: ?MathConstants,
    variations: []Variation = &.{},
    features: []Feature = &.{},
    synthetic_bold: bool = false,
    synthetic_italic: bool = false,
    family_substitution: bool = false,

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        allocator.free(self.postscript_name);
        allocator.free(self.variations);
        allocator.free(self.features);
    }

    pub fn spec(self: *const Instance) Spec {
        return .{
            .resource = self.resource,
            .face_index = self.face_index,
            .family = self.family,
            .postscript_name = self.postscript_name,
            .weight = self.weight,
            .style = self.style,
            .stretch = self.stretch,
            .ascent_ratio = self.ascent_ratio,
            .descent_ratio = self.descent_ratio,
            .line_gap_ratio = self.line_gap_ratio,
            .underline_position_ratio = self.underline_position_ratio,
            .underline_thickness_ratio = self.underline_thickness_ratio,
            .strikethrough_position_ratio = self.strikethrough_position_ratio,
            .strikethrough_thickness_ratio = self.strikethrough_thickness_ratio,
            .math = self.math,
            .variations = self.variations,
            .features = self.features,
            .synthetic_bold = self.synthetic_bold,
            .synthetic_italic = self.synthetic_italic,
            .family_substitution = self.family_substitution,
        };
    }

    pub fn clone(self: *const Instance, allocator: std.mem.Allocator) !Instance {
        const family = try allocator.dupeZ(u8, self.family);
        errdefer allocator.free(family);
        const postscript_name = try allocator.dupeZ(u8, self.postscript_name);
        errdefer allocator.free(postscript_name);
        const variations = try allocator.dupe(Variation, self.variations);
        errdefer allocator.free(variations);
        const features = try allocator.dupe(Feature, self.features);
        return .{
            .id = self.id,
            .resource = self.resource,
            .face_index = self.face_index,
            .family = family,
            .postscript_name = postscript_name,
            .weight = self.weight,
            .style = self.style,
            .stretch = self.stretch,
            .ascent_ratio = self.ascent_ratio,
            .descent_ratio = self.descent_ratio,
            .line_gap_ratio = self.line_gap_ratio,
            .underline_position_ratio = self.underline_position_ratio,
            .underline_thickness_ratio = self.underline_thickness_ratio,
            .strikethrough_position_ratio = self.strikethrough_position_ratio,
            .strikethrough_thickness_ratio = self.strikethrough_thickness_ratio,
            .math = self.math,
            .variations = variations,
            .features = features,
            .synthetic_bold = self.synthetic_bold,
            .synthetic_italic = self.synthetic_italic,
            .family_substitution = self.family_substitution,
        };
    }

    pub fn ownedByteSize(self: *const Instance) usize {
        return @sizeOf(Instance) +| self.family.len +| 1 +| self.postscript_name.len +| 1 +|
            self.variations.len *| @sizeOf(Variation) +| self.features.len *| @sizeOf(Feature);
    }
};

pub const Catalog = struct {
    instances: []Instance = &.{},

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.instances) |*instance| instance.deinit(allocator);
        allocator.free(self.instances);
        self.* = .{};
    }

    pub fn find(self: *const Catalog, id: Id) ?*const Instance {
        var low: usize = 0;
        var high = self.instances.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const order = std.mem.order(u8, &self.instances[middle].id, &id);
            switch (order) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return &self.instances[middle],
            }
        }
        return null;
    }
};

pub const Spec = struct {
    resource: resources.Id,
    face_index: u32,
    family: []const u8,
    postscript_name: []const u8,
    weight: u16,
    style: core.font.Style,
    stretch: core.font.Stretch,
    ascent_ratio: f64,
    descent_ratio: f64,
    line_gap_ratio: f64,
    underline_position_ratio: f64,
    underline_thickness_ratio: f64,
    strikethrough_position_ratio: f64,
    strikethrough_thickness_ratio: f64,
    math: ?MathConstants = null,
    variations: []const Variation = &.{},
    features: []const Feature = &.{},
    synthetic_bold: bool = false,
    synthetic_italic: bool = false,
    family_substitution: bool = false,
};

pub const Builder = struct {
    instances: std.ArrayList(Instance) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.instances.items) |*instance| instance.deinit(allocator);
        self.instances.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *Builder, allocator: std.mem.Allocator, io: std.Io, spec: Spec) !Id {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return try self.addUnlocked(allocator, spec);
    }

    fn addUnlocked(self: *Builder, allocator: std.mem.Allocator, spec: Spec) !Id {
        const id = identify(spec);
        for (self.instances.items) |instance| {
            if (std.mem.eql(u8, &instance.id, &id)) return id;
        }
        const family = try allocator.dupeZ(u8, spec.family);
        errdefer allocator.free(family);
        const postscript_name = try allocator.dupeZ(u8, spec.postscript_name);
        errdefer allocator.free(postscript_name);
        const variations = try allocator.dupe(Variation, spec.variations);
        errdefer allocator.free(variations);
        const features = try allocator.dupe(Feature, spec.features);
        errdefer allocator.free(features);
        try self.instances.append(allocator, .{
            .id = id,
            .resource = spec.resource,
            .face_index = spec.face_index,
            .family = family,
            .postscript_name = postscript_name,
            .weight = spec.weight,
            .style = spec.style,
            .stretch = spec.stretch,
            .ascent_ratio = spec.ascent_ratio,
            .descent_ratio = spec.descent_ratio,
            .line_gap_ratio = spec.line_gap_ratio,
            .underline_position_ratio = spec.underline_position_ratio,
            .underline_thickness_ratio = spec.underline_thickness_ratio,
            .strikethrough_position_ratio = spec.strikethrough_position_ratio,
            .strikethrough_thickness_ratio = spec.strikethrough_thickness_ratio,
            .math = spec.math,
            .variations = variations,
            .features = features,
            .synthetic_bold = spec.synthetic_bold,
            .synthetic_italic = spec.synthetic_italic,
            .family_substitution = spec.family_substitution,
        });
        return id;
    }

    fn find(self: *const Builder, id: Id) ?*const Instance {
        for (self.instances.items) |*instance| {
            if (std.mem.eql(u8, &instance.id, &id)) return instance;
        }
        return null;
    }

    pub fn get(self: *Builder, io: std.Io, id: Id) ?Instance {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const instance = self.find(id) orelse return null;
        return instance.*;
    }

    pub fn take(self: *Builder, allocator: std.mem.Allocator) !Catalog {
        std.mem.sort(Instance, self.instances.items, {}, lessThan);
        const instances = try self.instances.toOwnedSlice(allocator);
        self.* = .{};
        return .{ .instances = instances };
    }

    fn lessThan(_: void, lhs: Instance, rhs: Instance) bool {
        return std.mem.order(u8, &lhs.id, &rhs.id) == .lt;
    }
};

pub fn identify(spec: Spec) Id {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ss-render-font-instance-v2\x00");
    hasher.update(&spec.resource);
    hashInteger(&hasher, spec.face_index);
    hashBytes(&hasher, spec.family);
    hashBytes(&hasher, spec.postscript_name);
    hashInteger(&hasher, spec.weight);
    hashBytes(&hasher, @tagName(spec.style));
    hashBytes(&hasher, @tagName(spec.stretch));
    hashInteger(&hasher, @as(u64, @bitCast(spec.ascent_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.descent_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.line_gap_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.underline_position_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.underline_thickness_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.strikethrough_position_ratio)));
    hashInteger(&hasher, @as(u64, @bitCast(spec.strikethrough_thickness_ratio)));
    if (spec.math) |constants| {
        hasher.update(&.{1});
        inline for (std.meta.fields(MathConstants)) |field| {
            hashInteger(&hasher, @as(u64, @bitCast(@field(constants, field.name))));
        }
    } else hasher.update(&.{0});
    hashInteger(&hasher, spec.variations.len);
    for (spec.variations) |variation| {
        hasher.update(&variation.tag);
        hashInteger(&hasher, @as(u64, @bitCast(variation.value)));
    }
    hashInteger(&hasher, spec.features.len);
    for (spec.features) |feature| {
        hasher.update(&feature.tag);
        hashInteger(&hasher, feature.value);
    }
    hasher.update(&.{
        @intFromBool(spec.synthetic_bold),
        @intFromBool(spec.synthetic_italic),
        @intFromBool(spec.family_substitution),
    });
    var id: Id = undefined;
    hasher.final(&id);
    return id;
}

fn hashBytes(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    hashInteger(hasher, value.len);
    hasher.update(value);
}

fn hashInteger(hasher: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, @intCast(value), .little);
    hasher.update(&buffer);
}
