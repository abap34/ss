import std:themes/default as *

page table
let body_content = <<
| Left | Center | Right |
| :--- | :---: | ---: |
| _j_ with underlining | Several words wrap inside a narrow cell | 123 |
| ![star](fa:star) beside text | [A link with several words](https://example.com) | 9 |
| Last row | | end |
>>
let body = text!(body_content, default_theme().body with {
  text.size = 24
  text.line_height = 28
  layout.wrap = WrapMode.on
})
~ body.left == page.left + 80
~ body.right == body.left + 500
~ body.top == page.top - 60
end
