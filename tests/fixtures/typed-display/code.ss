import std:code as code_api
import std:text as text_api
import std:themes/default as base

type Example {
  code: code_api::Code
}

fn display(self: Placed<Example>) -> code_api::Code = self.value.code

const sample: code_api::Code = code_api::Code {
  source = <<
def twice(n):
    # **Literal** $x$ ![image](missing.png)
    return n * 2
>>
  language = "python"
  style = base::default_theme().code with { text.size = 18 }
}

page languages
  let title = place!(text_api::Text { content = "# Highlighted and plain source" })
  let highlighted = place!(sample)
  let plain = place!(sample with { language = "plain" style.text.size = 22 })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ highlighted.left == title.left
  ~ highlighted.top == title.bottom - 32
  ~ plain.left == highlighted.left
  ~ plain.top == highlighted.bottom - 48
end

page wrapped
  let palette = code_api::code_theme_github_dark()
  let dark = sample with {
    style.highlight = palette
    style.chrome.fill = palette.fill
    style.chrome.stroke = palette.stroke
  }
  let title = place!(text_api::Text { content = "# Code returned by a user display" })
  let example = place!(Example { code = dark })
  ~ title.left == page.left + 64
  ~ title.top == page.top - 48
  ~ example.left == title.left
  ~ example.top == title.bottom - 32
end
