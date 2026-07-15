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
    variations: []Variation = &.{},
    features: []Feature = &.{},
    synthetic_bold: bool = false,
    synthetic_italic: bool = false,
    family_substitution: bool = false,

    fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        allocator.free(self.postscript_name);
        allocator.free(self.variations);
        allocator.free(self.features);
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
    variations: []const Variation = &.{},
    features: []const Feature = &.{},
    synthetic_bold: bool = false,
    synthetic_italic: bool = false,
    family_substitution: bool = false,
};

pub const Builder = struct {
    instances: std.ArrayList(Instance) = .empty,

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        for (self.instances.items) |*instance| instance.deinit(allocator);
        self.instances.deinit(allocator);
        self.* = .{};
    }

    pub fn add(self: *Builder, allocator: std.mem.Allocator, spec: Spec) !Id {
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
            .variations = variations,
            .features = features,
            .synthetic_bold = spec.synthetic_bold,
            .synthetic_italic = spec.synthetic_italic,
            .family_substitution = spec.family_substitution,
        });
        return id;
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
    hasher.update("ss-render-font-instance-v1\x00");
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
