import std:document/numbering as { number_of }
import std:document/content as { PageNumber, format_page_number, Heading, default_heading_style }
import std:document/settings
import std:text/style

fn note!(content: String) -> Void
  pagectx().notes = content
end

fn/! pageno(style: TextBlockStyle = TextBlockStyle {}, format: (Page, Document) -> String = format_page_number) -> PageNumber
  return PageNumber { style = style format = format }
end

fn/! heading(title: String, level: Number = 1, style: TextBlockStyle = default_heading_style) -> Heading
  return Heading { title = title level = level style = style }
end
