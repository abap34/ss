import std:core/classes as classes
import std:core/layout as layout
import std:core/objects as objects
import std:core/paths as paths
import std:core/fills as fills
import std:core/shapes as shapes
import std:core/connectors as connectors
import std:core/render as render
import std:core/selectors as selectors
import std:core/utils as utils
import std:core/generated as generated
import std:core/components as components

fn move_to(x: Number, y: Number) -> PathCommand
  return paths::move_to(x, y)
end

fn line_to(x: Number, y: Number) -> PathCommand
  return paths::line_to(x, y)
end

fn quadratic_to(control_x: Number, control_y: Number, x: Number, y: Number) -> PathCommand
  return paths::quadratic_to(control_x, control_y, x, y)
end

fn cubic_to(control1_x: Number, control1_y: Number, control2_x: Number, control2_y: Number, x: Number, y: Number) -> PathCommand
  return paths::cubic_to(control1_x, control1_y, control2_x, control2_y, x, y)
end

fn arc_to(radius_x: Number, radius_y: Number, rotation: Number, large_arc: Bool, clockwise: Bool, x: Number, y: Number) -> PathCommand
  return paths::arc_to(radius_x, radius_y, rotation, large_arc, clockwise, x, y)
end

fn close_path() -> PathCommand
  return paths::close_path()
end

fn vector_stroke(color_name: Color?, width: Number = 1, cap: LineCap = LineCap.butt, join: LineJoin = LineJoin.miter, dash: String = "", dash_offset: Number = 0) -> VectorStrokeStyle
  return fills::vector_stroke(color_name, width, cap, join, dash, dash_offset)
end

fn no_stroke() -> VectorStrokeStyle
  return fills::no_stroke()
end

fn solid_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, cap: LineCap = LineCap.butt, join: LineJoin = LineJoin.miter) -> VectorStrokeStyle
  return fills::solid_stroke(color_name, width, cap, join)
end

fn dashed_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, dash: Number = 8, gap: Number = 5) -> VectorStrokeStyle
  return fills::dashed_stroke(color_name, width, dash, gap)
end

fn dotted_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, gap: Number = 4) -> VectorStrokeStyle
  return fills::dotted_stroke(color_name, width, gap)
end

fn dash_dot_stroke(color_name: Color = c"#4b5563", width: Number = 1.6, dash: Number = 8, gap: Number = 4) -> VectorStrokeStyle
  return fills::dash_dot_stroke(color_name, width, dash, gap)
end

fn vector_style(fill_value: FillStyle = FillStyle {}, stroke_value: VectorStrokeStyle = VectorStrokeStyle {}) -> VectorStyle
  return fills::vector_style(fill_value, stroke_value)
end

fn no_fill() -> FillStyle
  return fills::no_fill()
end

fn solid_fill(color_name: Color, opacity: Number = 1) -> FillStyle
  return fills::solid_fill(color_name, opacity)
end

fn linear_fill(color1: Color, color2: Color, start_x: Number = 0, start_y: Number = 0, end_x: Number = 1, end_y: Number = 1, spread: GradientSpread = GradientSpread.pad, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return fills::linear_fill(color1, color2, start_x, start_y, end_x, end_y, spread, opacity, space)
end

fn radial_fill(color1: Color, color2: Color, center_x: Number = 0.5, center_y: Number = 0.5, radius: Number = 0.5, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return fills::radial_fill(color1, color2, center_x, center_y, radius, opacity, space)
end

fn pattern_fill(pattern_value: PatternStyle, base: FillStyle = FillStyle {}) -> FillStyle
  return fills::pattern_fill(pattern_value, base)
end

fn with_pattern(fill_value: FillStyle, pattern_value: PatternStyle) -> FillStyle
  return fills::with_pattern(fill_value, pattern_value)
end

fn hatch_up(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::hatch_up(color_name, spacing, width)
end

fn hatch_down(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::hatch_down(color_name, spacing, width)
end

fn crosshatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::crosshatch(color_name, spacing, width)
end

fn horizontal_hatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::horizontal_hatch(color_name, spacing, width)
end

fn vertical_hatch(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::vertical_hatch(color_name, spacing, width)
end

fn grid_pattern(color_name: Color = c"#4b5563", spacing: Number = 8, width: Number = 1) -> PatternStyle
  return fills::grid_pattern(color_name, spacing, width)
end

fn dot_pattern(color_name: Color = c"#4b5563", spacing: Number = 8, radius: Number = 1.2) -> PatternStyle
  return fills::dot_pattern(color_name, spacing, radius)
end

fn checker_pattern(color_name: Color = c"#4b5563", cell_size: Number = 8) -> PatternStyle
  return fills::checker_pattern(color_name, cell_size)
end

fn wave_pattern(color_name: Color = c"#4b5563", width: Number = 16, height: Number = 8, line_width: Number = 1) -> PatternStyle
  return fills::wave_pattern(color_name, width, height, line_width)
end

fn gradient_right() -> GradientDirection
  return fills::gradient_right()
end

fn gradient_left() -> GradientDirection
  return fills::gradient_left()
end

fn gradient_down() -> GradientDirection
  return fills::gradient_down()
end

fn gradient_up() -> GradientDirection
  return fills::gradient_up()
end

fn gradient_down_right() -> GradientDirection
  return fills::gradient_down_right()
end

fn gradient_up_right() -> GradientDirection
  return fills::gradient_up_right()
end

fn gradient_down_left() -> GradientDirection
  return fills::gradient_down_left()
end

fn gradient_up_left() -> GradientDirection
  return fills::gradient_up_left()
end

fn linear_gradient_fill(start_color: Color, end_color: Color, direction: GradientDirection = GradientDirection {}, spread: GradientSpread = GradientSpread.pad, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return fills::linear_gradient_fill(start_color, end_color, direction, spread, opacity, space)
end

fn radial_gradient_fill(inner_color: Color, outer_color: Color, opacity: Number = 1, space: PaintSpace = PaintSpace.local) -> FillStyle
  return fills::radial_gradient_fill(inner_color, outer_color, opacity, space)
end

fn hatch_fill(color_name: Color, background: Color? = none, angle: Number = 45, spacing: Number = 8, width: Number = 1) -> FillStyle
  return fills::hatch_fill(color_name, background, angle, spacing, width)
end

fn crosshatch_fill(color_name: Color, background: Color? = none, angle: Number = 45, spacing: Number = 8, width: Number = 1) -> FillStyle
  return fills::crosshatch_fill(color_name, background, angle, spacing, width)
end

fn grid_fill(color_name: Color, background: Color? = none, spacing: Number = 8, width: Number = 1) -> FillStyle
  return fills::grid_fill(color_name, background, spacing, width)
end

fn dots_fill(color_name: Color, background: Color? = none, spacing: Number = 8, diameter: Number = 2) -> FillStyle
  return fills::dots_fill(color_name, background, spacing, diameter)
end

fn checker_fill(color_name: Color, background: Color? = none, size: Number = 8) -> FillStyle
  return fills::checker_fill(color_name, background, size)
end

fn brick_fill(color_name: Color, background: Color? = none, width: Number = 16, height: Number = 8, line_width: Number = 1) -> FillStyle
  return fills::brick_fill(color_name, background, width, height, line_width)
end

fn waves_fill(color_name: Color, background: Color? = none, spacing: Number = 10, width: Number = 1) -> FillStyle
  return fills::waves_fill(color_name, background, spacing, width)
end

fn stipple_sparse_fill(color_name: Color, background: Color? = none) -> FillStyle
  return fills::stipple_sparse_fill(color_name, background)
end

fn stipple_fill(color_name: Color, background: Color? = none) -> FillStyle
  return fills::stipple_fill(color_name, background)
end

fn stipple_dense_fill(color_name: Color, background: Color? = none) -> FillStyle
  return fills::stipple_dense_fill(color_name, background)
end

fn/! path_shape_unit(path_value: Path, fill_value: FillStyle = FillStyle {}, stroke_value: VectorStrokeStyle = VectorStrokeStyle {}) -> Object
  return shapes::path_shape_unit(path_value, fill_value, stroke_value)
end

fn/! path_shape(path_value: Path, width: Number, height: Number, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::path_shape(path_value, width, height, style)
end

fn shape_size(obj: Object, width: Number, height: Number) -> Object
  return shapes::shape_size(obj, width, height)
end

fn/! line(width: Number = 160, height: Number = 1, style: LineStyle = LineStyle {}) -> Object
  return shapes::line(width, height, style)
end

fn/! rectangle(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::rectangle(width, height, style)
end

fn/! rounded_rectangle(width: Number = 160, height: Number = 100, radius: Number = 0.12, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::rounded_rectangle(width, height, radius, style)
end

fn/! ellipse(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::ellipse(width, height, style)
end

fn/! circle(diameter: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::circle(diameter, style)
end

fn/! capsule(width: Number = 180, height: Number = 80, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::capsule(width, height, style)
end

fn/! triangle(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::triangle(width, height, style)
end

fn/! right_triangle(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::right_triangle(width, height, style)
end

fn/! diamond(width: Number = 120, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::diamond(width, height, style)
end

fn/! parallelogram(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::parallelogram(width, height, style)
end

fn/! trapezoid(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::trapezoid(width, height, style)
end

fn/! pentagon(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::pentagon(size, style)
end

fn/! hexagon(width: Number = 150, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::hexagon(width, height, style)
end

fn/! octagon(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::octagon(size, style)
end

fn/! star(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::star(size, style)
end

fn/! chevron(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::chevron(width, height, style)
end

fn/! arrow_shape(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::arrow_shape(width, height, style)
end

fn/! plus_shape(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::plus_shape(size, style)
end

fn/! heart(width: Number = 140, height: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::heart(width, height, style)
end

fn/! speech_bubble(width: Number = 180, height: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::speech_bubble(width, height, style)
end

fn/! cloud(width: Number = 180, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::cloud(width, height, style)
end

fn/! rect(width: Number = 160, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::rect(width, height, style)
end

fn/! rounded_rect(width: Number = 160, height: Number = 100, radius: Number = 0.12, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::rounded_rect(width, height, radius, style)
end

fn/! triangle_up(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::triangle_up(width, height, style)
end

fn/! triangle_right(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::triangle_right(width, height, style)
end

fn/! triangle_down(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::triangle_down(width, height, style)
end

fn/! triangle_left(width: Number = 120, height: Number = 110, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::triangle_left(width, height, style)
end

fn/! star4(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::star4(size, style)
end

fn/! star5(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::star5(size, style)
end

fn/! star6(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::star6(size, style)
end

fn/! cross_shape(size: Number = 120, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::cross_shape(size, style)
end

fn/! chevron_right(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::chevron_right(width, height, style)
end

fn/! chevron_left(width: Number = 150, height: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::chevron_left(width, height, style)
end

fn/! chevron_down(width: Number = 100, height: Number = 150, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::chevron_down(width, height, style)
end

fn/! chevron_up(width: Number = 100, height: Number = 150, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::chevron_up(width, height, style)
end

fn/! block_arrow_right(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::block_arrow_right(width, height, style)
end

fn/! block_arrow_left(width: Number = 170, height: Number = 90, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::block_arrow_left(width, height, style)
end

fn/! block_arrow_down(width: Number = 90, height: Number = 170, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::block_arrow_down(width, height, style)
end

fn/! block_arrow_up(width: Number = 90, height: Number = 170, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::block_arrow_up(width, height, style)
end

fn/! semicircle(width: Number = 140, height: Number = 80, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::semicircle(width, height, style)
end

fn/! quarter_circle(size: Number = 100, style: VectorStyle = VectorStyle {}) -> Object
  return shapes::quarter_circle(size, style)
end

fn marker_arrow_open(size: Number = 10, color_name: Color = c"#4b5563", line_width: Number = 1.6) -> MarkerStyle
  return shapes::marker_arrow_open(size, color_name, line_width)
end

fn marker_arrow_filled(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return shapes::marker_arrow_filled(size, color_name)
end

fn marker_triangle(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return shapes::marker_triangle(size, color_name)
end

fn marker_circle(size: Number = 9, color_name: Color = c"#4b5563") -> MarkerStyle
  return shapes::marker_circle(size, color_name)
end

fn marker_square(size: Number = 9, color_name: Color = c"#4b5563") -> MarkerStyle
  return shapes::marker_square(size, color_name)
end

fn marker_diamond(size: Number = 10, color_name: Color = c"#4b5563") -> MarkerStyle
  return shapes::marker_diamond(size, color_name)
end

fn marker_bar(size: Number = 10, color_name: Color = c"#4b5563", line_width: Number = 1.6) -> MarkerStyle
  return shapes::marker_bar(size, color_name, line_width)
end

fn default_connector_style() -> ConnectorStyle
  return connectors::default_connector_style()
end

fn/! connector(source: Object, target: Object, style: ConnectorStyle = connectors::default_connector_style()) -> Object
  return connectors::connector(source, target, style)
end

fn/! connect(source: Object, target: Object, style: ConnectorStyle = connectors::default_connector_style()) -> Object
  return connectors::connect(source, target, style)
end

fn/! connect_straight(source: Object, target: Object, style: ConnectorStyle = connectors::default_connector_style()) -> Object
  return connectors::connect_straight(source, target, style)
end

fn/! connect_orthogonal(source: Object, target: Object, style: ConnectorStyle = connectors::default_connector_style()) -> Object
  return connectors::connect_orthogonal(source, target, style)
end

fn/! connect_curve(source: Object, target: Object, style: ConnectorStyle = connectors::default_connector_style()) -> Object
  return connectors::connect_curve(source, target, style)
end

fn/! straight_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connectors::straight_connector(source, target, stroke_value)
end

fn/! horizontal_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connectors::horizontal_connector(source, target, stroke_value)
end

fn/! vertical_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connectors::vertical_connector(source, target, stroke_value)
end

fn/! curve_connector(source: Object, target: Object, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }) -> Object
  return connectors::curve_connector(source, target, stroke_value)
end

fn/! arrow_connector(source: Object, target: Object, route: ConnectorRoute = ConnectorRoute.straight, source_anchor: ConnectorAnchor = ConnectorAnchor.right, target_anchor: ConnectorAnchor = ConnectorAnchor.left, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }, marker_size: Number = 10) -> Object
  return connectors::arrow_connector(source, target, route, source_anchor, target_anchor, stroke_value, marker_size)
end

fn/! double_arrow_connector(source: Object, target: Object, route: ConnectorRoute = ConnectorRoute.straight, source_anchor: ConnectorAnchor = ConnectorAnchor.right, target_anchor: ConnectorAnchor = ConnectorAnchor.left, stroke_value: VectorStrokeStyle = VectorStrokeStyle { color = c"#4b5563" width = 1.6 }, marker_size: Number = 10) -> Object
  return connectors::double_arrow_connector(source, target, route, source_anchor, target_anchor, stroke_value, marker_size)
end

fn vflow(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  layout::vflow(policy, center_offset)
end

fn vflow_doc(policy: LayoutPolicy, center_offset: Number = 0) -> Void
  layout::vflow_doc(policy, center_offset)
end

fn cols2_parts(left: Object, right: Object, spec: Cols = Cols {}) -> Cols2
  return layout::cols2_parts(left, right, spec)
end

fn cols2(left: Object, right: Object, spec: Cols = Cols {}) -> Object
  return layout::cols2(left, right, spec)
end

fn surround(panel: Object, inner: Object, pad_x: Number, pad_y: Number) -> Void
  layout::surround(panel, inner, pad_x, pad_y)
end

fn/! obj(text_value: String, role_name: String, payload_name: String) -> Object
  return objects::obj(text_value, role_name, payload_name)
end

fn place!(obj: Object) -> Object
  return objects::place!(obj)
end

fn/! txt_obj(text_value: String, role_name: String) -> Object
  return objects::txt_obj(text_value, role_name)
end

fn/! title_obj(text_value: String) -> Object
  return objects::title_obj(text_value)
end

fn/! sub_obj(text_value: String) -> Object
  return objects::sub_obj(text_value)
end

fn/! body_obj(text_value: String) -> Object
  return objects::body_obj(text_value)
end

fn/! note_obj(text_value: String) -> Object
  return objects::note_obj(text_value)
end

fn/! by_obj(text_value: String) -> Object
  return objects::by_obj(text_value)
end

fn/! lab_obj(text_value: String) -> Object
  return objects::lab_obj(text_value)
end

fn/! cite_obj(text_value: String) -> Object
  return objects::cite_obj(text_value)
end

fn/! rule_obj() -> Object
  return objects::rule_obj()
end

fn/! path_obj(path_value: Path) -> Object
  return objects::path_obj(path_value)
end

fn/! panel_obj() -> Object
  return objects::panel_obj()
end

fn spacer(height: Number, width: Number = 1) -> Object
  return objects::spacer(height, width)
end

fn vspace(height: Number) -> Object
  return objects::vspace(height)
end

fn/! raw_obj(text_value: String, role_name: String, payload_name: String) -> Object
  return objects::raw_obj(text_value, role_name, payload_name)
end

fn/! math_obj(text_value: String) -> Object
  return objects::math_obj(text_value)
end

fn/! tex_obj(text_value: String) -> Object
  return objects::tex_obj(text_value)
end

fn/! fig_obj(text_value: String) -> Object
  return objects::fig_obj(text_value)
end

fn/! img_obj(path_value: String) -> Object
  return objects::img_obj(path_value)
end

fn/! pdf_obj(path_value: String) -> Object
  return objects::pdf_obj(path_value)
end

fn/! icon_obj(source: String) -> Object
  return objects::icon_obj(source)
end

fn/! code_obj(text_value: String) -> Object
  return objects::code_obj(text_value)
end

fn tex_engine(engine: TexEngine) -> Void
  render::tex_engine(engine)
end

fn page_tex_engine(engine: TexEngine) -> Void
  render::page_tex_engine(engine)
end

fn tex_preamble(src: String) -> Void
  render::tex_preamble(src)
end

fn page_tex_preamble(src: String) -> Void
  render::page_tex_preamble(src)
end

fn tex_preamble_file(path: String) -> Void
  render::tex_preamble_file(path)
end

fn page_tex_preamble_file(path: String) -> Void
  render::page_tex_preamble_file(path)
end

fn link(obj: Object, id: String) -> Object
  return render::link(obj, id)
end

fn md_link(label: String, href: String) -> String
  return render::md_link(label, href)
end

fn scale(obj: Object, factor: Number) -> Object
  return render::scale(obj, factor)
end

fn md_code(obj: Object, font_size_name: Number, line_height_name: Number, pad_x_name: Number, pad_y_name: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return render::md_code(obj, font_size_name, line_height_name, pad_x_name, pad_y_name, fill_name, stroke_name, line_width_name, radius_name)
end

fn code_theme_github_light() -> CodeHighlightTheme
  return render::code_theme_github_light()
end

fn code_theme_github_dark() -> CodeHighlightTheme
  return render::code_theme_github_dark()
end

fn code_theme_solarized_light() -> CodeHighlightTheme
  return render::code_theme_solarized_light()
end

fn code_theme_solarized_dark() -> CodeHighlightTheme
  return render::code_theme_solarized_dark()
end

fn code_theme_one_dark() -> CodeHighlightTheme
  return render::code_theme_one_dark()
end

fn code_theme_monokai() -> CodeHighlightTheme
  return render::code_theme_monokai()
end

fn code_theme(obj: Object, theme: CodeHighlightTheme) -> Object
  return render::code_theme(obj, theme)
end

fn code_theme_all(theme: CodeHighlightTheme) -> Void
  render::code_theme_all(theme)
end

fn code_theme_page(theme: CodeHighlightTheme) -> Void
  render::code_theme_page(theme)
end

fn md_bold(obj: Object, color_name: Color?) -> Object
  return render::md_bold(obj, color_name)
end

fn md_underline_style(color_name: Color? = none, opacity_name: Number = 1, width_name: Number? = none, offset_name: Number = 0, dash_name: String = "") -> MarkdownUnderlineStyle
  return render::md_underline_style(color_name, opacity_name, width_name, offset_name, dash_name)
end

fn md_underline(obj: Object, style: MarkdownUnderlineStyle = MarkdownUnderlineStyle {}) -> Object
  return render::md_underline(obj, style)
end

fn md_quote(obj: Object, style: MarkdownQuoteStyle = MarkdownQuoteStyle {}) -> Object
  return render::md_quote(obj, style)
end

fn md_table(obj: Object, pad_x_name: Number, pad_y_name: Number, border_name: Color, line_width_name: Number, header_fill_name: Color, alt_row_fill_name: Color? = none) -> Object
  return render::md_table(obj, pad_x_name, pad_y_name, border_name, line_width_name, header_fill_name, alt_row_fill_name)
end

fn box(obj: Object, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return render::box(obj, fill_name, stroke_name, line_width_name, radius_name)
end

fn under(obj: Object, color_name: Color?, line_width_name: Number, offset_name: Number) -> Object
  return render::under(obj, color_name, line_width_name, offset_name)
end

fn rule_l(obj: Object, stroke_name: Color?, line_width_name: Number, dash_name: String) -> Object
  return render::rule_l(obj, stroke_name, line_width_name, dash_name)
end

fn fit(obj: Object, policy_name: FitPolicy) -> Object
  return render::fit(obj, policy_name)
end

fn fit_warn(obj: Object) -> Object
  return render::fit_warn(obj)
end

fn fit_error(obj: Object) -> Object
  return render::fit_error(obj)
end

fn fit_ignore(obj: Object) -> Object
  return render::fit_ignore(obj)
end

fn prev_page() -> Page
  return selectors::prev_page()
end

fn objs(page_value: Page, role_name: String) -> Selection<Object>
  return selectors::objs(page_value, role_name)
end

fn objs_here(role_name: String) -> Selection<Object>
  return selectors::objs_here(role_name)
end

fn children(base: Object) -> Selection<Object>
  return selectors::children(base)
end

fn desc(base: Object) -> Selection<Object>
  return selectors::desc(base)
end

fn doc_pages() -> Selection<Page>
  return selectors::doc_pages()
end

fn pages(doc: Document) -> Selection<Page>
  return selectors::pages(doc)
end

fn objs_all(role_name: String) -> Selection<Object>
  return selectors::objs_all(role_name)
end

fn doc_objs(doc: Document, role_name: String) -> Selection<Object>
  return selectors::doc_objs(doc, role_name)
end

fn page_of(obj: Object) -> Page
  return selectors::page_of(obj)
end

fn union(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::union(left, right)
end

fn intersect(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::intersect(left, right)
end

fn diff(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selectors::diff(left, right)
end

fn math_align(obj: Object, align_name: Align) -> Object
  return utils::math_align(obj, align_name)
end

fn left_math(obj: Object) -> Object
  return utils::left_math(obj)
end

fn center_math(obj: Object) -> Object
  return utils::center_math(obj)
end

fn right_math(obj: Object) -> Object
  return utils::right_math(obj)
end

fn math_align_all(align_name: Align) -> Void
  utils::math_align_all(align_name)
end

fn raw_tex_width_ratio_all(ratio: Number) -> Void
  utils::raw_tex_width_ratio_all(ratio)
end

fn left_math_all() -> Void
  utils::left_math_all()
end

fn center_math_all() -> Void
  utils::center_math_all()
end

fn right_math_all() -> Void
  utils::right_math_all()
end

fn math_align_objects(items: Selection<Object>, align_name: Align) -> Selection<Object>
  return utils::math_align_objects(items, align_name)
end

fn pageno_s(page_no: Object) -> Object
  return generated::pageno_s(page_no)
end

fn/! pageno_obj() -> Object
  return generated::pageno_obj()
end

fn pagenos!(format: String? = none) -> Void
  generated::pagenos!(format)
end

fn footers!(text_value: String) -> Void
  generated::footers!(text_value)
end

fn logos!(path_value: String, scale: Number = 1) -> Void
  generated::logos!(path_value, scale)
end

fn watermark!(text_value: String) -> Void
  generated::watermark!(text_value)
end

fn need_titles() -> Void
  generated::need_titles()
end

fn numbered_item_role(counter_name: String) -> String
  return generated::numbered_item_role(counter_name)
end

fn/! numbered_item(counter_name: String, text_value: String) -> Object
  return generated::numbered_item(counter_name, text_value)
end

fn numbered_item_repr(item: Object) -> String
  return generated::numbered_item_repr(item)
end

fn set_numbered_item(item: Object, index: Number, format: String) -> Object
  return generated::set_numbered_item(item, index, format)
end

fn numbering!(counter_name: String, format: String = "{number}. {text}") -> Void
  generated::numbering!(counter_name, format)
end

fn mk_pagenos!(doc: Document, format: String?) -> Void
  generated::mk_pagenos!(doc, format)
end

fn mk_pageno!(page_value: Page, doc: Document, format: String?) -> Page
  return generated::mk_pageno!(page_value, doc, format)
end

fn set_pagenos(doc: Document) -> Void
  generated::set_pagenos(doc)
end

fn set_pageno(page_no: Object, doc: Document, format: String?) -> Object
  return generated::set_pageno(page_no, doc, format)
end

fn pageno_repr(page_no: Object) -> String
  return generated::pageno_repr(page_no)
end

fn mk_footers!(doc: Document, text_value: String) -> Void
  generated::mk_footers!(doc, text_value)
end

fn mk_footer!(page_value: Page, text_value: String) -> Page
  return generated::mk_footer!(page_value, text_value)
end

fn mk_logos!(doc: Document, path_value: String, scale: Number) -> Void
  generated::mk_logos!(doc, path_value, scale)
end

fn mk_logo!(page_value: Page, path_value: String, scale: Number) -> Page
  return generated::mk_logo!(page_value, path_value, scale)
end

fn mk_marks!(doc: Document, text_value: String) -> Void
  generated::mk_marks!(doc, text_value)
end

fn mk_mark!(page_value: Page, text_value: String) -> Page
  return generated::mk_mark!(page_value, text_value)
end

fn toc_obj() -> Object
  return generated::toc_obj()
end

fn set_tocs(doc: Document) -> Void
  generated::set_tocs(doc)
end

fn toc_row(title: Object, page_value: Page) -> String
  return generated::toc_row(title, page_value)
end

fn toc_text(doc: Document) -> String
  return generated::toc_text(doc)
end

fn set_toc(toc: Object, doc: Document) -> Object
  return generated::set_toc(toc, doc)
end

fn toc_repr(toc: Object) -> String
  return generated::toc_repr(toc)
end

fn chk_titles(doc: Document) -> Void
  generated::chk_titles(doc)
end

fn warn_title(page_value: Page) -> Page
  return generated::warn_title(page_value)
end

fn/! title(text_value: String) -> Object
  return components::title(text_value)
end

fn/! subtitle(text_value: String) -> Object
  return components::subtitle(text_value)
end

fn/! math(text_value: String, scale: Number = 1) -> Object
  return components::math(text_value, scale)
end

fn/! mathtex(text_value: String) -> Object
  return components::mathtex(text_value)
end

fn/! panel() -> Object
  return components::panel()
end

fn/! byline(text_value: String) -> Object
  return components::byline(text_value)
end

fn/! label(text_value: String) -> Object
  return components::label(text_value)
end

fn/! rule() -> Object
  return components::rule()
end

fn/! callout_text(text_value: String, style: CalloutStyle) -> Object
  return components::callout_text(text_value, style)
end

fn/! callout_bar(color_name: Color?, thickness: Number) -> Object
  return components::callout_bar(color_name, thickness)
end

fn/! callout_hbar(color_name: Color?, thickness: Number) -> Object
  return components::callout_hbar(color_name, thickness)
end

fn/! callout_vbar(color_name: Color?, thickness: Number) -> Object
  return components::callout_vbar(color_name, thickness)
end

fn/! callout_left_bracket(inner: Object, style: CalloutStyle) -> Object
  return components::callout_left_bracket(inner, style)
end

fn/! bracket_callout(target: Object, text_value: String, x: Number, top_y: Number, width: Number, style: CalloutStyle = CalloutStyle {}) -> Object
  return components::bracket_callout(target, text_value, x, top_y, width, style)
end

fn/! marked_callout_text(text_value: String, color_name: Color, weight: Number, size: Number, line_height: Number) -> Object
  return components::marked_callout_text(text_value, color_name, weight, size, line_height)
end

fn marked_callout!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return components::marked_callout!(source_text, target_text, note_text, style)
end

fn annotate!(source_text: String, target_text: String, note_text: String, style: MarkedCalloutStyle = MarkedCalloutStyle {}) -> Object
  return components::annotate!(source_text, target_text, note_text, style)
end

fn page_bg(fill_name: Color?) -> Void
  components::page_bg(fill_name)
end

fn doc_bg(fill_name: Color?) -> Void
  components::doc_bg(fill_name)
end

fn/! frame_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  return components::frame_s(inner, pad_x, pad_y)
end

fn/! frame(text_value: String, role_name: String, payload_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return components::frame(text_value, role_name, payload_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name)
end

fn surround_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  return components::surround_s(inner, pad_x, pad_y)
end

fn border_p(inner: Object, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width: Number, radius: Number) -> Object
  return components::border_p(inner, pad_x, pad_y, fill_name, stroke_name, line_width, radius)
end

fn border(inner: Object, pad_x: Number = 12, pad_y: Number = 8, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return components::border(inner, pad_x, pad_y, stroke_name, line_width, radius)
end

fn outline(inner: Object, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return components::outline(inner, stroke_name, line_width, radius)
end

fn/! code_l(text_value: String, language_name: String) -> Object
  return components::code_l(text_value, language_name)
end

fn code_in(text_value: String, language_name: String, left: Number, right: Number) -> Object
  return components::code_in(text_value, language_name, left, right)
end

fn code_panel(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number) -> Object
  return components::code_panel(text_value, language_name, left, right, pad_x, pad_y)
end

fn code_box(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  return components::code_box(text_value, language_name, left, right, pad_x, pad_y, fill_name, stroke_name, line_width_name, radius_name)
end

fn/! text(text_value: String) -> Object
  return components::text(text_value)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  return components::tex(text_value, scale)
end

fn/! figure(text_value: String) -> Object
  return components::figure(text_value)
end

fn/! image(path_value: String, factor: Number = 1) -> Object
  return components::image(path_value, factor)
end

fn/! pdf(path_value: String, factor: Number = 1, page_number: Number = 1, page_box: PdfPageBox = PdfPageBox.crop) -> Object
  return components::pdf(path_value, factor, page_number, page_box)
end

fn/! icon(source: String, width: Number = 72, height: Number = 72, color: Color = c"#374151") -> Object
  return components::icon(source, width, height, color)
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  return components::code(text_value, language_name)
end

fn/! code_file(path_value: String, language_name: String = "plain") -> Object
  return components::code_file(path_value, language_name)
end

fn/! note(text_value: String) -> Object
  return components::note(text_value)
end

fn/! citation(target: Object, number: Number, reference_text: String) -> Object
  return components::citation(target, number, reference_text)
end

fn/! pageno() -> Object
  return components::pageno()
end
