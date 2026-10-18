import std:text as text_api
import std:code as code_api

type Example { title: String source: String }
fn display(self: Placed<Example>) -> Group<text_api::Text, code_api::Code>
  return group(
    text_api::Text { content = self.value.title },
    code_api::Code { source = self.value.source language = "python" }
  )
end

const example: Example = Example {
  title = "# A typed group"
  source = <<
def twice(value):
    return value * 2
>>
}

page first
  let item = place!(example)
  let body = first(children(item))
  let title = first(children(body))
  let code = first(children(body) - selection(title))
  ~ title.left == page.left + 64
  ~ title.top == page.top - 64
  ~ code.left == title.left
  ~ code.top == title.bottom - 40
end

page reused
  let item = place!(example with { title = "# Reused input, independent children" })
  let body = first(children(item))
  let title = first(children(body))
  let code = first(children(body) - selection(title))
  ~ title.left == page.left + 64
  ~ title.top == page.top - 64
  ~ code.left == title.left
  ~ code.top == title.bottom - 40
end
