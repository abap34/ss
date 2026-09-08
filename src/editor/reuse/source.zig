const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const AnalysisSnapshot = @import("../../analysis/snapshot.zig").AnalysisSnapshot;
const generated_edit = @import("../edit/generated.zig");

pub fn canApply(snapshot: *AnalysisSnapshot, path: []const u8, generated: *const generated_edit.Edit, generation: u64) bool {
    if (!std.mem.eql(u8, generated.path, path) or
        generated.replacements.len == 0 or generated.mode == .width or
        generated.base_generation == std.math.maxInt(u64) or generation != generated.base_generation + 1)
    {
        return false;
    }
    if (snapshot.generation != generated.base_generation or
        !snapshot.coversPath(path) or
        snapshot.layout_output == null or
        snapshot.layout_output.?.editor == null or
        snapshot.retained_layout_state == null or
        snapshot.diagnostics.items.items.len != 0 or
        snapshot.layout_output.?.report.failure_count != 0 or
        !std.mem.eql(u8, snapshot.layout_output.?.editor.?.model.snapshot_id, generated.base_snapshot_id))
    {
        return false;
    }
    const state = &snapshot.retained_layout_state.?.state;
    const node = state.getNode(generated.node_id) orelse return false;
    if (node.kind != .object) return false;
    if ((state.parentPageOf(node.id) orelse return false) != generated.page_id) return false;
    if (!canRebaseGeneratedSource(snapshot, state, path, generated)) return false;
    if (hasLayoutDiagnostics(state)) return false;
    for (generated.replacements, 0..) |replacement, replacement_position| {
        if (replacement.index >= state.constraints.items.len or
            !std.math.isFinite(replacement.new_offset))
        {
            return false;
        }
        for (generated.replacements[0..replacement_position]) |previous| {
            if (previous.index == replacement.index) return false;
        }
        const constraint = state.constraints.items[replacement.index];
        if (!constraintEql(constraint, replacement.expected) or
            constraint.target_node != generated.node_id or
            constraint.role != .position or
            !canSyncConstraintUpdate(state, replacement))
        {
            return false;
        }
        if (replacement.literal_scale != 1 and replacement.literal_scale != -1) return false;
        const previous_text = generated.base_source[replacement.offset_span.start..replacement.offset_span.end];
        const replacement_text = generated.source[replacement.offset_span.start..replacement.offset_span.end];
        const parsed_previous = parseGeneratedNumericOffset(previous_text) orelse return false;
        const parsed_offset = parseGeneratedNumericOffset(replacement_text) orelse return false;
        const scale = @as(f64, replacement.literal_scale);
        const tolerance = @as(f64, core.layout.graph.ConstraintTolerance);
        if (!std.math.isFinite(parsed_previous) or
            !std.math.isFinite(parsed_offset) or
            @abs(parsed_previous * scale - @as(f64, replacement.expected.offset)) > tolerance or
            @abs(parsed_offset * scale - @as(f64, replacement.new_offset)) > tolerance)
        {
            return false;
        }
    }
    return true;
}

fn canRebaseGeneratedSource(
    snapshot: *const AnalysisSnapshot,
    state: *const core.DocumentState,
    path: []const u8,
    generated: *const generated_edit.Edit,
) bool {
    if (!generated.onlyChangesOffsets()) return false;
    const state_module = state.moduleByPathOrSpec(path) orelse return false;
    if (!std.mem.eql(u8, state_module.source, generated.base_source)) return false;

    var found_snapshot_module = false;
    for (snapshot.modules) |module| {
        const module_path = module.path orelse continue;
        if (!std.mem.eql(u8, module_path, path)) continue;
        if (!std.mem.eql(u8, module.source, generated.base_source)) return false;
        found_snapshot_module = true;
        break;
    }
    if (!found_snapshot_module) return false;
    for (snapshot.diagnostics.items.items) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.path, path)) continue;
        if (!std.mem.eql(u8, diagnostic.source, generated.base_source)) return false;
    }

    return true;
}

pub fn stateModuleForPathMutable(state: *core.DocumentState, path: []const u8) ?*core.SourceModule {
    for (state.modules.items) |*module| {
        if (module.path) |module_path| {
            if (std.mem.eql(u8, module_path, path)) return module;
        }
        if (std.mem.eql(u8, module.spec, path)) return module;
    }
    return null;
}

pub fn rebaseSnapshotSource(snapshot: *AnalysisSnapshot, path: []const u8, source: []const u8) void {
    for (snapshot.modules) |*module| {
        const module_path = module.path orelse continue;
        if (!std.mem.eql(u8, module_path, path)) continue;
        @memcpy(module.source, source);
        break;
    }
    for (snapshot.diagnostics.items.items) |*diagnostic| {
        if (!std.mem.eql(u8, diagnostic.path, path)) continue;
        @memcpy(diagnostic.source, source);
    }
}

fn constraintEql(left: core.Constraint, right: core.Constraint) bool {
    return left.target_node == right.target_node and
        left.target_anchor == right.target_anchor and
        constraintSourceEql(left.source, right.source) and
        left.offset == right.offset and
        optionalStringEql(left.origin, right.origin) and
        left.role == right.role and
        left.scope_depth == right.scope_depth and
        left.from_update == right.from_update;
}

fn canSyncConstraintUpdate(
    state: *const core.DocumentState,
    replacement: generated_edit.Replacement,
) bool {
    if (!replacement.expected.from_update) return true;
    var match_count: usize = 0;
    for (state.constraint_updates.items) |update| {
        if (!update.active) continue;
        const active_replacement = update.replacement orelse continue;
        if (!constraintEql(active_replacement, replacement.expected)) continue;
        match_count += 1;
    }
    return match_count == 1;
}

pub fn syncConstraintUpdate(
    state: *core.DocumentState,
    replacement: generated_edit.Replacement,
) void {
    if (!replacement.expected.from_update) return;
    for (state.constraint_updates.items) |*update| {
        if (!update.active) continue;
        const active_replacement = if (update.replacement) |*value| value else continue;
        if (!constraintEql(active_replacement.*, replacement.expected)) continue;
        active_replacement.offset = replacement.new_offset;
        return;
    }
}

fn constraintSourceEql(left: core.ConstraintSource, right: core.ConstraintSource) bool {
    return switch (left) {
        .page => |left_anchor| switch (right) {
            .page => |right_anchor| left_anchor == right_anchor,
            else => false,
        },
        .node => |left_node| switch (right) {
            .node => |right_node| left_node.node_id == right_node.node_id and left_node.anchor == right_node.anchor,
            else => false,
        },
    };
}

fn optionalStringEql(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |left_value| {
        const right_value = right orelse return false;
        return std.mem.eql(u8, left_value, right_value);
    }
    return right == null;
}

fn parseGeneratedNumericOffset(text: []const u8) ?f64 {
    var remaining = std.mem.trim(u8, text, " \t\r\n");
    if (remaining.len == 0) return null;
    var sign: f64 = 1;
    if (remaining[0] == '+' or remaining[0] == '-') {
        if (remaining[0] == '-') sign = -1;
        remaining = std.mem.trim(u8, remaining[1..], " \t\r\n");
    }
    if (remaining.len == 0) return null;
    const value = std.fmt.parseFloat(f64, remaining) catch return null;
    return sign * value;
}

pub fn hasLayoutDiagnostics(state: *const core.DocumentState) bool {
    for (state.diagnostics.items) |diagnostic| {
        if (diagnostic.phase == .layout) return true;
    }
    return false;
}
