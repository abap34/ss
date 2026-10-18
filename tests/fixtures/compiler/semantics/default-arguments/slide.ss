import std:themes/default as *

fn/! body(content: String, style: TextBlockStyle = current_theme().body) -> Text
  return text(content, style)
end

page main
  body!("Late theme")
end

document
  set_theme(default_theme() with { body.text.size = 22 })
end
