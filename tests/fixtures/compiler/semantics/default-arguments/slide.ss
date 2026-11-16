import std:themes/default as *

fn/! body(content: String, style: TextBlockStyle = presentation.text) -> Text
  return text(content, style)
end

page main
  body!("Forward theme")
end

const presentation: Theme = default_theme() with { text.size = 22 }
