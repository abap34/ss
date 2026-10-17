import std:themes/default
import std:themes/default as *
import std:internal/objects as { body_obj, body_obj! }
import std:theme/types as { ThemeOptions }

@render("markdown")
fn/! label(text_value: String) -> Object
  let obj = markdown(text_value)
  return obj
end

page sample
let title = label!("Hello")
let subtitle = default::h2("Qualified")
let nested = title || (subtitle // label("Below"))
let optional_width = style.marker?.width ?? 0
title || subtitle
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

enum Mode { light dark }
