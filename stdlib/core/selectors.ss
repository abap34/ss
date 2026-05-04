fn previous_page() -> page
  return select(pagectx(), "previous_page")
end

fn objects(page_value: page, role_name: string) -> selection<object>
  return select(page_value, "page_objects_by_role", role_name)
end

fn document_pages() -> selection<page>
  return select(docctx(), "document_pages")
end

fn document_objects(role_name: string) -> selection<object>
  return select(docctx(), "document_objects_by_role", role_name)
end
