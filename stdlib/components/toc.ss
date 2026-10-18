import std:components/toc/style as { TocStyle }
import std:document/content as { Heading, format_page_number }
import std:text/content as { Text }
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
  let headings = query::filter(select<Heading>(self.document), self.value.include)
  let format = self.value.format
  let body = join(headings, "
", (item: Placed<Heading>) |-> item.value.title ++ " ... " ++ format(item.page, item.document))
  return Text { content = self.value.title style = self.value.style.title } // Text { content = body style = self.value.style.body }
end
