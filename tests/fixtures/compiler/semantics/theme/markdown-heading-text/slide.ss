import std:themes/default as *

page ok
  let body = text!("## Heading", default_text_style with {
    size = 19
    headings.h2 = TypographyOverride { size = 35 color = c"#157a2b" }
    headings.h6 = TypographyOverride { size = 17 }
  })
end
