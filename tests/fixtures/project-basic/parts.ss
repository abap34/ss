import std:themes/default as *

fn module_label!(text_value: String, color_name: Color = c"0.07,0.08,0.10") -> Placed<Text>
  return text!(text_value, default_theme().body with {
    text.size = 24
    text.color = color_name
  })
end
