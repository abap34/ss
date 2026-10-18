import std:text as text
import std:themes/default as base

fn/! text(content: String) -> text::Text
  let theme = base::default_theme()
  return text::text(content, theme.body with {
    text.size = 23
    headings.h2 = text::MarkdownHeadingStyle { text = theme.h2.text with { color = c"#0d7d16" } }
  })
end
