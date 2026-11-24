import std:themes/default as *

const base: Theme = default_theme() with {
  text.size = 26
  text.line_height = 36
  text.color = c"#102a43"
}
const styled: Theme = base with {
  text.markdown.code = InlineCodeAppearance { color = c"#b5485d" fill = c"#f3f4f6" }
}

document
  theme!(styled)
end

page styled
  let body = text! <<
# Heading with `inline_code`

Before `value = left + right` after.

- List with `inline_code`

| Column |
| --- |
| `inline_code` |

==`highlighted_code`==

```text
block_code
```
>>
  ~ body.width == 700
  ~ body.left == page.left + 60
  ~ body.top == page.top - 60
end

page inherited
  let body = text!("Default `inline_code`", base.text)
end

page disabled
  let body = text!("Disabled `inline_code`", styled.text with {
    markdown.code.color = none
    markdown.code.fill = none
  })
end
