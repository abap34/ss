import std:text as typography
import std:themes/default as base
import std:layout/types as layout

fn/! styled(content: String, style: typography::TextBlockStyle) -> typography::Text
  return typography::Text { content = content style = style }
end

page styles
  let theme = base::default_theme()
  let body = theme.body with {
    text.parse = typography::TextParseMode.block
    text.size = 22
    text.line_height = 30
    layout.x = 72
    layout.right_inset = 72
    headings.h1 = typography::MarkdownHeadingStyle { text = theme.h1.text }
  }
  let first = styled!("# Typed text", body)
  let paragraph = styled!("**Markdown** and *inline emphasis* use the same immutable block style as the surrounding slide. This paragraph wraps within the page margins while retaining its own font and line height.", body)
  let label = styled!("An independently styled underline", body with {
    text.parse = typography::TextParseMode.plain
    layout.wrap = layout::WrapMode.off
    underline.color = c"#3156a6"
    underline.width = 2
    underline.offset = -5
  })
  ~ first.left == page.left + 72
  ~ first.top == page.top - 72
  ~ paragraph.left == first.left
  ~ paragraph.top == first.bottom - 30
  ~ label.left == first.left
  ~ label.top == paragraph.bottom - 40
end
