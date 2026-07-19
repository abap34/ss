import std:core/classes as classes
import std:core/fills as fills
import std:core/objects as objects
import std:core/paths as paths

fn/! path_shape_unit(path_value: Path, fill_value: FillStyle = FillStyle {}, stroke_value: VectorStrokeStyle = VectorStrokeStyle {}) -> Object
  let obj = objects::path_obj(path_value)
  obj.fill = fill_value
  obj.stroke = stroke_value
  return obj
end

fn/! path_shape(path_value: Path, width: Number, height: Number, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path_value, style.fill, style.stroke), width, height)
end

fn shape_size(obj: Object, width: Number, height: Number) -> Object
  ~ obj.width == width
  ~ obj.height == height
  return obj
end

fn/! rectangle(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0, 0),
    paths::line_to(1, 0),
    paths::line_to(1, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! rounded_rectangle(width: Number = 160, height: Number = 100, radius: Number = 0.12, style: VectorStyle = VectorStyle {}) -> Object
  let right = sub(1, radius)
  return shape_size(path_shape_unit(path(
    paths::move_to(radius, 0),
    paths::line_to(right, 0),
    paths::arc_to(radius, radius, 0, false, true, 1, radius),
    paths::line_to(1, right),
    paths::arc_to(radius, radius, 0, false, true, right, 1),
    paths::line_to(radius, 1),
    paths::arc_to(radius, radius, 0, false, true, 0, right),
    paths::line_to(0, radius),
    paths::arc_to(radius, radius, 0, false, true, radius, 0),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! ellipse(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0),
    paths::arc_to(0.5, 0.5, 0, false, true, 0.5, 1),
    paths::arc_to(0.5, 0.5, 0, false, true, 0.5, 0),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! circle(diameter: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return ellipse(diameter, diameter, style)
end

fn/! capsule(width: Number = 180, height: Number = 80, style: VectorStyle = VectorStyle {}) -> Object
  return rounded_rectangle(width, height, 0.5, style)
end

fn/! triangle(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0),
    paths::line_to(1, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! right_triangle(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0, 0),
    paths::line_to(1, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! diamond(width: Number = 120, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0),
    paths::line_to(1, 0.5),
    paths::line_to(0.5, 1),
    paths::line_to(0, 0.5),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! parallelogram(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.2, 0),
    paths::line_to(1, 0),
    paths::line_to(0.8, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! trapezoid(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.2, 0),
    paths::line_to(0.8, 0),
    paths::line_to(1, 1),
    paths::line_to(0, 1),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! pentagon(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0),
    paths::line_to(0.9755, 0.3455),
    paths::line_to(0.7939, 0.9045),
    paths::line_to(0.2061, 0.9045),
    paths::line_to(0.0245, 0.3455),
    paths::close_path()
  ), style.fill, style.stroke), size, size)
end

fn/! hexagon(width: Number = 150, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.25, 0),
    paths::line_to(0.75, 0),
    paths::line_to(1, 0.5),
    paths::line_to(0.75, 1),
    paths::line_to(0.25, 1),
    paths::line_to(0, 0.5),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! octagon(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.2929, 0),
    paths::line_to(0.7071, 0),
    paths::line_to(1, 0.2929),
    paths::line_to(1, 0.7071),
    paths::line_to(0.7071, 1),
    paths::line_to(0.2929, 1),
    paths::line_to(0, 0.7071),
    paths::line_to(0, 0.2929),
    paths::close_path()
  ), style.fill, style.stroke), size, size)
end

fn/! star(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0),
    paths::line_to(0.6176, 0.3382),
    paths::line_to(0.9755, 0.3455),
    paths::line_to(0.6902, 0.5618),
    paths::line_to(0.7939, 0.9045),
    paths::line_to(0.5, 0.7),
    paths::line_to(0.2061, 0.9045),
    paths::line_to(0.3098, 0.5618),
    paths::line_to(0.0245, 0.3455),
    paths::line_to(0.3824, 0.3382),
    paths::close_path()
  ), style.fill, style.stroke), size, size)
end

fn/! chevron(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0, 0),
    paths::line_to(0.65, 0),
    paths::line_to(1, 0.5),
    paths::line_to(0.65, 1),
    paths::line_to(0, 1),
    paths::line_to(0.35, 0.5),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! arrow_shape(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0, 0.28),
    paths::line_to(0.62, 0.28),
    paths::line_to(0.62, 0),
    paths::line_to(1, 0.5),
    paths::line_to(0.62, 1),
    paths::line_to(0.62, 0.72),
    paths::line_to(0, 0.72),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! plus_shape(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.35, 0),
    paths::line_to(0.65, 0),
    paths::line_to(0.65, 0.35),
    paths::line_to(1, 0.35),
    paths::line_to(1, 0.65),
    paths::line_to(0.65, 0.65),
    paths::line_to(0.65, 1),
    paths::line_to(0.35, 1),
    paths::line_to(0.35, 0.65),
    paths::line_to(0, 0.65),
    paths::line_to(0, 0.35),
    paths::line_to(0.35, 0.35),
    paths::close_path()
  ), style.fill, style.stroke), size, size)
end

fn/! heart(width: Number = 140, height: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.5, 0.92),
    paths::cubic_to(0.42, 0.82, 0.05, 0.6, 0.05, 0.3),
    paths::cubic_to(0.05, 0.08, 0.32, 0, 0.5, 0.2),
    paths::cubic_to(0.68, 0, 0.95, 0.08, 0.95, 0.3),
    paths::cubic_to(0.95, 0.6, 0.58, 0.82, 0.5, 0.92),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! speech_bubble(width: Number = 180, height: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
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
  ), style.fill, style.stroke), width, height)
end

fn/! cloud(width: Number = 180, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shape_size(path_shape_unit(path(
    paths::move_to(0.22, 0.78),
    paths::cubic_to(0.02, 0.78, 0, 0.5, 0.17, 0.42),
    paths::cubic_to(0.13, 0.22, 0.38, 0.1, 0.52, 0.25),
    paths::cubic_to(0.67, 0.08, 0.94, 0.2, 0.89, 0.43),
    paths::cubic_to(1.05, 0.52, 0.96, 0.78, 0.78, 0.78),
    paths::close_path()
  ), style.fill, style.stroke), width, height)
end

fn/! rect(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return rectangle(width, height, style)
end

fn/! rounded_rect(width: Number = 160, height: Number = 100, radius: Number = 0.12, style: VectorStyle = VectorStyle {}) -> Object
  return rounded_rectangle(width, height, radius, style)
end

fn/! triangle_up(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return triangle(width, height, style)
end

fn/! triangle_right(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(paths::move_to(0, 0), paths::line_to(1, 0.5), paths::line_to(0, 1), paths::close_path()), width, height, style)
end

fn/! triangle_down(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(paths::move_to(0, 0), paths::line_to(1, 0), paths::line_to(0.5, 1), paths::close_path()), width, height, style)
end

fn/! triangle_left(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(paths::move_to(1, 0), paths::line_to(0, 0.5), paths::line_to(1, 1), paths::close_path()), width, height, style)
end

fn/! star4(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0.5, 0),
    paths::line_to(0.62, 0.38),
    paths::line_to(1, 0.5),
    paths::line_to(0.62, 0.62),
    paths::line_to(0.5, 1),
    paths::line_to(0.38, 0.62),
    paths::line_to(0, 0.5),
    paths::line_to(0.38, 0.38),
    paths::close_path()
  ), size, size, style)
end

fn/! star5(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return star(size, style)
end

fn/! star6(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0.5, 0),
    paths::line_to(0.62, 0.28),
    paths::line_to(0.93, 0.25),
    paths::line_to(0.75, 0.5),
    paths::line_to(0.93, 0.75),
    paths::line_to(0.62, 0.72),
    paths::line_to(0.5, 1),
    paths::line_to(0.38, 0.72),
    paths::line_to(0.07, 0.75),
    paths::line_to(0.25, 0.5),
    paths::line_to(0.07, 0.25),
    paths::line_to(0.38, 0.28),
    paths::close_path()
  ), size, size, style)
end

fn/! cross_shape(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0.18, 0), paths::line_to(0.5, 0.32), paths::line_to(0.82, 0),
    paths::line_to(1, 0.18), paths::line_to(0.68, 0.5), paths::line_to(1, 0.82),
    paths::line_to(0.82, 1), paths::line_to(0.5, 0.68), paths::line_to(0.18, 1),
    paths::line_to(0, 0.82), paths::line_to(0.32, 0.5), paths::line_to(0, 0.18), paths::close_path()
  ), size, size, style)
end

fn/! chevron_right(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return chevron(width, height, style)
end

fn/! chevron_left(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(1, 0), paths::line_to(0.35, 0), paths::line_to(0, 0.5),
    paths::line_to(0.35, 1), paths::line_to(1, 1), paths::line_to(0.65, 0.5), paths::close_path()
  ), width, height, style)
end

fn/! chevron_down(width: Number = 100, height: Number = 150, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0, 0), paths::line_to(0, 0.65), paths::line_to(0.5, 1),
    paths::line_to(1, 0.65), paths::line_to(1, 0), paths::line_to(0.5, 0.35), paths::close_path()
  ), width, height, style)
end

fn/! chevron_up(width: Number = 100, height: Number = 150, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0, 1), paths::line_to(0, 0.35), paths::line_to(0.5, 0),
    paths::line_to(1, 0.35), paths::line_to(1, 1), paths::line_to(0.5, 0.65), paths::close_path()
  ), width, height, style)
end

fn/! block_arrow_right(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return arrow_shape(width, height, style)
end

fn/! block_arrow_left(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(1, 0.28), paths::line_to(0.38, 0.28), paths::line_to(0.38, 0),
    paths::line_to(0, 0.5), paths::line_to(0.38, 1), paths::line_to(0.38, 0.72),
    paths::line_to(1, 0.72), paths::close_path()
  ), width, height, style)
end

fn/! block_arrow_down(width: Number = 90, height: Number = 170, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0.28, 0), paths::line_to(0.28, 0.62), paths::line_to(0, 0.62),
    paths::line_to(0.5, 1), paths::line_to(1, 0.62), paths::line_to(0.72, 0.62),
    paths::line_to(0.72, 0), paths::close_path()
  ), width, height, style)
end

fn/! block_arrow_up(width: Number = 90, height: Number = 170, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0.28, 1), paths::line_to(0.28, 0.38), paths::line_to(0, 0.38),
    paths::line_to(0.5, 0), paths::line_to(1, 0.38), paths::line_to(0.72, 0.38),
    paths::line_to(0.72, 1), paths::close_path()
  ), width, height, style)
end

fn/! semicircle(width: Number = 140, height: Number = 80, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0, 1), paths::arc_to(0.5, 1, 0, false, true, 1, 1),
    paths::line_to(0, 1), paths::close_path()
  ), width, height, style)
end

fn/! quarter_circle(size: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return path_shape(path(
    paths::move_to(0, 0), paths::line_to(1, 0),
    paths::arc_to(1, 1, 0, false, true, 0, 1), paths::close_path()
  ), size, size, style)
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

fn marker_arrow_filled(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return MarkerStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(1, 0.5),
      paths::line_to(0, 1),
      paths::close_path()
    )
    width = size
    height = size
    fill = fills::solid_fill(color_name)
    stroke = fills::no_stroke()
  }
end

fn marker_triangle(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return marker_arrow_filled(size, color_name)
end

fn marker_circle(size: Number = 9, color_name: Color = c"#4b5563") -> MarkerStyle
  return MarkerStyle {
    path = path(
      paths::move_to(1, 0.5),
      paths::arc_to(0.5, 0.5, 0, false, true, 0, 0.5),
      paths::arc_to(0.5, 0.5, 0, false, true, 1, 0.5),
      paths::close_path()
    )
    width = size
    height = size
    fill = fills::solid_fill(color_name)
    stroke = fills::no_stroke()
  }
end

fn marker_square(size: Number = 9, color_name: Color = c"#4b5563") -> MarkerStyle
  return MarkerStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(1, 0),
      paths::line_to(1, 1),
      paths::line_to(0, 1),
      paths::close_path()
    )
    width = size
    height = size
    fill = fills::solid_fill(color_name)
    stroke = fills::no_stroke()
  }
end

fn marker_diamond(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return MarkerStyle {
    path = path(
      paths::move_to(0, 0.5),
      paths::line_to(0.5, 0),
      paths::line_to(1, 0.5),
      paths::line_to(0.5, 1),
      paths::close_path()
    )
    width = size
    height = size
    fill = fills::solid_fill(color_name)
    stroke = fills::no_stroke()
  }
end

fn marker_bar(size: Number = 10, color_name: Color = c"#4b5563", line_width: Number = 1.6) -> MarkerStyle
  return MarkerStyle {
    path = path(paths::move_to(1, 0), paths::line_to(1, 1))
    width = size
    height = size
    fill = fills::no_fill()
    stroke = fills::vector_stroke(color_name, line_width, LineCap.butt, LineJoin.miter)
  }
end
