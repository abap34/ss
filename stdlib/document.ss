import std:document/numbering as { number_of }
import std:document/content as { PageNumber, format_page_number, Heading, default_heading_style }
import std:text/style
import std:theme as *
import std:internal/document as generated
import std:internal/style as styles

fn pagenos!(format: String? = none, style: TextBlockStyle = current_theme().page_number) -> Void
  generated::mk_pagenos!(docctx(), format, (obj: Object) |-> styles::apply_text_block_style(obj, style))
end

fn/! pageno(style: TextBlockStyle = TextBlockStyle {}, format: (Page, Document) -> String = format_page_number) -> PageNumber
  return PageNumber { style = style format = format }
end

fn/! heading(title: String, level: Number = 1, style: TextBlockStyle = default_heading_style) -> Heading
  return Heading { title = title level = level style = style }
end

fn page_bg(fill_name: Color?) -> Void
  pagectx().background_fill = fill_name
end

fn doc_bg(fill_name: Color?) -> Void
  docctx().background_fill = fill_name
end

fn need_titles() -> Void
  generated::need_titles()
end

fn/! numbered_item(counter_name: String, text_value: String) -> Object
  return generated::numbered_item(counter_name, text_value)
end

fn numbering!(counter_name: String, format: String = "{number}. {text}") -> Void
  generated::numbering!(counter_name, format)
end

fn/! citation(number: Number, reference: String, style: TextBlockStyle = current_theme().citation) -> Object
  return styles::text_object("[" ++ str(number) ++ "] " ++ reference, "citation", style)
end
