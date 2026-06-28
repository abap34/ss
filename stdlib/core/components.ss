import std:core/classes as *
import std:core/layout as *
import std:core/objects as *
import std:core/render as *
import std:core/selectors as *
import std:core/utils as *
import std:core/generated as *

fn/! title(text_value: String) -> Object
  return title_obj(text_value)
end

fn/! subtitle(text_value: String) -> Object
  return sub_obj(text_value)
end

fn/! math(text_value: String, scale: Number = 1) -> Object
  let obj = math_obj(text_value)
  obj.math_scale = scale
  return obj
end

fn/! mathtex(text_value: String) -> Object
  return math_obj(text_value)
end

fn/! panel() -> Object
  return panel_obj()
end

fn/! byline(text_value: String) -> Object
  return by_obj(text_value)
end

fn/! label(text_value: String) -> Object
  return lab_obj(text_value)
end

fn/! rule() -> Object
  return rule_obj()
end

fn page_bg(fill_name: Color?) -> Void
  pagectx().background_fill = fill_name
end

fn doc_bg(fill_name: Color?) -> Void
  docctx().background_fill = fill_name
end

fn/! frame_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  surround_s(inner, pad_x, pad_y)
  return inner
end

fn/! frame(text_value: String, role_name: String, payload_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  let inner = raw_obj(text_value, role_name, payload_name)
  inner.layout_x = left
  inner.layout_right_inset = right
  inner.wrap = WrapMode.on
  let chrome = panel()
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = 34
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn surround_s(inner: Object, pad_x: Number, pad_y: Number) -> Object
  let chrome = panel()
  surround(chrome, inner, pad_x, pad_y)
  return inner
end

fn border_p(inner: Object, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width: Number, radius: Number) -> Object
  box(inner, fill_name, stroke_name, line_width, radius)
  inner.chrome_pad_x = pad_x
  inner.chrome_pad_y = pad_y
  return inner
end

fn border(inner: Object, pad_x: Number = 12, pad_y: Number = 8, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border_p(inner, pad_x, pad_y, none, stroke_name, line_width, radius)
end

fn outline(inner: Object, stroke_name: Color? = c"0.36,0.40,0.48", line_width: Number = 1, radius: Number = 8) -> Object
  return border(inner, 24, 16, stroke_name, line_width, radius)
end

fn/! code_l(text_value: String, language_name: String) -> Object
  let code = code_obj(text_value)
  code.language = language_name
  return code
end

fn code_in(text_value: String, language_name: String, left: Number, right: Number) -> Object
  let code = code_l(text_value, language_name)
  code.layout_x = left
  code.layout_right_inset = right
  code.wrap = WrapMode.on
  return code
end

fn code_panel(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel()
  chrome.layout_spacing_after = 34
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn code_box(text_value: String, language_name: String, left: Number, right: Number, pad_x: Number, pad_y: Number, fill_name: Color?, stroke_name: Color?, line_width_name: Number, radius_name: Number) -> Object
  let code = code_in(text_value, language_name, left, right)
  let chrome = panel()
  box(chrome, fill_name, stroke_name, line_width_name, radius_name)
  chrome.layout_spacing_after = 34
  surround(chrome, code, pad_x, pad_y)
  return code
end

fn/! text(text_value: String) -> Object
  return body_obj(text_value)
end

fn/! tex(text_value: String, scale: Number = 1) -> Object
  let obj = tex_obj(text_value)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  obj.math_scale = scale
  return obj
end

fn/! figure(text_value: String) -> Object
  let obj = fig_obj(text_value)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  return obj
end

fn/! image(path_value: String, factor: Number = 1) -> Object
  let obj = scale(img_obj(path_value), factor)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  require_asset_exists(obj)
  return obj
end

fn/! pdf(path_value: String, factor: Number = 1) -> Object
  let obj = scale(pdf_obj(path_value), factor)
  obj.layout_x = 102
  obj.layout_right_inset = 102
  obj.wrap = WrapMode.on
  require_asset_exists(obj)
  return obj
end

fn/! code(text_value: String, language_name: String = "python") -> Object
  let code = code_l(text_value, language_name)
  code.layout_x = 102
  code.layout_right_inset = 102
  code.wrap = WrapMode.on
  return code
end

fn/! code_file(path_value: String, language_name: String = "plain") -> Object
  return code(readlines(path_value), language_name)
end

fn/! note(text_value: String) -> Object
  let obj = note_obj(text_value)
  obj.layout_x = 120
  obj.layout_right_inset = 120
  obj.wrap = WrapMode.on
  return obj
end

fn/! citation(target: Object, number: Number, reference_text: String) -> Object
  let number_text = str(number)
  let marker = "[" ++ number_text ++ "]"
  let id = "citation:" ++ str(page_index(pagectx())) ++ ":" ++ number_text

  let ref = link(cite_obj(marker ++ " " ++ reference_text), id)
  ref.layout_x = 120
  ref.layout_right_inset = 90
  ref.wrap = WrapMode.on
  ~ ref.top == page.top - add(632, mul(sub(number, 1), 20))
  return ref
end

fn/! pageno() -> Object
  let page_no = pageno_obj()
  return page_no
end
