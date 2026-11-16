import std:theme as { theme_for }
import std:text/content as { Text, TextContent, text_content }
import std:text/types as { TextParseMode, SemanticRole, TextSemantics }
import std:text/style as { TextBlockStyle }

type PageNumber {
  format: (Page, Document) -> String = format_page_number
  style: TextBlockStyle? = none
}

fn format_page_number(page: Page, document: Document) -> String
  return str(page_index(page)) ++ "/" ++ str(page_count(document))
end

fn display(self: Placed<PageNumber>) -> Text
  return Text {
    content = TextContent { source = self.value.format(self.page, self.document) parse = TextParseMode.plain }
    style = self.value.style ?? (theme_for(self.page).text with { size = 13 line_height = 16 })
  }
end

type Heading {
  title: String
  level: Number = 1
  style: TextBlockStyle? = none
}

fn heading_text(title: String, level: Number, style: TextBlockStyle? = none) -> Text
  return Text { content = TextContent { source = title parse = TextParseMode.inline heading_level = level } style = style }
end

fn display(self: Placed<Heading>) -> Text
  return heading_text(self.value.title, self.value.level, self.value.style) with {
    semantics = TextSemantics { role = SemanticRole.heading heading_level = self.value.level }
  }
end
