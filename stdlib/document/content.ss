import std:text/content as { Text }
import std:text/style as { TextBlockStyle }

type PageNumber {
  format: (Page, Document) -> String = format_page_number
  style: TextBlockStyle = TextBlockStyle {}
}

fn format_page_number(page: Page, document: Document) -> String
  return str(page_index(page)) ++ "/" ++ str(page_count(document))
end

fn display(self: Placed<PageNumber>) -> Text
  return Text {
    content = self.value.format(self.page, self.document)
    style = self.value.style
  }
end

const default_heading_style: TextBlockStyle = TextBlockStyle {} with { text.size = 36 }

type Heading {
  title: String
  level: Number = 1
  style: TextBlockStyle = default_heading_style
}

fn display(self: Placed<Heading>) -> Text
  return Text { content = self.value.title style = self.value.style }
end
