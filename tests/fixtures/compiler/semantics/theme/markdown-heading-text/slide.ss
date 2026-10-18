import std:themes/default as *

page ok
  let body = text!("## Heading", default_text_style with {
    text.size = 19
    headings.h2 = MarkdownHeadingStyle { text = TextStyle { size = 35 color = c"#157a2b" } }
    headings.h6 = MarkdownHeadingStyle { text = TextStyle { size = 17 } }
  })
end
