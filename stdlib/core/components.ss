import std:core/classes
import std:core/layout
import std:core/objects
import std:core/render
import std:core/selectors
import std:core/generated

fn title(text_value: string) -> object
  return title_obj(text_value)
end

fn subtitle(text_value: string) -> object
  return sub_obj(text_value)
end

fn math(text_value: string) -> object
  return math_obj(text_value)
end

fn mathtex(text_value: string) -> object
  return tex_obj(text_value)
end

fn panel(style_value: style) -> object
  let panel = panel_obj()
  sty(panel, style_value)
  return panel
end

fn page_bg(fill_name: string) -> void
  set_prop(pagectx(), "background_fill", fill_name)
end

fn doc_bg(fill_name: string) -> void
  set_prop(docctx(), "background_fill", fill_name)
end

fn frame_s(inner: object, panel_style_name: string, pad_x: number, pad_y: number) -> object
  surround_s(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn frame(text_value: string, role_name: string, payload_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let inner = raw_obj(text_value, role_name, payload_name)
  flow(inner, left, right)
  let chrome = panel(style("custom"))
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_s(panel_style_name: string, inner: object, pad_x: number, pad_y: number) -> object
  let chrome = panel(style(panel_style_name))
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn border_p(inner: object, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width: number, radius: number) -> object
  box(inner, fill_name, stroke_name, str(line_width), str(radius))
  set_prop(inner, "chrome_pad_x", str(pad_x))
  set_prop(inner, "chrome_pad_y", str(pad_y))
  return inner
end

fn border(inner: object, pad_x: number = 12, pad_y: number = 8, stroke_name: string = "0.36,0.40,0.48", line_width: number = 1, radius: number = 8) -> object
  return border_p(inner, pad_x, pad_y, "", stroke_name, line_width, radius)
end

fn outline(inner: object, stroke_name: string = "0.36,0.40,0.48", line_width: number = 1, radius: number = 8) -> object
  return border(inner, 24, 16, stroke_name, line_width, radius)
end

fn code_l(text_value: string, language_name: string) -> object
  let code = code_obj(text_value)
  set_prop(code, "language", language_name)
  return code
end

fn code_in(text_value: string, language_name: string, left: string, right: string) -> object
  let code = code_l(text_value, language_name)
  flow(code, left, right)
  return code
end

fn code_panel(text_value: string, language_name: string, panel_style_name: string, left: string, right: string, pad_x: number, pad_y: number) -> object
  let code = code_in(text_value, language_name, left, right)
  surround_s(panel_style_name, code, pad_x, pad_y)
  return code
end

fn code_box(text_value: string, language_name: string, left: string, right: string, pad_x: number, pad_y: number, fill_name: string, stroke_name: string, line_width_name: string, radius_name: string) -> object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel(style("custom"))
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn text(text_value: string) -> object
  return body_obj(text_value)
end

fn tex(text_value: string, scale: number = 1) -> object
  let obj = flow(tex_obj(text_value), "102", "102")
  set_prop(obj, "math_scale", str(scale))
  return obj
end

fn figure(text_value: string) -> object
  return flow(fig_obj(text_value), "102", "102")
end

fn image(path_value: string, factor: number = 1) -> object
  let obj = scale(flow(img_obj(path_value), "102", "102"), factor)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: string, factor: number = 1) -> object
  let obj = scale(flow(pdf_obj(path_value), "102", "102"), factor)
  require_asset_exists(obj)
  return obj
end

fn code(text_value: string, language_name: string = "python") -> object
  let code = code_l(text_value, language_name)
  flow(code, "102", "102")
  return code
end

fn note(text_value: string) -> object
  return flow(note_obj(text_value), "120", "120")
end

fn citation(target: object, number: number, reference_text: string) -> object
  let number_text = str(number)
  let marker = "[" ++ number_text ++ "]"
  let escaped_marker = "\\[" ++ number_text ++ "\\]"
  let id = "citation:" ++ str(page_index(pagectx())) ++ ":" ++ number_text
  rewrite(target, marker, md_link(escaped_marker, "#" ++ id))

  let ref = link(cite_obj(marker ++ " " ++ reference_text), id)
  inset_x(ref, 120, 90)
  pin_t(ref, add(632, mul(sub(number, 1), 20)))
  return ref
end

fn pageno() -> object
  let page_no = pageno_obj()
  return page_no
end
