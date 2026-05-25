import std:themes/default

const accent: string = "0.2745,0.5098,0.7059"

fn badge(label_text: string, size: number = 16) -> object
  let item = text("[" ++ label_text ++ "]")
  item.text_size = size
  item.text_color = accent
  return item
end

document
pagenos("{page} / {total}")
end

page syntax_overview
let title = head("Syntax")
let body = text <<
The source uses imports, constants, functions, strings, properties, expressions, and constraints.
>>
let marker = badge("page " ++ str(page_index(pagectx())), 15)

body.text_size = 22
body.text_line_height = 32
flow(body, "102", "102")

below(body, title, 32)
below(marker, body, 20)
same_l(body, title, 0)
same_l(marker, body, 0)
end
