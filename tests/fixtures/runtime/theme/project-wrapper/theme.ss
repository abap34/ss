import std:text as text
import std:themes/default as base

fn/! text(content: String) -> text::Text
  let theme = base::default_theme()
  return text::text(content, theme.text with {
    size = 23
    headings.h2.color = c"#0d7d16"
  })
end
