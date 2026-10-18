import std:themes/default as *
fn label(item: Object) -> String = (item.link_id ?? "missing")
document
  let callback = label
end
document
  let item = body_obj("A")
  let value = callback(item)
  item.link_id = "marked"
  let output = body_obj(value)
  place_on!(new_page(docctx(), "main"), output)
end
