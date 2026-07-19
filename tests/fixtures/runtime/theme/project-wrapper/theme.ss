import std:themes/default as default

fn/! text(content: String) -> Object
  return default::text(content, default::current_theme() with {
    body.text.size = 23
    h2.text.color = c"#0d7d16"
  })
end
