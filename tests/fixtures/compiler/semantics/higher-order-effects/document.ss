import std:themes/default as *
fn label(item: Object) -> String = (item.link_id ?? "missing")
document
  let callback = label
end
document
  let item = text("A")
  let value = callback(item)
  item.link_id = "marked"
  let output = text(value)
  place_on!(new_page(docctx(), "main"), output)
end
