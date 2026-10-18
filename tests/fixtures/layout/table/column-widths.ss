import std:themes/default as *

page fixed_fraction
let body_content = <<
| Name | Description | Notes |
| :---{100pt} | :---:{1fr} | ---:{2fr} |
| Alpha | Several words wrap in the middle column | The final column receives twice as much remaining space |
| ![star](fa:star) Beta | **Formatted** content | 123 |
>>
let body = text!(body_content, default_theme().body with {
  text.size = 24
  text.line_height = 28
  layout.wrap = WrapMode.on
})
~ body.left == page.left + 80
~ body.right == body.left + 600
~ body.top == page.top - 60
end

page automatic
let body_content = <<
| Name | Description | Count |
| :---{auto} | ---{1fr} | ---:{auto} |
| Alpha | This column receives the space left after measuring the other columns | 123 |
| ![star](fa:star) Beta | [A link](https://example.com) | 9 |
>>
let body = text!(body_content, default_theme().body with {
  text.size = 24
  text.line_height = 28
  layout.wrap = WrapMode.on
})
~ body.left == page.left + 80
~ body.right == body.left + 600
~ body.top == page.top - 60
end
