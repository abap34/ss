fn mark(doc: Document) -> Void
  doc.layout_h_center_offset = 42
end
fn apply_to(doc: Document, callback: Document -> Void) -> Void = callback(doc)
fn label(doc: Document) -> String
  if doc.layout_h_center_offset == 42
    return "marked"
  end
  return "missing"
end
page main
  text!(label(docctx()))
  apply_to(docctx(), mark)
end
