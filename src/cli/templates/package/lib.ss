fn/! label(content: String, color: Color = c"#2563eb") -> Text
  return text(content, default_text_style with {
    color = color
    size = 28
  })
end
