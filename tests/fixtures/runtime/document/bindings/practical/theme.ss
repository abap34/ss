import std:themes/default as base

fn regular() -> Theme
  return base::default_theme() with { text.size = 18 }
end

fn large() -> Theme
  return regular() with { text.size = 26 }
end

fn footnote_style(theme: Theme) -> TextBlockStyle
  return theme.text with { size = 11 line_height = 14 }
end
