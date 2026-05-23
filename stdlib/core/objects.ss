import std:core/layout

fn obj(text_value: string, role_name: string, payload_name: string) -> object
  return new_object(pagectx(), text_value, role_name, payload_name)
end

fn txt_obj(text_value: string, role_name: string) -> object
  return obj(text_value, role_name, "text")
end

fn title_obj(text_value: string) -> object
  return txt_obj(text_value, "title")
end

fn sub_obj(text_value: string) -> object
  return txt_obj(text_value, "subtitle")
end

fn body_obj(text_value: string) -> object
  return txt_obj(text_value, "body")
end

fn note_obj(text_value: string) -> object
  return txt_obj(text_value, "note")
end

fn by_obj(text_value: string) -> object
  return txt_obj(text_value, "byline")
end

fn lab_obj(text_value: string) -> object
  return txt_obj(text_value, "label")
end

fn cite_obj(text_value: string) -> object
  return txt_obj(text_value, "citation")
end

fn rule_obj() -> object
  let obj = txt_obj("", "rule")
  return obj
end

fn panel_obj() -> object
  let obj = txt_obj("", "panel")
  return obj
end

fn spacer(height: number, width: number = 1) -> object
  let obj = panel_obj()
  fix_h(obj, height)
  fix_w(obj, width)
  return obj
end

fn vspace(height: number) -> object
  return spacer(height)
end

fn raw_obj(text_value: string, role_name: string, payload_name: string) -> object
  return obj(text_value, role_name, payload_name)
end

fn math_obj(text_value: string) -> object
  return raw_obj(text_value, "math", "math_text")
end

fn tex_obj(text_value: string) -> object
  return raw_obj(text_value, "math_tex", "math_tex")
end

fn fig_obj(text_value: string) -> object
  return raw_obj(text_value, "figure", "figure_text")
end

fn img_obj(path_value: string) -> object
  return raw_obj(path_value, "image", "image_ref")
end

fn pdf_obj(path_value: string) -> object
  return raw_obj(path_value, "pdf", "pdf_ref")
end

fn code_obj(text_value: string) -> object
  let code = raw_obj(text_value, "code", "code")
  return code
end
