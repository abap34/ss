import std:core/layout
import std:core/objects
import std:core/render
import std:core/selectors
import std:core/transforms

fn title(text_value: string) -> object
  return title_object(text_value)
end

fn subtitle(text_value: string) -> object
  return subtitle_object(text_value)
end

fn math(text_value: string) -> object
  return math_text_object(text_value)
end

fn mathtex(text_value: string) -> object
  return math_tex_object(text_value)
end

fn panel(style_value: style) -> object
  let panel = text_object("", "panel")
  set_style(panel, style_value)
  return panel
end

fn page_background(fill_name: string) -> object
  let bg = panel(style("custom"))
  set_prop(bg, "chrome_fill", fill_name)
  set_prop(bg, "chrome_line_width", "0")
  set_prop(bg, "chrome_radius", "0")
  left_inset(bg, 0)
  right_inset(bg, 0)
  top_inset(bg, 0)
  bottom_inset(bg, 0)
  return bg
end

fn frame_with_style(inner: object, panel_style_name: string, pad_x: number, pad_y: number) -> object
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn framed_object(text_value: string, role_name: string, payload_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_object(panel_style_name: string, inner: object, pad_x: number, pad_y: number) -> object
  let chrome = panel(style(panel_style_name))
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn panel_block(text_value: string, role_name: string, payload_name: string, panel_style_name: string, left: string, right: string, pad_x: number, pad_y: number) -> object
  let inner = payload_object(text_value, role_name, payload_name)
  flow_inset(inner, left, right)
  surround_object(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn code_with_language(text_value: string, language_name: string) -> object
  let code = code_object(text_value)
  set_prop(code, "language", language_name)
  return code
end

fn python_code_object(text_value: string) -> object
  return code_with_language(text_value, "python")
end

fn inset_code_with_language(text_value: string, language_name: string, left: string, right: string) -> object
  let code = code_with_language(text_value, language_name)
  flow_inset(code, left, right)
  return code
end

fn panel_code_with_language(text_value: string, language_name: string, panel_style_name: string, left: string, right: string, pad_x: number, pad_y: number) -> object
  let code = inset_code_with_language(text_value, language_name, left, right)
  surround_object(panel_style_name, code, pad_x, pad_y)
  return code
end

fn framed_code_with_language(text_value: string, language_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let code = inset_code_with_language(text_value, language_name, left, right)
  let chrome = panel(style("custom"))
  chrome_paint(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn text(text_value: string) -> object
  return body_object(text_value)
end

fn tex(text_value: string, scale: number = 1) -> object
  let obj = flow_inset(math_tex_object(text_value), "102", "102")
  set_prop(obj, "math_scale", str(scale))
  return obj
end

fn figure(text_value: string) -> object
  return flow_inset(figure_text_object(text_value), "102", "102")
end

fn image(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(flow_inset(image_object(path_value), "102", "102"), scale)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: string, scale: number = 1) -> object
  let obj = with_asset_scale(flow_inset(pdf_object(path_value), "102", "102"), scale)
  require_asset_exists(obj)
  return obj
end

fn code(text_value: string, language_name: string = "python") -> object
  let code = code_with_language(text_value, language_name)
  flow_inset(code, "102", "102")
  return code
end

fn note(text_value: string) -> object
  return flow_inset(note_object(text_value), "120", "120")
end

fn page_no() -> object
  let page_no = page_number_object()
  return page_no
end
