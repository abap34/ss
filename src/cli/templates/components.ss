import "./theme" as deck

fn cover!(title: String, author: String) -> Placed<Group<Text, Text>>
  let style = theme_for(pagectx()).text
  let title_style = style with { size = 56 line_height = 68 }
  let content = (text!(title, title_style) // text!(author)) with { gap = 32 }
  ~ content.left == page.left + 80
  ~ content.right == page.right - 80
  ~ content.center_y == page.center_y

  return content
end

fn footnote!(content: String) -> Placed<Text>
  let note = text!(content, deck::footnote_style(theme_for(pagectx())))

  ~ note.left == page.left + 80
  ~ note.right == page.right - 80
  ~ note.bottom == page.bottom + 32

  return note
end
