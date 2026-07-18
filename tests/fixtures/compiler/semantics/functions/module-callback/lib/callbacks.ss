import std:core/prelude as *

fn make_body!(page_value: Page, label: String) -> Object
  return place_on!(page_value, new(label, "body", "text"))
end

fn add_to_pages!(doc: Document, label: String) -> Void
  foreach(pages(doc), (page_value: Page) |-> make_body!(page_value, label))
end
