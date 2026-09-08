import std:themes/default
import std:themes/default as *
import std:core/objects as { body_obj, body_obj! }
import std:themes/base as { ThemeOptions }

@render("text")
fn/! label(text_value: String) -> Object
  let obj = text(text_value)
  return obj
end

page sample
let title = label!("Hello")
let subtitle = default::h2("Qualified")
if title then
  set_prop(title, "text_color", c"#334455")
else
  property title "text_color" c"#111111"
end
~ title.left == page.left + 24
~!~title.center_x
~!~title.left == page.left + 48
text! <<
body
>>
end
