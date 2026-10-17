import std:text as text
import std:theme as theme

fn/! text(content: String) -> Object
  return text::text(content, theme::current_theme() with {
    body.text.size = 23
    h2.text.color = c"#0d7d16"
  })
end
