import std:core/classes as classes
import std:core/paths as paths

fn vector_stroke(color_name: Color?, width: Number = 1, cap: LineCap = LineCap.butt, join: LineJoin = LineJoin.miter, dash: String = "", dash_offset: Number = 0) -> VectorStrokeStyle
  return VectorStrokeStyle {
    color = color_name
    width = width
    cap = cap
    join = join
    dash = dash
    dash_offset = dash_offset
  }
end

fn no_stroke() -> VectorStrokeStyle
  return VectorStrokeStyle { color = none }
end

fn solid_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, cap: LineCap = LineCap.butt, join: LineJoin = LineJoin.miter) -> VectorStrokeStyle
  return vector_stroke(color_name, width, cap, join)
end

fn dashed_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, dash: Number = 8, gap: Number = 5) -> VectorStrokeStyle
  return vector_stroke(color_name, width, LineCap.butt, LineJoin.miter, concat(concat(str(dash), ","), str(gap)))
end

fn dotted_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, gap: Number = 4) -> VectorStrokeStyle
  return vector_stroke(color_name, width, LineCap.round, LineJoin.round, concat(concat(str(width), ","), str(gap)))
end

fn dash_dot_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, dash: Number = 8, gap: Number = 4) -> VectorStrokeStyle
  return vector_stroke(color_name, width, LineCap.round, LineJoin.round, concat(concat(concat(concat(concat(concat(str(dash), ","), str(gap)), ","), str(width)), ","), str(gap)))
end

fn vector_style(fill_value: FillStyle = FillStyle {}, stroke_value: VectorStrokeStyle = VectorStrokeStyle {}) -> VectorStyle
  return VectorStyle {
    fill = fill_value
    stroke = stroke_value
  }
end

fn no_fill() -> FillStyle
  return FillStyle {}
end

fn solid_fill(color_name: Color, opacity: Number = 1) -> FillStyle
  return FillStyle {
    kind = FillKind.solid
    color = color_name
    opacity = opacity
  }
end

fn linear_fill(color1: Color, color2: Color, start_x: Number = 0, start_y: Number = 0, end_x: Number = 1, end_y: Number = 1, spread: GradientSpread = GradientSpread.pad, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return FillStyle {
    kind = FillKind.linear
    color = color1
    color2 = color2
    start_x = start_x
    start_y = start_y
    end_x = end_x
    end_y = end_y
    spread = spread
    opacity = opacity
    space = space
  }
end

fn radial_fill(color1: Color, color2: Color, center_x: Number = 0.5, center_y: Number = 0.5, radius: Number = 0.5, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return FillStyle {
    kind = FillKind.radial
    color = color1
    color2 = color2
    start_x = center_x
    start_y = center_y
    start_radius = 0
    end_x = center_x
    end_y = center_y
    end_radius = radius
    opacity = opacity
    space = space
  }
end

fn pattern_fill(pattern_value: PatternStyle, base: FillStyle = FillStyle {}) -> FillStyle
  return base with {
    pattern = pattern_value
  }
end

fn with_pattern(fill_value: FillStyle, pattern_value: PatternStyle) -> FillStyle
  return fill_value with {
    pattern = pattern_value
  }
end

fn gradient_right() -> GradientDirection
  return GradientDirection {}
end

fn gradient_left() -> GradientDirection
  return GradientDirection { start_x = 1 end_x = 0 }
end

fn gradient_down() -> GradientDirection
  return GradientDirection { start_x = 0.5 start_y = 0 end_x = 0.5 end_y = 1 }
end

fn gradient_up() -> GradientDirection
  return GradientDirection { start_x = 0.5 start_y = 1 end_x = 0.5 end_y = 0 }
end

fn gradient_down_right() -> GradientDirection
  return GradientDirection { start_x = 0 start_y = 0 end_x = 1 end_y = 1 }
end

fn gradient_up_right() -> GradientDirection
  return GradientDirection { start_x = 0 start_y = 1 end_x = 1 end_y = 0 }
end

fn gradient_down_left() -> GradientDirection
  return GradientDirection { start_x = 1 start_y = 0 end_x = 0 end_y = 1 }
end

fn gradient_up_left() -> GradientDirection
  return GradientDirection { start_x = 1 start_y = 1 end_x = 0 end_y = 0 }
end

fn linear_gradient_fill(start_color: Color, end_color: Color, direction: GradientDirection = GradientDirection {}, spread: GradientSpread = GradientSpread.pad, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return linear_fill(start_color, end_color, direction.start_x, direction.start_y, direction.end_x, direction.end_y, spread, opacity, space)
end

fn radial_gradient_fill(inner_color: Color, outer_color: Color, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return radial_fill(inner_color, outer_color, 0.5, 0.5, 0.5, opacity, space)
end

fn hatch_up(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(
      paths::move_to(0, spacing),
      paths::line_to(spacing, 0)
    )
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn hatch_down(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(spacing, spacing)
    )
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn crosshatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(spacing, spacing),
      paths::move_to(0, spacing),
      paths::line_to(spacing, 0)
    )
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn horizontal_hatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(paths::move_to(0, 0), paths::line_to(spacing, 0))
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn vertical_hatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(paths::move_to(0, 0), paths::line_to(0, spacing))
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn grid_pattern(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(spacing, 0),
      paths::move_to(0, 0),
      paths::line_to(0, spacing)
    )
    cell_width = spacing
    cell_height = spacing
    stroke = vector_stroke(color_name, width)
  }
end

fn dot_pattern(color_name: Color = c"#4b5563", spacing: Number = 8, radius: Number = 1.2) -> PatternStyle
  let center = div(spacing, 2)
  let k = mul(radius, 0.55228475)
  return PatternStyle {
    path = path(
      paths::move_to(add(center, radius), center),
      paths::cubic_to(add(center, radius), add(center, k), add(center, k), add(center, radius), center, add(center, radius)),
      paths::cubic_to(sub(center, k), add(center, radius), sub(center, radius), add(center, k), sub(center, radius), center),
      paths::cubic_to(sub(center, radius), sub(center, k), sub(center, k), sub(center, radius), center, sub(center, radius)),
      paths::cubic_to(add(center, k), sub(center, radius), add(center, radius), sub(center, k), add(center, radius), center),
      paths::close_path()
    )
    cell_width = spacing
    cell_height = spacing
    fill = color_name
  }
end

fn checker_pattern(color_name: Color = c"#4b5563", cell_size: Number = 8) -> PatternStyle
  let half = div(cell_size, 2)
  return PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(half, 0),
      paths::line_to(half, half),
      paths::line_to(0, half),
      paths::close_path(),
      paths::move_to(half, half),
      paths::line_to(cell_size, half),
      paths::line_to(cell_size, cell_size),
      paths::line_to(half, cell_size),
      paths::close_path()
    )
    cell_width = cell_size
    cell_height = cell_size
    fill = color_name
  }
end

fn wave_pattern(color_name: Color = c"#4b5563", width: Number = 16, height: Number = 8, line_width: Number = 1) -> PatternStyle
  return PatternStyle {
    path = path(
      paths::move_to(0, div(height, 2)),
      paths::cubic_to(div(width, 4), 0, mul(width, 0.75), height, width, div(height, 2))
    )
    cell_width = width
    cell_height = height
    stroke = vector_stroke(color_name, line_width, LineCap.round, LineJoin.round)
  }
end

fn hatch_fill(color_name: Color, background: Color? = none, angle: Number = 45, spacing: Number = 8, width: Number = 1) -> FillStyle
  let pattern_value = PatternStyle {
    path = path(paths::move_to(0, 0), paths::line_to(spacing, 0))
    cell_width = spacing
    cell_height = spacing
    rotation = angle
    stroke = vector_stroke(color_name, width)
  }
  return pattern_fill(pattern_value, FillStyle { kind = FillKind.solid color = background })
end

fn crosshatch_fill(color_name: Color, background: Color? = none, angle: Number = 45, spacing: Number = 8, width: Number = 1) -> FillStyle
  let pattern_value = PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(spacing, 0),
      paths::move_to(0, 0),
      paths::line_to(0, spacing)
    )
    cell_width = spacing
    cell_height = spacing
    rotation = angle
    stroke = vector_stroke(color_name, width)
  }
  return pattern_fill(pattern_value, FillStyle { kind = FillKind.solid color = background })
end

fn grid_fill(color_name: Color, background: Color? = none, spacing: Number = 8, width: Number = 1) -> FillStyle
  return pattern_fill(grid_pattern(color_name, spacing, width), FillStyle { kind = FillKind.solid color = background })
end

fn dots_fill(color_name: Color, background: Color? = none, spacing: Number = 8, diameter: Number = 2) -> FillStyle
  return pattern_fill(dot_pattern(color_name, spacing, div(diameter, 2)), FillStyle { kind = FillKind.solid color = background })
end

fn checker_fill(color_name: Color, background: Color? = none, size: Number = 8) -> FillStyle
  return pattern_fill(checker_pattern(color_name, size), FillStyle { kind = FillKind.solid color = background })
end

fn brick_fill(color_name: Color, background: Color? = none, width: Number = 16, height: Number = 8, line_width: Number = 1) -> FillStyle
  let double_height = mul(height, 2)
  let half_width = div(width, 2)
  let pattern_value = PatternStyle {
    path = path(
      paths::move_to(0, 0),
      paths::line_to(width, 0),
      paths::move_to(0, height),
      paths::line_to(width, height),
      paths::move_to(0, double_height),
      paths::line_to(width, double_height),
      paths::move_to(0, 0),
      paths::line_to(0, height),
      paths::move_to(half_width, height),
      paths::line_to(half_width, double_height)
    )
    cell_width = width
    cell_height = double_height
    stroke = vector_stroke(color_name, line_width)
  }
  return pattern_fill(pattern_value, FillStyle { kind = FillKind.solid color = background })
end

fn waves_fill(color_name: Color, background: Color? = none, spacing: Number = 10, width: Number = 1) -> FillStyle
  return pattern_fill(wave_pattern(color_name, mul(spacing, 2), spacing, width), FillStyle { kind = FillKind.solid color = background })
end

fn stipple_sparse_fill(color_name: Color, background: Color? = none) -> FillStyle
  return dots_fill(color_name, background, 14, 1.6)
end

fn stipple_fill(color_name: Color, background: Color? = none) -> FillStyle
  return dots_fill(color_name, background, 9, 1.8)
end

fn stipple_dense_fill(color_name: Color, background: Color? = none) -> FillStyle
  return dots_fill(color_name, background, 6, 2)
end
