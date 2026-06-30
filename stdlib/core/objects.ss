fn/! obj(text_value: String, role_name: String, payload_name: String) -> Object
  return new(text_value, role_name, payload_name)
end

fn place!(obj: Object) -> Object
  return place_on!(pagectx(), obj)
end

fn/! txt_obj(text_value: String, role_name: String) -> Object
  return obj(text_value, role_name, "text")
end

fn/! title_obj(text_value: String) -> Object
  return txt_obj(text_value, "title")
end

fn/! sub_obj(text_value: String) -> Object
  return txt_obj(text_value, "subtitle")
end

fn/! body_obj(text_value: String) -> Object
  return txt_obj(text_value, "body")
end

fn/! note_obj(text_value: String) -> Object
  return txt_obj(text_value, "note")
end

fn/! by_obj(text_value: String) -> Object
  return txt_obj(text_value, "byline")
end

fn/! lab_obj(text_value: String) -> Object
  return txt_obj(text_value, "label")
end

fn/! cite_obj(text_value: String) -> Object
  return txt_obj(text_value, "citation")
end

fn/! rule_obj() -> Object
  let obj = txt_obj("", "rule")
  return obj
end

fn/! shape_obj() -> Object
  let obj = txt_obj("", "shape")
  return obj
end

fn/! panel_obj() -> Object
  let obj = txt_obj("", "panel")
  return obj
end

fn spacer(height: Number, width: Number = 1) -> Object
  let obj = panel_obj()
  ~ obj.height == height
  ~ obj.width == width
  return obj
end

fn vspace(height: Number) -> Object
  return spacer(height)
end

fn/! raw_obj(text_value: String, role_name: String, payload_name: String) -> Object
  return obj(text_value, role_name, payload_name)
end

fn/! math_obj(text_value: String) -> Object
  return raw_obj(text_value, "math", "math_text")
end

fn/! tex_obj(text_value: String) -> Object
  return raw_obj(text_value, "math_tex", "math_tex")
end

fn/! fig_obj(text_value: String) -> Object
  return raw_obj(text_value, "figure", "figure_text")
end

fn/! img_obj(path_value: String) -> Object
  return raw_obj(path_value, "image", "image_ref")
end

fn/! pdf_obj(path_value: String) -> Object
  return raw_obj(path_value, "pdf", "pdf_ref")
end

fn/! code_obj(text_value: String) -> Object
  let code = raw_obj(text_value, "code", "code")
  return code
end
