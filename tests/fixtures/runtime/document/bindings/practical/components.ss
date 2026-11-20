import "./theme" as deck

type Claim { title: String }

fn display(self: Placed<Claim>) -> Text
  let claims = select<Claim>(self.document)
  return text("Claim " ++ str(number_of(self, claims) ?? 0) ++ ": " ++ self.value.title)
end

fn footnote!(content: String) -> Placed<Text>
  let item = text!(content, deck::footnote_style(theme_for(pagectx())))
  ~ item.left == page.left + 72
  ~ item.bottom == page.bottom + 32
  return item
end

fn add_page_number!(target: Page) -> Void
  let item = place_on!(target, pageno())
  target ~ item.right == target.right - 32
  target ~ item.bottom == target.bottom + 32
end

fn add_pageno_all!(doc: Document) -> Void
  let pages = pages(doc)
  foreach(pages, (page: Page) |-> add_page_number!(page))
end
