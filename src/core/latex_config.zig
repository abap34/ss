const std = @import("std");
const model = @import("model");

pub const LatexEngine = enum {
    pdflatex,
    lualatex,

    pub fn executable(self: LatexEngine) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) ?LatexEngine {
        if (std.mem.eql(u8, value, "pdflatex")) return .pdflatex;
        if (std.mem.eql(u8, value, "lualatex")) return .lualatex;
        return null;
    }
};

pub const Config = struct {
    preamble: []const u8 = "",
    engine: LatexEngine = .pdflatex,
};

pub fn forNode(node: *const model.Node) !Config {
    const placement = node.placement orelse return .{};
    if (placement.display != .native) return .{};
    const input = switch (placement.display.native) {
        .text => model.nodeTextContent(node) orelse return error.InvalidNativeDisplay,
        .image => if (model.nodeImageSourceKind(node) == .latex)
            model.nodeImageSource(node) orelse return error.InvalidNativeDisplay
        else
            return .{},
        .path_shape => return .{},
    };
    const config = input.field("config") orelse return error.InvalidNativeDisplay;
    if (config != .record) return error.InvalidNativeDisplay;
    const engine = config.record.field("engine") orelse return error.InvalidNativeDisplay;
    if (engine != .enum_case) return error.InvalidNativeDisplay;
    const preamble = config.record.field("preamble") orelse return error.InvalidNativeDisplay;
    if (preamble != .string) return error.InvalidNativeDisplay;
    return .{
        .engine = LatexEngine.parse(engine.enum_case.case_name) orelse return error.InvalidNativeDisplay,
        .preamble = preamble.string,
    };
}
