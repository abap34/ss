import std:themes/default as *

page ok
  let body = text("## Heading", current_theme() with {
    body.text.size = 19
    h2.text.size = 35
    h2.text.color = c"#157a2b"
    h6.text.size = 17
  })
end
