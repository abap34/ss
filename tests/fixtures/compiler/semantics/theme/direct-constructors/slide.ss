import std:themes/default as *

page ok
  let target = text!("target")
  byline!("author", current_theme().byline with { text.size = 29 })
  label!("label", current_theme().label with { text.size = 18 })
  citation!(1, "reference", current_theme().citation with { text.size = 16 })
  pageno!(current_theme().page_number with { text.size = 17 })
end
