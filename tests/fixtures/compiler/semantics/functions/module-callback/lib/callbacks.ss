import std:prelude as *

fn make_body!(page_value: Page, label: String) -> Placed<Text>
  return place_on!(page_value, text(label))
end

fn add_to_pages!(doc: Document, label: String) -> Void
  foreach(pages(doc), (page_value: Page) |-> make_body!(page_value, label))
end
