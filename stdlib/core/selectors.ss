import std:core/classes as *

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

fn page_of(obj: Object) -> Page
  return select(obj, "parent_page")
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
