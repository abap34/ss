import std:themes/default as *

page paragraph
let body_content = <<
A paragraph with **bold text**, _underlined text_, and [a link with several words](https://example.com).

An inline ![star](fa:star) keeps its position between the surrounding words as the paragraph wraps.

| Left | Right |
| :--- | ---: |
| Several words wrap inside this cell | ![star](fa:star) beside text |
>>
let body = text!(body_content, default_theme().body with {
  text.size = 24
  text.line_height = 36
  layout.wrap = WrapMode.on
})
~ body.left == page.left + 80
~ body.right == body.left + 320
~ body.top == page.top - 60
end
