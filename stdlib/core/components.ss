import std:core/classes
import std:core/layout
import std:core/objects
import std:core/render
import std:core/selectors
import std:core/utils
import std:core/generated

fn title(text_value: String) -> Object
  return title_obj(text_value)
end

fn subtitle(text_value: String) -> Object
  return sub_obj(text_value)
end

fn math(text_value: String) -> Object
  return math_obj(text_value)
end

fn mathtex(text_value: String) -> Object
  return tex_obj(text_value)
end

fn panel(style_value: Style) -> Object
  let panel = panel_obj()
  sty(panel, style_value)
  return panel
end

fn page_bg(fill_name: String) -> Void
  pagectx().background_fill = fill_name
end

fn doc_bg(fill_name: String) -> Void
  docctx().background_fill = fill_name
end

fn frame_s(inner: Object, panel_style_name: String, pad_x: Number, pad_y: Number) -> Object
  surround_s(panel_style_name, inner, pad_x, pad_y)
  return inner
end

fn frame(text_value: String, role_name: String, payload_name: String, left: String, right: String, pad_x: Number, pad_y: Number, fill_name: String, stroke_name: String, line_width_name: String, radius_name: String) -> Object
  let inner = raw_obj(text_value, role_name, payload_name)
  flow(inner, left, right)
  let chrome = panel(style("custom"))
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = "34"
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_s(panel_style_name: String, inner: Object, pad_x: Number, pad_y: Number) -> Object
  let chrome = panel(style(panel_style_name))
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn border_p(inner: Object, pad_x: Number, pad_y: Number, fill_name: String, stroke_name: String, line_width: Number, radius: Number) -> Object
  box(inner, fill_name, stroke_name, str(line_width), str(radius))
  inner.chrome_pad_x = str(pad_x)
  inner.chrome_pad_y = str(pad_y)
  return inner
end

fn border(inner: Object, pad_x: Number = 12, pad_y: Number = 8, stroke_name: String = "0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border_p(inner, pad_x, pad_y, "", stroke_name, line_width, radius)
end

fn outline(inner: Object, stroke_name: String = "0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border(inner, 24, 16, stroke_name, line_width, radius)
end

fn code_l(text_value: String, language_name: String) -> Object
  let code = code_obj(text_value)
  code.language = language_name
  return code
end

fn code_in(text_value: String, language_name: String, left: String, right: String) -> Object
  let code = code_l(text_value, language_name)
  flow(code, left, right)
  return code
end

fn code_panel(text_value: String, language_name: String, panel_style_name: String, left: String, right: String, pad_x: Number, pad_y: Number) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel(style(panel_style_name))
  chrome.layout_spacing_after = "34"
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn code_box(text_value: String, language_name: String, left: String, right: String, pad_x: Number, pad_y: Number, fill_name: String, stroke_name: String, line_width_name: String, radius_name: String) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel(style("custom"))
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = "34"
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn text(text_value: String) -> Object
  return body_obj(text_value)
end

fn tex(text_value: String, scale: Number = 1) -> Object
  let obj = flow(tex_obj(text_value), "102", "102")
  obj.math_scale = str(scale)
  return obj
end

fn figure(text_value: String) -> Object
  return flow(fig_obj(text_value), "102", "102")
end

fn image(path_value: String, factor: Number = 1) -> Object
  let obj = scale(flow(img_obj(path_value), "102", "102"), factor)
  require_asset_exists(obj)
  return obj
end

fn pdf(path_value: String, factor: Number = 1) -> Object
  let obj = scale(flow(pdf_obj(path_value), "102", "102"), factor)
  require_asset_exists(obj)
  return obj
end

fn code(text_value: String, language_name: String = "python") -> Object
  let code = code_l(text_value, language_name)
  flow(code, "102", "102")
  return code
end

fn note(text_value: String) -> Object
  return flow(note_obj(text_value), "120", "120")
end

fn citation(target: Object, number: Number, reference_text: String) -> Object
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

fn pageno() -> Object
  let page_no = pageno_obj()
  return page_no
end
