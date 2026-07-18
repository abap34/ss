import std:themes/default as *

page ok
  h2("Heading", current_theme() with {
    h2.layout.x = 137
    h2.underline.color = c"#a1264f"
    h2.underline.width = 3
  })
end
