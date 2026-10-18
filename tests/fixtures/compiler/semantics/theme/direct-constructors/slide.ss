import std:themes/default as *

page ok
  let target = text!("target")
  text!("author", default_theme().byline with { text.size = 29 })
  text!("label", default_theme().label with { text.size = 18 })
  text!("[1] reference", default_theme().citation with { text.size = 16 })
  pageno!(default_theme().page_number with { text.size = 17 })
end
