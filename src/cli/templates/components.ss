fn cover!(title: String, author: String) -> Placed<Group<Text, Text>>
  let theme = theme_for(pagectx())
  let title_style = theme.h1 with { text.size = 56 text.line_height = 68 }
  let content = (text!(title, title_style) // text!(author, theme.byline)) with { gap = 32 }
  ~ content.left == page.left + 80
  ~ content.right == page.right - 80
  ~ content.center_y == page.center_y

  return content
end

fn footnote!(content: String) -> Placed<Text>
  let note = text!(content, theme_for(pagectx()).note)

  ~ note.left == page.left + 80
  ~ note.right == page.right - 80
  ~ note.bottom == page.bottom + 32

  return note
end
