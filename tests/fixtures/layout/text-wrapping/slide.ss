import std:themes/default as *

const theme: Theme = default_theme(ThemeOptions {
  font_family = "DejaVu Sans"
}) with {
  body.text.size = 28
  body.text.line_height = 36
}

document
vflow_doc(LayoutPolicy.center)
end

page bullet
let body_content = <<
- 表示がすっきり整う
>>
let body = text!(body_content, theme.body)
end

page ordered
let body_content = <<
1. silver green violet
>>
let body = text!(body_content, theme.body with {
  text.size = 31.25
  text.line_height = 40
})
end

page nested
let body_content = <<
> - 音色がやわらかに響く
>>
let body = text!(body_content, theme.body)
end

page narrow
let body_content = <<
- 表示がすっきり整う
>>
let body = text!(body_content, theme.body)
~ body.width == 160
end
