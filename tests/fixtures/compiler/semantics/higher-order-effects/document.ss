fn label(doc: Document) -> String
  if doc.layout_h_center_offset == 42
    return "marked"
  end
  return "missing"
end
document
  let callback = label
end
document
  let current = docctx()
  let value = callback(current)
  current.layout_h_center_offset = 42
  let output = text(value)
  place_on!(new_page(docctx(), "main"), output)
end
