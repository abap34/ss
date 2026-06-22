import std:themes/default as *

fn module_label!(text_value: String, color_name: Color = c"0.07,0.08,0.10") -> Object
  return text!(text_value, 24, color_name)
end
