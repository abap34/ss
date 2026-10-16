import std:themes/default as *

document
theme!(default_theme(ThemeOptions {
  font_family = "DejaVu Sans"
}) with {
  body.text.size = 28
  body.text.line_height = 36
})
vflow_doc(LayoutPolicy.center)
end

page bullet
let body = text! <<
- 表示がすっきり整う
>>
end

page ordered
let body_content = <<
1. silver green violet
>>
let body = text!(body_content, current_theme() with {
  body.text.size = 31.25
  body.text.line_height = 40
})
end

page nested
let body = text! <<
> - 音色がやわらかに響く
>>
end

page narrow
let body = text! <<
- 表示がすっきり整う
>>
~ body.width == 160
end
