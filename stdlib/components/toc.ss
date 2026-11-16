import std:components/toc/style as { TocStyle }
import std:document/content as { Heading, format_page_number, heading_text }
import std:math/types as { LatexConfig }
import std:text/content as { Text, text_content }
import std:text as { NEWLINE, TextParseMode }
import std:query as query

type Toc {
  title: String
  style: TocStyle = TocStyle {}
  format: (Page, Document) -> String = format_page_number
  include: Placed<Heading> -> Bool = include_heading
}

fn include_heading(item: Placed<Heading>) -> Bool = item.value.level == 1

fn/! toc(title: String, style: TocStyle = TocStyle {}, format: (Page, Document) -> String = format_page_number, include: Placed<Heading> -> Bool = include_heading) -> Toc
  return Toc { title = title style = style format = format include = include }
end

fn display(self: Placed<Toc>) -> Group<Text, Text>
  let style = self.value.style
  let headings = query::filter(select<Heading>(self.document), self.value.include)
  let format = self.value.format
  let body = join(headings, NEWLINE, (item: Placed<Heading>) |-> item.value.title ++ " ... " ++ format(item.page, item.document))
  return heading_text(self.value.title, 1, style.title) // Text { content = text_content(body, LatexConfig {}, TextParseMode.plain) style = style.entries }
end
