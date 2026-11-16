import std:themes/default as { default_theme }

const accent: Color = c"#2563eb"
const theme: Theme = default_theme(ThemeOptions { accent_color = accent }) with {
  text.size = 26
  text.line_height = 38
  text.layout.left_inset = 80
  text.layout.right_inset = 80
  text.headings.h1.color = accent
  text.code.size = 22
}

fn footnote_style(t: Theme) -> TextBlockStyle
  return t.text with { size = 16 line_height = 18 }
end
