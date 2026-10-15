import std:themes/default as *

page main
  text!("Late theme")
end

document
  theme!(default_theme() with { body.text.size = 22 })
end
