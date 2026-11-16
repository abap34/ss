import std:themes/default as *

page ok
  let target = text!("target")
  text!("author", default_theme().text with { size = 29 })
  text!("label", default_theme().text with { size = 18 })
  text!("[1] reference", default_theme().text with { size = 16 })
  pageno!(default_theme().text with { size = 17 })
end
