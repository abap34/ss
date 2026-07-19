import std:core/classes as classes

fn move_to(x: Number, y: Number) -> PathCommand
  return PathCommand { verb = PathVerb.move x = x y = y }
end

fn line_to(x: Number, y: Number) -> PathCommand
  return PathCommand { verb = PathVerb.line x = x y = y }
end

fn quadratic_to(control_x: Number, control_y: Number, x: Number, y: Number) -> PathCommand
  return PathCommand {
    verb = PathVerb.quadratic
    control_x = control_x
    control_y = control_y
    x = x
    y = y
  }
end

fn cubic_to(control1_x: Number, control1_y: Number, control2_x: Number, control2_y: Number, x: Number, y: Number) -> PathCommand
  return PathCommand {
    verb = PathVerb.cubic
    control_x = control1_x
    control_y = control1_y
    control2_x = control2_x
    control2_y = control2_y
    x = x
    y = y
  }
end

fn arc_to(radius_x: Number, radius_y: Number, rotation: Number, large_arc: Bool, clockwise: Bool, x: Number, y: Number) -> PathCommand
  return PathCommand {
    verb = PathVerb.arc
    radius_x = radius_x
    radius_y = radius_y
    rotation = rotation
    large_arc = large_arc
    clockwise = clockwise
    x = x
    y = y
  }
end

fn close_path() -> PathCommand
  return PathCommand { verb = PathVerb.close }
end
