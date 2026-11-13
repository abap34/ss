import std:themes/default as { default_theme }

const accent: Color = c"#2563eb"
const theme: Theme = default_theme(ThemeOptions {
  font_family = "Helvetica"
  accent_color = accent
}) with {
  body.text.size = 26
  body.text.line_height = 38
  body.layout.x = 80
  body.layout.right_inset = 80
  h1.text.color = accent
  h1.layout.x = 80
  h1.layout.right_inset = 80
  code.text.size = 22
  code.layout.x = 80
  code.layout.right_inset = 80
}
