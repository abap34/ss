import std:themes/default as *

page ok
  h2("Heading", default_theme().h2 with {
    layout.x = 137
    underline.color = c"#a1264f"
    underline.width = 3
  })
end
