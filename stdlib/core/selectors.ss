import std:core/classes

fn prev_page() -> Page
  return select(pagectx(), "previous_page")
end

fn objs(page_value: Page, role_name: String) -> Selection<Object>
  return select(page_value, "page_objects_by_role", role_name)
end

fn objs_here(role_name: String) -> Selection<Object>
  return objs(pagectx(), role_name)
end

fn children(base: Object) -> Selection<Object>
  return select(base, "children")
end

fn desc(base: Object) -> Selection<Object>
  return select(base, "descendants")
end

fn doc_pages() -> Selection<Page>
  return select(docctx(), "document_pages")
end

fn pages(doc: Document) -> Selection<Page>
  return select(doc, "document_pages")
end

fn objs_all(role_name: String) -> Selection<Object>
  return select(docctx(), "document_objects_by_role", role_name)
end

fn doc_objs(doc: Document, role_name: String) -> Selection<Object>
  return select(doc, "document_objects_by_role", role_name)
end

fn mark(kind_name: String, value_text: String) -> Metadata
  return emit_metadata(pagectx(), kind_name, value_text)
end

fn doc_mark(kind_name: String, value_text: String) -> Metadata
  return emit_metadata(docctx(), kind_name, value_text)
end

fn doc_marks(doc: Document, kind_name: String) -> Selection<Metadata>
  return metadata_in_document(doc, kind_name)
end

fn page_marks(page_value: Page, kind_name: String) -> Selection<Metadata>
  return metadata_on_page(page_value, kind_name)
end

fn mark_text(item: Metadata) -> String
  return metadata_content(item)
end

fn mark_page(item: Metadata) -> Page
  return metadata_page(item)
end

fn page_of(obj: Object) -> Page
  return select(obj, "parent_page")
end

fn prop_all(items: Selection<Object>, key_name: String, value_name: String) -> Selection<Object>
  set_prop(items, key_name, value_name)
  return items
end

fn style_all(items: Selection<Object>, style_value: Style) -> Selection<Object>
  items.style = style_value
  return items
end

fn union(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selection_union(left, right)
end

fn intersect(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selection_intersection(left, right)
end

fn diff(left: Selection<Object>, right: Selection<Object>) -> Selection<Object>
  return selection_difference(left, right)
end

fn prop_except(items: Selection<Object>, excluded: Selection<Object>, key_name: String, value_name: String) -> Selection<Object>
  let targets = diff(items, excluded)
  set_prop(targets, key_name, value_name)
  return targets
end

fn style_except(items: Selection<Object>, excluded: Selection<Object>, style_value: Style) -> Selection<Object>
  let targets = diff(items, excluded)
  targets.style = style_value
  return targets
end
