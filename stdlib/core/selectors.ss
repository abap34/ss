fn previous_page() -> selection
  return select(pagectx(), "previous_page")
end

fn objects(page_value: page, role_name: string) -> selection
  return select(page_value, "page_objects_by_role", role_name)
end

fn document_pages() -> selection
  return select(docctx(), "document_pages")
end

fn document_objects(role_name: string) -> selection
  return select(docctx(), "document_objects_by_role", role_name)
end
