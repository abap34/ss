// Reachability is shared by the call, return-value and access analyses.
// The type checker still checks unreachable statements.
const ast = @import("ast");
pub const Alternatives = @import("core").placement_inputs.Alternatives;

pub const Exits = struct {
    next: bool = true,
    returned: bool = false,

    pub const stop: Exits = .{ .next = false, .returned = true };

    pub fn either(a: Exits, b: Exits) Exits {
        return .{ .next = a.next or b.next, .returned = a.returned or b.returned };
    }

    pub fn then(a: Exits, b: Exits) Exits {
        return if (a.next) .{ .next = b.next, .returned = a.returned or b.returned } else a;
    }
};

// Only function bodies and the interiors of compound statements compose in
// source order. Each document/page statement has its own graph entry.
pub fn block(pass: anytype, statements: []const ast.Statement) anyerror!Exits {
    var exits = Exits{};
    for (statements) |stmt| {
        if (!exits.next) break;
        exits = exits.then(try pass.visit(stmt, exits.returned));
    }
    return exits;
}

pub fn statement(pass: anytype, stmt: ast.Statement) anyerror!Exits {
    switch (stmt.kind) {
        .return_expr => |expr| try pass.onReturn(expr),
        .return_void => try pass.onReturn(null),
        .if_stmt => |branch| {
            const truth = try pass.condition(branch.condition);
            if (truth == .yes) return pass.arm(branch.then_statements.items, 0);
            if (truth == .no) return pass.arm(branch.else_statements.items, 0);
            const yes = try pass.arm(branch.then_statements.items, 0);
            return yes.either(try pass.arm(branch.else_statements.items, 1));
        },
        else => {
            try pass.simple(stmt);
            return .{};
        },
    }
    return Exits.stop;
}

pub const Coalesce = enum { left, right, both };

pub fn coalesce(present: Alternatives) Coalesce {
    return switch (present) {
        .yes => .left,
        .no => .right,
        // Until there is a proof, either operand may supply the value.
        .bottom, .either => .both,
    };
}

pub fn memberPresence(receiver: Alternatives, field: Alternatives, optional: bool) Alternatives {
    if (!optional) return field;
    return switch (receiver) {
        .yes => field,
        .no => .no,
        .bottom, .either => if (field == .bottom) .either else field.join(.no),
    };
}

// The type alone settles presence for ordinary scalar results. Never interpret
// arithmetic or open a function body solely to obtain that fact.
pub fn presence(ty: ast.Type) Alternatives {
    return switch (ty.kind) {
        .none => .no,
        .any, .optional, .parameter, .hole, .unresolved => .either,
        .void => .bottom,
        else => .yes,
    };
}

pub fn needsValueFlow(ty: ast.Type) bool {
    return switch (ty.kind) {
        .boolean, .function, .record, .group, .optional, .any, .parameter, .placed, .placement, .page, .document, .selection => true,
        else => false,
    };
}
