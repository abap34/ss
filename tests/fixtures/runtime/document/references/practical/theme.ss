const regular: Theme = Theme {} with {
  text.size = 17
  text.line_height = 23
}

const large: Theme = regular with {
  text.size = 29
  text.line_height = 35
}

fn footnote_style(t: Theme) -> TextBlockStyle
  return t.text with { size = 11 line_height = 15 }
end
