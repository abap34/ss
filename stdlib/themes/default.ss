import std:theme/types as { Theme, ThemeOptions }
import std:code/palettes as palette

fn default_theme(options: ThemeOptions = ThemeOptions {}) -> Theme
  let colors = palette::code_theme_github_light()
  return Theme {} with {
    text.font.family = options.font_family ?? "Helvetica"
    text.color = options.text_color ?? c"0.07,0.08,0.10"
    text.size = 24
    text.line_height = 31
    text.layout.spacing_after = 28
    text.headings.h1.size = 40
    text.markdown.link.color = options.accent_color ?? c"#1a40bf"
    text.markdown.bold.color = options.accent_color ?? c"#0d4d94"
    text.markdown.quote.color = options.muted_color ?? c"#374151"
    text.markdown.quote.fill = c"#f3f6fa"
    text.markdown.quote.bar.color = options.accent_color ?? c"#4f7cac"
    text.code.font.family = options.code_font_family ?? "monospace"
    text.code.chrome.fill = colors.fill
    text.code.chrome.stroke = colors.stroke
    text.math.scale = 1.05
  }
end
