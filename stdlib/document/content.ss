import std:theme as { theme_for, Theme }
import std:text/content as { Text, text_content }
import std:text/types as { SemanticRole, TextSemantics }
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
    content = text_content(self.value.format(self.page, self.document))
    style = self.value.style ?? theme_for(self.page).page_number
  }
end

const default_heading_style: TextBlockStyle = TextBlockStyle {} with { text.size = 36 }

type Heading {
  title: String
  level: Number = 1
  style: TextBlockStyle? = none
}

fn heading_style(theme: Theme, level: Number) -> TextBlockStyle
  if level == 2
    return theme.h2
  end
  if level == 3
    return theme.h3
  end
  if level == 4
    return theme.h4
  end
  if level == 5
    return theme.h5
  end
  if level == 6
    return theme.h6
  end
  return theme.h1
end

fn display(self: Placed<Heading>) -> Text
  return Text {
    content = text_content(self.value.title)
    style = self.value.style ?? heading_style(theme_for(self.page), self.value.level)
    semantics = TextSemantics { role = SemanticRole.heading heading_level = self.value.level }
  }
end
