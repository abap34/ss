const std = @import("std");
const core = @import("core");

const DPoint = struct {
    x: f64,
    y: f64,
};

pub fn build(allocator: std.mem.Allocator, values: []const core.Value) !core.Path {
    if (values.len == 0 or values.len > 255) return error.InvalidPathArity;

    var commands = std.ArrayList(core.PathCommand).empty;
    errdefer commands.deinit(allocator);

    var current: ?DPoint = null;
    var subpath_start: ?DPoint = null;
    var subpath_open = false;

    for (values) |value| {
        const record = switch (value) {
            .record => |record| record,
            else => return error.ExpectedPathCommand,
        };
        if (!std.mem.eql(u8, record.type_name, "PathCommand")) return error.ExpectedPathCommand;
        const verb = try enumField(record, "verb", "PathVerb");

        if (std.mem.eql(u8, verb, "move")) {
            const point = try pointFields(record, "x", "y");
            try appendCommand(allocator, &commands, .{ .move_to = toPoint(point) });
            current = point;
            subpath_start = point;
            subpath_open = true;
            continue;
        }

        if (current == null or !subpath_open) return error.InvalidPathCommandOrder;

        if (std.mem.eql(u8, verb, "line")) {
            const point = try pointFields(record, "x", "y");
            try appendCommand(allocator, &commands, .{ .line_to = toPoint(point) });
            current = point;
        } else if (std.mem.eql(u8, verb, "quadratic")) {
            const control = try pointFields(record, "control_x", "control_y");
            const end = try pointFields(record, "x", "y");
            const start = current.?;
            const cubic = core.PathCubic{
                .control1 = toPoint(.{
                    .x = start.x + (control.x - start.x) * (2.0 / 3.0),
                    .y = start.y + (control.y - start.y) * (2.0 / 3.0),
                }),
                .control2 = toPoint(.{
                    .x = end.x + (control.x - end.x) * (2.0 / 3.0),
                    .y = end.y + (control.y - end.y) * (2.0 / 3.0),
                }),
                .end = toPoint(end),
            };
            try appendCommand(allocator, &commands, .{ .cubic_to = cubic });
            current = end;
        } else if (std.mem.eql(u8, verb, "cubic")) {
            const control1 = try pointFields(record, "control_x", "control_y");
            const control2 = try pointFields(record, "control2_x", "control2_y");
            const end = try pointFields(record, "x", "y");
            try appendCommand(allocator, &commands, .{ .cubic_to = .{
                .control1 = toPoint(control1),
                .control2 = toPoint(control2),
                .end = toPoint(end),
            } });
            current = end;
        } else if (std.mem.eql(u8, verb, "arc")) {
            const end = try pointFields(record, "x", "y");
            const radius_x = try numberField(record, "radius_x");
            const radius_y = try numberField(record, "radius_y");
            const rotation = try numberField(record, "rotation");
            const large_arc = try booleanField(record, "large_arc");
            const clockwise = try booleanField(record, "clockwise");
            if (radius_x < 0 or radius_y < 0) return error.InvalidArcRadius;
            try appendArc(allocator, &commands, current.?, end, radius_x, radius_y, rotation, large_arc, clockwise);
            current = end;
        } else if (std.mem.eql(u8, verb, "close")) {
            if (subpath_start == null) return error.InvalidPathCommandOrder;
            try appendCommand(allocator, &commands, .{ .close = {} });
            current = subpath_start.?;
            subpath_open = false;
        } else {
            return error.InvalidPathVerb;
        }
    }

    return .{ .commands = try commands.toOwnedSlice(allocator) };
}

fn appendCommand(allocator: std.mem.Allocator, commands: *std.ArrayList(core.PathCommand), command: core.PathCommand) !void {
    if (!command.isFinite()) return error.NonFinitePathCoordinate;
    try commands.append(allocator, command);
}

fn enumField(record: core.RecordValue, name: []const u8, expected_type: []const u8) ![]const u8 {
    const value = record.field(name) orelse return error.MissingPathCommandField;
    return switch (value) {
        .enum_case => |case| if (std.mem.eql(u8, case.enum_name, expected_type)) case.case_name else error.InvalidPathCommandField,
        else => error.InvalidPathCommandField,
    };
}

fn numberField(record: core.RecordValue, name: []const u8) !f64 {
    const value = record.field(name) orelse return error.MissingPathCommandField;
    const number = switch (value) {
        .number => |number| @as(f64, number),
        else => return error.InvalidPathCommandField,
    };
    if (!std.math.isFinite(number)) return error.NonFinitePathCoordinate;
    return number;
}

fn booleanField(record: core.RecordValue, name: []const u8) !bool {
    const value = record.field(name) orelse return error.MissingPathCommandField;
    return switch (value) {
        .boolean => |boolean| boolean,
        else => error.InvalidPathCommandField,
    };
}

fn pointFields(record: core.RecordValue, x_name: []const u8, y_name: []const u8) !DPoint {
    return .{
        .x = try numberField(record, x_name),
        .y = try numberField(record, y_name),
    };
}

fn toPoint(point: DPoint) core.PathPoint {
    return .{ .x = @floatCast(point.x), .y = @floatCast(point.y) };
}

fn appendArc(
    allocator: std.mem.Allocator,
    commands: *std.ArrayList(core.PathCommand),
    start: DPoint,
    end: DPoint,
    radius_x_value: f64,
    radius_y_value: f64,
    rotation_degrees: f64,
    large_arc: bool,
    clockwise: bool,
) !void {
    if (samePoint(start, end)) return;
    if (radius_x_value == 0 or radius_y_value == 0) {
        try appendCommand(allocator, commands, .{ .line_to = toPoint(end) });
        return;
    }

    var radius_x = radius_x_value;
    var radius_y = radius_y_value;
    const phi = rotation_degrees * std.math.pi / 180.0;
    const cos_phi = @cos(phi);
    const sin_phi = @sin(phi);
    const half_dx = (start.x - end.x) / 2.0;
    const half_dy = (start.y - end.y) / 2.0;
    const x1_prime = cos_phi * half_dx + sin_phi * half_dy;
    const y1_prime = -sin_phi * half_dx + cos_phi * half_dy;

    var radii_scale = (x1_prime * x1_prime) / (radius_x * radius_x) +
        (y1_prime * y1_prime) / (radius_y * radius_y);
    if (radii_scale > 1) {
        radii_scale = @sqrt(radii_scale);
        radius_x *= radii_scale;
        radius_y *= radii_scale;
    }

    const rx2 = radius_x * radius_x;
    const ry2 = radius_y * radius_y;
    const x1p2 = x1_prime * x1_prime;
    const y1p2 = y1_prime * y1_prime;
    const numerator = @max(0.0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2);
    const denominator = rx2 * y1p2 + ry2 * x1p2;
    const sign: f64 = if (large_arc == clockwise) -1 else 1;
    const coefficient = if (denominator == 0) 0 else sign * @sqrt(numerator / denominator);
    const center_x_prime = coefficient * (radius_x * y1_prime / radius_y);
    const center_y_prime = coefficient * (-radius_y * x1_prime / radius_x);
    const center = DPoint{
        .x = cos_phi * center_x_prime - sin_phi * center_y_prime + (start.x + end.x) / 2.0,
        .y = sin_phi * center_x_prime + cos_phi * center_y_prime + (start.y + end.y) / 2.0,
    };

    const start_vector = DPoint{
        .x = (x1_prime - center_x_prime) / radius_x,
        .y = (y1_prime - center_y_prime) / radius_y,
    };
    const end_vector = DPoint{
        .x = (-x1_prime - center_x_prime) / radius_x,
        .y = (-y1_prime - center_y_prime) / radius_y,
    };
    const start_angle = std.math.atan2(start_vector.y, start_vector.x);
    var sweep_angle = vectorAngle(start_vector, end_vector);
    if (!clockwise and sweep_angle > 0) sweep_angle -= 2.0 * std.math.pi;
    if (clockwise and sweep_angle < 0) sweep_angle += 2.0 * std.math.pi;

    const segment_count: usize = @max(1, @as(usize, @intFromFloat(@ceil(@abs(sweep_angle) / (std.math.pi / 2.0)))));
    const segment_angle = sweep_angle / @as(f64, @floatFromInt(segment_count));
    var index: usize = 0;
    while (index < segment_count) : (index += 1) {
        const theta1 = start_angle + segment_angle * @as(f64, @floatFromInt(index));
        const theta2 = theta1 + segment_angle;
        const alpha = (4.0 / 3.0) * @tan(segment_angle / 4.0);
        const point1 = ellipsePoint(center, radius_x, radius_y, cos_phi, sin_phi, theta1);
        var point2 = ellipsePoint(center, radius_x, radius_y, cos_phi, sin_phi, theta2);
        const derivative1 = ellipseDerivative(radius_x, radius_y, cos_phi, sin_phi, theta1);
        const derivative2 = ellipseDerivative(radius_x, radius_y, cos_phi, sin_phi, theta2);
        if (index + 1 == segment_count) point2 = end;
        try appendCommand(allocator, commands, .{ .cubic_to = .{
            .control1 = toPoint(.{ .x = point1.x + alpha * derivative1.x, .y = point1.y + alpha * derivative1.y }),
            .control2 = toPoint(.{ .x = point2.x - alpha * derivative2.x, .y = point2.y - alpha * derivative2.y }),
            .end = toPoint(point2),
        } });
    }
}

fn ellipsePoint(center: DPoint, radius_x: f64, radius_y: f64, cos_phi: f64, sin_phi: f64, theta: f64) DPoint {
    const x = radius_x * @cos(theta);
    const y = radius_y * @sin(theta);
    return .{
        .x = center.x + cos_phi * x - sin_phi * y,
        .y = center.y + sin_phi * x + cos_phi * y,
    };
}

fn ellipseDerivative(radius_x: f64, radius_y: f64, cos_phi: f64, sin_phi: f64, theta: f64) DPoint {
    const dx = -radius_x * @sin(theta);
    const dy = radius_y * @cos(theta);
    return .{
        .x = cos_phi * dx - sin_phi * dy,
        .y = sin_phi * dx + cos_phi * dy,
    };
}

fn vectorAngle(left: DPoint, right: DPoint) f64 {
    return std.math.atan2(left.x * right.y - left.y * right.x, left.x * right.x + left.y * right.y);
}

fn samePoint(left: DPoint, right: DPoint) bool {
    return left.x == right.x and left.y == right.y;
}
