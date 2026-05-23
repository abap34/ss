import std:core/objects

fn compile_math(source: string) -> string ! ExternalProcess | ReadTemp | WriteTemp @host(cache = math_hash(source))

fn op_text(self: object) -> object ! LowerRender @op(draw_text)
fn op_code(self: object) -> object ! LowerRender @op(draw_code_highlight)
fn op_math(self: object) -> object ! LowerRender @op(draw_vector_math)
fn op_vec(self: object) -> object ! LowerRender @op(draw_vector_asset)
fn op_img(self: object) -> object ! LowerRender @op(draw_raster_asset)
fn op_box(self: object) -> object ! LowerRender @op(draw_chrome)
fn op_rule(self: object) -> object ! LowerRender @op(draw_rule)

fn sty(obj: object, style_value: style) -> object
  set_prop(obj, "style", style_value)
  return obj
end

fn clear(obj: object) -> object
  set_content(obj, "")
  return obj
end

fn append(obj: object, text_value: string) -> object
  set_content(obj, content(obj) ++ text_value)
  return obj
end

fn rewrite(obj: object, old_value: string, new_value: string) -> object
  set_content(obj, replace(content(obj), old_value, new_value))
  return obj
end

fn pkg(name: string) -> void
  extend_render_env(docctx(), "add", "math.latex.packages", name)
end

fn page_pkg(name: string) -> void
  extend_render_env(pagectx(), "add", "math.latex.packages", name)
end

fn obj_pkg(obj: object, name: string) -> object
  extend_render_env(obj, "add", "math.latex.packages", name)
  return obj
end

fn link(obj: object, id: string) -> object
  set_prop(obj, "link_id", id)
  return obj
end

fn md_link(label: string, href: string) -> string
  return "[" ++ label ++ "](" ++ href ++ ")"
end

fn scale(obj: object, factor: number) -> object
  set_prop(obj, "asset_scale", str(factor))
  return obj
end

fn txt_p(obj: object, font_name: string, font_size_name: string, line_height_name: string, color_name: string) -> object
  set_prop(obj, "text_font", font_name)
  set_prop(obj, "text_size", font_size_name)
  set_prop(obj, "text_line_height", line_height_name)
  set_prop(obj, "text_color", color_name)
  return obj
end

fn font(obj: object, family_name: string) -> object
  set_prop(obj, "text_font", family_name)
  set_prop(obj, "text_bold_font", family_name ++ " Bold")
  set_prop(obj, "text_italic_font", family_name ++ " Italic")
  return obj
end

fn fonts(obj: object, family_stack: string) -> object
  return font(obj, family_stack)
end

fn code_font(obj: object, family_name: string) -> object
  set_prop(obj, "text_code_font", family_name)
  return obj
end

fn txt_flow(obj: object, font_size_name: string, line_height_name: string, spacing_after_name: string, left_name: string, right_name: string) -> object
  set_prop(obj, "layout_font_size", font_size_name)
  set_prop(obj, "layout_line_height", line_height_name)
  set_prop(obj, "layout_spacing_after", spacing_after_name)
  set_prop(obj, "layout_x", left_name)
  set_prop(obj, "layout_right_inset", right_name)
  set_prop(obj, "wrap", "on")
  return obj
end

fn txt(obj: object, font_name: string, font_size_name: string, line_height_name: string, color_name: string, spacing_after_name: string, left_name: string, right_name: string) -> object
  txt_p(obj, font_name, font_size_name, line_height_name, color_name)
  txt_flow(obj, font_size_name, line_height_name, spacing_after_name, left_name, right_name)
  return obj
end

fn md_code(obj: object, font_size_name: string, line_height_name: string, pad_x_name: string, pad_y_name: string, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  set_prop(obj, "text_markdown_code_font_size", font_size_name)
  set_prop(obj, "text_markdown_code_line_height", line_height_name)
  set_prop(obj, "text_markdown_code_pad_x", pad_x_name)
  set_prop(obj, "text_markdown_code_pad_y", pad_y_name)
  set_prop(obj, "text_markdown_code_fill", fill_name)
  set_prop(obj, "text_markdown_code_stroke", stroke_name)
  set_prop(obj, "text_markdown_code_line_width", line_width_name)
  set_prop(obj, "text_markdown_code_radius", radius_name)
  return obj
end

fn md_table(obj: object, pad_x_name: string, pad_y_name: string, border_name: string, line_width_name: string, header_fill_name: string, alt_row_fill_name: string = "") -> object
  set_prop(obj, "text_markdown_table_cell_pad_x", pad_x_name)
  set_prop(obj, "text_markdown_table_cell_pad_y", pad_y_name)
  set_prop(obj, "text_markdown_table_border", border_name)
  set_prop(obj, "text_markdown_table_line_width", line_width_name)
  set_prop(obj, "text_markdown_table_header_fill", header_fill_name)
  set_prop(obj, "text_markdown_table_alt_row_fill", alt_row_fill_name)
  return obj
end

fn box(obj: object, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  set_prop(obj, "chrome_fill", fill_name)
  set_prop(obj, "chrome_stroke", stroke_name)
  set_prop(obj, "chrome_line_width", line_width_name)
  set_prop(obj, "chrome_radius", radius_name)
  return obj
end

fn under(obj: object, color_name: string, line_width_name: string, offset_name: string) -> object
  set_prop(obj, "underline_color", color_name)
  set_prop(obj, "underline_width", line_width_name)
  set_prop(obj, "underline_offset", offset_name)
  return obj
end

fn rule_l(obj: object, stroke_name: string, line_width_name: string, dash_name: string) -> object
  set_prop(obj, "rule_stroke", stroke_name)
  set_prop(obj, "rule_line_width", line_width_name)
  set_prop(obj, "rule_dash", dash_name)
  return obj
end

fn fit(obj: object, policy_name: string) -> object
  set_prop(obj, "fit", policy_name)
  return obj
end

fn fit_warn(obj: object) -> object
  return fit(obj, "warn")
end

fn fit_error(obj: object) -> object
  return fit(obj, "error")
end

fn fit_ignore(obj: object) -> object
  return fit(obj, "ignore")
end

fn styled(text_value: string, role_name: string, style_value: style) -> object
  let obj = txt_obj(text_value, role_name)
  sty(obj, style_value)
  return obj
end

fn title_as(text_value: string, variant_name: string) -> object
  let obj = title_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn subtitle_as(text_value: string, variant_name: string) -> object
  let obj = sub_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn byline(text_value: string) -> object
  return by_obj(text_value)
end

fn byline_as(text_value: string, variant_name: string) -> object
  let obj = by_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn label(label_style_name: string, text_value: string) -> object
  let obj = lab_obj(text_value)
  sty(obj, style(label_style_name))
  return obj
end

fn rule(rule_style_name: string) -> object
  let obj = rule_obj()
  sty(obj, style(rule_style_name))
  return obj
end
