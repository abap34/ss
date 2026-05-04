import std:core/layout

fn text_object(text_value: string, role_name: string) -> object
  let obj = object(text_value, role_name, "text")
  return obj
end

fn text_defaults(obj: object, font_name: string, font_size_name: string, line_height_name: string, color_name: string, spacing_after_name: string, left_name: string, right_name: string, wrap_name: string) -> object
  set_prop(obj, "text_font", font_name)
  set_prop(obj, "text_size", font_size_name)
  set_prop(obj, "text_line_height", line_height_name)
  set_prop(obj, "text_color", color_name)
  set_prop(obj, "layout_font_size", font_size_name)
  set_prop(obj, "layout_line_height", line_height_name)
  set_prop(obj, "layout_spacing_after", spacing_after_name)
  set_prop(obj, "layout_x", left_name)
  set_prop(obj, "layout_right_inset", right_name)
  set_prop(obj, "wrap", wrap_name)
  return obj
end

fn layout_defaults(obj: object, font_size_name: string, line_height_name: string, spacing_after_name: string, left_name: string, right_name: string, wrap_name: string) -> object
  set_prop(obj, "layout_font_size", font_size_name)
  set_prop(obj, "layout_line_height", line_height_name)
  set_prop(obj, "layout_spacing_after", spacing_after_name)
  set_prop(obj, "layout_x", left_name)
  set_prop(obj, "layout_right_inset", right_name)
  set_prop(obj, "wrap", wrap_name)
  return obj
end

fn chrome_defaults(obj: object) -> object
  set_prop(obj, "render_kind", "chrome")
  set_prop(obj, "chrome_line_width", "1")
  set_prop(obj, "chrome_radius", "10")
  return obj
end

fn title_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "title"), "Helvetica", "34", "40", "0,0,0.0353", "54", "72", "72", "on")
end

fn subtitle_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "subtitle"), "Helvetica", "18", "24", "0,0,0.0353", "34", "96", "96", "on")
end

fn body_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "body"), "Helvetica", "20", "28", "0,0,0.0353", "28", "96", "96", "on")
end

fn note_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "note"), "Helvetica", "20", "28", "0,0,0.0353", "24", "96", "96", "on")
end

fn byline_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "byline"), "Helvetica", "20", "26", "0.2745,0.5098,0.7059", "18", "72", "72", "on")
end

fn label_object(text_value: string) -> object
  return text_defaults(text_object(text_value, "label"), "Helvetica", "14", "18", "0.2745,0.5098,0.7059", "0", "72", "72", "off")
end

fn rule_object() -> object
  let obj = text_object("", "rule")
  layout_defaults(obj, "4", "4", "0", "72", "72", "off")
  set_prop(obj, "render_kind", "chrome")
  set_prop(obj, "rule_line_width", "1")
  return obj
end

fn panel_object() -> object
  let obj = text_object("", "panel")
  layout_defaults(obj, "4", "4", "0", "72", "72", "off")
  chrome_defaults(obj)
  return obj
end

fn spacer(height: number, width: number = 1) -> object
  let obj = panel_object()
  fixed_height(obj, height)
  fixed_width(obj, width)
  return obj
end

fn vspace(height: number) -> object
  return spacer(height)
end

fn payload_object(text_value: string, role_name: string, payload_name: string) -> object
  let obj = object(text_value, role_name, payload_name)
  return obj
end

fn math_text_object(text_value: string) -> object
  return text_defaults(payload_object(text_value, "math", "math_text"), "Courier", "18", "24", "0.05,0.05,0.25", "28", "102", "102", "off")
end

fn math_tex_object(text_value: string) -> object
  return text_defaults(payload_object(text_value, "math", "math_tex"), "Courier", "18", "24", "0.05,0.05,0.25", "28", "102", "102", "off")
end

fn figure_text_object(text_value: string) -> object
  return text_defaults(payload_object(text_value, "figure", "figure_text"), "Courier", "16", "20", "0.18,0.18,0.18", "28", "102", "102", "off")
end

fn image_object(path_value: string) -> object
  return layout_defaults(payload_object(path_value, "figure", "image_ref"), "16", "20", "28", "102", "102", "off")
end

fn pdf_object(path_value: string) -> object
  return layout_defaults(payload_object(path_value, "figure", "pdf_ref"), "16", "20", "28", "102", "102", "off")
end

fn code_object(text_value: string) -> object
  let code = payload_object(text_value, "code", "code")
  text_defaults(code, "Courier", "15", "20", "0.12,0.12,0.12", "28", "102", "102", "off")
  set_prop(code, "render_kind", "code")
  set_prop(code, "text_code_font", "Courier")
  set_prop(code, "code_plain_color", "0.12,0.12,0.12")
  set_prop(code, "code_keyword_color", "0.1725,0.3451,0.7882")
  set_prop(code, "code_comment_color", "0.3059,0.5412,0.3608")
  set_prop(code, "code_string_color", "0.6980,0.2549,0.2157")
  return code
end

fn inset_object(text_value: string, role_name: string, payload_name: string, left: number, right: number) -> object
  let obj = payload_object(text_value, role_name, payload_name)
  inset_x(obj, left, right)
  return obj
end

fn inset_text(text_value: string, role_name: string, left: number, right: number) -> object
  let obj = text_object(text_value, role_name)
  inset_x(obj, left, right)
  return obj
end
