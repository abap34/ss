import std:text as text
import std:text as { default_text_style }

fn/! text(content: String) -> text::Text
  return text::text(content, default_text_style with {
    text.size = 23
    headings.h2 = text::MarkdownHeadingStyle { text = text::TextStyle { color = c"#0d7d16" } }
  })
end
