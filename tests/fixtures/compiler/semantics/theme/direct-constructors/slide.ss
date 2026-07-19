import std:themes/default as *

page ok
  let target = text!("target")
  byline!("author", current_theme() with { byline.text.size = 29 })
  label!("label", current_theme() with { label.text.size = 18 })
  citation!(target, 1, "reference", current_theme() with { citation.text.size = 16 })
  pageno!(current_theme() with { generated.pageno.text.size = 17 })
end
