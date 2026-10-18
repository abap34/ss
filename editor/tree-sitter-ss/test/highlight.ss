import std:text as *
import std:text as text_module
import std:text/types as { TextStyle }

fn/! label(text_value: String) -> Text
  return text(text_value)
end

page sample
let title = label("Hello")
let subtitle = text_module::text("Qualified")
let nested = title || (subtitle // label("Below"))
let optional_width: Number? = none
let width = optional_width ?? 0
let placed = place!(nested)
if true
  place!(title with { style.text.color = c"#334455" })
else
  place!(title with { style.text.color = c"#111111" })
end
~ placed.left == page.left + 24
~!~placed.center_x
~!~placed.left == page.left + 24
text! <<
body
>>
end

enum Mode { light dark }
