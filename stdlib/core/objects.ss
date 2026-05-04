import std:core/layout

fn text_object(text_value: string, role_name: string) -> object
  let obj = object(text_value, role_name, "text")
  return obj
end

fn title_object(text_value: string) -> object
  return text_object(text_value, "title")
end

fn subtitle_object(text_value: string) -> object
  return text_object(text_value, "subtitle")
end

fn body_object(text_value: string) -> object
  return text_object(text_value, "body")
end

fn note_object(text_value: string) -> object
  return text_object(text_value, "note")
end

fn byline_object(text_value: string) -> object
  return text_object(text_value, "byline")
end

fn label_object(text_value: string) -> object
  return text_object(text_value, "label")
end

fn rule_object() -> object
  return text_object("", "rule")
end

fn spacer(height: number, width: number = 1) -> object
  let obj = text_object("", "panel")
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
  return payload_object(text_value, "math", "math_text")
end

fn math_tex_object(text_value: string) -> object
  return payload_object(text_value, "math", "math_tex")
end

fn figure_text_object(text_value: string) -> object
  return payload_object(text_value, "figure", "figure_text")
end

fn image_object(path_value: string) -> object
  return payload_object(path_value, "figure", "image_ref")
end

fn pdf_object(path_value: string) -> object
  return payload_object(path_value, "figure", "pdf_ref")
end

fn code_object(text_value: string) -> object
  let code = payload_object(text_value, "code", "code")
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
