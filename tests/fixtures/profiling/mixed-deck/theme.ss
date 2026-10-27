import std:themes/default as { default_theme }
import std:text as native_text
import std:text/style as { TextBlockStyle }
import std:text/types as { MarkdownHeadingStyle, MarkdownHeadingStyles }
import std:math/types as { LatexConfig }

const accent: Color = c"#4682b4"
const theme: Theme = item061()
const latex_config: LatexConfig = LatexConfig { preamble = readlines("preamble.tex") }

fn item061() -> Theme
  let value = default_theme(ThemeOptions {
    font_family = "M PLUS 1p"
    code_font_family = "JuliaMono"
    text_color = c"#000009"
    accent_color = accent
    muted_color = c"#808080"
  }) with {
    body.text.size = 28
    body.text.line_height = 36
    body.text.markdown.bold_color = c"#000009"
    h1.text.size = 44
    h1.text.line_height = 52
    h2.text.size = 34
    h2.text.line_height = 42
    h3.text.size = 28
    h3.text.line_height = 36
    pdf.chrome.stroke = c"#ffffff"
  }
  return value with {
    body.text.markdown.code.colors = value.code.highlight.code
    body.headings = MarkdownHeadingStyles {
      h1 = MarkdownHeadingStyle { text = value.h1.text }
      h2 = MarkdownHeadingStyle { text = value.h2.text }
      h3 = MarkdownHeadingStyle { text = value.h3.text }
      h4 = MarkdownHeadingStyle { text = value.h4.text }
      h5 = MarkdownHeadingStyle { text = value.h5.text }
      h6 = MarkdownHeadingStyle { text = value.h6.text }
    }
  }
end

const head_style: TextBlockStyle = theme.h1 with {
  text.size = 40
  text.line_height = 48
  text.color = accent
  layout.spacing_after = 34
}

const item063: TextBlockStyle = theme.h1 with {
  text.size = 60
  text.line_height = 68
  text.font.weight = 400
  text.color = accent
  layout.spacing_after = 26
}

const item064: TextBlockStyle = theme.h2 with {
  text.size = 34
  text.line_height = 42
  text.font.weight = 700
  text.color = accent
  layout.x = 72
  layout.right_inset = 72
  layout.spacing_after = 24
}

const item065: TextBlockStyle = theme.byline with {
  text.size = 22
  text.line_height = 28
  text.color = accent
}

fn/! text(content: String, style: TextBlockStyle = theme.body, config: LatexConfig = latex_config) -> Text
  return native_text::text(content, style, config)
end

fn item066!(title: String, level: Number = 3) -> Placed<Group<Heading, PathShape>>
  let label = heading!(title, level, head_style)
  let item067 = line!(1136, 2, LineStyle { stroke = solid_stroke(accent, 2) })
  ~ label.left == page.left + 72
  ~ label.top == page.top - 56
  ~ item067.left == label.left
  ~ item067.right == page.right - 72
  ~ item067.top == label.bottom
  return group!(label, item067)
end

fn item068!(title: String) -> Placed<Group<Heading, PathShape>>
  return item066!(title, 2)
end

fn item069!(title: String) -> Placed<Heading>
  let label = heading!(title, 1, item063)
  ~ label.left == page.left + 96
  ~ label.right == page.right - 96
  ~ label.center_y == page.center_y
  return label
end

fn item070!(title: String, subtitle: String, author: String) -> Placed<Group<Text, Text, Text, PathShape>>
  let item071 = text!(title, item063)
  let item072 = text!(subtitle, item064)
  let item073 = text!(author, item065)
  let item067 = line!(160, 2, LineStyle { stroke = solid_stroke(accent, 2) })
  ~ item071.left == page.left + 72
  ~ item071.top == page.top - 148
  ~ item072.left == item071.left
  ~ item072.top == item071.bottom - 28
  ~ item073.left == item072.left
  ~ item073.top == item072.bottom - 40
  ~ item067.left == page.left + 72
  ~ item067.top == item073.bottom - 32
  return group!(item071, item072, item073, item067)
end

fn item074!(content: String) -> Placed<Text>
  let item075 = text!(content, theme.body with { text.size = 16 text.line_height = 20 })
  ~ item075.bottom == page.bottom + 20
  ~ item075.left == page.left + 60
  return item075
end

fn item076!(target: Page) -> Void
  let item075 = place_on!(target, pageno(theme.page_number))
  target ~ item075.right == target.right - 24
  target ~ item075.bottom == target.bottom + 20
end

fn/! item077(content: String, style: TextBlockStyle = theme.body, config: LatexConfig = latex_config) -> Text
  let item078 = style with { text.color = c"#ff0000" }
  return native_text::text(content, item078, config)
end