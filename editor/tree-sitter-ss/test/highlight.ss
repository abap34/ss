import std:themes/default

@render("text")
fn label(text_value: string) -> object
  let obj = text(text_value)
  return obj
end

page sample
let title = label("Hello")
if title then
  set_prop(title, "text_color", c"#334455")
else
  property title "text_color" c"#111111"
end
~ title.left == page.left + 24
end
