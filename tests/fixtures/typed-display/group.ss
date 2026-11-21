import std:text as text_api
import std:code as code_api

type Example { title: String source: String }
fn display(self: Placed<Example>) -> Group<text_api::Text, code_api::Code>
  return group(
    text_api::Text { content = text_api::TextContent { source = self.value.title } },
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
  let body = first(select<Group<text_api::Text, code_api::Code>>(item))
  let title = first(select<text_api::Text>(body))
  let code = first(select<code_api::Code>(body))
  ~ title.left == page.left + 64
  ~ title.top == page.top - 64
  ~ code.left == title.left
  ~ code.top == title.bottom - 40
end

page reused
  let item = place!(example with { title = "# Reused input, independent children" })
  let body = first(select<Group<text_api::Text, code_api::Code>>(item))
  let title = first(select<text_api::Text>(body))
  let code = first(select<code_api::Code>(body))
  ~ title.left == page.left + 64
  ~ title.top == page.top - 64
  ~ code.left == title.left
  ~ code.top == title.bottom - 40
end
