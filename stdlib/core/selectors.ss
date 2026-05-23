import std:core/classes

fn prev_page() -> page
  return select(pagectx(), "previous_page")
end

fn objs(page_value: page, role_name: string) -> selection<object>
  return select(page_value, "page_objects_by_role", role_name)
end

fn objs_here(role_name: string) -> selection<object>
  return objs(pagectx(), role_name)
end

fn children(base: object) -> selection<object>
  return select(base, "children")
end

fn desc(base: object) -> selection<object>
  return select(base, "descendants")
end

fn doc_pages() -> selection<page>
  return select(docctx(), "document_pages")
end

fn pages(doc: document) -> selection<page>
  return select(doc, "document_pages")
end

fn objs_all(role_name: string) -> selection<object>
  return select(docctx(), "document_objects_by_role", role_name)
end

fn doc_objs(doc: document, role_name: string) -> selection<object>
  return select(doc, "document_objects_by_role", role_name)
end

fn mark(kind_name: string, value_text: string) -> metadata
  return emit_metadata(pagectx(), kind_name, value_text)
end

fn doc_mark(kind_name: string, value_text: string) -> metadata
  return emit_metadata(docctx(), kind_name, value_text)
end

fn doc_marks(doc: document, kind_name: string) -> selection<metadata>
  return metadata_in_document(doc, kind_name)
end

fn page_marks(page_value: page, kind_name: string) -> selection<metadata>
  return metadata_on_page(page_value, kind_name)
end

fn mark_text(item: metadata) -> string
  return metadata_content(item)
end

fn mark_page(item: metadata) -> page
  return metadata_page(item)
end

fn page_of(obj: object) -> page
  return select(obj, "parent_page")
end

fn prop_all(items: selection<object>, key_name: string, value_name: string) -> selection<object>
  set_prop(items, key_name, value_name)
  return items
end

fn style_all(items: selection<object>, style_value: style) -> selection<object>
  items.style = style_value
  return items
end

fn union(left: selection<object>, right: selection<object>) -> selection<object>
  return selection_union(left, right)
end

fn intersect(left: selection<object>, right: selection<object>) -> selection<object>
  return selection_intersection(left, right)
end

fn diff(left: selection<object>, right: selection<object>) -> selection<object>
  return selection_difference(left, right)
end

fn prop_except(items: selection<object>, excluded: selection<object>, key_name: string, value_name: string) -> selection<object>
  let targets = diff(items, excluded)
  set_prop(targets, key_name, value_name)
  return targets
end

fn style_except(items: selection<object>, excluded: selection<object>, style_value: style) -> selection<object>
  let targets = diff(items, excluded)
  targets.style = style_value
  return targets
end
