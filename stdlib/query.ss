import std:internal/classes

fn previous_page(page_value: Page) -> Page?
  return select(page_value, "previous_page")
end

fn objs(page_value: Page, role_name: String) -> Selection<Object>
  return select(page_value, "page_objects_by_role", role_name)
end

fn objs_here(role_name: String) -> Selection<Object>
  return objs(pagectx(), role_name)
end

fn filter<T>(items: Selection<T>, predicate: T -> Bool) -> Selection<T>
  return selection_filter(items, predicate)
end

fn selection<T>(item: T) -> Selection<T>
  return select(item, "self_placement")
end

fn children(base: Placement) -> Selection<Placement>
  return select(base, "children")
end

fn descendants(base: Placement) -> Selection<Placement>
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
