import "./theme" as deck

type Card {
  title: String
  peer: Ref<Placed<Card>>
}

fn display(self: Placed<Card>) -> Text
  let peer = *self.value.peer
  let caption = self.value.title ++ " -> " ++ peer.value.title ++ " / " ++ str(page_index(peer.page))
  return text(caption, theme_for(self.page).text)
end

fn/! card(title: String, peer: Ref<Placed<Card>>) -> Card
  return Card { title = title peer = peer }
end

fn footnote!(content: String) -> Placed<Text>
  let note = text!(content, deck::footnote_style(theme_for(pagectx())))
  ~ note.left == page.left + 80
  ~ note.bottom == page.bottom + 32
  return note
end

fn title(card: Placed<Card>) -> String = card.value.title
