import std:graphics/types as { LineCap, LineJoin, FillRule, PaintSpace, GradientSpread, FillKind, PathVerb, PathCommand, VectorStrokeStyle, LineStyle, GradientDirection, PatternStyle, FillStyle, MarkerStyle, VectorStyle }
import std:graphics/content as { PathShape }
import std:graphics/path as paths
import std:graphics/paint as fills

fn/! path_shape(path_value: Path, width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}, marker_start: MarkerStyle? = none, marker_end: MarkerStyle? = none) -> PathShape
  return PathShape { path = path_value width = width height = height style = style marker_start = marker_start marker_end = marker_end }
end

fn/! rectangle(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(0, 0),
    paths::line_to(1, 0),
    paths::line_to(1, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), width, height, style)
end

fn/! circle(width: Number = 120, height: Number = width, style: VectorStyle = VectorStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(0.5, 0),
    paths::arc_to(0.5, 0.5, 0, false, true, 0.5, 1),
    paths::arc_to(0.5, 0.5, 0, false, true, 0.5, 0),
    paths::close_path()
  ), width, height, style)
end

fn/! arrow_shape(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(0, 0.28),
    paths::line_to(0.62, 0.28),
    paths::line_to(0.62, 0),
    paths::line_to(1, 0.5),
    paths::line_to(0.62, 1),
    paths::line_to(0.62, 0.72),
    paths::line_to(0, 0.72),
    paths::close_path()
  ), width, height, style)
end

fn/! speech_bubble(width: Number = 180, height: Number = 120, style: VectorStyle = VectorStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(0.12, 0.05),
    paths::line_to(0.88, 0.05),
    paths::arc_to(0.1, 0.1, 0, false, true, 0.98, 0.15),
    paths::line_to(0.98, 0.68),
    paths::arc_to(0.1, 0.1, 0, false, true, 0.88, 0.78),
    paths::line_to(0.48, 0.78),
    paths::line_to(0.28, 0.98),
    paths::line_to(0.31, 0.78),
    paths::line_to(0.12, 0.78),
    paths::arc_to(0.1, 0.1, 0, false, true, 0.02, 0.68),
    paths::line_to(0.02, 0.15),
    paths::arc_to(0.1, 0.1, 0, false, true, 0.12, 0.05),
    paths::close_path()
  ), width, height, style)
end

fn/! line(width: Number = 160, height: Number = 1, style: LineStyle = LineStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(style.start_x, style.start_y),
    paths::line_to(style.end_x, style.end_y)
  ), width, height, VectorStyle { stroke = style.stroke }, style.marker_start, style.marker_end)
end

fn/! elbow_line(width: Number = 160, height: Number = 100, style: LineStyle = LineStyle {}) -> PathShape
  return path_shape(path(
    paths::move_to(style.start_x, style.start_y),
    paths::line_to(style.end_x, style.start_y),
    paths::line_to(style.end_x, style.end_y)
  ), width, height, VectorStyle { stroke = style.stroke }, style.marker_start, style.marker_end)
end

fn marker_arrow_open(size: Number = 10, color_name: Color = c"#4b5563", line_width: Number = 1.6) -> MarkerStyle
  return MarkerStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(1, 0.5),
      paths::line_to(0, 1)
    )
    width = size
    height = size
    fill = fills::no_fill()
    stroke = fills::vector_stroke(color_name, line_width, LineCap.round, LineJoin.round)
  }
end
