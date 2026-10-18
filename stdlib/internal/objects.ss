import std:internal/classes

fn/! obj(text_value: String, role_name: String, payload_name: String) -> Object
  return new(text_value, role_name, payload_name)
end

fn/! txt_obj(text_value: String, role_name: String) -> Object
  return obj(text_value, role_name, "text")
end

fn/! body_obj(text_value: String) -> Object
  return txt_obj(text_value, "body")
end
