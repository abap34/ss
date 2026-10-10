const std = @import("std");
const core = @import("core");

pub fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

pub fn validBounds(bounds: anytype, page_width: f64, page_height: f64) bool {
    const tolerance = @as(f64, core.layout.graph.ConstraintTolerance);
    if (!std.math.isFinite(bounds.x) or !std.math.isFinite(bounds.y) or
        !std.math.isFinite(bounds.width) or !std.math.isFinite(bounds.height)) return false;
    if (bounds.x < 0 or bounds.y < 0 or bounds.width <= 0 or bounds.height <= 0) return false;
    return bounds.x + bounds.width <= page_width + tolerance and
        bounds.y + bounds.height <= page_height + tolerance;
}

pub fn pageForId(pages: []const core.layout.conflicts.Page, page_id: core.NodeId) ?core.layout.conflicts.Page {
    for (pages) |page| if (page.id == page_id) return page;
    return null;
}
