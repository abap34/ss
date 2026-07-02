const core = @import("core");

const types = @import("types.zig");

pub fn hints(snapshot: anytype, path: []const u8, opts: types.QueryOptions) []const core.InlayHint {
    const budget = types.QueryBudget.start(opts);
    if (budget.expired()) return &.{};
    _ = path;
    return snapshot.hints;
}
