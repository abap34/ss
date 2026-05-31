import std:core/objects

fn compile_math(source: String) -> String ! ExternalProcess | ReadTemp | WriteTemp @host(cache = math_hash(source))

fn op_text(self: Object) -> Object ! LowerRender @op(draw_text)
fn op_code(self: Object) -> Object ! LowerRender @op(draw_code_highlight)
fn op_math(self: Object) -> Object ! LowerRender @op(draw_vector_math)
fn op_vec(self: Object) -> Object ! LowerRender @op(draw_vector_asset)
fn op_img(self: Object) -> Object ! LowerRender @op(draw_raster_asset)
fn op_box(self: Object) -> Object ! LowerRender @op(draw_chrome)
fn op_rule(self: Object) -> Object ! LowerRender @op(draw_rule)

fn sty(obj: Object, style_value: Style) -> Object
  obj.style = style_value
  return obj
end

fn clear(obj: Object) -> Object
  obj.content = ""
  return obj
end

fn append(obj: Object, text_value: String) -> Object
  obj.content = obj.content ++ text_value
  return obj
end

fn rewrite(obj: Object, old_value: String, new_value: String) -> Object
  obj.content = replace(obj.content, old_value, new_value)
  return obj
end

fn pkg(name: String) -> Void
  extend_render_env(docctx(), "add", "math.latex.packages", name)
end

fn page_pkg(name: String) -> Void
  extend_render_env(pagectx(), "add", "math.latex.packages", name)
end

fn obj_pkg(obj: Object, name: String) -> Object
  extend_render_env(obj, "add", "math.latex.packages", name)
  return obj
end

fn link(obj: Object, id: String) -> Object
  obj.link_id = id
  return obj
end

fn md_link(label: String, href: String) -> String
  return "[" ++ label ++ "](" ++ href ++ ")"
end

fn scale(obj: Object, factor: Number) -> Object
  obj.asset_scale = str(factor)
  return obj
end

fn txt_p(obj: Object, font_name: String, font_size_name: String, line_height_name: String, color_name: String) -> Object
  obj.text_font = font_name
  obj.text_size = font_size_name
  obj.text_line_height = line_height_name
  obj.text_color = color_name
  return obj
end

fn font(obj: Object, family_name: String) -> Object
  obj.text_font = family_name
  obj.text_bold_font = family_name ++ " Bold"
  obj.text_italic_font = family_name ++ " Italic"
  return obj
end

fn fonts(obj: Object, family_stack: String) -> Object
  return font(obj, family_stack)
end

fn code_font(obj: Object, family_name: String) -> Object
  obj.text_code_font = family_name
  return obj
end

fn txt_flow(obj: Object, font_size_name: String, line_height_name: String, spacing_after_name: String, left_name: String, right_name: String) -> Object
  obj.layout_font_size = font_size_name
  obj.layout_line_height = line_height_name
  obj.layout_spacing_after = spacing_after_name
  obj.layout_x = left_name
  obj.layout_right_inset = right_name
  obj.wrap = "on"
  return obj
end

fn txt(obj: Object, font_name: String, font_size_name: String, line_height_name: String, color_name: String, spacing_after_name: String, left_name: String, right_name: String) -> Object
  txt_p(obj, font_name, font_size_name, line_height_name, color_name)
  txt_flow(obj, font_size_name, line_height_name, spacing_after_name, left_name, right_name)
  return obj
end

fn md_code(obj: Object, font_size_name: String, line_height_name: String, pad_x_name: String, pad_y_name: String, fill_name: String, stroke_name: String, line_width_name: String, radius_name: String) -> Object
  obj.text_markdown_code_font_size = font_size_name
  obj.text_markdown_code_line_height = line_height_name
  obj.text_markdown_code_pad_x = pad_x_name
  obj.text_markdown_code_pad_y = pad_y_name
  obj.text_markdown_code_fill = fill_name
  obj.text_markdown_code_stroke = stroke_name
  obj.text_markdown_code_line_width = line_width_name
  obj.text_markdown_code_radius = radius_name
  return obj
end

fn md_table(obj: Object, pad_x_name: String, pad_y_name: String, border_name: String, line_width_name: String, header_fill_name: String, alt_row_fill_name: String = "") -> Object
  obj.text_markdown_table_cell_pad_x = pad_x_name
  obj.text_markdown_table_cell_pad_y = pad_y_name
  obj.text_markdown_table_border = border_name
  obj.text_markdown_table_line_width = line_width_name
  obj.text_markdown_table_header_fill = header_fill_name
  obj.text_markdown_table_alt_row_fill = alt_row_fill_name
  return obj
end

fn box(obj: Object, fill_name: String, stroke_name: String, line_width_name: String, radius_name: String) -> Object
  obj.chrome_fill = fill_name
  obj.chrome_stroke = stroke_name
  obj.chrome_line_width = line_width_name
  obj.chrome_radius = radius_name
  return obj
end

fn under(obj: Object, color_name: String, line_width_name: String, offset_name: String) -> Object
  obj.underline_color = color_name
  obj.underline_width = line_width_name
  obj.underline_offset = offset_name
  return obj
end

fn rule_l(obj: Object, stroke_name: String, line_width_name: String, dash_name: String) -> Object
  obj.rule_stroke = stroke_name
  obj.rule_line_width = line_width_name
  obj.rule_dash = dash_name
  return obj
end

fn fit(obj: Object, policy_name: String) -> Object
  obj.fit = policy_name
  return obj
end

fn fit_warn(obj: Object) -> Object
  return fit(obj, "warn")
end

fn fit_error(obj: Object) -> Object
  return fit(obj, "error")
end

fn fit_ignore(obj: Object) -> Object
  return fit(obj, "ignore")
end

fn styled(text_value: String, role_name: String, style_value: Style) -> Object
  let obj = txt_obj(text_value, role_name)
  sty(obj, style_value)
  return obj
end

fn title_as(text_value: String, variant_name: String) -> Object
  let obj = title_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn subtitle_as(text_value: String, variant_name: String) -> Object
  let obj = sub_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn byline(text_value: String) -> Object
  return by_obj(text_value)
end

fn byline_as(text_value: String, variant_name: String) -> Object
  let obj = by_obj(text_value)
  sty(obj, style(variant_name))
  return obj
end

fn label(label_style_name: String, text_value: String) -> Object
  let obj = lab_obj(text_value)
  sty(obj, style(label_style_name))
  return obj
end

fn rule(rule_style_name: String) -> Object
  let obj = rule_obj()
  sty(obj, style(rule_style_name))
  return obj
end
